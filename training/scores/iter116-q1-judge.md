# Iter 116 Q1 — Judge Report

**Question topic**: Iceberg table maintenance — delete-file accumulation from CDC, position-delete compaction vs full data-file rewrite, when to run which.

**Phase**: extended (post-final; topic already PASSED at avg 4.640 over 12 questions).

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | Two material errors that would break production runs (see below). Conceptual framing is correct and matches Trino 467 / Iceberg 1.5.2 semantics; specific SQL invocations are not. |
| Clarity | 5 | Excellent. "Open each Parquet data file, open every delete file, merge in memory" mental model is exactly right for a SaaS engineer. Threshold table at the end is concrete and actionable. No unexplained jargon. |
| Practical applicability | 3 | Diagnostic query, runbook structure, nightly/weekly schedule, and decision criteria are directly usable. But the headline "ad-hoc Trino fix right now" overstates Trino OPTIMIZE's ability to apply position deletes, and the primary Spark snippet uses an unsupported option — engineer will hit `IllegalArgumentException` or silent no-op on first run. |
| Completeness | 4 | Covers WHY deletes slow queries, both procedures, diagnostic query, ad-hoc vs scheduled, full weekly maintenance sequence with ordering rationale, and threshold guidance. Missing: explicit "Trino OPTIMIZE is not equivalent to Spark rewrite_data_files for delete handling" caveat; no mention of `rewrite_manifests` even though manifest pile-up commonly co-occurs with this symptom. |
| **Average** | **3.75** | Just above pass threshold. |

**Verdict**: PASS (3.75) — clears the 3.5 bar, but only because clarity and completeness compensate for two specific technical defects. In a stricter rubric this would fail. Topic already marked PASSED so no checklist impact; report retained for teacher correction.

---

## What was verified correct (via WebSearch + official docs)

1. **Position-delete mechanics under merge-on-read are accurately described.** Debezium + Iceberg MoR writes position delete files per UPDATE/DELETE batch; Trino merges deletes against data files at read time. Performance degrades non-linearly with delete-file count. Confirmed against iceberg.apache.org/spec and the trinodb/trino #17114 issue ("Read Iceberg v2 table with many delete file is very slowly") which documents exactly this pathology.

2. **`$files` metadata table content column encoding (0=data, 1=position deletes, 2=equality deletes).** Correct against the Iceberg spec.

3. **`rewrite_position_delete_files` purpose — minor compaction of delete files and dropping dangling deletes.** Confirmed against iceberg.apache.org/docs/1.5.1/spark-procedures and the RewritePositionDeleteFiles javadoc (1.5.2).

4. **`rewrite_data_files` with `delete-file-threshold` correctly applies deletes during data-file rewrite.** Confirmed: `DELETE_FILE_THRESHOLD` is a valid `SizeBasedDataRewriter` option (default `Integer.MAX_VALUE`, so deletes are normally NOT considered for compaction; setting to 1 forces every data file with >=1 attached delete to be rewritten clean).

5. **Maintenance ordering: compact → expire_snapshots → remove_orphan_files → rewrite_manifests.** Correct and matches the canonical pattern. The reasoning "snapshots still reference pre-compaction delete files, expire then orphan-cleanup releases bytes" is exactly the right explanation.

6. **`target-file-size-bytes`, `min-input-files`, named-argument syntax for `rewrite_data_files`.** All valid for Iceberg 1.5.2.

7. **Trino-native `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` syntax.** Valid against trino.io/docs/current/connector/iceberg.html — default is 100MB, the parameter exists.

---

## Errors and gaps

### HIGH — `delete-file-threshold` is NOT a valid option for `rewrite_position_delete_files`

The answer's Strategy 1 snippet (lines 47–53 of the answer) calls:
```python
CALL iceberg.system.rewrite_position_delete_files(
    table   => 'analytics.events',
    options => map('delete-file-threshold', '1')
)
```

Verified against the RewritePositionDeleteFiles javadoc (iceberg.apache.org/javadoc/1.5.2/.../RewritePositionDeleteFiles.html): the option constants are limited to `PARTIAL_PROGRESS_ENABLED`, `PARTIAL_PROGRESS_MAX_COMMITS`, `MAX_CONCURRENT_FILE_GROUP_REWRITES`, `REWRITE_JOB_ORDER` (plus internal `MIN_INPUT_FILES`, `REWRITE_ALL`, `MAX_FILE_GROUP_SIZE_BYTES` inherited from the rewriter base). There is no `delete-file-threshold` option on this procedure. `delete-file-threshold` is a `SizeBasedDataRewriter` option, valid only for `rewrite_data_files`.

