# Iter 163 Q1 — Verifying ANALYZE Stats and CBO Usage in Trino

## Answer

## Checking what stats Trino has for your table

After running `ANALYZE`, you can see exactly what statistics Trino collected using a simple command:

```sql
SHOW STATS FOR iceberg.analytics.events;
```

This outputs a table showing:
- `column_name` — which columns were analyzed
- `distinct_values_count` — the NDV (number of distinct values) for that column
- `nulls_fraction` — proportion of NULLs
- `row_count` — total rows in the table
- Other metadata like `low_value` and `high_value`

**If `distinct_values_count` is NULL** for any of the columns you're filtering or joining on, that means `ANALYZE` either hasn't run for that column, or didn't update it as expected.

## The critical issue: Your column-targeted ANALYZE may not have taken effect

You've hit the **single most important footgun** with Trino ANALYZE on Iceberg. If you previously ran a **full-table** ANALYZE and now want a **faster column-targeted** run, you must **first drop the existing extended stats**. Otherwise Trino keeps the old per-column Puffin entries around and the column-targeted ANALYZE may not update statistics the way you expect — `SHOW STATS` may keep showing the old NDV values long after you "refreshed" them.

This is exactly what's happening to you. Here's the two-step fix:

```sql
-- Step 1: Drop the old statistics from your previous full-table ANALYZE
ALTER TABLE iceberg.analytics.events EXECUTE drop_extended_stats;

-- Step 2: Now run your column-targeted ANALYZE (this will write fresh stats)
ANALYZE iceberg.analytics.events
  WITH (columns = ARRAY['user_id', 'plan_type', 'region']);
```

After that, run `SHOW STATS FOR iceberg.analytics.events` again — you should now see concrete numbers (not NULL) for `distinct_values_count` on those columns.

## How to verify the CBO is actually using the stats

To confirm the optimizer is working with your stats and building the right query plan:

```sql
EXPLAIN (TYPE LOGICAL)
SELECT ...  /* your actual query here */
```

Look at the output for two things:

1. **Check row estimates are NOT `?`**: Each operator's line will show `Estimates: {rows: <number>, ...}`. If you see `rows: ?` or extremely round defaults (like "1000" or "10000"), the CBO is still guessing — your stats aren't being picked up.

2. **Check join order and build/probe side**: If you have multiple tables, the EXPLAIN will show which table is being used as the "build" side (hashed in memory) and which is the "probe" side (streamed). With good stats, smaller tables should be built, not probed. Compare the EXPLAIN output before and after your `ANALYZE` — if the join order changed, the stats are working.

## Why your queries might still be slow

One important caveat: **ANALYZE only helps with join ordering and cardinality estimation**. It does NOT make your initial table scans faster. If your dashboard queries are mostly scanning the `events` table with filters on `plan_type` and `region`, the real problem is probably that:

- Your data isn't sorted by those columns (file skipping isn't helping).
- You don't have partition pruning set up for these columns.

`ANALYZE` helps when you have **multi-table joins** (like joining events to users to tenants). If your queries are single-table scans with filters, you need to look at partition strategy and data layout, not statistics.
