# Iter140 Q1 — Judge Scoring

**Question topic**: Iceberg DELETE/UPDATE behavior on disk — CoW vs MoR, file count growth, GDPR-compliant deletion sequence.

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4/5 | Core CoW/MoR mechanics correct; one MEDIUM error on Trino `SET TBLPROPERTIES` syntax + connector property exposure. |
| Clarity | 5/5 | Crisp two-mode framing, contrast table, runnable SQL labelled by engine, jargon glossed inline. |
| Practical utility | 4/5 | Diagnosis + 3 named fixes + decision matrix; mismatch between "Trino or Spark" label on Fix 3 and the SQL given reduces actionability slightly. |
| Completeness | 5/5 | Covers CoW, MoR, file inventory query, compaction, mode switch, full GDPR 3-step (DELETE → compact → expire → orphan), retention floor caveat. |

**Overall**: **(4 + 5 + 4 + 5) / 4 = 4.50/5**

**Verdict**: **PASS** (>= 4.0)

---

## Verified Correct (with sources)

1. **Iceberg 1.5.2 defaults to Copy-on-Write for DELETE/UPDATE/MERGE** — Confirmed. The Iceberg configuration reference states `write.delete.mode`, `write.update.mode`, `write.merge.mode` all default to `copy-on-write`.
   - Source: <https://iceberg.apache.org/docs/latest/configuration/>
   - Source: <https://www.dremio.com/blog/row-level-changes-on-the-lakehouse-copy-on-write-vs-merge-on-read-in-apache-iceberg/>

2. **CoW mechanics — read matching data file, filter in memory, write new file, dereference old** — Correct industry-standard description.
   - Source: <https://www.guptaakashdeep.com/copy-on-write-or-merge-on-read-apache-iceberg-2/>

3. **MoR mechanics — write small delete file (position or equality), leave data files untouched, merge at read time** — Correct.
   - Source: <https://dev.to/alexmercedcoder/understanding-the-apache-iceberg-delete-files-3abo>
   - Source: <https://iceberg.apache.org/spec/>

4. **`$files` metadata table content column values: 0 = data, 1 = position delete, 2 = equality delete** — Correct per Iceberg spec.
   - Source: <https://iceberg.apache.org/spec/?h=content>

5. **`rewrite_data_files` Spark procedure with `delete-file-threshold` option** — Correct; default is to skip files with delete files, setting threshold to 1+ forces rewrite that applies pending deletes.
   - Source: <https://iceberg.apache.org/docs/latest/spark-procedures/>
   - Source: <https://www.dremio.com/blog/compaction-in-apache-iceberg-fine-tuning-your-iceberg-tables-data-files/>

6. **Trino `iceberg.expire_snapshots.min-retention` default = 7d; Spark has no equivalent floor** — Correct. The Trino connector rejects retention shorter than this configured minimum.
   - Source: <https://trino.io/docs/current/connector/iceberg.html>

7. **GDPR 3-step sequence (DELETE → compact/rewrite → expire_snapshots → remove_orphan_files)** — Correct and necessary; `DELETE` alone does not physically remove bytes from object storage because old snapshots still reference the data files.
   - Source: <https://iceberg.apache.org/docs/latest/maintenance/>

8. **Trino `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '...')`** — Valid Trino 467 syntax.
   - Source: <https://trino.io/docs/current/connector/iceberg.html>

9. **`$properties` metadata table on Trino** — Valid syntax `SELECT * FROM iceberg.schema."table$properties"`.
   - Source: <https://trino.io/docs/current/connector/iceberg.html>

---

## Errors / Gaps

### MEDIUM: Fix 3 mislabels engine support

The answer's Fix 3 says `-- Trino or Spark (affects NEW operations only)` and then provides:

```sql
ALTER TABLE iceberg.analytics.events SET TBLPROPERTIES (
    'write.delete.mode' = 'copy-on-write',
    ...
)
```

Two issues:
- **`SET TBLPROPERTIES` is Spark syntax**. Trino uses `ALTER TABLE name SET PROPERTIES property_name = value` (no `TBL` prefix, no parentheses, comma-separated assignments).
  - Source: <https://trino.io/docs/current/sql/alter-table.html>
- **The Trino Iceberg connector does not currently expose `write.delete.mode` / `write.update.mode` / `write.merge.mode` as settable Trino table properties.** The connector's documented modifiable properties are `format`, `format_version`, `partitioning`, `sorted_by`, `max_commit_retry`, `delete_after_commit_enabled`, `max_previous_versions`, `object_store_layout_enabled`, `data_location`. To change the write modes from Trino's side requires using Spark.
  - Source: <https://trino.io/docs/current/connector/iceberg.html>

In the production stack (Trino 467 for query, Spark for ingestion), the practical impact is small — the user would simply run the mode change from Spark — but the label "Trino or Spark" is misleading and the SQL would fail in Trino.

### LOW: `$properties` query example uses LIKE on a key that won't fully match

The example `WHERE key LIKE 'write.%mode'` would match `write.delete.mode`, `write.update.mode`, `write.merge.mode` correctly (the `%` between `write.` and `mode` covers `delete.`, `update.`, `merge.`). This is technically fine; no fix needed but the pattern is unusual. Not a blocker.

### LOW: Spark `expire_snapshots` retention floor caveat is incomplete

The answer correctly notes Trino has a 7d floor but Spark does not enforce one. Worth adding: Iceberg core has `history.expire.max-snapshot-age-ms` and `history.expire.min-snapshots-to-keep` table properties that protect snapshots even when Spark runs without a floor. For GDPR work this is benign because the user is intentionally shrinking retention, but a complete answer would mention these guardrails.

### LOW: CoW "file count typically stays the same or decreases" oversimplified

CoW can also increase file count modestly if the rewrite splits a large file across writer tasks based on target file size, or if predicate-pushdown matched rows in many files and each rewrote partition produces multiple files. The answer's "Why Query Times Go Up Even in CoW Mode" section partially covers this with the 230 MB rewrite example, so this is a minor framing issue, not a factual error.

---

## Resource Fix Recommendations

1. **High priority — fix the Trino vs Spark syntax confusion.** Update the resource that covers CoW/MoR mode switching (likely `resources/` row-level delete or maintenance file) to:
   - Show **Spark** as the engine for changing `write.*.mode` properties via `ALTER TABLE ... SET TBLPROPERTIES (...)`.
   - Explicitly state that Trino 467 cannot toggle these write-mode properties via `ALTER TABLE ... SET PROPERTIES` — list the Trino-modifiable property allowlist.
   - For the production stack (Trino query, Spark ingestion), recommend running the mode change from Spark.

2. **Minor — add `history.expire.*` guardrail properties** to the snapshot expiry resource so readers know Spark has table-level safety nets even though it lacks a connector floor like Trino's.

3. **Minor — add a note that CoW can also increase file count** when rewrites split files to honor `target-file-size-bytes`, to round out the "Why Query Times Go Up" section.

Overall this answer is a strong PASS; the MEDIUM finding is a single isolated syntax mismatch on Fix 3 and does not derail the core teaching.
