# Answer to Q2: View-per-Tenant vs OPA Row-Level Filtering at Scale (Iter 320)

At 200 tenants, you're in the middle of a critical scaling decision. The view-per-tenant approach starts to strain operationally — though not necessarily in raw query performance. Let me break down what actually changes and when it breaks.

## The Real Performance Picture

**Query performance: minimal difference.** Neither approach is inherently faster at runtime. A query against a tenant-scoped view and a query against a shared table with OPA's row filter both:
- Scan the same Iceberg table and partition structure
- Filter to the same tenant's rows in roughly the same way
- Produce identical execution plans

The difference is *where and when* the filtering happens — in the view's hardcoded WHERE clause vs. in OPA's policy rule — but Trino's query planner optimizes both paths identically.

**Where it breaks: operational overhead, not query latency.** The scaling problem hits you in three places as you move from 200 toward 1,000 tenants:

1. **Catalog listing slowdown.** Every `SHOW TABLES` query and every IDE/client that introspects your schema crawls through Hive Metastore listings. With 200+ tenant schemas (one per tenant with per-tenant views), each listing operation becomes slower. By 1,000 tenants, this becomes a genuine planner bottleneck — not in terms of query execution, but in terms of how long it takes Trino's coordinator to build query plans for common introspection queries.

2. **Schema migration becomes a manual audit nightmare.** When you add a column to your base `analytics.events` table, you must update the view definition for *every tenant* to either expose the new column or explicitly exclude it. At 200 tenants, this is a scripted deploy. At 500+ tenants, it's a deploy step that eats meaningful CI/CD time, and the risk of accidentally missing a view or misconfiguring one grows.

3. **Onboarding becomes a deployment artifact.** Adding tenant #201 is no longer "create a user in the auth system" — it's "create a view, create a role, grant the role, then update and redeploy your infrastructure code." This shift makes high-churn scenarios (many adds/removals per week) operationally expensive.

## When View-per-Tenant Still Works

- **1–50 tenants**: Use views. Trivial to provision.
- **50–200 tenants**: Views still work. This is where you are — it's tractable for onboarding and catalog operations are acceptable.
- **200+**: Migrate to OPA row filters. The operational pain becomes real.
- **1,000+**: Views become a planner bottleneck on every schema change.

The **200-tenant threshold is a rule of thumb, not a hard rule.** Two modifiers matter:

- **If you have high tenant churn** (50+ adds/removals per week), migrate earlier.
- **If growth is stable and slow**, views can stretch further.

## What Switching to OPA Row Filters Actually Buys You

The operational wins are concrete:

1. **One shared table, one Rego policy rule.** When you add a column to `analytics.events`, it's visible to all tenants automatically — no view-by-view audit. The isolation enforcement lives entirely in OPA's policy.

2. **Tenant onboarding becomes a config entry.** Adding tenant #201 is a single row in your principal-to-tenant mapping (a Rego rule or data structure OPA evaluates), not a SQL DDL change.

3. **Catalog listings are fast again.** Trino sees one physical table `analytics.events` instead of hundreds of tenant-scoped schemas and views.

## The OPA Row-Filter Mechanism

When OPA's row-filter mode is enabled, here's what happens:

1. Tenant queries `SELECT * FROM analytics.events`.
2. Trino's coordinator asks OPA: "Can this user see this table?"
3. OPA responds with a **row-filter expression**: `{"rowFilters": [{"expression": "tenant_id = 'acme'"}]}`
4. Trino's planner **injects that WHERE clause into the plan** automatically.
5. Only the tenant's rows are scanned and returned.

From the application's perspective: there's no `WHERE tenant_id = ?` in your SQL. OPA enforces it transparently. If you forget the filter in application code, Trino still only returns the calling tenant's rows.

## The OPA Latency Concern

OPA row filters do add a small latency cost per query because Trino makes an HTTP call to OPA during query analysis. However:

- This is a **one-time analysis-phase cost per query**, not a per-row cost.
- For typical network latencies (single-digit milliseconds on-prem), the overhead is negligible compared to data scanning.
- If OPA latency becomes visible, you can optimize using OPA's **batch endpoint** (`opa.policy.batched-uri`), which collapses multiple filter checks into a single HTTP round-trip.

## Recommendation: Plan the Migration Now

1. **Now (200 tenants)**: Continue with views. You're in the comfort zone.
2. **At 200–250 tenants**: Start the migration plan. Write your OPA row-filter Rego rules and test them in a staging environment against a subset of tenants.
3. **Before 300 tenants**: Run both patterns in parallel during a cutover period to build confidence.
4. **At 300+ tenants**: Fully switch to OPA row filters.

The migration requires:
- Rewriting your OPA policy to include the row-filter rule
- Updating your principal-to-tenant mapping data structure
- Testing that every tenant can see only their own rows: CI assertion `SELECT DISTINCT tenant_id FROM analytics.events` returns exactly one value per tenant principal
- Running both patterns side-by-side during cutover

**Bottom line:** OPA row filters are not faster — they're easier to manage at scale. At 200 tenants, you're not broken yet, but start planning the switch for when you reach 250–300. The operational overhead, not query latency, is what kills the view pattern.
