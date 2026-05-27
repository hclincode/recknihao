# Iter 146 Q2 — Judge Report

## Question
> An engineer accidentally ran a DELETE that wiped a week of customer records from an Iceberg table. Can the table be rolled back to before the delete, and how?

## Overall Score: 4.90 / 5 — **PASS**

Weighted average:
- Technical accuracy (2x): 5.0 → 10.0
- Clarity (1x): 5.0 → 5.0
- Practical usefulness (1x): 5.0 → 5.0
- Completeness (1x): 4.5 → 4.5
- Total: 24.5 / 5 = **4.90**

---

## Per-dimension scores

### Technical accuracy: 5 / 5
All Trino/Iceberg facts verified against official Trino 481 docs (production runs Trino 467; the documented syntax has been stable since the new table procedure landed in Release 469). Where Trino 467 specifically is concerned, see the note below in "Minor caveats."

Verified-correct claims:
1. **Snapshot model** — every write (INSERT/DELETE/UPDATE/MERGE) creates a new immutable snapshot pointer; rollback is a metadata pointer move that does not touch data files. Correct per Trino "Trino on ice III" and Iceberg spec.
2. **`$snapshots` columns** — `snapshot_id`, `committed_at`, `operation`, `summary` are all real columns; `operation` values include `append`/`replace`/`overwrite`/`delete`. Verified at https://trino.io/docs/current/connector/iceberg.html (Metadata tables).
3. **`$history` columns** — `made_current_at`, `snapshot_id`, `parent_id`, `is_current_ancestor` all correct. Verified at https://trino.io/docs/current/connector/iceberg.html.
4. **Time travel syntax** — `SELECT ... FROM table FOR VERSION AS OF <snapshot_id>` is the documented Trino syntax. Verified.
5. **Rollback syntax** — `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id => <id>)` is valid. The Iceberg connector docs show the positional form (`rollback_to_snapshot(8954597067493422955)`), but Trino's ALTER TABLE EXECUTE explicitly supports the `=>` named-parameter form, and the procedure parameter is `snapshot_id`. The named form is correct and arguably clearer for an SOP. Verified at https://trino.io/docs/current/sql/alter-table.html.
6. **7-day minimum retention** — both `iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention` default to `7d`. Verified.
7. **Rollback is instant / atomic / non-destructive** — correct: only the metadata pointer changes; the prior snapshots remain in history and are time-travelable until `expire_snapshots` removes them.
8. **DELETE files remain on disk** — correct; deleted-row files referenced by the pre-delete snapshot persist as long as that snapshot is retained.

### Clarity: 5 / 5
- Three-step flow (find snapshot → verify → rollback) is the cleanest possible mental model for incident response.
- Inline annotations on what each query does and why are explicit.
- Summary table at the end gives the engineer a runbook they can paste into a postmortem.
- Beginner-friendly framing of "snapshot = pointer to set of Parquet files" makes the operation safe to reason about even for someone with zero Iceberg background.

### Practical usefulness: 5 / 5
- Every SQL statement is copy-pasteable for Trino against the production stack (Trino + Iceberg + Hive Metastore).
- Verification step with COUNT before rollback is exactly the safety check an on-call engineer should run.
- Acknowledges the production stack constraint (Trino-driven rollback rather than only the Spark `CALL iceberg.system.rollback_to_snapshot` form) — Trino's table procedure is fully usable here.
- Debezium reconciliation section converts a generic Iceberg answer into one that fits the actual SaaS data flow (CDC into the lake).

### Completeness: 4.5 / 5
Covers all five rubric anchors: find snapshot, verify, roll back, retention window risk, CDC reconciliation.

Minor gaps (downgrade from 5 → 4.5):
- **Spark fallback not mentioned** — the production ingestion path is Spark + Iceberg 1.5.2. If the user's Trino version is older than 469 or the JWT/OPA policy blocks `ALTER TABLE EXECUTE` on this catalog, the Spark equivalent `CALL spark_catalog.system.rollback_to_snapshot('analytics.customer_records', <id>)` would be the safety net. The answer could mention this in one sentence.
- **Branch/tag-based recovery** — Iceberg supports tagging snapshots before risky ops; a passing reference would help the engineer prevent the next incident.
- **`older_than` vs `retain_last` interplay** — when telling the engineer to check retention, naming both `history.expire.max-snapshot-age-ms` and `history.expire.min-snapshots-to-keep` would have been more complete than naming only the first.

---

## Errors and gaps

### HIGH severity
None.

### MEDIUM severity
None.

### LOW severity
1. **Spark CALL fallback not mentioned** — the production environment also has Spark; mentioning the Spark equivalent rollback path as a fallback would harden the runbook.
2. **`SHOW CREATE TABLE` output hint** — the answer says to look for `write.metadata.delete-after-commit.enabled` and `history.expire.max-snapshot-age-ms`. These are Iceberg table properties, but they are not always emitted by Trino's `SHOW CREATE TABLE` unless explicitly set. A better diagnostic is `SELECT * FROM "table$properties"` (the Iceberg connector `$properties` metadata table). Minor.
3. **Trino 467 vs 469 caveat** — the new table procedure form (`ALTER TABLE EXECUTE rollback_to_snapshot`) landed in Trino release 469 (27 Jan 2025), per the release notes. Production stack lists Trino 467. On Trino 467, the engineer would have to use the deprecated `CALL iceberg.system.rollback_to_snapshot('schema','table', <id>)` form. The answer should ideally flag this version sensitivity. Downgraded to LOW because the production stack is likely tracking close to current, and the named form will be the correct one once they upgrade.

---

## Resource fix recommendations

Only minor enhancements suggested — no correctness fixes required.

1. In the Iceberg rollback / time-travel resource, add a one-line note: "On Trino < 469 use `CALL iceberg.system.rollback_to_snapshot(schema, table, snapshot_id)`; on Trino 469+ use `ALTER TABLE ... EXECUTE rollback_to_snapshot(...)`. The CALL form is deprecated but still supported."
2. Add a sentence: "If Trino rollback is blocked by OPA policy or the catalog is in maintenance, the Spark equivalent is `CALL spark_catalog.system.rollback_to_snapshot('schema.table', <snapshot_id>)`."
3. Add a brief "preventative" callout introducing Iceberg branches/tags as a way to checkpoint before risky DML.
4. Replace `SHOW CREATE TABLE ...` retention-property diagnostic with `SELECT * FROM "table_name$properties"` example.

---

## Sources

- [Iceberg connector — Trino documentation](https://trino.io/docs/current/connector/iceberg.html)
- [ALTER TABLE — Trino documentation](https://trino.io/docs/current/sql/alter-table.html)
- [Release 469 (27 Jan 2025) — Trino release notes](https://trino.io/docs/current/release/release-469.html)
- [Deprecate `CALL rollback_to_snapshot` and add corresponding table procedure in Iceberg — PR #24580](https://github.com/trinodb/trino/pull/24580)
- [Apache Iceberg Time Travel & Rollbacks in Trino — Starburst](https://www.starburst.io/blog/apache-iceberg-time-travel-rollbacks-in-trino/)
- [Maintenance — Apache Iceberg documentation](https://iceberg.apache.org/docs/latest/maintenance/)
