# Iter134 Q1 — Answer

**Question**: "I've been told that Iceberg with Parquet stores data 'by column' and that means queries only read the columns they need. I get that part — if I do SELECT SUM(revenue), it skips reading user_id and event_name. But I'm seeing something confusing in production: I have a query that filters on plan_type (like WHERE plan_type = 'enterprise') and it still seems to be reading a huge amount of data, even though plan_type is one of only four possible values and I expected it to be fast. I thought columnar storage meant it could just go to the plan_type column and skip most rows. Why isn't the filter helping? Is there something about how the data physically sits in the files that determines whether a filter actually skips data, versus just reads the whole column anyway?"

---

## The Core Problem: You're Confusing Column-Level I/O with File-Level Pruning

The confusion is understandable because you're mixing two different "skipping" mechanisms that sound similar but work at completely different layers:

1. **Column selection** — "skip columns you don't read" — works because Parquet stores columns separately on disk.
2. **Partition pruning** — "skip entire files based on min/max statistics" — only works if the column you're filtering on is part of the table's **partition spec**.

When you filter on `plan_type = 'enterprise'`, Parquet certainly skips reading the other columns (user_id, event_name, etc.). But your query is still reading the **entire plan_type column from every file** in the table, then applying the filter row-by-row within that column. Billions of rows, even if it's just one column, is still a huge amount of data.

**The real speedup from analytical databases comes from partition pruning, not from column selection.** And partition pruning requires a specific physical arrangement of the data on disk.

---

## How Parquet Actually Decides Whether a Filter Helps

Every Iceberg table on your MinIO is stored as Parquet files, and each Parquet file is internally organized in a specific way that determines whether a `WHERE` clause can skip reading rows. Here's what's physically happening:

### Layer 1: Parquet Row Groups and Per-Column Statistics

A Parquet file is divided into chunks called **row groups** (typically ~128 MB each). For every column in every row group, Parquet's writer stores tiny **statistics**:
- `min` — the smallest value of that column in this row group
- `max` — the largest value
- `null_count` — how many nulls

**Example:** imagine a Parquet file for your `user_events` table. It might have 8 row groups. Here is what the statistics might say for the `plan_type` column:

```
Row group 1 (rows 1–50M):
  min = 'basic'
  max = 'enterprise'
  null_count = 0

Row group 2 (rows 50M–100M):
  min = 'basic'
  max = 'starter'
  null_count = 0

Row group 3 (rows 100M–150M):
  min = 'enterprise'
  max = 'enterprise'
  null_count = 0
```

Now when Trino executes `SELECT * FROM events WHERE plan_type = 'enterprise'`, it reads these statistics and checks each row group:

- **Row group 1:** min/max is 'basic' to 'enterprise'. 'enterprise' *might* be in here. Must read the entire row group.
- **Row group 2:** min/max is 'basic' to 'starter'. 'enterprise' is definitely NOT in here. **Can skip the entire 128 MB row group without reading a single row.**
- **Row group 3:** min/max is 'enterprise' to 'enterprise'. Only 'enterprise' is in here. Must read it, but every row matches.

This is called **predicate pushdown** — Trino pushes the filter down to the Parquet layer so it can skip row groups using statistics.

The key problem: this only helps when the data within a row group is physically sorted or clustered by `plan_type`. If every row group contains a mix of all four plan types (which is typical when data is written in arrival order), the min/max for every row group will be `'basic'` to `'starter'` to `'enterprise'` — and predicate pushdown can't skip any of them.

### Layer 2: Iceberg File-Level Statistics (Manifest Files)

Iceberg goes one level higher. It maintains **manifest files** — small metadata files that list every Parquet data file in the table, along with per-column min/max statistics *aggregated for the entire file*.

So if `user_events_2026_05_15.parquet` contains a mix of all four plan types:
```
plan_type: min = 'basic', max = 'starter'
occurred_at: min = '2026-05-15 00:00:00', max = '2026-05-15 23:59:59'
```

Iceberg knows: this file *might* contain rows where `plan_type = 'enterprise'`. Cannot skip the file.

But if another file had:
```
plan_type: min = 'basic', max = 'starter'  — no 'enterprise' here
occurred_at: min = '2026-05-16 00:00:00', max = '2026-05-16 23:59:59'
```

Iceberg *could* prove the file contains zero `'enterprise'` rows and skip opening it entirely. But only if `plan_type` is a partition column — otherwise these statistics may not be tracked at the file level.

---

## Why Your `plan_type` Filter Isn't Helping: The Partition Column Requirement

Here is the critical detail: **Trino can skip entire files based on Iceberg's file-level statistics only if the column is part of the table's partition spec — or if the data happened to be sorted so that files are pure-plan-type.**

If your `user_events` table is partitioned by `day(occurred_at)` only:

```sql
CREATE TABLE iceberg.analytics.user_events (
  ...columns...
)
WITH (
  partitioning = ARRAY['day(occurred_at)'],
  format = 'PARQUET'
);
```

