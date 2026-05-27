# Score: iter56-q1

**Topic**: Multi-tenant analytics
**Score**: 4.8 / 5.0

## Dimension scores
- Completeness: 4/5
- Accuracy: 5/5
- Clarity: 5/5
- No hallucination: 5/5

## What the answer got right
- Correctly explains that a plain DELETE writes a new snapshot with delete files (Merge-on-Read semantics) and leaves the original Parquet bytes on MinIO — directly addresses the user's worry about "marking" vs deleting.
- Provides the correct ordering: DELETE → `rewrite_data_files` → `expire_snapshots`.
- Identifies the right engine for each step: DELETE is Trino-or-Spark, the `CALL iceberg.system.*` procedures are Spark-only.
- Uses correct Iceberg system procedure syntax (`CALL iceberg.system.rewrite_data_files(table => ..., where => ...)` and `CALL iceberg.system.expire_snapshots(table => ..., older_than => ..., retain_last => ...)`).
- Flags the aggressive `older_than => current_timestamp() - interval '0' day, retain_last => 1` as a GDPR-only exception that breaks time-travel — important nuance.
- Mentions the Merge-on-Read caveat that compaction must run before snapshot expiry.
- Verification checklist + summary table at the end gives the engineer an actionable runbook.
- Calls out the rollback window between step 1 and step 3 as a useful safety property.
- Stays inside the production stack (MinIO, Trino, Spark, Iceberg).

## What the answer missed or got wrong
- **`remove_orphan_files` is not mentioned at all.** The expected purge sequence in the rubric is DELETE → rewrite_data_files → expire_snapshots → **remove_orphan_files**. The answer implies `expire_snapshots` alone removes all unreferenced files, but `remove_orphan_files` is the canonical follow-up step that catches files left behind by failed writes or partial commits. For a GDPR sign-off this matters.
- **Metadata-table verification is missing.** The expected answer recommends checking the `$snapshots` metadata table (to confirm no snapshots older than the delete exist) and `$files` (to confirm no files contain the deleted tenant's partition key). The answer instead suggests `mc ls`-style MinIO inspection, which is less precise and doesn't take advantage of Iceberg's built-in introspection tables.
- The Copy-on-Write vs Merge-on-Read distinction is mentioned only obliquely. The answer assumes Merge-on-Read throughout; it does not explain that CoW DELETEs rewrite affected files entirely (no delete-file step), which means step 2 may be a no-op for CoW tables.
- The "time-travel design tension with GDPR" framing — the conceptual core of the question — is implied rather than stated explicitly.

## Recommendation for teacher
The resource at `resources/05-multi-tenant-analytics.md` should add a fourth step (`remove_orphan_files`) to the GDPR sequence and the summary table, and add a verification subsection using `$snapshots` and `$files` metadata tables. Both are already implicitly correct in the resource's other sections (e.g., the Iceberg metadata table leak section discusses `$files` and `$snapshots`), so it's just a matter of cross-linking them into the GDPR runbook. Also worth adding an explicit one-sentence callout that Copy-on-Write tables behave differently in step 2 (the rewrite happens at DELETE time, so step 2 is largely a no-op).
