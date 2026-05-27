# Iter119 Q2 — Judge Report
**Topic**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup (storage bloat from 5-minute micro-batches)

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Iceberg mechanics correct: immutable writes, snapshots reference older files until expired, expire_snapshots is what makes files eligible for deletion, remove_orphan_files physically deletes. Procedure signatures verified against Iceberg 1.5.x docs: `rewrite_data_files` with `options => map('target-file-size-bytes', ...,'min-input-files', ...)` is correct; `expire_snapshots` with named args `table`, `older_than`, `retain_last` is correct (note actual default `retain_last` is 1; default min snapshot age is 5 days at table-level, but using `current_timestamp - interval '30' day` is a valid explicit older_than); `remove_orphan_files` with `older_than` and default 3-day guard is correct; `rewrite_manifests` with just `table` arg is correct. Catalog name `iceberg.system.*` matches the production Trino/Spark catalog naming. Engine labeling is correct — explicitly tells user to run via Spark, not Trino, because Trino's `ALTER TABLE ... EXECUTE` form has fewer options. Math (2M ÷ 14 = ~143K rows; 14 jobs/day × 30 days = 420 snapshots) is right. Minor nit: claim "one manifest file per snapshot" is a simplification (a snapshot's manifest list points to multiple manifest files), but not misleading for a beginner audience. |
| Beginner clarity | 5 | Zero assumed knowledge. The "Iceberg never modifies files in place" framing leads immediately into why old files survive. "Storage debt" framing is excellent. The 3-layer explanation (raw small files → compaction history retention → no expiry) is the clearest decomposition seen across recent iterations. Concrete arithmetic (2M ÷ 5min → 14 jobs → 420 files) anchors the abstract concept. The "temporary spike after compaction — don't panic" callout pre-empts a real beginner confusion. |
| Practical applicability | 5 | Engineer knows exactly what to do: (a) the audit SQL against `$snapshots` is runnable in Trino as-is; (b) the 4-step Spark CALL block is copy-pastable with concrete parameter values (256 MB, retain_last 10, 30 days, 3 days); (c) a recurring schedule is prescribed (nightly compaction + weekly expire/orphan/manifest); (d) two ongoing health metrics with thresholds (<50–100 snapshots, <100 files per partition for <100 GB tables). The "submit via Spark, not Trino" guidance aligns with production stack. The `$files` diagnostic SQL pairs well with iter118's per-partition diagnostic addition in resource 18. |
| Completeness | 5 | Covers why storage bloats (immutability + snapshot retention + no expiry + small-file Parquet overhead), the full 4-step fix in correct order (compact → expire → orphan → manifest), the ongoing prevention schedule, the temporary-spike warning between step 1 and step 2, and ongoing health metrics. Connects micro-batch frequency to the symptom severity. Does not miss any major nuance for the question asked. Could optionally have mentioned MinIO/S3FileIO + remove_orphan_files known issue (cited as a future-iteration teacher note in iter39 rubric), but that is not required for the question. |
| **Average** | **5.0** | **PASS** |

## Verdict
PASS at 5.0/5.0. One of the strongest end-to-end answers seen for the table-maintenance topic. Correctly diagnoses the storage trap, explains the mechanics in beginner-friendly terms, prescribes the canonical 4-step Spark fix with correct procedure signatures for Iceberg 1.5.x, includes runnable diagnostic SQL, schedules ongoing maintenance, and pre-empts the post-compaction spike that often panics first-time operators.

## What was verified correct (via WebSearch)
- `rewrite_data_files` accepts `options => map('target-file-size-bytes', ..., 'min-input-files', ...)` — confirmed via iceberg.apache.org/docs/1.5.1/spark-procedures and Dremio compaction blog. `min-input-files` controls minimum files per partition to trigger rewrite. Default `target-file-size-bytes` is the table property `write.target-file-size-bytes` (default 512 MB), so explicit 256 MB override is valid.
- `expire_snapshots(table, older_than, retain_last)` — confirmed via iceberg.apache.org/docs/latest/spark-procedures and tabular.io cookbook. Named-argument form (`older_than =>`, `retain_last =>`) is the recommended form.
- `remove_orphan_files(table, older_than)` — confirmed, including the default 3-day age guard (matches the answer's 3-day older_than choice).
- `rewrite_manifests(table)` — confirmed as a valid Spark procedure that compacts manifest files.
- Order of operations (compact → expire → orphan → manifest) — confirmed correct. Compaction first creates new files but old files remain referenced by old snapshots. Expire snapshots un-references the old files. Remove orphan files (or expire itself) physically deletes. Rewrite manifests cleans up metadata last.
- `CALL iceberg.system.*` is Spark-only syntax (Trino uses `ALTER TABLE ... EXECUTE` form) — confirmed against trino.io/docs/current/connector/iceberg.html. Answer correctly steers the user to Spark.

## Errors or gaps found
- Minor: "one manifest file per snapshot" oversimplifies. A snapshot has one manifest list, which points to one or more manifest files (typically one per data write task per partition group). Not misleading for the explanation, but technically loose.
- Minor: `expire_snapshots` default `retain_last` is actually 1 (not unlimited), and there is also a table-level `history.expire.max-snapshot-age-ms` default of 5 days. The answer uses explicit `older_than` + `retain_last => 10`, which is fine, but did not call out the table-level default that may already be partially in effect.
- Minor: Did not mention Trino catalog-level `iceberg.expire-snapshots.min-retention` floor (default 7 days) that blocks Trino's `ALTER TABLE EXECUTE expire_snapshots` from going below 7 days — relevant context if the user later tries the Trino form. The answer does say "submit via Spark", which sidesteps the issue, but a one-line callout would help.
- Minor: No mention of the known `remove_orphan_files` + S3FileIO compatibility issue on some Iceberg/Spark combinations against MinIO (iceberg issues #3838, #12765). Production stack is MinIO, so this could bite. Already flagged as a teacher follow-up in iter39 rubric notes.

## Resource fix recommendations
None required for a passing answer. Optional polish for resources/17:
1. Add a one-line callout: "When the schema in `expire_snapshots` does not specify `retain_last`, it defaults to 1 — combined with the table-level `history.expire.max-snapshot-age-ms` default of 5 days. Explicit `older_than` + `retain_last` is recommended for production."
2. Add the deferred MinIO + S3FileIO + `remove_orphan_files` known-issue callout flagged in iter39 (cite iceberg issues #3838 and #12765, workaround: run with Hadoop FileIO or scope via `location` parameter).

## Rubric update
**Topic**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup
- Prior running avg: 4.640 across 12 questions
- New: (4.640 × 12 + 5.0) / 13 = (55.68 + 5.0) / 13 = 60.68 / 13 = **4.668** across 13 questions
- Status: **PASSED** (well above 3.5 threshold)
