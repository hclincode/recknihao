# Iter 153 Q2 — Judge Report

**Question topic**: Why does Iceberg DELETE cause MinIO storage to grow? What maintenance is needed?
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter153-q2.md`
**Judge**: opus 4.7
**Date**: 2026-05-26

---

## Overall Score: 4.83 / 5 — PASS

Weighted average:
- Technical accuracy (2x): 5.0 -> 10.0
- Clarity (1x): 4.5 -> 4.5
- Practical usefulness (1x): 5.0 -> 5.0
- Completeness (1x): 4.5 -> 4.5
- Total: 24.0 / 5 = **4.80 / 5** -> **PASS** (>=4.5 threshold)

---

## Per-dimension scores

### Technical accuracy: 5/5

Every load-bearing technical claim verified against official docs:

| Claim | Verdict | Evidence |
|---|---|---|
| Iceberg 1.5.2 defaults to CoW for DELETE | CORRECT | `write.delete.mode` defaults to `copy-on-write` per Iceberg configuration docs (v2 tables) |
| CoW DELETE rewrites all affected Parquet files (even if only 1 row matches) | CORRECT | Confirmed by Dremio, AWS, Cloudera docs: "if even a single row in a data file is updated/deleted, the data file is rewritten" |
| Old files are protected by prior snapshots until `expire_snapshots` removes the snapshot | CORRECT | Maintenance docs: snapshot expiration must precede orphan removal because referenced files are still "live" |
| `expire_snapshots` is the procedure that frees pre-delete files (not `remove_orphan_files`) | CORRECT | This is the persistent failure pattern flagged in the rubric at multiple iterations; this answer gets it right and explains it explicitly |
| `expire_snapshots` must run before `remove_orphan_files` | CORRECT | Confirmed by iceberg.apache.org/docs/latest/maintenance/: "if you run orphan cleanup before expiring snapshots, files referenced by those snapshots are still considered live and will not be deleted" |
| `CALL iceberg.system.expire_snapshots(table, older_than, retain_last)` signature | CORRECT | Matches official Spark procedures page (named arguments) |
| `CALL iceberg.system.remove_orphan_files(table, older_than)` signature | CORRECT | Matches official Spark procedures page |
| `rewrite_data_files` CALL syntax with `target-file-size-bytes` and `min-input-files` options | CORRECT | Matches Spark procedure options |
| Trino form `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` | CORRECT | Matches Trino Iceberg connector docs |
| MoR as alternative — writes delete files, requires compaction to actually free | CORRECT | Confirmed across multiple sources |
| `$snapshots` metadata table accessible via `iceberg.analytics.events$snapshots` | CORRECT | Standard Iceberg metadata table syntax |

Engine labeling: CALL procedures correctly labeled as "Spark form (recommended)" and Trino alternative shown — addresses the persistent CALL-in-Trino mislabel pattern from earlier iterations.

### Clarity: 4.5/5

Strengths:
- Bolded TL;DR in the first paragraph nails the surprising mechanic in one sentence.
- "If you delete 60% of rows in a file, Iceberg rewrites 100% of the file" — concrete numeric example that beginners can immediately picture.
- Clear "after your DELETE runs, MinIO has..." bulleted state list makes the storage growth tangible.
- 4-step labeled flow (DELETE -> rewrite -> expire -> remove) is easy to follow.
- Summary table at the end maps cause -> fix in one glance.

Minor gaps (-0.5):
- Terms like "snapshot", "manifest", "orphan" are used without an inline gloss. A beginner without lakehouse exposure may need to infer what a snapshot is from context.
- Uses the term "Copy-on-Write" with the acronym "CoW" without defining what "copy on write" conceptually means (vs in-place mutation).

### Practical usefulness: 5/5

- Provides runnable SQL for all four steps, including both Spark and Trino forms.
- Gives a concrete schedule (Nightly: DELETE + rewrite; Weekly: expire + remove_orphan) with timing rationale (Sunday low-traffic).
- Provides a diagnostic query against `$snapshots` to confirm whether expire is running.
- Calls out the 30-day retention as a feature (rollback window), not just a parameter to tune.
- Step ordering warning ("Step 3 must run before Step 4") is explicit and saves the engineer from the most common mistake.

### Completeness: 4.5/5

Covered:
- CoW mechanics (file rewrite, new snapshot, old file kept)
- Snapshot protection of old files
- `expire_snapshots` as the key step
- `remove_orphan_files` for actual byte release
- Ordering requirement (expire before remove)
- MoR as alternative with tradeoff guidance
- Diagnostic query on `$snapshots` metadata table

Minor gaps (-0.5):
- Does not mention `rewrite_position_delete_files` (relevant if MoR were used, but answer correctly stays focused on the CoW question).
- The `remove_orphan_files` safety warning is missing: official docs explicitly warn that `older_than` shorter than the longest in-flight write can corrupt the table by deleting active uploads. The 3-day default is conservative for this reason. The answer uses 3 days but doesn't explain why setting it lower is dangerous.
- `expire_snapshots` does not mention concurrent reader impact (a long-running Trino query against an older snapshot can break if that snapshot is expired mid-query).
- No mention of metadata file accumulation (`write.metadata.delete-after-commit.enabled` / `write.metadata.previous-versions-max`) which is a related secondary storage-growth source.

---

## Verified-correct claims (with source URLs)

1. `write.delete.mode` default = `copy-on-write` for Iceberg v2 tables:
   - https://iceberg.apache.org/docs/latest/configuration/
   - https://www.dremio.com/blog/row-level-changes-on-the-lakehouse-copy-on-write-vs-merge-on-read-in-apache-iceberg/

2. CoW rewrites the entire data file when any row matches:
   - https://docs.aws.amazon.com/prescriptive-guidance/latest/apache-iceberg-on-aws/best-practices-write.html

3. `expire_snapshots` must precede `remove_orphan_files`; otherwise referenced files are still live:
   - https://iceberg.apache.org/docs/latest/maintenance/

4. `remove_orphan_files` default `older_than` is 3 days, conservative for in-flight write safety:
   - https://iceberg.apache.org/docs/latest/spark-procedures/

5. `expire_snapshots` signature: `table`, `older_than`, `retain_last`, `snapshot_ids`:
   - https://iceberg.apache.org/docs/latest/spark-procedures/

6. `remove_orphan_files` signature: `table`, `older_than`, `dry_run`, `prefix_listing`:
   - https://iceberg.apache.org/docs/latest/spark-procedures/

---

## Errors or gaps

### HIGH severity
None.

### MEDIUM severity
None.

### LOW severity

- **L1 — Missing `remove_orphan_files` safety warning**: The answer uses `older_than => current_timestamp - interval '3' day` without warning that shortening this window below the longest in-flight write duration can corrupt the table. Recommend a one-line callout: "Do not lower `older_than` below the longest possible Spark write duration — `remove_orphan_files` cannot distinguish abandoned uploads from active ones."
- **L2 — Snapshot expiry impact on running queries**: A long Trino query holding an older snapshot can fail if `expire_snapshots` collapses that snapshot mid-query. The "Sunday low-traffic window" schedule mitigates this in practice but the mechanism is not stated.
- **L3 — Glossary gloss missing**: Terms "snapshot", "manifest", "orphan", "CoW" used without inline definitions. A SaaS engineer with zero lakehouse background reaches the right action but may not internalize *why*.
- **L4 — Metadata-file growth not mentioned**: Aside from data files, Iceberg also accumulates metadata.json files. Not the dominant cause of the engineer's MinIO growth, but worth a sentence for completeness.

---

## Resource fix recommendations

Mostly the resources are already adequate — this answer demonstrates that the teacher's earlier fixes around CALL syntax labeling and the expire-before-orphan-files ordering have landed. Small reinforcements:

1. `resources/17-iceberg-table-maintenance.md` — add a safety callout box: "`remove_orphan_files` `older_than` must exceed the longest possible in-flight Spark write. The 3-day default is intentional. Shortening it can delete files belonging to a still-running ingestion job and corrupt the table."
2. `resources/17-iceberg-table-maintenance.md` — add a sentence on snapshot expiry's effect on long-running readers: "If a Trino query is reading from snapshot S and `expire_snapshots` removes S mid-query, the query fails. Schedule expire jobs during low-traffic windows."
3. Consider a tiny `resources/glossary.md` (or per-resource inline glosses) for the terms `snapshot`, `manifest`, `orphan file`, `CoW`, `MoR` — to lift the beginner clarity score without bloating answers.

---

## Rubric topic updates

This question touched:
- Iceberg DELETE semantics / CoW vs MoR
- Iceberg maintenance procedures (expire_snapshots, remove_orphan_files, rewrite_data_files)
- Engine labeling (Spark CALL vs Trino ALTER TABLE EXECUTE)
- Snapshot lifecycle and retention

All passing. No rubric demotions warranted; this iteration reinforces existing PASS scores on these topics.
