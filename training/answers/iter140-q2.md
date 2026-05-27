# Iter140 Q2 — Answer

**Question**: "We're setting up partitioning on our main events table and trying to decide how to split it. We have about 80 tenants and our data is very uneven — our top 5 customers generate maybe 60% of all events, while the bottom 40 are basically quiet. Should we partition by tenant ID, by day, by month, or some combination? I'm worried that if we partition by tenant, the big customers will create massive partitions while the tiny ones have almost nothing in them, but if we partition by day, then a query filtering by tenant will have to scan everything. How do you think through this trade-off?"

---

## The Key Insight: Partition Pruning and File-Level Pruning Are Separate

You're facing a real tension, and the answer hinges on understanding something that surprises most engineers: **you don't need `tenant_id` in the partition spec for per-tenant queries to be fast.** Iceberg has two independent pruning mechanisms:

1. **Partition pruning** — skips entire files whose partition value doesn't match the query. Only works for columns in the partition spec.
2. **File-level min/max statistics** — stored for **every column** in every manifest entry, not just partition columns. If a file's `tenant_id` min/max range doesn't contain 'acme', Trino skips that file entirely.

The second mechanism means that if your data is **physically sorted or clustered by tenant_id within each day partition**, per-tenant queries can skip most files without `tenant_id` being a partition column.

---

## Why Partitioning by Tenant Alone Causes Problems

With 80 tenants and a 60/5 data skew, partitioning by `tenant_id` directly creates three problems:

**Partition skew on writes:** Your 5 large customers each get one giant partition per day (~dozens of GB). Your 40 small customers each get a micro-partition (10–50 MB). Spark tasks writing to large tenants run 100–1000x longer than tasks for small tenants. Write latency is bounded by the slowest task.

**Small-file accumulation for small tenants:** If each small tenant's daily partition holds 20 MB and your compaction target is 256 MB, that partition can never reach the target. You accumulate one tiny file per day × 365 days = 365 tiny files per small tenant per year — and Trino must open all of them even for a simple row count.

**Partition count explosion:** 80 tenants × 365 days = 29,200 partitions/year. You burn through partition headroom quickly, limiting future schema evolution.

---

## Why Partitioning by Day Alone Doesn't Solve Tenant Queries

```sql
-- PARTITIONED BY (day(occurred_at))
SELECT COUNT(*) FROM events
WHERE occurred_at >= '2026-05-01'
  AND tenant_id = 'acme';
```

Iceberg prunes to May's files (fast) but then opens **every file in May** — it can't use partition pruning on `tenant_id`. Without data clustering, each file holds a random mix of all 80 tenants, and file-level min/max ranges span the full tenant space — nothing gets pruned.

---

## The Recommended Approach: Partition by Day, Sort by Tenant

**Start with this partition spec:**

```sql
-- Trino 467
CREATE TABLE iceberg.analytics.events (
    event_id    VARCHAR,
    tenant_id   VARCHAR,
    occurred_at TIMESTAMP(6),
    event_type  VARCHAR,
    payload     VARCHAR
)
WITH (
    partitioning = ARRAY['day(occurred_at)'],
    format       = 'PARQUET'
);
```

**Then run nightly sort compaction:**

```python
# Spark — run after ingestion finishes each night
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table      => 'analytics.events',
        strategy   => 'sort',
        sort_order => 'tenant_id ASC NULLS LAST, occurred_at ASC',
        options    => map('target-file-size-bytes', '268435456', 'min-input-files', '5')
    )
""")
```

**Why this works:** After sorting, rows for each tenant cluster together in the Parquet files. A file containing only Acme's events has `tenant_id min='acme', max='acme'`. A file containing only Beta's events has `min='beta', max='beta'`. Now a query for `WHERE tenant_id = 'acme'` can skip every file where `max < 'acme'` or `min > 'acme'` — which is ~95% of May's files.

**Verify it's working:**

