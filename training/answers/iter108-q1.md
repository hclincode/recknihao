# Iter108 Q1 — Answer

**Question**: Our product analytics team — internal people, not customers — wants to run cross-tenant reports: things like "which of our 80 customers had the biggest drop in active users this month" or "what is the median session length across all tenants this week." Right now we have Trino set up so that each customer-facing dashboard query is scoped to that tenant's data, which is good. But that means our internal team is also blocked from querying across tenants. If I give them access to the underlying Iceberg tables directly, I'm worried I'm blowing a hole in the isolation model we set up. Is there a standard way to give internal teams cross-tenant access on the same Trino cluster without letting that access bleed over into what customers can see? Or do we need completely separate tables or a separate cluster just for internal reporting?

---

## Answer: Cross-Tenant Internal Reporting Without Blowing Your Isolation Model

Good news: the production stack you have (Trino + Iceberg + OPA) has a standard, proven pattern for exactly this. You don't need a separate cluster or separate tables for internal reporting. Instead, **give your internal data team a different Trino principal with explicit access to the unfiltered base tables, while keeping customer-facing access scoped through the per-tenant views and OPA policies you already have.**

Here's how to think about it:

### The core principle: Different principals for different access patterns

Your current setup likely looks like:
- **Customer-facing queries**: run as a tenant principal (e.g., `acme-service-account`) → can only access `tenant_acme.events` view → WHERE clause baked in → OPA enforces it
- **Ingestion**: runs as `spark-ingest` → can INSERT/DELETE on base tables only, never SELECT

For **internal reporting**, add a third principal:
- **Internal data team**: runs as `data-team` → **explicit OPA allow-rule to SELECT the unfiltered base tables** → can run cross-tenant queries like `SELECT tenant_id, COUNT(*) FROM analytics.events WHERE ...`

This is not a data isolation hole because **it's a different identity**, with different OPA policy rules. Customer code never uses the `data-team` credential; internal analysts do.

### How to implement it (the three-step pattern)

**Step 1: Create an internal data-team principal in your OPA policy**

Your production stack uses OPA as the Trino authorization backend. Update your OPA Rego bundle to:
- Allow `data-team` principal SELECT on `iceberg.analytics.events` (the unfiltered base table)
- Deny it access to customer-facing schemas and per-tenant views (to prevent footguns)
- Deny `data-team` access to the `system` catalog (same as customer principals — the `system.runtime.queries` table exposes all tenants' SQL)

The specific Rego rules live in your external governance document. The shape is: if `principal == "data-team"` and `table == "iceberg.analytics.events"`, return `allow: true`.

**Step 2: Create a separate Kubernetes ServiceAccount for your data team**

Your data team uses a short-lived JWT minted by your auth service with `sub: "data-team"` to connect to Trino. The JWT claim carries an internal-only identity, not a tenant_id:

```json
{
  "sub": "data-team",
  "role": "internal-analytics"
}
```

In an OPA-backed Trino deployment, the backend service presents per-request identity via the HTTP `X-Trino-User` header (impersonation) or a per-request JWT — not 80 separate connection pools. One pool, per-request principal switching.

**Step 3: Data team queries the unfiltered base table directly**

```sql
-- "Which of our 80 customers had the biggest drop in active users this month?"
SELECT
  tenant_id,
  DATE_TRUNC('month', event_ts) AS month,
  COUNT(DISTINCT user_id) AS active_users
FROM iceberg.analytics.events  -- base table, not a per-tenant view
WHERE event_ts >= CURRENT_DATE - INTERVAL '2' MONTH
GROUP BY tenant_id, month
ORDER BY month DESC, active_users DESC;

-- "What is the median session length across all tenants this week?"
SELECT
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY session_length_ms) AS median_session_ms
FROM iceberg.analytics.events
WHERE event_ts >= CURRENT_DATE - INTERVAL '1' WEEK;
```

### Why this doesn't blow the isolation model

- **Customer queries still go through per-tenant views and OPA rules.** Your existing customer-facing Trino principal can only SELECT `tenant_acme.events`, never `iceberg.analytics.events` directly. OPA denies any attempt to bypass the view. Nothing changes for customers.

- **The data-team principal is a separate identity with its own OPA policy.** Even if a customer somehow obtained a `data-team` JWT (a deployment bug), they still can't query another customer's data through the existing per-tenant views — and OPA denies base-table access to all non-internal principals.

- **Defense-in-depth.** OPA policy says "only data-team can read the base table" AND the customer principal's role only grants SELECT on the view. Two layers of defense.

### Block metadata table leaks for internal team too

OPA should also deny `data-team` access to:
- **`events$partitions` / `events$files`**: expose per-tenant data volumes — denied by OPA for all non-ingestion principals
- **`system.runtime.queries`**: shows all queries running on the cluster including other tenants' SQL

### Control internal query load with resource groups

Internal cross-tenant queries (scanning all 80 tenants' partitions) are heavier than per-tenant queries. Put `data-team` in its own Trino resource group to prevent a full-table scan from starving customer queries:

```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 200,
    "subGroups": [
      {"name": "internal", "softMemoryLimit": "30%", "hardConcurrencyLimit": 10},
      {"name": "tenant_acme", "softMemoryLimit": "10%", "hardConcurrencyLimit": 5}
    ]
  }],
  "selectors": [
    {"user": "data-team", "group": "global.internal"},
    {"user": "acme-service-account", "group": "global.tenant_acme"}
  ]
}
```

This goes in `etc/resource-groups.json` (not the `.properties` file, which only points to the JSON config).

### What you do NOT need to do

- **Do not expose base tables to customers.** Never change this — it's the core of your isolation model.
- **Do not give internal team members a customer-scoped view with looser filtering.** They get the unfiltered base table, not a weakened customer view.
- **Do not run a separate cluster or maintain separate tables.** One table, one OPA policy with a data-team carve-out, done.

### Key gotcha: OPA row-filter mode

If your OPA policy uses row-filter mode (automatically injecting `WHERE tenant_id = 'acme'` into customer queries), explicitly carve out the `data-team` principal so it does NOT get a row filter injected. The policy should: "if principal is data-team, return no row filter; if principal is any other tenant, return `tenant_id = '<their_tenant>'`."

---

**Bottom line:** You already have the isolation primitives in place. Extend your OPA policy to grant `data-team` base-table access, give your internal team a separate JWT credential with `sub: "data-team"`, cap their resource usage with a resource group, and you're done. No separate tables, no separate cluster, no hole in the model.
