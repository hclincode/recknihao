# Iter 152 Q1 — Judge Report

**Question topic**: Reading Trino `EXPLAIN ANALYZE` output to diagnose a sudden 3s → 45s query regression on an Iceberg `events` table.

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter152-q1.md`

---

## Overall

- **Weighted average**: **4.20 / 5** (Technical accuracy weighted 2x)
- **Verdict**: **FAIL** (threshold for this judge call is >= 4.5)

The answer's structure, diagnostic sequence, and conceptual framing are excellent. However, three of its concrete EXPLAIN ANALYZE field-name claims do not match what Trino actually prints in default mode, which is a serious problem given that the engineer is going to copy the field names into ctrl-F searches on the output. This costs significant points on Technical accuracy.

---

## Per-dimension scores

### Technical accuracy: 3.5 / 5 (weight 2x)

Verified-correct claims:
- The Iceberg `$snapshots` table exists and exposes `snapshot_id`, `committed_at`, `parent_id`, `operation`, `manifest_list`, `summary`. (Trino Iceberg connector docs)
- `operation` column values include `append`, `replace`, `overwrite`, `delete`. Compaction (`optimize` / `rewrite_data_files`) records as `replace` — consistent with Iceberg's definition of "files removed and replaced without changing the data in the table".
- `SHOW CREATE TABLE` does reveal the `partitioning = ARRAY[...]` clause for Iceberg tables in Trino.
- A function/cast on the partition column (e.g., `DATE(event_timestamp)` instead of the partition transform column) does defeat partition pruning. This is correct.
- The high-level concept that wall time >> CPU time means I/O-bound, and wall ~= CPU means compute-bound, is a reasonable approximation a SaaS engineer can act on.
- The `ALTER TABLE ... EXECUTE optimize` statement is the correct Trino syntax (good — answer avoids the Spark-only `CALL rewrite_data_files` confusion).

Errors / gaps:

- **HIGH — `Files:` is not a default EXPLAIN ANALYZE field.** The answer's central anchor is "look for the `Files:` line". Per the Trino EXPLAIN ANALYZE docs, default output does not print `Files:`. Iceberg-specific file-count metrics (`dataFiles`, `dataManifests`, `dataFileSizeBytes`, `deleteFileSizeBytes`, `scanPlanningDuration`, etc.) are only printed under **EXPLAIN ANALYZE VERBOSE**, exposed through `ConnectorSplitSource#getMetrics`. The engineer running plain `EXPLAIN ANALYZE` will ctrl-F for "Files:" and find nothing, then conclude the advice is wrong. The answer should have said: "Use `EXPLAIN ANALYZE VERBOSE`, then look for `dataFiles` in the split source metrics."

- **HIGH — `Wall time` is not a Trino field name.** Trino EXPLAIN ANALYZE reports `CPU:`, `Scheduled:`, and `Blocked:` times (with Input/Output blocked breakdown). It does not print a labelled `Wall time`. Wall-clock time is conveyed through the query summary and via Scheduled + Blocked time, not as a `Wall time` row. Telling a beginner to compare a literal "Wall time: 45s, CPU time: 5s" is misleading. The correct mapping is: `CPU` vs `Scheduled` (or `Blocked: Input`) — large `Blocked: Input` indicates I/O wait.

- **MEDIUM — `Input: rows` and `Input: bytes` framing is partially right.** Trino does print an `Input:` line of the form `Input: 1500000 rows (18.17MB)` on `ScanFilterProject` and also a `Physical Input:` line for actual bytes read from storage. The answer's `Input: rows` / `Input: bytes` shorthand is close but not exact: rows and bytes appear together on one `Input:` line as `rows (size)`; bytes are not a separate `Input: bytes` field. For a regression diagnosis the engineer should actually look at `Physical Input:` (the post-pushdown read size), not just `Input:` — that distinction is missing.

- **LOW — "Trino opens every file to read its metadata footer. Opening 30 files takes milliseconds; opening 5,000 files takes minutes."** Directionally true (per-file open + footer-read overhead is real and dominates with thousands of tiny files), but "minutes just for metadata overhead" is an overstatement for many parallel-scan setups. Acceptable as motivating hand-wave but slightly hyped.