The answer's own explanatory sentence — "`delete-file-threshold=1` means: process any data file that has at least 1 delete file attached" — describes the `rewrite_data_files` semantic, not the position-delete-files semantic. The two have been conflated.

Effect on a real engineer:
- Best case: the option is silently ignored and the procedure compacts small delete files into larger delete files (does not produce clean data files). Engineer will see "delete file count dropped from 40,000 to ~few hundred", *think* the problem is solved, and still have a MoR-merge cost at read time because the deletes are still applied per-row at query.
- Worse: depending on Spark Iceberg version, unknown options may raise `IllegalArgumentException` on the rewriter validation path.

The two procedures actually do different things and the answer never explains this:
- `rewrite_position_delete_files` — produces fewer, larger delete files; data files unchanged; deletes still applied at read time, just from fewer files.
- `rewrite_data_files` with `delete-file-threshold` — produces new data files with deleted rows physically removed; delete files become dangling and drop out of new snapshots; no read-time merge needed for those files.

For "40,000 delete files tanking query performance from CDC," the actually-correct surgical fix is `rewrite_data_files` with `delete-file-threshold => '1'` and a tight `where` predicate scoped to affected partitions — not `rewrite_position_delete_files`.

### HIGH — Trino `ALTER TABLE EXECUTE optimize` is presented as equivalent to Spark `rewrite_data_files`; it is not

Lines 87–91 of the answer:
> "Trino 467 native compaction — applies deletes and consolidates small files. Equivalent to rewrite_data_files; runs directly in Trino session."

This is the wrong framing for the prod stack. Verified against trinodb/trino issue #16574 ("Support data and delete file thresholds for Iceberg OPTIMIZE", open feature request, March 2023): Trino's OPTIMIZE does not expose `delete-file-threshold` or `min-input-files` controls. While Trino's OPTIMIZE output does report `removed_delete_files_count` and it will rewrite data files that have attached deletes when those data files fall under the `file_size_threshold`, OPTIMIZE will NOT rewrite a perfectly-sized 256MB data file that has 200 position deletes attached — exactly the situation in a CDC pile-up where data files are well-sized but delete files have accumulated.

For 40,000 delete files on well-sized data files, Trino `EXECUTE optimize(file_size_threshold => '128MB')` may do little useful work. The answer's claim that this brings query latency back within 5–30 minutes is optimistic and likely wrong for the specific pathology the question describes.

The honest framing the answer should have given:
- Trino OPTIMIZE is best for small-file consolidation, will incidentally apply deletes to files it rewrites for size reasons, but will not target a "data files are fine, delete files are the problem" pile-up.
- For the CDC delete-pile-up scenario specifically, the correct path is Spark `rewrite_data_files` with `delete-file-threshold => '1'`. There is no Trino-native ad-hoc equivalent.

### MEDIUM — Comparison table mislabels `rewrite_position_delete_files`

The table on lines 75–80:
> | `rewrite_position_delete_files` | Targets: Delete files only | Speed: Fast (small files only) | Best for: CDC with clean data files |

This conveys "use this for CDC delete pile-up" but, per the HIGH error above, this procedure does not solve the 40,000-delete-file query slowdown — it just makes the delete files fewer-and-bigger. The "best for" column should be something like "delete files have piled up AND you want to keep MoR semantics; you accept that reads still merge deletes per row, just from fewer files."

### MEDIUM — `rewrite_manifests` mentioned only in the weekly schedule, no diagnostic for when it actually helps

Heavy delete-file accumulation typically co-occurs with manifest-list bloat (each Debezium micro-batch commits a snapshot, each snapshot adds manifest entries). For "queries getting slower week over week with no data growth," manifest planning overhead is often a significant fraction of the regression. The answer's weekly schedule includes `rewrite_manifests` but does not explain that it is a separate, much-cheaper intervention that should be tried before any data-file rewrite — and that resources/05 explicitly recommends as the first-line response per the iter116 teacher fixes.

### LOW — Runtime estimate "30–90 minutes" for clearing 40,000 delete files is unsupported

No basis given for the estimate. Real-world runtime depends on data file count, partition count, executor parallelism, and MinIO throughput. Better to say "depends on cluster size and number of affected data files; expect tens of minutes to several hours" and give a `EXPLAIN` or `$files` diagnostic for sizing the job before submitting.

### LOW — No explicit Spark vs Trino engine label on the CALL blocks

