# Iter118 Q2 — Judge Report

**Topic**: Query performance regression diagnosis: oncall workflow for slow queries — concurrency, partition skew, data model, file layout

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Verified against trino.io and iceberg.apache.org docs. EXPLAIN ANALYZE descriptions (Files count, wall time vs CPU time, Input rows/bytes) match Trino's documented output format. The `iceberg.analytics."feature_usage$snapshots"` syntax with `summary['total-data-files']` and `summary['added-data-files']` is correct for Trino's Iceberg connector. `rewrite_data_files` procedure call with `target-file-size-bytes` (268435456 = 256 MB, valid) and `min-input-files` options is correct Iceberg 1.5.x syntax. `expire_snapshots` with `older_than` and `retain_last` is correct. Partition pruning advice on derived expressions like `DATE(event_time)` aligns with Trino's documented limitation. Resource groups (per-user queues, concurrent caps) is an accurate concept. Stack-fit is good: Trino UI URL, MinIO, Kubernetes CronJobs for compaction, Spark for procedures — all match on-prem prod_info.md. The recommendation to "ensure larger table appears first in FROM clause" as a hint is somewhat outdated (modern Trino uses CBO and reorders joins automatically if stats exist), but framed as a hint not a guarantee — minor. |
| Beginner clarity | 5 | Excellent narrative structure: numbered step-by-step checklist where each step has an estimated time, what to look for, red flags, and concrete fix. Tables for "files count interpretation" and "WHERE clause vs pruning result" let a non-OLAP reader pattern-match without theory. Jargon is introduced gently (small files, partition skew, compaction). The quick decision tree at the end is gold for an engineer skimming under oncall pressure. |
| Practical applicability | 5 | Every step has a runnable command, SQL query, or UI action with exact paths. The kubectl/Spark/Trino-UI mix is tailored to the actual prod stack. The "what to do next" answer is unambiguous at every branch. Specifically calls out the compaction CronJob check on the right namespace and the snapshot-expiry-not-just-rewrite gotcha. The decision tree gives a fast path. An oncall engineer with no OLAP background could execute this end-to-end. |
| Completeness | 5 | Covers all four diagnostic categories the question asked about: bad SQL (Step 3, 4, 7), data layout (Step 4, 5, 6), concurrency (Step 1), and "something else" (Step 8 data growth, Step 2 infra-wide check). Includes the maintenance/compaction dimension that is the most likely root cause given the question (2M rows/day across 80 tenants over a month). Wraps up with prioritized top-3 root causes. The only minor gap is no mention of checking Iceberg manifest file count separately from data file count, and no callout that EXPLAIN ANALYZE actually runs the query (resource cost to re-run a slow query), but these are minor. |
| **Average** | **5.0** | **PASS** |

## Verdict
Excellent oncall-style answer that gives a stack-tailored, time-boxed, branching checklist for diagnosing Trino+Iceberg slowdowns. Technically accurate against current Trino 467 and Iceberg 1.5.2 behavior, hits every category the question asked about, and ends with a one-page decision tree the engineer can paste into a runbook.

## What was verified correct (via WebSearch)
- EXPLAIN ANALYZE output includes Input rows/bytes, wall time, CPU time, scheduled time, blocked time — answer's description of "Wall time >> CPU time = I/O-bound" reading is consistent with Trino docs.
- `rewrite_data_files` procedure signature with `options => map(...)` containing `target-file-size-bytes` and `min-input-files` is the documented Iceberg 1.5 Spark procedure form.
- Default target file size is 512 MB; 256 MB (268435456 bytes) is a valid override.
- `$snapshots` metadata table exposes `snapshot_id`, `committed_at`, `operation`, `summary` map with `total-data-files`, `added-data-files` keys — Trino map-access syntax `summary['total-data-files']` is correct.
- Partition pruning on derived expressions like `DATE(event_time)` is a documented Trino limitation (Trino issues #19266, #25436). The answer's recommendation to add a direct partition-column filter as a workaround is consistent with Trino's blog post on date predicates.
- Resource groups with `hardConcurrencyLimit` and per-user selectors is the correct Trino multi-tenant queue control mechanism.

## Errors or gaps found
- LOW: "ensure the larger table appears first in the FROM clause; Trino's planner uses that as a hint" — modern Trino with CBO and ANALYZE'd stats reorders joins automatically. The hint-based ordering matters mainly without stats. Not wrong, but oversimplified for Trino 467.
- LOW: No callout that `EXPLAIN ANALYZE` actually executes the query (cost/risk of re-running a slow query against production), nor mention of `EXPLAIN (TYPE DISTRIBUTED)` as a cheaper alternative for cardinality-only checks.
- LOW: Skew Step 5 mentions `bucket(user_id, 100)` sub-partition fix but doesn't note that adding a partition transform to an existing table requires partition evolution (`ALTER TABLE ... SET PARTITION SPEC`) and only applies to new data — engineer might think it retroactively rebalances.
- LOW: Step 6 file-count check uses snapshot summary which reflects post-commit state across the whole table, but doesn't mention the `$files` or `$partitions` metadata tables which give more granular file-size distribution useful for confirming small-files diagnosis.

## Resource fix recommendations
None required for this answer to pass. Optional enhancements for the resources/ files covering query-perf-regression:
- Add a one-line caveat that `EXPLAIN ANALYZE` re-executes the query; suggest `EXPLAIN (TYPE DISTRIBUTED)` for plan-only inspection.
- Add a note that partition-spec changes via `ALTER TABLE ... SET PARTITION SPEC` only affect new writes, not historical data.
- Mention `$files` and `$partitions` metadata tables as complements to `$snapshots` for small-files diagnosis (file-size histogram per partition).
- Refresh the join-ordering hint guidance to clarify CBO behavior with `ANALYZE`d stats in modern Trino.

## Rubric update
Topic: Query performance regression diagnosis: oncall workflow for slow queries — concurrency, partition skew, data model, file layout
- Prior avg: 5.0 across 2 questions (PASSED)
- This score: 5.0
- New avg: (5.0 + 5.0 + 5.0) / 3 = **5.0** across 3 questions — remains PASSED
