# Iter286 Q1 — Iceberg Dynamic Filtering Wait Timeout (Catalog Config Only)

## Answer

Yes — that's exactly what's happening. Iceberg's probe-side wait-timeout is expiring before the Postgres build side finishes, causing Iceberg to launch its scan unfiltered.

## How the timeout works

In your join (200M-row Iceberg × 50K-row Postgres), Trino picks Postgres as the build side (smaller table). Trino scans Postgres first to collect customer IDs, derives a dynamic filter (an IN-list), and pushes it into the Iceberg scan to prune which Parquet files to read.

When Postgres is slow, the filter arrives late. Iceberg's wait-timeout expires, and Iceberg launches its scan without waiting — the full 200M rows are read unfiltered. The default timeout is **1 second**, which is commonly exceeded by JDBC operations under load.

## How to raise the timeout

**There is no per-query session property for the Iceberg connector's wait timeout.** This is different from the Hive connector (which has `<hive-catalog>.dynamic_filtering_wait_timeout` as a session property). The Iceberg connector exposes this only as a catalog-level config:

```properties
# etc/catalog/iceberg.properties — on the Trino coordinator
iceberg.dynamic-filtering.wait-timeout=20s
```

This requires a **coordinator restart** to take effect. After the restart, the new timeout applies to all queries against that catalog.

Attempting a session property will fail:
```sql
-- DOES NOT WORK — this session property does not exist for Iceberg
SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';
-- Error: Session property does not exist
```

## Tradeoff of raising the timeout

Raising to 20s means queries where DF doesn't arrive in time will wait up to 20 additional seconds before Iceberg scans unfiltered. For batch jobs this is worth it. For interactive sub-second queries, weigh the tradeoff.

## Workarounds if you can't restart the coordinator

**Option 1: Make the Postgres build side faster** — add a selective WHERE predicate on the Postgres side so it returns fewer rows faster:

```sql
SELECT e.*, c.name
FROM iceberg.analytics.events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
WHERE c.plan = 'enterprise';  -- reduces 50K → ~5K rows, finishes in ms
```

**Option 2: Deploy a second Iceberg catalog with a longer timeout** — no restart of the main catalog needed:

```properties
# etc/catalog/iceberg_batch.properties
connector.name=iceberg
iceberg.dynamic-filtering.wait-timeout=30s
# ... same metastore/S3 config as your main iceberg catalog
```

Use `iceberg_batch.analytics.events` in batch jobs; keep `iceberg.analytics.events` at the default 1s for interactive queries.

**Option 3: Ingest the Postgres customers table into Iceberg** — then both sides are in-catalog, no cross-connector timeout asymmetry, and DF is more efficient.

## Verify the fix

```sql
EXPLAIN ANALYZE
SELECT e.event_id, c.name
FROM iceberg.analytics.events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
WHERE c.plan = 'enterprise';
```

Look for on the Iceberg TableScan node:
- `dynamicFilters = {customer_id_filter = ...}` in the plan — confirms DF is wired
- `dynamicFilterSplitsProcessed = N` (N > 0) — confirms the filter fired and pruned splits before scanning

If `dynamicFilterSplitsProcessed = 0`, the timeout still fired — increase it further or add a selective WHERE clause on the Postgres side.