Per persistent pattern in the rubric notes (iter 36 Q3, iter 47 Q1, iter 86 Q2), unlabeled `CALL iceberg.system.*` blocks risk the engineer attempting them in Trino. The answer does label the ad-hoc section as "Trino-Native" but the nightly/weekly schedule section just shows `CALL iceberg.system.*` without an explicit "Spark SQL only" header on the block. Beginner reader could paste these into Trino and get errors.

### LOW — JWT/OPA prod-fit context not surfaced

Not directly relevant to a compaction question, but the weekly schedule example runs as raw SQL without mentioning that on the production stack these jobs run via a service principal in a Kubernetes CronJob authenticated via JWT against OPA-authorized roles. Minor.

---

## Resource fix recommendations

### HIGH — Fix the conflation of `delete-file-threshold` between the two procedures

**Path**: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md` (the "Diagnosing position-delete-file accumulation" section around lines 2150–2230 already contains the correct decision table — but the answer's Strategy 1 snippet appears to be invented and not drawn from this resource).

Required change: Add (or strengthen if already present) an explicit warning block:

> **CRITICAL**: `delete-file-threshold` is a `rewrite_data_files` option ONLY. Passing it to `rewrite_position_delete_files` is silently ignored or rejected. The two procedures solve different problems:
> - `rewrite_position_delete_files` — compacts MANY small delete files into FEWER large delete files. Reads still merge deletes per row. Use when delete-file COUNT is the bottleneck and you want to keep MoR semantics.
> - `rewrite_data_files` with `options => map('delete-file-threshold', '1')` — rewrites DATA files with deleted rows physically removed. No read-time merge for those files. Use when you want the deletes APPLIED, not just compacted.
>
> For Debezium CDC delete-file pile-up (the typical "40,000 delete files slowing Trino" scenario), `rewrite_data_files` with `delete-file-threshold => '1'` is usually the correct primary fix.

### HIGH — Correct the "Trino EXECUTE optimize is equivalent to Spark rewrite_data_files" framing

**Path**: `/Users/hclin/github/recknihao/resources/05-iceberg-table-maintenance.md` (presumed; verify path)

Required addition: A short subsection titled "When Trino OPTIMIZE is NOT enough" with:
- Trino OPTIMIZE rewrites data files below `file_size_threshold`; it will incidentally apply attached deletes to files it rewrites, but it does NOT have a `delete-file-threshold` knob.
- For CDC delete-file pile-up on already well-sized data files, Trino OPTIMIZE alone may do little useful work. Schedule Spark `rewrite_data_files` with `delete-file-threshold => '1'` for that case.
- Link to trinodb/trino issue #16574 as the canonical reference that this is a known Trino gap.

### MEDIUM — Add a "try rewrite_manifests first" callout to the delete-file diagnostic flow

**Path**: `/Users/hclin/github/recknihao/resources/05-iceberg-table-maintenance.md`

The iter116 teacher fixes already added "Try rewrite_manifests FIRST" for partition-evolution planning latency. Extend the same callout to the delete-file/CDC slowdown flow: if `$files` shows mostly well-sized data files and the slowdown correlates with snapshot-count growth (not delete-file count specifically), `rewrite_manifests` is often the cheapest first intervention.

### LOW — Engine labels on every CALL block

**Path**: `/Users/hclin/github/recknihao/resources/05-iceberg-table-maintenance.md` and `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`

Persistent rubric pattern: every code block starting with `CALL iceberg.system.*` should have a `-- Spark SQL only — not available in Trino` comment in the first line, or a fenced-code language hint of `sparksql`. Reduces beginner footgun.

---

## Sources verified

- [Apache Iceberg Spark Procedures (1.5.1)](https://iceberg.apache.org/docs/1.5.1/spark-procedures/)
- [RewritePositionDeleteFiles javadoc (1.5.2)](https://iceberg.apache.org/javadoc/1.5.2/org/apache/iceberg/actions/RewritePositionDeleteFiles.html)
- [RewriteDataFiles javadoc (1.5.2)](https://iceberg.apache.org/javadoc/1.5.2/org/apache/iceberg/actions/RewriteDataFiles.html)
- [Trino Iceberg connector docs (current)](https://trino.io/docs/current/connector/iceberg.html)
- [trinodb/trino issue #16574 — Support data and delete file thresholds for Iceberg OPTIMIZE](https://github.com/trinodb/trino/issues/16574)
- [trinodb/trino issue #17114 — Read Iceberg v2 table with many delete file is very slowly](https://github.com/trinodb/trino/issues/17114)
- [Iceberg PR: deleteFileThreshold parameter to SizeBasedDataRewriter](https://www.mail-archive.com/issues@iceberg.apache.org/msg156845.html)
