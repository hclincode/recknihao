# Iter66 Q2 — Answer

**Question**: We're expecting to sign 20-30 new customers this quarter and I want to automate the process of getting them set up to query their analytics data. Right now when a new customer signs up, someone on the data team manually creates a Trino role for them, sets up a view that filters data to their tenant_id, and then updates some access control config. It usually takes a day or two and sometimes things get missed. I want this to happen automatically the moment a customer account is created in our app — ideally within seconds. What does that automated provisioning workflow actually look like? What are the specific steps in the right order, and what systems need to be updated so the new tenant can run queries immediately without any manual intervention?

---

## Answer

This is a 6-step workflow that your provisioning service runs in order every time a customer signs up. Done correctly, the whole thing completes in under 10 seconds and the new tenant can query their data immediately. The key is doing the steps in the right order — some steps depend on earlier ones, and skipping any step creates a silent failure that looks like success.

### The 6 steps in order

**Step 1: CREATE ROLE**

```sql
CREATE ROLE IF NOT EXISTS acme_role;
```

This creates a named permission bundle — nothing more. No user has it yet. `IF NOT EXISTS` makes this idempotent: if provisioning is re-triggered for the same tenant, this step is a no-op instead of an error.

**Step 2: GRANT ROLE TO USER**

```sql
GRANT ROLE acme_role TO USER "acme-service-account";
```

This assigns the role to the tenant's service account (the JWT principal they use to authenticate). This step has no `IF NOT EXISTS` equivalent — if you run it twice, Trino may raise an error that the grant already exists. Your provisioning code should catch "already granted" errors and treat them as success.

**Why this order matters**: The role must exist before you can grant it. But more importantly, this step is the one most commonly skipped — and if it's skipped, the tenant gets "Access Denied" on every query even though everything else is set up correctly. The role exists, the view exists, but nobody holds the role.

**Step 3: CREATE VIEW with hard-coded tenant filter**

```sql
CREATE OR REPLACE VIEW iceberg.tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM iceberg.analytics.events
  WHERE tenant_id = 'acme';
```

The `WHERE tenant_id = 'acme'` filter is baked into the view definition. The tenant cannot remove or bypass it. Use `CREATE OR REPLACE` for idempotency. Create one view per Iceberg table the tenant needs to access — if you have `analytics.events`, `analytics.orders`, and `analytics.users`, create three views.

Put tenant views in a dedicated schema (`iceberg.tenant_acme`) so they can never accidentally reference a different tenant's view by a name collision.

**Step 4: GRANT SELECT ON VIEW TO ROLE**

```sql
GRANT SELECT ON iceberg.tenant_acme.events TO ROLE acme_role;
```

This gives the role — and therefore the tenant — read access to their view. The base table (`analytics.events`) is not mentioned here and remains inaccessible to the role.

**Step 5: REVOKE direct base-table access**

```sql
REVOKE ALL PRIVILEGES ON iceberg.analytics.events FROM USER "acme-service-account";
```

This is the step most teams miss. By default, Trino's built-in access control allows all users to read all tables unless explicitly restricted. Even though you haven't granted the tenant access to the base table, they may still be able to query it under default allow-all settings.

If you skip this step, a tenant can run `SELECT * FROM analytics.events` and see every customer's data — bypassing the view's filter entirely.

On your production stack with OPA as the authorization backend, the OPA policy is what enforces this restriction. The OPA policy must explicitly deny base-table SELECT for tenant service account principals. Your infrastructure team manages OPA policy deployment via the centralized governance document. But your provisioning service should still include the Trino SQL REVOKE as a belt-and-suspenders measure.

**Step 6: Block access to the system catalog and Iceberg metadata tables (OPA)**

Even with the view-only pattern, two additional leaks require OPA policy coverage:

1. **`system.runtime.queries`**: Without explicit denial, the tenant can query this and see every other tenant's SQL text and query metadata. The OPA policy must deny the `system` catalog to tenant principals entirely.

2. **Iceberg `$`-suffixed metadata tables** (`events$partitions`, `events$files`, etc.): These reveal internal storage layout, file paths, and partition data — effectively exposing which other tenants exist and their data volumes. The OPA policy must deny access to any table name containing `$` for tenant principals.

