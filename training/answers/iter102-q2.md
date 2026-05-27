# Iter102 Q2 — Answer

**Question**: We partition our main events table by tenant_id so each customer's queries only scan their own data. That works great for customer-facing dashboards. But now our internal analytics team needs to run queries across all tenants — things like "total events per tenant this week" for billing reports — and those queries seem really slow because they have to scan every tenant's partition. Is there a way to make those cross-tenant queries faster without breaking the per-tenant isolation that customer queries depend on?

---

## Answer

### Why cross-tenant queries are slow

You've partitioned by `(day(occurred_at), tenant_id)`. This is exactly right for customer-facing dashboards — when Acme runs a query, Iceberg reads only Acme's partition files. But when your internal team needs "total events per tenant this week," the query must touch **every tenant's partition**. You can't skip any.

Concretely: if you have 80 tenants, a per-tenant dashboard reads ~1 day's files (fast). A `SELECT tenant_id, COUNT(*) FROM events WHERE occurred_at >= ... GROUP BY tenant_id` must scan all 80 tenant-partitions for the date range — 80× more files than a single-tenant query. The partition pruning that makes per-tenant queries fast doesn't help here because there's no tenant-id predicate to prune on.

### Option 1: Metadata-only aggregations (fast, for identity-partitioned tables)

If your partition spec uses **identity `tenant_id`** (not bucketed), per-tenant billing counts can be **metadata-only** — Iceberg reads only manifest files, never opens Parquet data files:

```sql
-- If partitioned by: ARRAY['day(occurred_at)', 'tenant_id'] (identity)
-- This reads ONLY manifest metadata — runs in milliseconds regardless of table size.
SELECT partition.tenant_id, SUM(record_count) AS total_rows
FROM iceberg.analytics."events$files"
WHERE partition.day_occurred_at >= DATE '2026-05-19'
GROUP BY partition.tenant_id
ORDER BY total_rows DESC;
```

Or using the `$partitions` table directly:

```sql
SELECT partition.tenant_id, record_count, file_count, total_size
FROM iceberg.analytics."events$partitions"
ORDER BY record_count DESC;
```

**Caveat:** this only works when `tenant_id` is an identity partition. If you used `bucket(tenant_id, N)`, the partition struct contains `tenant_id_bucket` (an integer 0-N-1), not the original tenant_id — the metadata-only approach doesn't work and requires a data file scan.

### Option 2: Changing partition order — marginal benefit, real trade-offs

Switching from `ARRAY['day(occurred_at)', 'tenant_id']` to `ARRAY['tenant_id', 'day(occurred_at)']` (tenant-first) would improve cross-tenant sequential scans slightly, but breaks the per-tenant customer dashboard optimization — a per-tenant query like "Acme's events in May" would now scan Acme's entire partition (all days) then filter by date in the engine. For a SaaS serving customers, day-first is almost always correct. Don't change partition order for this use case.

### Option 3: Pre-aggregated summary table (recommended)

The practical answer: create a dedicated **materialized summary table** updated by a nightly Spark job, specifically for internal cross-tenant analytics.

**Create the summary table:**

```sql
CREATE TABLE iceberg.analytics.daily_event_rollup (
  event_date   DATE,
  tenant_id    VARCHAR,
  event_type   VARCHAR,
  event_count  BIGINT,
  unique_users BIGINT,
  rollup_time  TIMESTAMP
)
WITH (partitioning = ARRAY['event_date', 'tenant_id']);
```

**Nightly Spark job** (runs during off-hours, no customer impact):

```sql
INSERT INTO iceberg.analytics.daily_event_rollup
SELECT
  DATE(event_ts) AS event_date,
  tenant_id,
  event_type,
  COUNT(*)             AS event_count,
  COUNT(DISTINCT user_id) AS unique_users,
  CURRENT_TIMESTAMP    AS rollup_time
FROM iceberg.analytics.events
WHERE event_ts >= CURRENT_TIMESTAMP - INTERVAL '1' DAY
GROUP BY 1, 2, 3;
```

**Internal team queries the rollup, not raw events:**

```sql
SELECT
  event_date,
  tenant_id,
  SUM(event_count) AS total_events
FROM iceberg.analytics.daily_event_rollup
WHERE event_date >= DATE '2026-05-19'
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;
```

Why this wins:
- Billions of raw rows compressed to thousands of pre-aggregated rows per day. Sub-second response.
- Internal queries don't compete with customer dashboards for the same files.
- Add more dimensions (by country, by feature, etc.) without touching the base table.
- Cost: ~5 minutes of Spark CPU per day during a scheduled window, negligible storage.

### Option 4: Separate internal Trino cluster (for heavy ad-hoc analytics)

If internal analytics needs truly expensive, ad-hoc exploration across years of history, stand up a **second Trino cluster** reading the same MinIO Iceberg tables. Internal cluster has no resource limits; customer cluster stays isolated. They share zero query resources. Usually overkill — use option 3 first.

### Keeping per-tenant isolation intact

None of these changes affect customer isolation:

- **Metadata-only queries** still go through OPA policies — customer roles can't see other tenants' file metadata.
- **Summary tables** are internal-only — customer views still point to the filtered base table.
- **Separate cluster** serves only your team, not customers.

The per-tenant Trino views, OPA policies, and role grants are at the authorization layer, independent of partition layout. You can optimize partition design and add summary tables without touching isolation guarantees.

### Recommendation

1. **Check your partition spec**: `SHOW CREATE TABLE iceberg.analytics.events`. If `tenant_id` is identity (not bucket), metadata-only counts are already free — use `$files` or `$partitions` for per-tenant billing queries.

2. **For "total events per tenant" billing dashboards**: create `daily_event_rollup` and run a nightly Spark rollup job. Internal team gets sub-second responses instead of full table scans.

3. **Keep customer queries on the base table**: per-tenant views filter the raw table — no mixing with summaries for customer-facing data.

One nightly Spark job and one extra table solves the problem without sacrificing isolation or customer-facing performance.