Then:
- Iceberg's writer groups rows into files **by day**. All events from May 15 go into one set of files; all events from May 16 go into another.
- Within a single day's file, events are stored in whatever order they arrived — a random mix of enterprise, basic, starter, basic, enterprise...
- The file-level `plan_type` statistics for that day say `min = 'basic', max = 'enterprise'` — which means Iceberg cannot prove any file is safe to skip.
- **Every file must be opened.** Your query reads the `plan_type` column from every one of those 4,860 files.

Compare this to what happens with a partition column:

```sql
SELECT COUNT(*) FROM user_events WHERE occurred_at >= '2026-05-01' AND plan_type = 'enterprise';
```

- Iceberg's manifest file says exactly which files contain data for May 2026.
- Trino skips all files outside that date range — maybe 4,800 out of 4,860 files.
- Trino opens only the ~60 May files, then uses row-group statistics to skip non-enterprise row groups within them.
- Result: scans a tiny fraction of the table instead of 100%.

---

## A Mental Model: What "Columnar" Actually Buys You

It helps to separate three distinct performance benefits, which are often confused:

| Mechanism | What it skips | Requires |
|---|---|---|
| Column projection | Columns not in SELECT | Just Parquet format |
| Row-group predicate pushdown | 128 MB chunks where value can't match | Data sorted/clustered within the file |
| Partition pruning (file skip) | Entire Parquet files | Partition column in WHERE clause |

You already have column projection working — your `SELECT SUM(revenue) WHERE plan_type='enterprise'` is not reading `user_id`, `event_name`, or other columns. That's real. But file skipping (the biggest win) is not happening because `plan_type` is not a partition column.

---

## Diagnostic: Confirm What's Happening

To confirm your suspicion, run `EXPLAIN ANALYZE` in Trino and look at the file count:

```sql
EXPLAIN ANALYZE
SELECT COUNT(*) FROM iceberg.analytics.user_events WHERE plan_type = 'enterprise';
```

Look in the output for `Files:`. If it says `Files: 4860` and you have 4,860 files in the table, every file was opened — the filter helped zero at the file level.

Now try adding a partition column filter:

```sql
EXPLAIN ANALYZE
SELECT COUNT(*) FROM iceberg.analytics.user_events
WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-06-01 00:00:00'
  AND plan_type = 'enterprise';
```

If the `Files:` count drops to ~30 (one per day in May), the partition pruning is working. The `plan_type` filter then refines which rows are counted within those 30 files.

---

## How to Fix It: Three Options

### Option 1: Always pair with a partition column filter (easiest, no schema change)

```sql
-- SLOW: reads all files, plan_type has no file-level pruning
SELECT COUNT(*) FROM user_events WHERE plan_type = 'enterprise';

-- FAST: occurred_at prunes files, plan_type filters rows within those files
SELECT COUNT(*) FROM user_events
WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-06-01 00:00:00'
  AND plan_type = 'enterprise';
```

Most SaaS analytics queries already have a date range anyway ("this month's enterprise events"). Adding a date filter is the pragmatic fix that requires no infrastructure change.

### Option 2: Add plan_type to the partition spec (requires data rewrite)

```sql
-- Add plan_type as a partition column alongside the existing day partition
ALTER TABLE iceberg.analytics.user_events
  SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'plan_type'];
```

Now Iceberg creates separate files for each `(day, plan_type)` combination. A query for `plan_type = 'enterprise'` can skip all files belonging to other plan types.

**Trade-off:** You now have 4× as many files (one per plan type per day). Queries that scan all plan types (aggregations over all users) open 4× the files. Depending on your query mix, this can help some queries and hurt others.

### Option 3: Build a rollup table (best for dashboards)

Aggregate the raw events into a tiny summary table nightly:

```sql
CREATE TABLE iceberg.analytics.events_by_plan_day (
  plan_type  VARCHAR,
  event_date DATE,
  event_count BIGINT,
  revenue_sum DECIMAL(18, 2)
)
WITH (partitioning = ARRAY['event_date']);

-- Nightly job populates it
INSERT INTO iceberg.analytics.events_by_plan_day
SELECT
  plan_type,
  CAST(occurred_at AS DATE) AS event_date,
  COUNT(*) AS event_count,
  SUM(revenue) AS revenue_sum
FROM user_events
GROUP BY plan_type, CAST(occurred_at AS DATE);
```

This rollup table has 365 days × 4 plans = ~1,500 rows per year. Querying it for enterprise events is instantaneous — it scans a few KB instead of terabytes. This is the standard pattern for "always-available" aggregations on a SaaS dashboard.

---

## Key Takeaway

**Columnar storage skips columns; partition pruning skips files.** A filter on a non-partition column (`plan_type`) only helps at the row-group level within files you still have to open. A filter on a partition column (`occurred_at` or `tenant_id`) lets Iceberg skip entire files before opening them — that's where the 10–100x speedup comes from.

For your production queries: always include a filter on a partition column (typically a date range), and then filter on whatever other columns you need. The partition column does 95% of the I/O reduction.