```sql
-- Trino: inspect per-file tenant_id ranges after sorting
SELECT
    file_path,
    lower_bounds['tenant_id'] AS tenant_min,
    upper_bounds['tenant_id'] AS tenant_max,
    record_count
FROM iceberg.analytics."events$files"
WHERE partition.occurred_at_day = CAST(CURRENT_DATE - INTERVAL '1' DAY AS DATE)
ORDER BY lower_bounds['tenant_id']
LIMIT 20;
```

After sorting: most files show identical `tenant_min` and `tenant_max` (a single tenant per file). Before sorting: every file shows `min='acme', max='zulu'` (all 80 tenants mixed).

```sql
-- Verify pruning is working: check files read vs total
EXPLAIN ANALYZE
SELECT event_type, COUNT(*) FROM iceberg.analytics.events
WHERE occurred_at >= TIMESTAMP '2026-05-01'
  AND occurred_at < TIMESTAMP '2026-06-01'
  AND tenant_id = 'acme'
GROUP BY event_type;
-- Look for "Files: N out of M" in the output — N should be ~1-5% of M after sorting.
```

---

## When to Add Tenant Partitioning

Add `tenant_id` as a partition column only if, after 1–3 months of monitoring, per-tenant queries still pull >30% of daily data despite sorting. At that point you have evidence the skew is severe enough.

**Avoid `bucket(tenant_id, N)` for your use case.** Bucket partitioning hashes tenant IDs to buckets — a per-tenant query must still scan an entire bucket (which contains multiple tenants). You lose the file-level pruning benefit, and billing queries (`SELECT tenant_id, COUNT(*) GROUP BY tenant_id`) can no longer be answered from metadata alone.

**Better alternative for the 5 dominant tenants:** isolate them into dedicated tables.

```sql
-- Shared table: the 75 small tenants, partitioned by day only
CREATE TABLE iceberg.analytics.events_shared ...
PARTITIONED BY (day(occurred_at));

-- Dedicated table per whale tenant
CREATE TABLE iceberg.analytics.events_acme ...
PARTITIONED BY (day(occurred_at));

-- Union view for internal cross-tenant queries
CREATE VIEW iceberg.analytics.all_events AS
SELECT * FROM iceberg.analytics.events_shared
UNION ALL
SELECT * FROM iceberg.analytics.events_acme
UNION ALL
SELECT * FROM iceberg.analytics.events_beta;
```

This isolates write skew (large tenants don't dominate compaction of the shared table) without the partition-count overhead of a pure tenant partition scheme.

---

## Partition Evolution: You Can Add Later Without Downtime

Iceberg's partition evolution means you don't need to get the partition spec perfect on day 1. If you start with `day(occurred_at)` and later decide to add a tenant dimension, you can:

```sql
-- Trino: evolve to add tenant partitioning later
ALTER TABLE iceberg.analytics.events
SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id'];

-- Then migrate historical data to the new spec (Spark)
CALL iceberg.system.rewrite_data_files(
    table   => 'analytics.events',
    options => map('rewrite-all', 'true', 'target-file-size-bytes', '268435456')
);
```

Old files stay on the old spec; new files use the new spec; queries prune across both transparently.

---

## Practical Recommendation

**Phase 1 (now):** `PARTITIONED BY (day(occurred_at))` + nightly sort compaction on `tenant_id`. Simple, low-overhead, handles 95% of SaaS query patterns.

**Phase 2 (after 1–3 months of EXPLAIN ANALYZE monitoring):** If per-tenant query file reads are still >30% of daily data, isolate the top 5 tenants to dedicated tables and keep the rest in the shared table.

**Phase 3 (only if needed):** Evolve the shared table partition spec to add a second dimension — but only with hard data showing the current approach is insufficient.

| Approach | Write cost | Query perf (by tenant) | Operational overhead |
|---|---|---|---|
| Tenant partition only | High skew | Excellent pruning | High (partition skew, small files) |
| Day partition only | Low | Poor (full daily scan per tenant) | Low |
| Day + sort by tenant (recommended) | Low | Good (file-level pruning after sort) | Medium (nightly sort compaction) |
| Day + dedicated tables for whales | Low | Excellent per-whale, good for rest | Higher (multiple tables) |
