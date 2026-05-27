# Iter111 Q2 — Answer

**Question**: We have about 200 tenants sharing the same Iceberg tables. Most of them are small businesses with maybe a few thousand events per month, but we have 3-4 enterprise customers with tens of millions of events each. The problem is that when we run our internal "analytics on analytics" — like, how many API calls did each tenant make last week, broken down by endpoint — the query takes forever because the enterprise customers' data completely dominates scan time. But we still need results for all 200 tenants in one report. Is there a way to structure the data or the query so that the small tenants don't have to wait while we crunch through the enterprise data? Or is this just a "throw more hardware at it" problem?

---

## Answer

This is not a "throw more hardware at it" problem — it's a classic case of **partition skew** meeting multi-tenant analytics, and there are concrete architectural fixes.

### Why partition strategy alone won't solve this

You probably have `partitioning = ARRAY['day(event_ts)', 'tenant_id']`. Trino's partition pruning works correctly: a query filtering `WHERE tenant_id = 'acme'` reads only Acme's files. But when your internal report queries **all tenants** with no tenant_id filter, Trino opens all files. The enterprise tenants' data simply takes longer because they have more data — there's no pruning to apply on a cross-tenant scan.

Bucketing (`bucket(tenant_id, 32)`) helps with manifest bloat for 100+ tenants, but doesn't fix the skew problem on queries that scan all buckets.

### Solution 1: Pre-computed rollups for internal dashboards (lowest effort)

Instead of scanning raw events every time, run a nightly rollup job that pre-aggregates the data:

```sql
-- Nightly Spark job (or Trino CTAS)
CREATE TABLE analytics.api_calls_daily_summary AS
SELECT
  tenant_id,
  endpoint,
  event_date,
  COUNT(*) AS call_count
FROM analytics.events
WHERE event_date = CURRENT_DATE - INTERVAL '1' DAY
GROUP BY tenant_id, endpoint, event_date;
```

Your internal report then queries this pre-aggregated summary table — a few thousand rows — instead of the raw events table with tens of millions of rows. Even if enterprise tenants dominate the raw data, the rollup is a cross-tenant join on a tiny table: instant.

This is the right first move because it requires no schema changes, no data migration, and takes effect immediately.

### Solution 2: Migrate heavy tenants to dedicated tables (recommended long-term)

Move the 3–4 enterprise customers out of the shared table into their own dedicated tables (e.g., `analytics.acme_events`). Your internal report then runs against the shared table — now much smaller and fast to scan — plus targeted lookups into the enterprise-dedicated tables.

**Step 1: Identify which tenants warrant migration**

```sql
-- Query Iceberg partition metadata — no full table scan needed
SELECT
  partition.tenant_id,
  record_count,
  file_count,
  ROUND(total_size / (1024.0 * 1024.0 * 1024.0), 2) AS total_gb
FROM iceberg.analytics."events$partitions"
ORDER BY total_size DESC
LIMIT 10;
```

Note: `partition.tenant_id` only works if `tenant_id` is in your current partition spec. If the query errors, you don't have tenant_id as a partition column — add it first via partition evolution, or use a row-count query grouped by tenant_id.

If 3 tenants hold >50 GB each and the remaining 197 are under 1 GB total, they are migration candidates.

**Step 2: Safe cutover sequence (one tenant at a time)**

```sql
-- 1. Create dedicated table for the enterprise tenant
CREATE TABLE analytics.acme_events AS
  SELECT * FROM analytics.events WHERE tenant_id = 'acme';

-- 2. Verify row counts match before deleting anything
SELECT COUNT(*) FROM analytics.acme_events;
SELECT COUNT(*) FROM analytics.events WHERE tenant_id = 'acme';

-- 3. Swap the Trino view to point at the dedicated table
CREATE OR REPLACE VIEW tenant_acme.events AS
  SELECT * FROM analytics.acme_events;

-- 4. Delete from shared table LAST (shared table is backup until this point)
DELETE FROM analytics.events WHERE tenant_id = 'acme';
```

The shared table is untouched as a backup until step 4. If anything fails before step 4, roll back by dropping `analytics.acme_events` and pointing the view back.

After migration:
- Enterprise customers' dashboards run against their dedicated tables (fast — no other tenants' data)
- Internal cross-tenant report runs against the shared table (now 197 small tenants only, fast)
- Internal report adds a UNION ALL across the dedicated tables for the enterprise tenants, or uses a separate query path

### Solution 3: OPA row-filter injection (for per-tenant queries)

Your stack uses OPA as the Trino authorization backend. OPA can automatically inject `WHERE tenant_id = '<caller>'` into every query from a tenant principal, before execution. This makes per-tenant customer-facing queries fast without any application code change.

However, this doesn't solve your cross-tenant internal report — internal admin queries run unfiltered against all tenants. Row-level filtering helps individual tenants; it doesn't fix the enterprise-data-dominates-cross-tenant-scan problem.

### Recommended approach

1. **Immediately**: Set up a nightly rollup (Solution 1). Internal reports become instant.
2. **Over the next sprint**: Migrate the top 2–3 enterprise tenants to dedicated tables (Solution 2). This is the structural fix that makes the problem go away permanently.
3. **Ongoing**: New enterprise tenants above a data-volume threshold (e.g., >10M rows) get dedicated tables at onboarding rather than retrospectively.
