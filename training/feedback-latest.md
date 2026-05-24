# Feedback — Iteration 51 (Extended Phase)

**Date**: 2026-05-24
**Phase**: Extended (continuing until 2026-05-30 12:00 CST)
**Iteration average**: 4.25
**Status**: All 20 topics PASSED.

---

## Iteration 51 score summary

| Question | Topic(s) | Score |
|---|---|---|
| Q1 — Storage sizing for MinIO migration (250 GB Postgres, 500M rows, 50M/month growth) | Storage sizing and growth estimation | 4.25 |
| Q2 — Cohort retention query in Trino (7/30/90-day milestone pattern) | Analytical query patterns on Iceberg+Trino | 4.25 |
| **Iteration average** | | **4.25** |

---

## Topic score updates after iteration 51

| Topic | Prior avg | Prior q | New avg | New q | Change |
|---|---|---|---|---|---|
| Storage sizing and growth estimation | 4.375 | 2 | 4.333 | 3 | −0.042 (Q1 at 4.25) |
| Analytical query patterns on Iceberg+Trino | 4.375 | 2 | 4.333 | 3 | −0.042 (Q2 at 4.25) |

Both topics remain PASSED (well above 3.5).

---

## What went well

**Q2 pedagogical structure (4.25).** The three-CTE framing (first_events → cohort_sizes → returns) was strong and well-explained. Correct Trino `date_diff` syntax. `BETWEEN 1 AND 7` correctly excludes the day-0 signup event. Incomplete-data gotcha (`date_diff >= 90` filter) was present and explained. Sample output block helped orient the reader.

**Q1 Postgres-baseline decomposition (4.25).** Correct identification of all Postgres overhead sources (indexes 30–50%, MVCC dead tuples, row headers). Runnable `pg_total_relation_size` / `pg_indexes_size` diagnostic query. Per-column Parquet compression breakdown. MinIO EC:4+2 = 1.5x overhead correctly stated. expire_snapshots operational trap included.

---

## Issues

### Q1 factual error: Iceberg default codec is Zstd, not Snappy (since 1.4.0)

The answer stated "Iceberg's default codec is Snappy." This is incorrect for Iceberg 1.5.2 (production version). Iceberg switched the default Parquet write codec to **Zstd** in version 1.4.0. The "switch to Zstd to get 20–30% better compression" recommendation in the answer is therefore moot for the production stack — engineers are already on Zstd by default unless they overrode it explicitly.

**Fix applied**: `resources/11-lakehouse-storage-sizing.md` — added "Default Parquet compression codec" subsection after the compression-by-column-type table, stating Zstd as the 1.4.0+ default with verification and change SQL for both Spark and Trino.

### Q2 critical bug: SUM(CASE WHEN ... THEN 1) counts events not distinct users

The `returns` CTE used:
```sql
SUM(CASE WHEN date_diff('day', f.first_event_at, e.occurred_at) BETWEEN 1 AND 7 THEN 1 ELSE 0 END) AS returned_7d
```
This counts event rows, not distinct users. A user who fires 5 events in the 7-day window contributes 5 to `returned_7d` and 1 to `total_users`, producing retention percentages above 100%.

The correct idiom is:
```sql
COUNT(DISTINCT CASE WHEN date_diff('day', f.first_event_at, e.occurred_at) BETWEEN 1 AND 7 THEN e.user_id END) AS returned_7d
```
`COUNT(DISTINCT ...)` ignores NULLs — when the CASE condition is false it returns NULL, which is excluded from the count.

**Fix applied**: `resources/07-analytical-query-patterns.md` — added "Milestone-retention variant: % came back in 7 / 30 / 90 days" section in the cohort analysis block. Includes the full three-CTE query with `COUNT(DISTINCT CASE WHEN ... THEN user_id END)`, an explicit callout that `SUM(CASE WHEN ... THEN 1)` double-counts repeat events, the incomplete-cohort filter explanation, the overlapping-vs-non-overlapping bucket note, and the timestamp-vs-date precision caveat.

### Recurring beginner clarity gap

"Dictionary encoding," "delta encoding," "erasure coding," "EC:4+2," "rewrite_data_files," "expire_snapshots" appear in Q1 without inline plain-English glosses. Q2 uses "cohort," "CTE," "BETWEEN," and "date_diff" without glosses for a beginner. This is a persistent multi-iteration gap that is tracked but not yet fully addressed in the resources.

---

## Resource fixes applied in iter51

**HIGH priority — COMPLETED**: `resources/11-lakehouse-storage-sizing.md`
- Added "Default Parquet compression codec" subsection: Zstd is the default for Iceberg 1.4.0+, not Snappy. Includes `SHOW CREATE TABLE` verification command, `ALTER TABLE SET TBLPROPERTIES` syntax for both Spark and Trino, and a note that existing files retain their original codec until `rewrite_data_files` runs.

**HIGH priority — COMPLETED**: `resources/07-analytical-query-patterns.md`
- Added "Milestone-retention variant: % came back in 7 / 30 / 90 days" section. Correct full three-CTE query using `COUNT(DISTINCT CASE WHEN ... THEN user_id END)`. Explicit warning against `SUM(CASE WHEN ... THEN 1)` with explanation of why it over-counts. Incomplete-cohort filter. Overlapping vs non-overlapping bucket note. Timestamp vs date precision caveat.

---

## Weakest topics heading into iter52

| Topic | Avg | q |
|---|---|---|
| Multi-tenant analytics | 4.270 | 52 |
| Postgres-to-Iceberg ingestion | 4.276 | 52 |
| Storage sizing and growth estimation | 4.333 | 3 |
| Analytical query patterns on Iceberg+Trino | 4.333 | 3 |
| Iceberg partition design | 4.500 | 6 |

Novel angles for iter52:
- **Analytical query patterns**: First test of the milestone-retention pattern post-fix (should now score correctly with COUNT(DISTINCT CASE WHEN)); window functions — LAG/LEAD for week-over-week retention delta, RANK/NTILE for percentile distribution (only 3q so far)
- **Storage sizing**: Test Zstd-default angle now that resource is fixed; cost-per-event formula (parquet_bytes_per_row × monthly_rows / 1B); when to switch from Snappy to Zstd on existing tables (rewrite_data_files cost)
- **Multi-tenant**: JWT claim → resource group selector mapping; OPA integration pattern; GRANT ROLE chain verification (role → group → resource group selector)
- **Postgres-to-Iceberg**: Schema evolution under CDC — adding a column to Postgres, how Debezium schema registry handles it, what happens in Iceberg (ALTER TABLE ADD COLUMN in Spark before consumer resumes)
