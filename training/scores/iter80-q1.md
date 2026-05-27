# Iter 80 Q1 — Judge Score

**Topic**: Multi-tenant analytics: isolating customer data in SaaS
**Question**: One specific tenant's dashboard is consistently slow while all others are fine. We partition by tenant_id. Where do we start diagnosing this?
**Score date**: 2026-05-25

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Concurrency-first framing, EXPLAIN ANALYZE for file count, partition skew query, resource group assignment check via `system.runtime.queries.resource_group_id`, and query change diff are all correct. **Bug**: the `$snapshots` query selects `added_data_files_count` and `total_data_files_count` as direct columns — those columns belong to the `$manifests` table, not `$snapshots`. In `$snapshots` they live inside the `summary` map (e.g., `summary['total-data-files']`, `summary['added-data-files']`). The query as written will fail with "Column 'added_data_files_count' cannot be resolved". Also, "every file takes 10–50 ms" is a hand-wavy rule of thumb, not a documented constant. |
| Beginner clarity | 4.5 | Jargon (partition pruning, partition skew, compaction, small files, resource groups) is unpacked in context. Concrete file count thresholds in a table make the EXPLAIN ANALYZE step actionable. The numeric example (10,000 files × 30 ms = 5 min overhead) is vivid even if approximate. Refresh-storm framing in step 1 is approachable. |
| Practical applicability | 4.5 | Targeted at this production stack (Trino 467 + Iceberg + JWT auth + resource groups). The Trino UI URL, the `system.runtime.queries` selector test, the partition-skew SQL, and the resource group selector failure mode (`global` instead of `global.tenant_acme`) are all directly actionable. The bad `$snapshots` query is the only thing the engineer can't run as-is. |
| Completeness | 4.5 | Hits all 7 checklist points: concurrency first, EXPLAIN ANALYZE for file count, partition skew, compaction/small files, query change detection, resource group verification, and clear prioritization (the "Quick diagnosis flow" at the bottom + "Start there" guidance). The 6-step structure + summary flow is well-scoped. Doesn't explicitly call out checking the `partition` projection in EXPLAIN ANALYZE output (showing whether tenant_id was actually pushed down), but otherwise complete. |
| **Average** | **4.25** | |

## Points covered

1. **Concurrency check first** — YES, step 1, with `system.runtime.queries` query and refresh-storm framing
2. **EXPLAIN ANALYZE shows file count** — YES, step 2, with a threshold table for interpreting file counts
3. **Partition skew check** — YES, step 3, with COUNT(*) per tenant_id query
4. **Compaction/small-files check** — YES, step 4, but the `$snapshots` query is malformed (see Issues)
5. **Query change detection** — YES, step 5, comparing today's query vs two weeks ago, including the `Input rows` delta indicator
6. **Resource group assignment verification** — YES, step 6, with the `global` vs `global.tenant_acme` failure mode
7. **Clear prioritization** — YES, "Quick diagnosis flow" + "Most one-tenant slowdowns trace to #1 or #2. Start there."

## Issues

1. **`$snapshots` columns are wrong** (technical accuracy hit). The query
   ```sql
   SELECT snapshot_id, added_data_files_count, total_data_files_count
   FROM iceberg.analytics."events$snapshots"
   ```
   will fail. These columns exist in `$manifests`. In `$snapshots`, file counts live in the `summary` map. Correct alternatives:
   ```sql
   -- Option A: $snapshots summary map
   SELECT snapshot_id, committed_at,
          summary['total-data-files']  AS total_data_files,
          summary['added-data-files']  AS added_data_files,
          summary['total-records']     AS total_records
   FROM iceberg.analytics."events$snapshots"
   ORDER BY committed_at DESC LIMIT 5;

   -- Option B: $manifests for per-manifest counts
   SELECT added_data_files_count, existing_data_files_count, deleted_data_files_count
   FROM iceberg.analytics."events$manifests";
   ```
   Alternatively, `$files` gives the live per-file row.

2. "Every file takes 10–50 ms to open" is presented as fact but is environment-dependent. Could be softened.

3. EXPLAIN ANALYZE step doesn't tell the engineer where to look in the output ("Input: X rows (Y files)" line in the table scan operator) — assumes they know.

## Accuracy verification (via WebSearch)

- `system.runtime.queries` having a `resource_group_id` column: **confirmed** in Trino docs (added in release 318 / 0.206).
- `events$snapshots` table syntax with double-quoted identifier: **correct syntax** for the Iceberg connector.
- `$snapshots` schema (per Trino 481 Iceberg connector docs): columns are `committed_at, snapshot_id, parent_id, operation, manifest_list, summary`. `total_data_files_count` and `added_data_files_count` are **NOT** in `$snapshots`.
- `$manifests` schema (per Trino 481 Iceberg connector docs): does contain `added_data_files_count, existing_data_files_count, deleted_data_files_count`.
- EXPLAIN ANALYZE in Trino does expose input rows and file counts per scan operator: **confirmed** by Trino docs.

## Resource fix needed?

**Yes (small).** Update `resources/05-multi-tenant-analytics.md` (or wherever the compaction check is documented) so the `$snapshots` example uses `summary['total-data-files']` / `summary['added-data-files']`, OR points to `$manifests`/`$files` for direct columns. This same bug could recur in future answers about Iceberg maintenance and small-files diagnosis.

## Updated topic average

Prior: 4.420 across 76 questions → sum 335.92.
New: (335.92 + 4.25) / 77 = 340.17 / 77 ≈ **4.418 across 77 questions**. **PASSED**.
