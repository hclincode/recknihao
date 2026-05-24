# Iter52 Questions

**Date**: 2026-05-24
**Weakest topics**: Postgres-to-Iceberg ingestion (4.276, 52q), Multi-tenant analytics (4.270, 52q)

---

## Q1 — Postgres-to-Iceberg ingestion (CDC schema evolution)

**Question**: We set up a Debezium pipeline that streams change events from our Postgres `events` table into Iceberg on MinIO. It's been running fine. Now one of our developers added a new column — `device_os VARCHAR(50)` — directly to the Postgres table with a plain `ALTER TABLE`. Nobody touched the pipeline. What actually happens? Does Debezium start failing? Does the Iceberg table break? Do we need to stop everything and manually add the column on the Iceberg side before we can resume, or does it handle it automatically somehow?

**Target topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling
**Expected answer should cover**: Debezium detects the DDL change through Postgres WAL / logical replication slot and the schema registry (Confluent Schema Registry or Apicurio). The connector does NOT crash silently — it emits events with the new field if schema compatibility allows. The new column starts appearing in Debezium's Kafka messages as a new field; rows before the ALTER TABLE have the field as null. The Iceberg table does NOT automatically add the column — the Iceberg schema and the incoming Debezium message schema are now out of sync, and without intervention the Spark/Flink consumer writing to Iceberg will fail or silently drop the new field. The fix: run `ALTER TABLE <iceberg_table> ADD COLUMN device_os VARCHAR` in Spark SQL before the consumer resumes. Iceberg supports schema evolution natively — adding a column is metadata-only and non-breaking; existing rows read the new column as NULL. Order of operations: add the column in Iceberg FIRST, then let the consumer resume. You do not need to stop the Debezium connector or replay history — only the consumer writing to Iceberg needs to be paused briefly. Iceberg assigns each column a unique field ID internally, so renaming or reordering columns later is safe (Iceberg tracks by ID, not position).

---

## Q2 — Analytical query patterns (week-over-week with LAG)

**Question**: Our product dashboard shows "weekly active users" — basically how many distinct users did something in a given week. Right now we just show the raw number. Our customers want to see the change from the previous week — like "+12% vs last week" or "−300 users vs last week." I know how to compute the weekly count with a GROUP BY, but I don't know how to pull in last week's number in the same query row so I can subtract them. Is there a clean way to do this in SQL without joining the table to itself twice?

**Target topic**: Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL
**Expected answer should cover**: This is the classic use case for the `LAG()` window function — it lets you reference the value from the previous row (previous week) without a self-join. Step 1: compute weekly active users with GROUP BY week using `date_trunc('week', occurred_at)` in Trino. Step 2: apply `LAG(wau, 1) OVER (ORDER BY week_start)` to pull the prior week's count. Step 3: compute delta as `wau - prior_wau` and percent change with `NULLIF(..., 0)` to avoid division-by-zero. Full example:
```sql
WITH weekly AS (
  SELECT
    date_trunc('week', occurred_at) AS week_start,
    COUNT(DISTINCT user_id) AS wau
  FROM iceberg.analytics.events
  GROUP BY 1
)
SELECT
  week_start,
  wau,
  LAG(wau, 1) OVER (ORDER BY week_start) AS prior_week_wau,
  wau - LAG(wau, 1) OVER (ORDER BY week_start) AS wau_delta,
  ROUND(
    (wau - LAG(wau, 1) OVER (ORDER BY week_start)) * 100.0
    / NULLIF(LAG(wau, 1) OVER (ORDER BY week_start), 0),
    1
  ) AS wau_pct_change
FROM weekly
ORDER BY week_start;
```
Explain `LAG(wau, 1)` in plain English: "look back 1 row in the ordered result — i.e., the previous week." First week's row will show NULL for prior_week_wau — that's expected. Mention `LEAD()` as the opposite (looks forward one row). Production note: partition filter on occurred_at so Trino can prune files rather than scanning all history.
