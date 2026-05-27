# Iter 160 Q2 — Trino CBO / ANALYZE TABLE: Does Iceberg Collect Statistics Automatically?

## Answer

## The Good News: Iceberg Collects Statistics Automatically

You don't need to run an ANALYZE command. **Iceberg automatically stores min/max statistics on every column for every data file when it writes.** This is baked into the system — Spark and Trino both populate `lower_bounds` and `upper_bounds` maps in the manifest entry for every column on every write, not just partition columns. The query planner consumes these automatically.

## The Real Problem: Your Data Isn't Physically Clustered

The 400-million-row full scan with only 2 million rows actually matching is almost certainly a **data clustering problem**, not a statistics problem. Here's why:

Iceberg stores per-file min/max ranges, but **these only unlock skipping if the data inside each file is physically clustered**. When your 400M-row table has events arriving in random order (the default write pattern), each Parquet file contains a random mix of all months' worth of events. So for every file:

```
file_0001.parquet:  occurred_at min = Jan 1, max = Dec 31
file_0002.parquet:  occurred_at min = Jan 1, max = Dec 31
...all files look identical...
```

When Trino's planner checks "are there any rows with `occurred_at >= May 1`?", the answer for every file's min/max range is "possibly yes" (May 1 falls somewhere between Jan 1 and Dec 31). So **no files can be skipped** — even though 90% of rows are in the last 3 months. The planner is doing exactly what it should; it's the data layout that's the problem.

## The Fix: Reorder Your Data with `rewrite_data_files`

Run Iceberg's compaction with a **sort strategy**. This physically reorders rows within files so that similar `occurred_at` values cluster together:

```sql
-- Spark SQL only (you CANNOT run this from Trino)
CALL iceberg.system.rewrite_data_files(
  table      => 'analytics.your_table_name',
  strategy   => 'sort',
  sort_order => 'occurred_at ASC NULLS LAST',
  options    => map(
    'target-file-size-bytes', '268435456',  -- 256 MB
    'rewrite-all',            'true'        -- force rewrite all files for initial sort
  )
);
```

After this runs, each file holds a contiguous range of dates — so `occurred_at min = May 1, max = June 30` in one file. Now when the planner checks your May 1+ filter, it can prove that 300 files contain only January–April and skip them entirely. Your 400M row scan collapses to 2M.

**Important caveats:**
- This must run in Spark (`spark-submit` or `spark-sql`), not Trino.
- With `rewrite-all=true`, it rewrites every file — expect multi-hour runtime on 400M rows. Schedule it during off-hours.
- It's a one-time migration. After it runs, nightly compaction (without `rewrite-all=true`) keeps the sort order clean on new writes.

## Why EXPLAIN Didn't Show What Was Wrong

Your EXPLAIN would have shown `Physical Input: 400 million rows` — but the issue isn't missing statistics (those exist), it's that the statistics don't help because the file's min/max range proves nothing. The partition column is in the WHERE clause and partition pruning works, but non-partition-column statistics can only skip files when the data is sorted. That's the asymmetry.

**Bottom line:** You already have the statistics Trino needs. What you're missing is sorted data. Run `rewrite_data_files` with sort strategy once, then routine nightly compaction (without sort) maintains it. Your 2-minute query becomes 2 seconds.
