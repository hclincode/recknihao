# Iter65 Q2 Judge Feedback
## Score: 5.0 / 5.0
| Dimension | Score |
|---|---|
| Completeness | 5 |
| Accuracy | 5 |
| Clarity | 5 |
| No hallucination | 5 |
| **Average** | **5.0** |

## Points covered
All 5 expected-coverage points fully addressed:

1. **Yes, simple DELETE leaves data on disk + MVCC explained** — Explicit "Yes, it's true. A simple DELETE leaves the customer's bytes sitting on MinIO." Names MVCC, explains that "every write to an Iceberg table creates an immutable snapshot, and old snapshots are kept" and that DELETE "writes a small delete file — a marker that says 'ignore these rows in these data files.'" Concrete framing: "regulator running `mc ls --recursive` against your MinIO storage will still find Acme's data bytes sitting there."

2. **Full 4-step sequence in correct order** — DELETE → rewrite_data_files → expire_snapshots → remove_orphan_files. Explicit "Run these **in this order**. Each step builds on the previous one."

3. **Why each step is needed, with on-disk explanations:**
   - DELETE: creates delete files / markers, "queries return 0 rows, but the bytes are still on MinIO."
   - rewrite_data_files: "Spark reads the affected Parquet files, applies the delete markers in memory, and writes **new** Parquet files without Acme's rows... But **the old Parquet files still exist on MinIO** because the prior snapshot still references them."
   - expire_snapshots: "THIS IS WHERE THE BYTES GET DELETED" — "issues S3 DELETE calls against MinIO. This is the moment Acme's bytes are physically removed from storage."
   - remove_orphan_files: Catches files from "Spark ingestion jobs that crashed mid-write — the file got uploaded but the snapshot commit failed."

4. **Verification at three levels** — query layer (COUNT = 0), metadata layer ($files and $snapshots), storage layer (mc ls). Explicitly calls out `$files` as "your strongest evidence for a regulator." Provides runnable SQL for both metadata tables.

5. **Practical notes** — `CALL iceberg.system.*` is "Spark SQL only" with the Trino equivalent (`ALTER TABLE ... EXECUTE expire_snapshots`) noted as a fallback. "One table at a time" repetition instruction with examples (events, orders, users, sessions). retain_last=1 warning: "aggressive — only use this for GDPR deletions... can cause in-flight queries to fail with 'file not found.'" Automation guidance (Airflow / Kubernetes CronJob). Timing guidance: "as soon as you receive the deletion request, not on day 29."

Bonus content beyond the rubric:
- Numbered 8-item GDPR audit checklist that maps directly to a compliance ticket.
- Clear "If you sign off after only step 1 (the DELETE), orphan files and old snapshot references still hold the customer's bytes. You are not compliant." final warning.
- `older_than => now() - interval '1' day` safety buffer rationale for orphan cleanup ("prevents the procedure from deleting files currently being written by in-flight Spark jobs").

## Factual issues (if any)
None of substance. Parameter names verified against the official Iceberg docs and the production stack:
- `table =>`, `where =>` for rewrite_data_files — correct.
- `table =>`, `older_than =>`, `retain_last =>` for expire_snapshots — correct.
- `table =>`, `older_than =>` for remove_orphan_files — correct.
- The Trino equivalent `ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '0s')` is named with the right form (Trino uses `retention_threshold`, not `older_than`).
- Use of `now()` vs `current_timestamp()` — both are valid Spark SQL functions; resource 05 uses `current_timestamp()` while resource 17 uses `current_timestamp`. The answer's use of `now()` is acceptable Spark SQL syntax (Spark accepts both `now()` and `current_timestamp()`).
- The statement that expire_snapshots "issues S3 DELETE calls against MinIO" is verified by the Iceberg docs ("data files that were deleted by snapshots that are expired will be deleted").

## Notes
This is an exemplary GDPR deletion answer — directly answers the engineer's "yes, it's true, here's why, here's the fix, here's how to prove it" structure. The on-disk explanation at each step is the clearest part; the engineer leaves with a mental model of what is on MinIO at each transition, not just a list of commands to run. The three-layer verification framing (query / metadata / storage) is the right auditor's framing. The numbered audit checklist at the end is the kind of artifact you could paste directly into a JIRA ticket for a compliance officer.

Weakest single item: the answer could have explicitly named "Merge-on-Read (MoR) vs Copy-on-Write (CoW)" to explain *why* rewrite_data_files matters — under MoR (the Iceberg default in many configurations) the original Parquet files contain the deleted tenant's bytes verbatim until rewrite happens. The answer implies this with "Iceberg doesn't erase the customer's Parquet data files" but doesn't name MoR by name. This is a nuance the resource calls out explicitly. Not enough to dock a point because the operational outcome (always run step 2) is correct, but worth mentioning as the one optional improvement.

This is the 65th question on the Multi-tenant topic (already PASSED at 4.352). New running average: 4.362 across 65 questions.
