# Iter59 Q1 — Answer

**Question**: Our security auditor isn't satisfied with "we have views and Trino access control in place." She wants us to write an automated test — something that runs in CI — that actually proves Tenant A's credentials cannot read Tenant B's data. She wants evidence, not documentation. I have no idea how you would even write a test like that for a query engine. What does that test look like, where does it live, and how do we run it as part of our pipeline?

---

## Answer

The test is straightforward: connect to Trino using Tenant A's actual service account credentials, try to query Tenant B's data, and assert that the query raises an **Access Denied exception** — not that it returns zero rows.

### Why zero rows is not the same as access denied

This is the critical distinction the auditor is implicitly asking for. If your row-level filter or view silently returns empty results instead of rejecting the query, the test passes incorrectly. Isolation is broken, but the test can't see it. You must assert on the **exception type**, not the result set.

```python
# WRONG — silent bypass passes the test incorrectly
result = cursor.execute("SELECT * FROM tenant_b.events")
assert result.rowcount == 0  # passes even if isolation is broken by a filter bug

# CORRECT — assert the query was REJECTED
with pytest.raises(trino.exceptions.TrinoQueryError) as exc_info:
    cursor.execute("SELECT * FROM tenant_b.events")
assert "Access Denied" in str(exc_info.value)
```

### Test credentials setup

Use the same Trino roles and service accounts as production. If production uses JWT tokens where each tenant authenticates via a service account (e.g., `acme-service-account`, `globex-service-account`), your CI environment must mirror that RBAC exactly.

For a staging environment:
1. Create two Trino service accounts: `test-tenant-a` and `test-tenant-b`
2. Grant each account exactly the roles they'd have in production: access to their own views, no access to the other tenant's view or the shared base table
3. Generate JWT tokens for each (or use username/password if using file-based auth in staging)
4. Store tokens as CI secrets

The point is that the test uses the **real auth mechanism** — not a superuser or admin bypass. Testing as admin proves nothing about tenant isolation.

### The three tests

```python
# tests/integration/test_trino_tenant_isolation.py

import pytest
import trino

TRINO_HOST = "trino-staging.internal"
TRINO_PORT = 443

def get_cursor(user: str, token: str):
    conn = trino.dbapi.connect(
        host=TRINO_HOST,
        port=TRINO_PORT,
        user=user,
        http_scheme="https",
        auth=trino.auth.JWTAuthentication(token),
    )
    return conn.cursor()

def test_tenant_a_can_read_own_view(tenant_a_cursor):
    """Tenant A can read their own scoped view — baseline sanity check."""
    tenant_a_cursor.execute("SELECT COUNT(*) FROM tenant_a.events")
    rows = tenant_a_cursor.fetchall()
    assert rows[0][0] >= 0  # any result is fine; we just need no exception

def test_tenant_a_cannot_read_tenant_b_view(tenant_a_cursor):
    """Tenant A querying Tenant B's view must raise Access Denied, not return zero rows."""
    with pytest.raises(trino.exceptions.TrinoQueryError) as exc_info:
        tenant_a_cursor.execute("SELECT * FROM tenant_b.events LIMIT 1")
    assert "Access Denied" in str(exc_info.value), (
        f"Expected Access Denied but got: {exc_info.value}"
    )

def test_tenant_a_cannot_read_base_table(tenant_a_cursor):
    """Tenant A must not be able to query the shared base table directly."""
    with pytest.raises(trino.exceptions.TrinoQueryError) as exc_info:
        tenant_a_cursor.execute("SELECT * FROM iceberg.analytics.events LIMIT 1")
    assert "Access Denied" in str(exc_info.value), (
        f"Expected Access Denied but got: {exc_info.value}"
    )

@pytest.fixture
def tenant_a_cursor():
    return get_cursor("test-tenant-a", TOKEN_TENANT_A)

@pytest.fixture
def tenant_b_cursor():
    return get_cursor("test-tenant-b", TOKEN_TENANT_B)
```

### View-level vs base-table access: two distinct failure modes

The auditor needs both tested separately:

- **View-level test**: Tenant A tries `SELECT FROM tenant_b.events` (Tenant B's scoped view). This catches misconfigured schema-level grants.
- **Base-table test**: Tenant A tries `SELECT FROM iceberg.analytics.events` directly. This catches cases where a tenant's role was accidentally granted SELECT on the base table instead of only their view.

Both must fail with Access Denied. A role that can see the base table breaks multi-tenant isolation completely, regardless of whether the views filter correctly.

### Additional tests worth adding

```python
def test_tenant_a_cannot_see_system_queries_from_tenant_b(tenant_a_cursor):
    """Tenant A should not see Tenant B's in-flight queries via system catalog."""
    tenant_a_cursor.execute(
        "SELECT query FROM system.runtime.queries WHERE user = 'test-tenant-b'"
    )
    rows = tenant_a_cursor.fetchall()
    assert len(rows) == 0  # or raises Access Denied depending on Trino config

def test_tenant_a_cannot_read_metadata_tables(tenant_a_cursor):
    """Tenant A cannot read Iceberg metadata tables on the base table."""
    with pytest.raises(trino.exceptions.TrinoQueryError) as exc_info:
        tenant_a_cursor.execute(
            'SELECT * FROM iceberg.analytics."events$partitions" LIMIT 1'
        )
    assert "Access Denied" in str(exc_info.value)
```

Metadata tables (`events$partitions`, `events$files`, `events$snapshots`) are readable by anyone who can SELECT on the base table. If a tenant gets access to them, they can enumerate partition values — which leaks `tenant_id` ranges even without reading actual event data.

### Where the test lives and how CI runs it

**File location**: `tests/integration/test_trino_tenant_isolation.py`

**When it runs**: After the Trino staging environment is up and RBAC is configured. This is an integration test — it cannot run against a mock, because the whole point is that the real auth mechanism rejects the queries.

**GitHub Actions example**:

```yaml
jobs:
  trino-isolation-test:
    runs-on: self-hosted  # needs VPN/internal network access to Trino staging
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        run: pip install trino pytest
      - name: Run tenant isolation tests
        env:
          TOKEN_TENANT_A: ${{ secrets.CI_TENANT_A_JWT }}
          TOKEN_TENANT_B: ${{ secrets.CI_TENANT_B_JWT }}
        run: pytest tests/integration/test_trino_tenant_isolation.py -v
```

If CI runs in Kubernetes, use a Job that runs against the staging Trino cluster — same credentials, same RBAC rules, no mocking.

### What the auditor gets

A CI artifact showing:
- `test_tenant_a_can_read_own_view` — PASSED
- `test_tenant_a_cannot_read_tenant_b_view` — PASSED (exception raised, Access Denied confirmed)
- `test_tenant_a_cannot_read_base_table` — PASSED (exception raised, Access Denied confirmed)

If any of these fail, the CI pipeline blocks the merge. Isolation is enforced continuously, not just documented once.