These are policy-level controls your infrastructure team deploys separately from your provisioning script. Your provisioning service assumes these policies are already in place. Your CI test suite must verify them (see verification section).

### How to automate this from your application

Your provisioning service is a microservice that runs when a customer account is created.

**Architecture:**
- Customer signup in your SaaS app fires an internal event (webhook, message queue, or direct HTTP call)
- The provisioning service receives the `tenant_id` and `service_account` for the new customer
- The provisioning service authenticates to Trino with admin JWT credentials
- It executes the 6 SQL steps above in order
- On completion, it signals your SaaS app that the tenant is ready to query

**Connecting to Trino programmatically:**

```python
import trino

conn = trino.dbapi.connect(
    host="trino-coordinator.internal",
    port=8443,
    auth=trino.auth.JWTAuthentication(admin_jwt_token),
    http_scheme="https",
)
cursor = conn.cursor()

def provision_tenant(tenant_id: str, service_account: str):
    role_name = f"{tenant_id}_role"
    schema_name = f"tenant_{tenant_id}"

    steps = [
        f"CREATE ROLE IF NOT EXISTS {role_name}",
        f'GRANT ROLE {role_name} TO USER "{service_account}"',
        f"""CREATE OR REPLACE VIEW iceberg.{schema_name}.events AS
              SELECT * FROM iceberg.analytics.events
              WHERE tenant_id = '{tenant_id}'""",
        f"GRANT SELECT ON iceberg.{schema_name}.events TO ROLE {role_name}",
        f'REVOKE ALL PRIVILEGES ON iceberg.analytics.events FROM USER "{service_account}"',
    ]

    for sql in steps:
        try:
            cursor.execute(sql)
        except trino.exceptions.TrinoUserError as e:
            if "already" in str(e).lower():
                pass  # Idempotent — grant already exists
            else:
                raise RuntimeError(f"Provisioning failed at step: {sql}") from e
```

**Error handling is critical**: If any step raises an unexpected error, the provisioning service must fail loudly and return an error to the SaaS app. The SaaS app should surface this to the ops team. A partial provisioning (steps 1-3 completed, step 4 failed) leaves the tenant in a broken state where the view exists but the role cannot read it.

### What goes wrong if steps are out of order or skipped

| Skipped step | Symptom | How it manifests |
|---|---|---|
| Step 2 (GRANT ROLE TO USER) | Tenant gets "Access Denied" on all queries | The role exists but nobody holds it |
| Step 4 (GRANT SELECT ON VIEW) | Tenant gets "Access Denied" on view queries | The view exists but the role cannot read it |
| Step 5 (REVOKE base table) | Security breach — tenant can read all tenants' data | `SELECT * FROM analytics.events` succeeds and returns all rows |
| Step 6 (OPA system catalog) | Tenant can see all other tenants' query history | `SELECT * FROM system.runtime.queries` succeeds |

Steps 2 and 4 cause visible failures the tenant will report. Steps 5 and 6 are silent security breaches that the tenant will likely never report — they are the dangerous ones.

### Verifying the new tenant is correctly provisioned

After provisioning, your CI/test suite must run these checks as the tenant's service account:

```sql
-- Should succeed — returns their data
SELECT COUNT(*) FROM iceberg.tenant_acme.events;

-- Should fail with Access Denied — base table off-limits
SELECT COUNT(*) FROM iceberg.analytics.events;

-- Should fail with Access Denied — other tenant's view off-limits
SELECT COUNT(*) FROM iceberg.tenant_beta.events;

-- Should fail with Access Denied — system catalog blocked
SELECT COUNT(*) FROM system.runtime.queries;

-- Should return only 'acme' — no cross-tenant data in view
SELECT DISTINCT tenant_id FROM iceberg.tenant_acme.events;
```

Run these checks automatically after every provisioning operation. If any check fails, fail the deployment and alert the ops team before the customer is activated. The last check (distinct tenant_id) is especially important: if the view filter is wrong, this query reveals the breach even before a real user queries.

### End-to-end timing

From customer signup to ready state: **under 10 seconds**.
- 6 SQL DDL statements against Trino: typically 1-3 seconds total
- CI verification checks: 2-5 seconds
- Total: customer receives "Your analytics access is ready" notification in under 10 seconds

No manual intervention. No day-long delays. No missed steps.
