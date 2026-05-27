# Iter283 Q2 — Federate vs Ingest: 20M-Row Slowly-Changing Postgres accounts Table

## Answer

At 20 million rows joined on every analytics query, you're above the federate-comfortably threshold. But before you commit to ingesting, verify that your slowness isn't caused by a fixable tuning issue — because federation with dynamic filtering can be fast for selective joins.

## The structural costs of your current setup

Three things make federating a 20M-row table expensive:

1. **JDBC row-by-row overhead**: Every row from Postgres comes over JDBC as a serialized row-oriented object. This is inherently slower than reading columnar Parquet from MinIO.

2. **Single-threaded scan**: The PostgreSQL connector in OSS Trino 467 runs as a single task — all 20M rows stream through one JDBC connection on one Trino worker thread. The Iceberg side can parallelize across 20+ workers; the Postgres side can't. This single thread becomes the bottleneck.

3. **No pre-computed join**: Every analytics query re-executes the full federation. Dynamic filtering helps (Trino builds an IN-list of matching account IDs and pushes it into the Iceberg scan to prune files), but it only works if certain conditions are met.

## Tune first — verify the real bottleneck

Run `EXPLAIN ANALYZE` on your slowest query and check these two things:

**1. Is dynamic filtering actually firing?**
Look for `dynamicFilterSplitsProcessed > 0` on the Iceberg scan. If it shows `0`, the Postgres build took more than Iceberg's default wait timeout (1 second) and the filter timed out without pruning anything.

Quick fix — raise the timeout per session:
```sql
SET SESSION iceberg.dynamic_filtering_wait_timeout = '15s';
```

**2. Are your predicates pushing down to Postgres?**
Look at the `TableScan[app_pg:public.accounts]` node in the EXPLAIN output. It should show your WHERE clause filters as a constraint annotation. If the scan is bare (no constraint), all 20M rows are coming over JDBC.

Also check: if you're joining without a selective WHERE on `accounts`, dynamic filtering builds a huge IN-list (≥256 values gets compacted to a range by Trino's `domain-compaction-threshold`), and the Iceberg scan is barely pruned. Adding a selective predicate on `accounts` (e.g., `WHERE a.plan IN ('enterprise', 'pro')`) can cut the Postgres scan from 20M to a few hundred thousand rows.

**If your query is fast (<1s) with these fixes applied, keep federating.** The overhead is architectural, not fundamental.

## When to ingest (your case likely qualifies)

Copy `accounts` into Iceberg if:
- Queries are still slow (>2s) even with dynamic filtering firing and predicates pushing down
- The Postgres read replica is sustaining high CPU from Trino JDBC traffic
- You're running federation queries frequently (dozens+ per hour)

At 20M rows, the `accounts` table is roughly 150–300 MB compressed in Parquet. A single daily `INSERT INTO iceberg.analytics.accounts SELECT * FROM app_pg.public.accounts` costs minimal Spark compute, and every query after that reads from MinIO columnar storage — 10–20× cheaper per query than JDBC. The break-even against frequent federation is roughly 1–2 weeks.

Additional benefits when both tables are in Iceberg:
- **Broadcast join becomes viable**: If `accounts` compresses to <100 MB in Parquet, Trino can broadcast it to every worker as the join build side, eliminating network shuffle
- **Dynamic filtering is intra-catalog**: No cross-catalog DF coordination; more precise IN-lists; no 1-second timeout pressure
- **Zero load on Postgres replica**: JDBC traffic drops to only the ingestion job

## Initial load

```sql
-- One-time CTAS to copy accounts into Iceberg
CREATE TABLE iceberg.analytics.accounts
WITH (
  format = 'PARQUET',
  partitioning = ARRAY[]  -- no partition needed for a dimension table this size
)
AS SELECT * FROM app_pg.public.accounts;
```

## Keeping it in sync (a few hundred updates/day)

Since `accounts` changes slowly, run an incremental MERGE every hour or overnight:

```sql
MERGE INTO iceberg.analytics.accounts AS tgt
USING (
  SELECT *
  FROM app_pg.public.accounts
  WHERE updated_at >= (current_timestamp - INTERVAL '2' HOUR)  -- overlap for safety
) AS src ON tgt.id = src.id
WHEN MATCHED AND src.updated_at > tgt.updated_at THEN UPDATE SET
  plan = src.plan,
  status = src.status,
  name = src.name,
  updated_at = src.updated_at
WHEN NOT MATCHED THEN INSERT VALUES (src.id, src.plan, src.status, src.name, src.updated_at);
```

The upper-bound watermark prevents races where rows arrive during the MERGE window.

## Hybrid option (if you need sub-minute freshness on recent changes)

If plan changes need to appear in dashboards within minutes:

```sql
CREATE OR REPLACE VIEW analytics.accounts_live AS
-- Historical: pre-materialized in Iceberg (fast, columnar)
SELECT id, plan, status, name, updated_at FROM iceberg.analytics.accounts
WHERE updated_at < (current_timestamp - INTERVAL '1' HOUR)

UNION ALL

-- Live tail: last hour from Postgres (only a handful of rows in flight)
SELECT id, plan, status, name, updated_at FROM app_pg.public.accounts
WHERE updated_at >= (current_timestamp - INTERVAL '1' HOUR);
```

This keeps Postgres load minimal (only recent changes are federated), gives sub-minute freshness on new account updates, and serves all historical queries from Iceberg.

## Decision summary

| Situation | Recommendation |
|---|---|
| DF firing, predicates pushing, queries <1s | Keep federating — no action needed |
| DF timing out or predicates not pushing | Raise DF wait timeout to 15s, add selective WHERE first |
| Queries still >2s after tuning | Copy to Iceberg — you've hit the structural JDBC limit |
| Need sub-minute freshness on changes | Hybrid UNION ALL view (Iceberg historical + live Postgres tail) |

For your case (20M rows, every analytics query, already feeling sluggish), the data strongly favors ingesting into Iceberg with an hourly incremental sync.
