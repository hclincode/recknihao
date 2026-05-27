# Answer to Q2: Partition Strategy for a Multi-Tenant SaaS Events Table (Iter 305)

## The Decision Process

Partitioning is about reducing how much data Trino has to read on a query. Without it, every query scans the entire table. With it, Iceberg's manifest metadata tells Trino which files to skip based on partition values in your `WHERE` clause.

For a multi-tenant SaaS event table with `tenant_id`, `event_type`, `occurred_at`, and `user_id`, you have three realistic choices:

1. **`PARTITIONED BY (day(occurred_at))`** — time only. Good for cross-tenant dashboards.
2. **`PARTITIONED BY (day(occurred_at), tenant_id)`** — time + tenant identity. **Standard SaaS default.**
3. **`PARTITIONED BY (day(occurred_at), bucket(tenant_id, 64))`** — time + bucketed tenant. Only for 200+ tenants with extreme skew.

**The standard recommendation for 80 tenants with variable event volumes: option 2 — `(day(occurred_at), tenant_id)`.**

## Why This Combination Works Best

- A query filtering by date range (`WHERE occurred_at >= ... AND occurred_at < ...`) prunes to only that date range's files — Trino skips everything else.
- A query also filtering by tenant (`AND tenant_id = 'acme'`) prunes both by day AND by tenant — even fewer files read.
- A cross-tenant query (`WHERE occurred_at >= ...` only) still prunes correctly on the date range.

**Column order in the partition spec** (`day` first vs `tenant_id` first) does NOT affect pruning — both columns prune independently. Day-first is the convention because it clusters temporally similar rows together, improving compression.

## The Metadata-Only Billing Query

With identity `tenant_id` (not bucketed), per-tenant row count queries are **metadata-only** — Trino reads only Iceberg's manifest files, not actual data:

```sql
SELECT tenant_id, COUNT(*)
FROM iceberg.analytics.customer_events
WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-06-01 00:00:00'
GROUP BY tenant_id;
```

Iceberg's manifest lists each file with its partition key and row count. Trino sums row counts from the manifest — no Parquet files opened. On a 10 TB table this completes in seconds. **Bucketed `tenant_id` loses this optimization.**

## Production DDL

**Trino:**
```sql
CREATE TABLE iceberg.analytics.customer_events (
  event_id    VARCHAR,
  tenant_id   VARCHAR,
  user_id     VARCHAR,
  event_type  VARCHAR,
  occurred_at TIMESTAMP(6),
  payload     MAP<VARCHAR, VARCHAR>
)
WITH (
  partitioning = ARRAY['day(occurred_at)', 'tenant_id'],
  format = 'PARQUET'
);
```

**Spark SQL:**
```sql
CREATE TABLE iceberg.analytics.customer_events (
  event_id    STRING,
  tenant_id   STRING,
  user_id     STRING,
  event_type  STRING,
  occurred_at TIMESTAMP,
  payload     MAP<STRING, STRING>
)
USING iceberg
PARTITIONED BY (day(occurred_at), tenant_id);
```

## Handling Wildly Different Tenant Volumes (Skew)

**Partition count:** 80 tenants × 365 days = 29,200 partitions/year. Totally manageable.

**File distribution:** Each day, ingestion writes one file per tenant partition — 80 files per day. Whale tenants get large files (500 MB–1 GB/day); small tenants get tiny files (10–50 MB/day). This is expected and normal.

**The small-file problem is fixed with nightly compaction, not with bucketing.** At 80 tenants, identity `tenant_id` is right. Only switch to `bucket(tenant_id, 64)` at 200+ tenants where managing per-partition file counts becomes operationally painful AND you're willing to lose the metadata-only billing query.

## Nightly Compaction (Required)

If ingestion writes frequently (micro-batches every 5 minutes = 23,000+ files per day), Trino spends minutes just opening file footers. Fix it:

```sql
-- Spark only — run nightly after last ingest
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.customer_events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB target
    'min-input-files', '5'                  -- only compact partitions with 5+ files
  )
);
```

Pair with weekly snapshot expiry:

```sql
-- Spark:
CALL iceberg.system.expire_snapshots(
  table => 'analytics.customer_events',
  older_than => current_timestamp() - INTERVAL '7' DAY,
  retain_last => 5
);

-- Or Trino (467 enforces 7-day minimum floor):
ALTER TABLE iceberg.analytics.customer_events
EXECUTE expire_snapshots(retention_threshold => '7d');
```

## Partition Evolution — Yes, You Can Change It Later

Iceberg lets you change the partition spec **without rewriting old data**. This is a real differentiator from Hive.

```sql
-- Trino: change spec for new writes immediately
ALTER TABLE iceberg.analytics.customer_events
SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id'];
```

Old data stays under the old spec; new data uses the new spec. A one-time Spark `rewrite_data_files` with `'rewrite-all', 'true'` migrates historical files to the new spec when you're ready.

## Verify Pruning Is Working

```sql
EXPLAIN ANALYZE
SELECT COUNT(*)
FROM iceberg.analytics.customer_events
WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-06-01 00:00:00'
  AND tenant_id = 'acme';
```

Look at `Input: X rows, Y bytes` in the table scan node. Add and remove `AND tenant_id = 'acme'` and compare — with tenant pruning, bytes read should drop proportionally (approximately 1/80th if tenants are equal-sized).

## What NOT to Do

1. **Don't partition by `hour()` or `minute()`** — creates millions of tiny partitions; query planning alone takes minutes.
2. **Don't partition by `tenant_id` alone** — loses time-based pruning; cross-tenant dashboards scan everything.
3. **Don't partition by `event_type`** — low-cardinality (20 values) creates 20x more partitions with minimal benefit. Use sort-based clustering in compaction instead.
4. **Don't skip the compaction job** — partition pruning reduces which files are read, but file count within each partition still matters for query planning overhead.
