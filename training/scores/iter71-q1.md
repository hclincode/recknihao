# Iter71 Q1 Score

## Scores
| Dimension | Score |
|---|---|
| Completeness | 5 |
| Accuracy | 5 |
| Clarity | 5 |
| No hallucination | 5 |
| **Final** | **5.00** |

## Points covered
All 5 required points were covered cleanly:

1. **Targeted row-level DELETE scoped to tenant_id** — Covered in section (a). Explicitly contrasts against partition drop and explains why partition drop wipes all tenants for those dates.
2. **Direct MinIO file deletion is unsafe** — Covered in section (b). Lists three specific failure modes: dangling metadata pointers / file-not-found errors, broken time-travel, Hive Metastore vs MinIO inconsistency.
3. **Iceberg DELETE creates delete files (MoR), bytes remain** — Covered in section (c). Explicitly names "delete files," explains they are markers, notes that `mc ls` would still find the bytes, and labels this as a GDPR violation.
4. **Physical removal = rewrite_data_files + expire_snapshots + remove_orphan_files** — All three procedures covered in section (d) with correct Spark SQL syntax. The role of each step is explained: rewrite compacts away delete markers, expire_snapshots is the step that issues physical DELETEs to MinIO, remove_orphan_files cleans up files from crashed ingest jobs. Engineer also correctly notes that `CALL iceberg.system.*` procedures are Spark-only (not Trino) — matches prod_info.md stack.
5. **Verification checklist (query + metadata + storage)** — Covered with concrete commands for each: `SELECT COUNT(*)`, `events$files` metadata table, `mc ls --recursive`.

Additional strong elements:
- Failure-mode table at the end reinforces the chain reasoning.
- The `INTERVAL '0' DAY` aggressive-expiry caveat is correctly flagged as GDPR-specific and irreversible.
- Production-stack alignment is explicit (Spark for procedures, Trino for DELETE, MinIO for storage verification).

## Issues found
None of substance. Technical claims verified against official Iceberg and Trino docs:
- `DELETE FROM iceberg.<schema>.<table> WHERE ...` is valid Trino merge-on-read syntax for Iceberg v2 tables. [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html), [Starburst blog on Iceberg DML in Trino](https://www.starburst.io/blog/apache-iceberg-dml-update-delete-merge-maintenance-in-trino/)
- `CALL iceberg.system.expire_snapshots(...)` removes data files no longer referenced by a non-expired snapshot — i.e., issues actual storage DELETEs. [Iceberg maintenance docs](https://iceberg.apache.org/docs/latest/maintenance/), [Iceberg Spark procedures](https://iceberg.apache.org/docs/1.5.1/spark-procedures/)
- `CALL iceberg.system.rewrite_data_files(table => ..., where => '...')` — the `where` parameter is supported and is the documented way to scope rewrite to a filter. [Iceberg 1.5.1 Spark procedures](https://iceberg.apache.org/docs/1.5.1/spark-procedures/)
- `CALL iceberg.system.remove_orphan_files(...)` lists the table location and removes files not referenced by any valid snapshot, with a default 3-day age guard. [Iceberg Spark procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)

Minor (not score-affecting) omissions:
- Does not mention the known Iceberg + S3FileIO bug where `remove_orphan_files` can fail in some Spark/Iceberg combinations on MinIO/S3 (issues #3838, #12765). Worth a teacher note for a future iteration but not required for completeness here.
- Does not mention 30-day GDPR response window or that the audit log for the deletion (snapshot ID, timestamp, operator) should also be retained as evidence. Nice-to-have, not required by the rubric.

## Resource fix needed?
No. The answer is at the ceiling of all four dimensions for the asked question. Optional future enhancement: add a brief callout in the GDPR-purge resource about the `remove_orphan_files` + S3FileIO compatibility caveat for MinIO deployments.