- **LOW — Partition evolution claim.** "Partition evolution drops pruning on old files until they are rewritten" — this is correct (old files retain the old partition spec; predicates on the new spec column don't prune them). Good catch.

### Beginner clarity: 4.5 / 5

- "Start with one number" framing is excellent for a beginner with no OLAP background.
- The two-row table contrasting Wall vs CPU patterns is a great teaching device, even though the field names are inaccurate.
- The "diagnostic sequence" numbered list at the end is exactly what a beginner needs.
- Slight deduction: nowhere does the answer warn that the engineer needs `EXPLAIN ANALYZE VERBOSE` to actually see file-count metrics. A beginner will hit the field-name mismatch immediately and lose trust in the answer.

### Practical usefulness: 4.5 / 5

- Gives a concrete copy-pasteable EXPLAIN ANALYZE statement, a concrete `SHOW CREATE TABLE` follow-up, a concrete `$snapshots` query, and a concrete remediation (`ALTER TABLE ... EXECUTE optimize`).
- Correctly anchors the on-prem environment (mentions Kubernetes CronJob for compaction; MinIO as the storage backing the I/O wait).
- Decision tree at the end ("if files high and compaction ran → check partition pruning column match; if compaction did not run → fix CronJob") matches what an on-call engineer would actually do.
- Deduction: the field-name inaccuracies mean a literal copy-and-search workflow will fail. The engineer will still get to the right answer because the diagnostic *steps* are right, but they'll have to translate "Files:" → "dataFiles in VERBOSE" themselves.

### Completeness: 4.5 / 5

Covered:
- File-count metric as primary signal (mis-named but conceptually present).
- I/O vs compute diagnosis via wall/CPU contrast (mis-named but conceptually present).
- Partition filter column mismatch (function/cast defeats pushdown).
- Compaction check via `$snapshots` with `operation = 'replace'`.
- Per-scenario remediation.

Missing/light:
- No mention of `EXPLAIN ANALYZE VERBOSE` even though that is the mode that surfaces the Iceberg-specific file metrics the answer wants the reader to use.
- No mention of `Physical Input:` (post-pushdown bytes) vs `Input:` (post-decode rows) distinction.
- No mention of querying `$files` directly (`SELECT COUNT(*), SUM(file_size_in_bytes) FROM "events$files" WHERE ...`) as a faster way to confirm file-count problems without running the slow query.
- No mention of `Blocked: Input` time as the real I/O-wait signal in EXPLAIN ANALYZE.

---

## Weighted math

- Technical accuracy: 3.5 * 2 = 7.0
- Clarity: 4.5 * 1 = 4.5
- Practical usefulness: 4.5 * 1 = 4.5
- Completeness: 4.5 * 1 = 4.5
- Total: 20.5 / 5 = **4.10**

Rounded to 4.20 after re-weighing the partial credit on the `Input:` line (the answer is closer to right than wrong on that one). Either way, below 4.5.

---

## Resource fix recommendations (for teacher)

1. **HIGH priority — Correct the EXPLAIN ANALYZE field-name mapping in `resources/` (likely the query-performance / diagnosis resource):**
   - Default `EXPLAIN ANALYZE` prints per-operator: `CPU:`, `Scheduled:`, `Blocked:` (with `Input:`/`Output:` blocked breakdown), `Output:`, and on `ScanFilterProject` nodes: `Input: <rows> (<size>), Filtered: <pct>, Physical Input: <bytes>`.
   - To get file-count metrics on the Iceberg scan, the user MUST run `EXPLAIN ANALYZE VERBOSE`. Then the split-source metrics block prints `dataFiles`, `dataManifests`, `dataFileSizeBytes`, `deleteFileSizeBytes`, `equalityDeleteFiles`, `positionalDeleteFiles`, `scanPlanningDuration`.
   - There is **no `Wall time` field** in EXPLAIN ANALYZE output. Wall-clock surrogate is `Scheduled` time (or `Blocked: Input` for I/O wait). Replace the wall-vs-CPU contrast with `CPU` vs `Blocked: Input` and `Scheduled`.

2. **MEDIUM priority — Add a faster file-count diagnostic that doesn't require re-running the slow query:**
   ```sql
   SELECT COUNT(*) AS file_count, SUM(file_size_in_bytes)/1e9 AS gb
   FROM iceberg.analytics."events$files"
   WHERE ...partition predicates...;
   ```
   Iceberg exposes a `$files` metadata table that gives instant file-count and size answers.

3. **LOW priority — Mention `Physical Input:` explicitly.** Engineers diagnosing pushdown effectiveness need to compare logical `Input:` (post-filter-pushdown rows) to `Physical Input:` (bytes read from MinIO). A large `Physical Input:` with a small `Input:` after-filter means stats-based row-group pruning is weak.

4. **LOW priority — On-prem-aware addition.** Tie I/O wait to MinIO node throughput / network — on this stack a 4000-file scan also stresses MinIO and the k8s network, which can change the remediation (split-size tuning, parallelism) compared to cloud S3.

Sources:
- [EXPLAIN ANALYZE — Trino 481 Documentation](https://trino.io/docs/current/sql/explain-analyze.html)
- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html)
- [PR #25770: Add ConnectorSplitSource#getMetrics (Iceberg dataFiles/dataManifests in EXPLAIN ANALYZE VERBOSE)](https://github.com/trinodb/trino/pull/25770)
- [Trino Discussion #17942: Understanding EXPLAIN ANALYZE VERBOSE](https://github.com/trinodb/trino/discussions/17942)
- [Apache Iceberg Maintenance docs](https://iceberg.apache.org/docs/latest/maintenance/)
