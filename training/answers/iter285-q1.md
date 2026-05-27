# Iter285 Q1 — Dynamic Filtering Breakdown with High-Cardinality Join Keys

## Answer

Yes — dynamic filtering (DF) degrades and eventually stops being effective as the number of distinct join keys grows. With 2 million distinct customer IDs, you've hit multiple limits simultaneously.

## Why DF is failing at 2M distinct values

**Stage 1: IN-list compaction to a BETWEEN range**

When Trino builds a dynamic filter from the Postgres side, it collects distinct customer IDs. Once the distinct values exceed a threshold (default: 256 per the `domain-compaction-threshold` setting), Trino **stops maintaining the precise IN-list and switches to a MIN/MAX range filter**:

```sql
-- What DF sends to Iceberg's file pruner:
WHERE customer_id BETWEEN min_customer_id AND max_customer_id
```

At 2M distinct values, you're way past this limit. A BETWEEN range is far weaker than an IN-list: it only prunes Iceberg files whose min/max statistics fall entirely outside the range. If your customer IDs are sparse across a wide range, the BETWEEN is nearly useless.

**Stage 2: Iceberg's 1-second wait timeout**

The Iceberg connector waits at most 1 second (default `iceberg.dynamic-filtering.wait-timeout=1s`) for the Postgres build side to deliver its filter values. Scanning 2M rows from Postgres over a single JDBC connection typically takes 3–15 seconds. If the Postgres build finishes after 1 second, Iceberg already launched its scan without any dynamic filter — all 80M rows are read unfiltered.

**Stage 3: DF generation giving up entirely**

If the build side exceeds Trino's internal row cap for DF collection, Trino may skip DF generation entirely for the query. Check your EXPLAIN output — if there's no `dynamicFilters = {...}` annotation on the Iceberg TableScan at all, this is the problem.

## What to tune

**Fix 1: Raise the Iceberg DF wait timeout (most impactful)**

This gives the Postgres build side time to deliver the range filter before Iceberg gives up:

```sql
-- Per-session:
SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';

-- Or permanently in etc/catalog/iceberg.properties (adjust catalog name):
iceberg.dynamic-filtering.wait-timeout=20s
```

Even though the filter is a BETWEEN range (not an IN-list), waiting for it still beats Iceberg scanning 80M rows with no filter at all.

**Fix 2: Enable large dynamic filters (if DF isn't generating at all)**

```sql
SET SESSION enable_large_dynamic_filters = true;
```

This removes the row-count cap on the build side so DF still fires even for millions of rows (though it will still be range-form due to compaction).

**Fix 3: Add a selective WHERE predicate on the Postgres side**

If your queries typically filter to a subset of customers (e.g., `WHERE dim.plan = 'enterprise'`), push that predicate to shrink the build side dramatically before DF kicks in:

```sql
SELECT fact.*
FROM iceberg.analytics.events AS fact
JOIN app_pg.public.customers AS dim ON fact.customer_id = dim.id
WHERE dim.plan = 'enterprise';
-- If 'enterprise' covers ~5K customers instead of 2M, DF works precisely
```

## Verify what's actually happening

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT fact.* FROM iceberg.analytics.events AS fact
JOIN app_pg.public.customers AS dim ON fact.customer_id = dim.id;
```

Look for `dynamicFilters = {...}` on the Iceberg TableScan node:
- **Present**: DF is wired up. Run `EXPLAIN ANALYZE` and check `dynamicFilterSplitsProcessed > 0` on the Iceberg operator. If it's 0, the wait-timeout fired — raise it.
- **Absent**: DF generation gave up — enable `enable_large_dynamic_filters`.

## The real fix for 2M distinct keys: ingest the lookup table into Iceberg

At 2M distinct join keys, no DF tuning fully solves the problem. The range filter is a coarse approximation, and the Postgres build scan itself is slow. The right long-term fix is to replicate the Postgres lookup table into Iceberg:

```sql
-- One-time CTAS:
CREATE TABLE iceberg.analytics.customers AS SELECT * FROM app_pg.public.customers;

-- Nightly sync:
MERGE INTO iceberg.analytics.customers AS tgt
USING (SELECT * FROM app_pg.public.customers WHERE updated_at >= current_timestamp - INTERVAL '25' HOUR) AS src
ON tgt.id = src.id
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *;
```

With both tables in Iceberg: the build side scans in parallel from MinIO (not single-threaded JDBC), DF can deliver a precise IN-list or at worst a tighter range, and there's no 1-second wait-timeout race. The join drops from minutes to seconds.

## Summary

| Limit | Your situation | Fix |
|---|---|---|
| IN-list compacted to BETWEEN (>256 distinct values) | 2M >> 256 — you get BETWEEN range | Raise `domain_compaction_threshold` (limited help at 2M); add selective WHERE predicate |
| Iceberg wait-timeout (default 1s) | Postgres scan takes 3–15s | Raise `iceberg.dynamic_filtering_wait_timeout` to 20s |
| DF generation cap | May give up entirely | `SET SESSION enable_large_dynamic_filters = true` |
| Structural limit at 2M keys | DF fundamentally weak | Ingest Postgres lookup into Iceberg — join both sides from MinIO |
