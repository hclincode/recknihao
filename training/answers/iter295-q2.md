# Answer to Q2: Choosing Partitions for a Multi-Tenant Events Table

## The direct answer

**For your 2-billion-row events table with ~800 tenants, use `PARTITIONED BY (day(occurred_at), tenant_id)`.**

This covers 95% of real SaaS queries: time-range filters ("last 30 days"), per-tenant filters ("show acme's data"), and cross-tenant aggregations ("daily active users"). You don't have to choose between time or tenant — Iceberg lets you use both, and queries benefit from both.

## What partitioning actually does (plain language)

Partitioning tells Iceberg to split your table's files into groups based on column values, so queries can skip whole groups they don't need.

- Without partitioning: a query reads the entire 2 TB table.
- Partitioned by `day(occurred_at)`: a one-month query reads only that month's files (~2 TB ÷ 12 = ~170 GB).
- Partitioned by `day(occurred_at)` AND `tenant_id`: "acme's events from last month" reads only acme's files from those 30 days.

This file-skipping is called **partition pruning**. Iceberg checks each file's metadata and never opens files that can't match your WHERE clause.

## What `day(occurred_at)` and `bucket(user_id, 16)` mean

**`day(occurred_at)`** is a partition transform that rounds timestamps down to calendar days. All events from May 15, 2026 land in the same partition. When you write `WHERE occurred_at >= TIMESTAMP '2026-05-01'`, Iceberg automatically figures out which day-partitions overlap that range and skips the rest. This is called **hidden partitioning** — you write normal SQL and Iceberg does the skipping automatically.

**`bucket(user_id, 16)`** is a different transform — it hashes the `user_id` column and puts rows into one of 16 fixed buckets (0–15). A query for a specific user (e.g., `WHERE user_id = 'u_12345'`) prunes to exactly 1 bucket, skipping the other 15. But a query for "show me all user events this week" has to open all 16 buckets regardless — bucketing doesn't help that query at all.

## Why NOT to use `bucket(user_id, 16)` for your events table

Most SaaS dashboards query events like this:
- "Weekly active users" = count distinct users over a time range (filters by time, aggregates across all users)
- "Conversion funnel" = events of multiple types from the same user over a time period (filters by time)
- "User timeline" = all events for a specific user account (filters by tenant + time)

**None of these benefit from user-level bucketing.** The first example must scan all buckets to count all users. The second needs all buckets. The third is already fast because `tenant_id` pruning covers it.

`bucket(user_id, 16)` only helps if 95%+ of your queries are "give me user X's events" — a direct user-id lookup. For typical product analytics, that's not the case.

## How to set it up

```sql
CREATE TABLE iceberg.analytics.user_events (
  event_id    VARCHAR,
  tenant_id   VARCHAR,
  user_id     VARCHAR,
  event_name  VARCHAR,
  occurred_at TIMESTAMP(6),
  plan_type   VARCHAR,
  country     VARCHAR
)
WITH (
  partitioning = ARRAY['day(occurred_at)', 'tenant_id'],
  format = 'PARQUET'
);
```

Both columns prune independently. A query with `WHERE tenant_id = 'acme' AND occurred_at >= TIMESTAMP '2026-05-01'` prunes on both axes — Iceberg evaluates both predicates against all file metadata and skips anything that can't match. The order in the array affects file clustering on disk (compression efficiency) but **not** pruning capability — both partitions prune every query correctly.

## Why day-first (not tenant-first)?

For SaaS workloads, most dashboards are time-range first (internal reports show "events from the past month" across all tenants). Files grouped by day compress better because events from the same day are similar in type and structure. The partition metadata is organized by the leading column, so listing files for a date range is slightly faster.

If 90%+ of your queries were "show me acme's events for all time," tenant-first would give better compression on per-tenant scans. For mixed workloads (cross-tenant metrics + per-tenant dashboards), day-first is the safe choice.

## Partition count: you're well within limits

With 800 tenants and `(day, tenant_id)` partitioning over a year:
- Partitions per year = 365 days × 800 tenants = **292,000 partitions**
- Iceberg's comfort zone = ~100,000 to 1,000,000 partitions per table
- You're solidly in the middle ✓

This count comes from *days × tenants*, not from event count. Your 2 billion events only affect partition *size*. Each partition holds roughly 2B ÷ 292,000 = ~6,800 events per day-tenant pair — healthy file sizes.

## When to use `bucket(tenant_id, 64)` instead

Only switch to bucketing tenant_id if:
1. You have **1,000+ tenants** and identity partitioning produces unmanageable metadata, OR
2. One tenant produces 80%+ of events, causing write skew (Spark tasks writing to that tenant's partition serialize and slow down)

With bucketing you trade one problem for another. You gain even file distribution but lose the **metadata-only billing query optimization**:

```sql
-- With identity tenant_id partitioning: runs in ~2 seconds (metadata only, no Parquet files opened)
SELECT tenant_id, COUNT(*)
FROM iceberg.analytics.user_events
WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-06-01 00:00:00'
GROUP BY tenant_id;

-- With bucket(tenant_id, 64): runs in ~2 minutes (must open data files to identify tenants per bucket)
```

Iceberg's manifests store `tenant_id='acme'` per file (identity partition), so Trino answers the COUNT directly from metadata. With `bucket(tenant_id, 64)`, the manifest stores `tenant_id_bucket=7` — a number — and data files must be opened to recover individual tenant IDs. Only bucket if you absolutely need write balance.

## The small-files problem: set up nightly compaction

Every Spark write creates new Parquet files. Frequent writes (e.g., every 5 minutes) create thousands of tiny files per partition over time. Opening metadata for thousands of tiny files is slower than reading a few 256 MB files.

Schedule nightly compaction via Spark (NOT Trino — Trino doesn't expose `CALL iceberg.system.*` procedures):

```sql
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.user_events',
  options => map('target-file-size-bytes', '268435456')  -- 256 MB
);
```

This merges small files within each partition to 256 MB targets. Run it every night during low traffic.

## Summary: your decision

| Question | Answer |
|---|---|
| Should I partition? | Yes. 2B rows without partitioning = every query scans everything. |
| By date or tenant? | Both: `ARRAY['day(occurred_at)', 'tenant_id']` |
| Should I use `bucket(user_id, 16)`? | No — doesn't match SaaS query patterns. Use Bloom filters for user-level lookups instead. |
| What if one tenant is huge? | Still use identity `tenant_id` for ≤1,000 tenants. If write skew is severe, bucket tenant_id — but understand you lose fast per-tenant COUNT queries. |
| Do I need compaction? | Yes — run nightly `rewrite_data_files` via Spark. |

**Use `PARTITIONED BY (day(occurred_at), tenant_id)`. Pair it with nightly compaction. Done.**
