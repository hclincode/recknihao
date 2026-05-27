# Iter75 Q1 — Answer

**Question**: We have a shared Iceberg table with `tenant_id` column (200 tenants, growing 15-20/month). A senior engineer argues for separate-schema-per-tenant instead. What are the actual trade-offs, and when does each approach make sense?

---

## Answer

There's no single right answer — only trade-offs based on your constraints. Here's an honest comparison across the dimensions that matter most, followed by a concrete recommendation for your situation.

### The two models

**Model 1: Shared table** — all tenants in one `analytics.events` table with `tenant_id` column, partitioned by `(tenant_id, day(...))`. Isolation enforced via Trino views + OPA.

**Model 2: Separate schema per tenant** — `acme.events`, `beta.events`, etc. Schema boundary is the isolation boundary; OPA still required for enforcement.

### Isolation guarantees

Your senior engineer's argument ("separate schemas means data can't bleed") is partially true but mostly a false sense of security. In Model 2, Trino has no inherent mechanism preventing `acme_role` from querying `beta.events` — OPA must still explicitly block this. With Model 1, the same OPA enforcement ensures the same isolation. Both models require the same enforcement work.

The key difference: **Model 1 with Trino views + SECURITY INVOKER gives you defense in depth**. A bug in the view's `WHERE tenant_id = 'acme'` clause still can't expose other tenants' data because the tenant's role has no base-table access at all. In Model 2, a misconfigured OPA rule directly exposes tenant data with no second guard.

### Schema evolution — Model 1 wins decisively

At 200 tenants (and growing to 400+ in two years), schema evolution is the most important dimension.

**Model 1:** One `ALTER TABLE analytics.events ADD COLUMN new_field VARCHAR` applies immediately. Old Parquet files get NULL for the new column automatically (Iceberg handles this). Done in seconds.

**Model 2:** The same change requires 200 `ALTER TABLE` statements — one per tenant schema. A common approach is a Spark job that batches them, but you still have to track which tenants completed migration, handle the new tenants who signed up during the migration window, and monitor for schema drift ("why does tenant 327 have 52 columns but tenant 401 has 51?"). Schema drift is a real operational burden at scale.

### Cross-tenant analytics

When your product team asks "who are our top 10 customers by usage?" or "total events across all tenants this month?"

**Model 1:** Simple: `SELECT tenant_id, COUNT(*) FROM analytics.events GROUP BY tenant_id ORDER BY 2 DESC LIMIT 10`. Partition pruning works correctly. No complexity.

**Model 2:** Either a 200-way `UNION ALL` (which someone must maintain as tenants are added) or a separate aggregation job that pre-computes cross-tenant rollups nightly. Both add complexity and maintenance burden.

### Hive Metastore overhead at scale

The Hive Metastore stores metadata for every table and partition. This is often overlooked until it becomes a problem.

**Model 1:** ~10–20 fact tables + dimension tables. The metastore stays small and fast indefinitely.

**Model 2:** 10 tables per tenant × 200 tenants = 2,000 metastore entries today. At 400 tenants: 4,000. Hive Metastore performance degrades with thousands of tables: listing tables in a namespace slows, schema inference at query planning time slows, Spark ingest jobs wait on metastore responses. You'll need workarounds (separate metastore instances per tier) well before you reach 1,000 tenants.

### Query performance

In practice, Model 1 with `(tenant_id, day(...))` partitioning performs nearly identically to Model 2 for per-tenant queries. Trino + Iceberg hidden partitioning means the view's `WHERE tenant_id = 'acme'` filter causes Iceberg to skip every file not in Acme's partition. The overhead is negligible. The real performance lever is resource groups (per-tenant concurrency caps) — not table layout.

### GDPR purge complexity

Both models handle purges cleanly:
- Model 1: `DELETE FROM analytics.events WHERE tenant_id = 'acme'` + `rewrite_data_files` + `expire_snapshots` + `remove_orphan_files`
- Model 2: `DROP SCHEMA acme CASCADE` — simpler for offboarding, just delete the schema

This dimension roughly ties, with Model 2 having a slight edge for tenant offboarding.

### When to choose each model

**Choose Model 1 (shared table) when:**
- 50–500+ tenants and growing — schema evolution overhead in Model 2 becomes prohibitive
- Schema changes happen regularly (new event types, new fields)
- You need cross-tenant internal analytics without complex orchestration
- You want to avoid Hive Metastore bloat at scale

**Choose Model 2 (separate schema) when:**
- < 50 tenants with slow expected growth
- Contractual/regulatory requirement for physical separation (HIPAA, financial services)
- Tenant needs to take their full dataset on offboarding (drop schema = clean export)
- Tenants have wildly different retention policies requiring per-schema management

### Your situation: 200 tenants, 15–20/month growth → use Model 1

At your scale and growth rate, Model 1 is clearly the right choice:

1. Schema evolution happens often; 200+ ALTER statements per change is untenable
2. Metastore at 2,000 tables today, 4,000+ in two years — you'll hit performance problems
3. Internal cross-tenant analytics are simpler
4. The isolation guarantee from separate schemas is illusory without OPA anyway — you need OPA regardless, and with OPA + SECURITY INVOKER views, Model 1 is equally safe

### Implementing Model 1 correctly

```sql
-- Shared base table (admin access only)
CREATE TABLE analytics.events (
  event_id    VARCHAR,
  tenant_id   VARCHAR,
  user_id     VARCHAR,
  event_type  VARCHAR,
  occurred_at TIMESTAMP
)
WITH (partitioning = ARRAY['tenant_id', 'day(occurred_at)']);

-- Per-tenant view (one per tenant, created at onboarding)
CREATE VIEW tenant_acme.events
SECURITY INVOKER
AS SELECT * FROM analytics.events WHERE tenant_id = 'acme';

-- Grant view access only (never base table)
CREATE ROLE acme_role;
GRANT SELECT ON tenant_acme.events TO ROLE acme_role;
GRANT ROLE acme_role TO USER "acme-service-account";

-- Revoke implicit base-table access from the user principal
REVOKE ALL PRIVILEGES ON analytics.events FROM USER "acme-service-account";
```

The `SECURITY INVOKER` clause means the view runs with the caller's permissions. Since `acme-service-account` has no base-table access, the isolation is enforced at the database level — not just by the `WHERE` clause in the view.

Your senior engineer's concern is valid, but it's solved by this enforcement, not by separate schemas.
