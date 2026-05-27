# Answer to Q1: OPA Row-Filter Alternative to Per-Tenant Views at 200+ Tenant Scale (Iter 312)

Yes, the view-per-tenant approach does become a real operational problem at scale, though not in the way you might initially think. The bottleneck isn't query performance or Trino itself — it's the management overhead and catalog complexity of maintaining hundreds of view definitions.

## The Problem with View-Per-Tenant at 200+ Tenants

1. **Schema change friction.** Every time you modify the base `analytics.events` table schema (add a column, change a type), you need to verify and potentially update every single tenant view. At 80 tenants this is tedious; at 200+ it becomes a blocker in your deployment pipeline.

2. **Catalog listing becomes slow.** `SHOW TABLES` or `SHOW SCHEMAS` on your Hive Metastore reads through all those tenant schemas and views. Clients start timing out or feeling sluggish.

3. **Onboarding automation becomes non-trivial.** Adding tenant #81 means generating and executing a `CREATE VIEW` statement, provisioning a role, and granting permissions. At 500 tenants, that's real operational complexity.

## The OPA Row-Filter Alternative

Instead of separate views, you have:
- ONE physical table: `analytics.events` with a `tenant_id` column
- ONE static OPA policy rule that injects a WHERE clause automatically

When a tenant queries `SELECT * FROM analytics.events`, OPA intercepts that query at analysis time and rewrites it to `SELECT * FROM analytics.events WHERE tenant_id = 'their-tenant-id'`. The rewrite happens transparently — your application doesn't change, the query doesn't include the filter, OPA adds it. Only their rows ever leave the engine.

## What "Configure OPA to Do Something Smarter" Actually Means

OPA has a **row-filter mode** (distinct from its allow/deny mode). Instead of returning just yes/no, OPA returns a SQL WHERE fragment that Trino automatically injects into the query plan. The mechanics:

1. Your Trino OPA plugin configuration includes an extra property pointing to the row-filter endpoint:
   ```
   opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters
   ```

2. You write a Rego rule in OPA that says: "for principal `acme--svc` querying table `analytics.events`, return the filter `tenant_id = 'acme'`."

3. Onboarding tenant #81 means adding one row to your principal-to-tenant mapping (encode it in the username like `tenant-81--svc`, or add a line to an OPA data bundle JSON file). **No SQL DDL.**

## When to Migrate

| Tenant count | Recommendation |
|---|---|
| 1–50 | Per-tenant views — clean, simple, easy to debug |
| 50–200 | Per-tenant views still work fine. Your 80-tenant setup is in the comfortable zone. |
| 200+ | Migrate to OPA row filters. Operational pain outweighs engineering cost of switching. |
| 500+ | OPA row filters are essentially mandatory. Per-tenant views become a planner bottleneck. |

The 200-tenant threshold is a rule of thumb, not a hard line. If your tenants are stable and your schema rarely changes, views can stretch past 200. If you're adding 50+ tenants per week or deploying schema changes daily, migrate earlier.

## The Security Requirement

OPA row filters move the isolation boundary from the SQL layer (the view's WHERE clause) to the policy layer (the Rego rule). The critical requirement is the same: you must test that a tenant principal running `SELECT DISTINCT tenant_id FROM analytics.events` returns only their own tenant ID, and an admin principal sees all of them. Make this a CI test and run it on every OPA policy change.

## The Migration Path

It's non-trivial but doable:
1. Write the OPA row-filter Rego rule (your external governance document covers the specific syntax)
2. Set up a principal-to-tenant mapping (encode in JWT/username like `tenant-id--svc`, or maintain a JSON bundle mapping usernames to tenants)
3. Run both patterns in parallel during cutover — queries can use either the old view or the new filtered table
4. Verify with CI tests that every tenant still sees only their data under the new rule
5. Switch client connections from the views to the base table, then drop the views

The schema change is free. The migration is the one-time cost.
