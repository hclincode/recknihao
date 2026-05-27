# Judge — Iter 104 Q1

**Topic**: Multi-tenant analytics
**Score**: 4.75 / 5 (Tech 4.5, Clarity 5.0, Practical 5.0, Completeness 4.5)

## Verdict
A strong, production-ready answer that maps cleanly onto the on-prem Spark + Trino + Iceberg 1.5.2 + MinIO stack. The three-step DELETE -> rewrite -> expire model is well-presented, the Trino 7-day expire-snapshots floor is correctly identified as a blocker for an immediate GDPR purge, and Spark is correctly recommended for the one-off erasure. The main technical gap is that the answer presents "DELETE does not rewrite Parquet files" as universal, when in fact this is only true when the table uses merge-on-read; copy-on-write (the historical default in Iceberg until recently) does rewrite immediately.

## What was verified correct (via WebSearch)
- DELETE with merge-on-read creates position delete files and leaves Parquet data files untouched — verified against iceberg.apache.org docs and Dremio/Cloudera explainers.
- `CALL iceberg.system.rewrite_data_files(table => ..., where => ..., options => map(...))` — the `where` named parameter is a valid filter argument per the official Spark procedures docs.
- `CALL iceberg.system.expire_snapshots(table => ..., older_than => ..., retain_last => ...)` syntax matches the official Spark procedure signature.
- `CALL iceberg.system.remove_orphan_files(table => ..., older_than => ...)` is correct.
- Trino's `iceberg.expire-snapshots.min-retention` defaults to `7d` and `retention_threshold` must be >= this value, so `'0d'` will fail unless the catalog config is changed and the cluster restarted — verified against trino.io and Starburst forum.
- `ALTER TABLE ... EXECUTE optimize` and `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '...')` are the correct Trino forms.
- Snapshot isolation protects concurrent readers — confirmed.
- Partition pruning on `tenant_id` correctly scopes the DELETE and rewrite — confirmed.

## Errors or gaps
- The flat statement "Iceberg does not rewrite Parquet files" is only true when the table is configured with `write.delete.mode=merge-on-read`. With copy-on-write (still the default in many Iceberg versions/configurations), DELETE will rewrite files synchronously, making step 2 partly redundant. The answer should at minimum note "assuming the table is configured for merge-on-read" or show how to check `write.delete.mode`.
- "Reversible via `rollback_to_snapshot` for ~7 days if needed" — the 7-day window is not a built-in Iceberg guarantee; it depends on the table's snapshot retention properties / when `expire_snapshots` last ran. Minor.
- The Trino OPTIMIZE limitation around position deletes (issue #25279, which the iter104 teacher specifically added to resources/10) is not surfaced here even though the answer steers users to Spark for step 2 anyway. Including this rationale would strengthen the "use Spark" recommendation.
- `older_than => current_timestamp()` combined with `retain_last => 1` works, but if the table has a `min-snapshots-to-keep` or `max-snapshot-age-ms` property set, behavior may differ. A brief callout would be useful for production.

## Resource fix recommendations
- MEDIUM: Add a clear explanation of COW vs MoR DELETE behavior in the multi-tenant deletion section. Show how to inspect `write.delete.mode` on the table and how to set it. Without this, engineers reading the answer may assume the data file is preserved when in fact COW rewrote it immediately.
- LOW: Add a short note on Iceberg snapshot retention properties (`history.expire.min-snapshots-to-keep`, `history.expire.max-snapshot-age-ms`) so that `expire_snapshots(retain_last => 1)` is not surprising when these are also set on the table.
- LOW: Cross-link the GDPR delete section to the Trino OPTIMIZE position-delete limitation note (issue #25279) so the "use Spark" recommendation is grounded in a concrete Trino gap, not just the 7-day floor.

## Updated topic state
- Multi-tenant analytics: 99 questions / running avg 4.447
