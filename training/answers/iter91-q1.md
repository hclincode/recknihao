# Iter91 Q1 — Answer

**Question**: How do I write a CI test that proves tenant A's service account genuinely cannot read tenant B's rows?

---

## Answer

## The Core Problem

SQL injection, forgotten WHERE clauses, and OPA misconfigurations are all silent by default. A policy can *look* correct on paper and still leak data. You need tests that run before each deploy to prove: "tenant A's service account gets `Access Denied` when trying to read tenant B's rows."

## The Three-Layer Test Stack

Your test should hit three distinct layers. Do not test only one layer — a passing test at the view layer doesn't tell you the access control layer is working.

### Layer 1: The Query Engine (Trino) — Most Important

Run this **from a Trino client in CI** (via the `trino` CLI or Python JDBC). Authenticate as each tenant's service account and verify access boundaries.

**Test 1A: Tenant A cannot read the base table**
```sql
-- Authenticate as: acme-service-account
-- Expected: Access Denied
SELECT count(*) FROM iceberg.analytics.events;
```

**Test 1B: Tenant A can read only their own view**
```sql
-- Authenticate as: acme-service-account
SELECT count(*) FROM iceberg.tenant_acme.events;

-- Critical assertion: view returns ONLY acme's rows
SELECT distinct tenant_id FROM iceberg.tenant_acme.events;
-- Expected: ['acme'] only. If it returns ['acme', 'beta', 'gamma'], the view filter is broken.
```

**Test 1C: Tenant A cannot read Tenant B's view**
```sql
-- Authenticate as: acme-service-account
-- Expected: Access Denied
SELECT count(*) FROM iceberg.tenant_beta.events;
```

**Test 1D: Tenant A cannot access metadata tables**
```sql
-- Authenticate as: acme-service-account
-- Expected: Access Denied (OPA denies all $ tables for tenant principals)
SELECT count(*) FROM iceberg.analytics."events$partitions";

-- Expected: Access Denied
SELECT count(*) FROM system.runtime.queries;
```

These two detect silent leaks where tenants can see other tenants' partition sizes and query history.

### Layer 2: The Application Layer — Middle Importance

Once Trino-layer tests pass, verify your app doesn't accidentally inject the wrong tenant context.

```python
# Verify your app builds queries that land in the scoped view, not the base table
from your_analytics_lib import AnalyticsClient
client = AnalyticsClient(trino_conn=trino_acme_conn)
result = client.query("SELECT count(*) FROM events")
assert result > 0, "Expected acme to have at least some events"
# Layer 1 tests confirm the base table is blocked; Layer 2 confirms the app routes correctly
```

### Layer 3: Audit Trail — Verification Only

```sql
-- Connect as admin/data-team principal
SELECT count(*) as failure_count
FROM iceberg.analytics.query_audit_log
WHERE create_time >= current_timestamp - interval '5' minute
  AND context.user IN ('acme-service-account', 'beta-service-account')
  AND failureInfo.errorCode.name = 'PERMISSION_DENIED';

-- Expected: > 0 (the layer 1 deny tests should have generated entries)
-- If 0: Trino is not logging denials — audit infrastructure is broken
```

## The CI Test File

```python
# tests/security/test_rls_isolation.py
import pytest
import trino

@pytest.fixture
def trino_acme_conn():
    jwt_token = os.environ["ACME_JWT_TOKEN"]
    return trino.dbapi.connect(
        host="trino-coordinator.default.svc.cluster.local",
        port=8080, user="acme-service-account",
        auth=trino.auth.JWTAuthentication(jwt_token),
        catalog="iceberg", schema="analytics",
    )

def test_tenant_cannot_read_base_table(trino_acme_conn):
    with pytest.raises(Exception) as exc_info:
        cursor = trino_acme_conn.cursor()
        cursor.execute("SELECT count(*) FROM iceberg.analytics.events")
        cursor.fetchall()
    assert "Access Denied" in str(exc_info.value) or "PERMISSION_DENIED" in str(exc_info.value)

def test_tenant_view_is_filtered_to_tenant(trino_acme_conn):
    cursor = trino_acme_conn.cursor()
    cursor.execute("SELECT distinct tenant_id FROM tenant_acme.events LIMIT 100")
    tenant_ids = [row[0] for row in cursor.fetchall()]
    assert len(tenant_ids) > 0, "View returned no rows"
    assert all(tid == "acme" for tid in tenant_ids), f"View returned non-acme rows: {tenant_ids}"

def test_tenant_cannot_read_other_tenant_view(trino_acme_conn):
    with pytest.raises(Exception) as exc_info:
        cursor = trino_acme_conn.cursor()
        cursor.execute("SELECT count(*) FROM tenant_beta.events")
        cursor.fetchall()
    assert "Access Denied" in str(exc_info.value) or "PERMISSION_DENIED" in str(exc_info.value)

def test_tenant_cannot_read_metadata_tables(trino_acme_conn):
    with pytest.raises(Exception) as exc_info:
        cursor = trino_acme_conn.cursor()
        cursor.execute('SELECT count(*) FROM iceberg.analytics."events$partitions"')
        cursor.fetchall()
    assert "Access Denied" in str(exc_info.value)
```

## What a Passing Test Proves

If all four layer-1 tests pass:
- OPA is correctly denying cross-tenant reads at query execution time ✓
- The tenant views exist with correct WHERE filters ✓
- The role grants are scoped (tenant A's role has no access to tenant B's view) ✓
- Metadata tables are protected (tenants can't enumerate other tenants) ✓

## What Failure Looks Like

**Base table not blocked:**
```
Test 1A: SELECT count(*) FROM iceberg.analytics.events
Result: 1000000 rows. Expected: Access Denied. FAIL.
```
Fix: Check your OPA policy deny rule for the base table.

**View filter missing:**
```
Test 1B: SELECT distinct tenant_id FROM iceberg.tenant_acme.events
Result: ['acme', 'beta', 'gamma']. Expected: ['acme']. FAIL.
```
Fix: Verify the view's WHERE clause is actually applied.

**Role grants too broad:**
```
Test 1C: SELECT count(*) FROM iceberg.tenant_beta.events AS acme-service-account
Result: 1234 rows. Expected: Access Denied. FAIL.
```
Fix: Verify the acme role has ONLY SELECT on tenant_acme schema, not tenant_beta.

## Key Implementation Details

1. **Use JWT auth in CI** — your production stack uses JWT tokens. In CI, store test JWTs as k8s Secrets, mounted to the test pod environment.
2. **Test against the actual Trino coordinator** — do not mock Trino. Your test pod must connect to `trino-coordinator.default.svc.cluster.local`.
3. **Fail the entire CI pipeline** on any isolation breach — do not log a warning and continue.
4. **Run pre-deploy AND post-deploy** — pre-deploy to block bad changes, post-deploy as a smoke test.
