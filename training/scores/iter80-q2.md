# Iter 80 Q2 — Judge Score
**Topic**: Iceberg table maintenance
**Score date**: 2026-05-25

| Dimension | Score |
|---|---|
| Technical accuracy | 4.25 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.81** |

## Points covered
1. Small files problem — clearly explained: Iceberg never modifies in place, each write creates a new Parquet file (288 files/day per partition example concrete and persuasive).
2. Consequences — all three covered: (a) query planning overhead with 10ms/file estimate, (b) storage bloat because old snapshots hold references, (c) eventual ingestion failures from oversized manifests.
3. Detection — `$snapshots` query, EXPLAIN ANALYZE Files count, dashboard timeouts at 60s, MinIO storage growing without ingestion — all practical.
4. Compaction — `rewrite_data_files` Spark CALL with `target-file-size-bytes` and `min-input-files` options; Trino `ALTER TABLE EXECUTE optimize` shown.
5. `expire_snapshots` — both Spark CALL (`older_than`/`retain_last`) and Trino `EXECUTE expire_snapshots(retention_threshold => '30d')` shown.
6. `remove_orphan_files` — both syntaxes shown, 3-day safety window explained, MinIO physical deletion noted.
7. Correct ordering: compaction -> expire snapshots -> remove orphan files -> rewrite manifests. Trino 7-day min-retention floor for expire_snapshots correctly called out with the catalog property name `iceberg.expire-snapshots.min-retention`.
8. `rewrite_manifests` correctly labeled Spark-only.
9. Commit conflict warning during simultaneous ingestion + compaction.
10. Ongoing schedule recommendations after the recovery (nightly + weekly cadence).

## Issues
1. **Technical accuracy bug in the diagnostic SQL** (lines 34–39): The `$snapshots` metadata table in Trino does **not** have top-level columns `added_data_files_count` or `total_data_files_count`. These values live inside the `summary` map column (keys `added-data-files` and `total-data-files`). The query as written will fail in Trino with a "column does not exist" error. The columns `added_data_files_count` and `existing_data_files_count` are actual columns on the `$manifests` table, which appears to be the source of confusion. Correct Trino form would be: `SELECT snapshot_id, committed_at, summary['added-data-files'], summary['total-data-files'] FROM iceberg.analytics."events$snapshots" ORDER BY committed_at DESC LIMIT 10;`
2. Minor: the "Trino 467 equivalent" framing is helpful and matches prod_info.md.
3. The "10 ms per file" planning-overhead figure is illustrative but slightly hand-wavy — fine as an order-of-magnitude estimate but a careful reader might object. Acceptable.

## Accuracy verification (WebSearch)
- Verified `ALTER TABLE ... EXECUTE optimize` is correct Trino syntax — confirmed by trino.io Iceberg connector docs.
- Verified `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '30d')` is correct — confirmed.
- Verified `iceberg.expire-snapshots.min-retention` default of 7 days is correct — confirmed by Trino docs.
- Verified `CALL iceberg.system.rewrite_manifests` is Spark-only (no Trino equivalent) — correct.
- Verified `$snapshots` schema: columns are `committed_at`, `snapshot_id`, `parent_id`, `operation`, `manifest_list`, `summary` map. The answer's direct-column access of `added_data_files_count`/`total_data_files_count` is **incorrect** for Trino.
- Verified `CALL iceberg.system.rewrite_data_files` accepts `target-file-size-bytes` and `min-input-files` options — correct.

## Resource fix needed?
Yes — minor. The diagnostic snapshot query is a recurring weak spot. Resource should explicitly show that `$snapshots` exposes file counts via the `summary` map (e.g., `summary['total-data-files']`) and that direct `total_data_files_count`/`added_data_files_count` columns belong to `$manifests`, not `$snapshots`. A side-by-side "diagnostic queries for Trino vs. Spark" snippet would prevent this from recurring (it has shown up in earlier iterations too).

## Updated topic average: 4.630 / 11 questions
Prior avg 4.612 across 10 questions; new running avg = (4.612 * 10 + 4.81) / 11 = **4.630** across 11 questions. Status: **PASSED**.
