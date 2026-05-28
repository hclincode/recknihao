# Judge Feedback — Iter 354 Q1

**Date**: 2026-05-29
**Phase**: extended
**Topic**: Iceberg table maintenance — equality delete cleanup on Debezium-ingested Iceberg 1.5.2 tables (re-probe of iter353 Q1 FAIL)

**Question**: "We run `rewrite_data_files` every night on our Debezium-ingested Iceberg tables, but when I check the `$files` metadata table I keep seeing the `content=2` row (equality deletes) growing every day. I thought compaction was supposed to clean those up — is the procedure broken, or am I missing a separate step to handle equality delete files?"

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.5 | Correctly cites #12838, `remove-dangling-deletes` in 1.8+, no `rewrite_equality_delete_files` procedure exists, and Trino's 7-day floor. BUT the central workaround claim — that `rewrite_data_files` + `remove_orphan_files` cleans up dangling equality deletes — is factually wrong. `remove_orphan_files` only removes files NOT referenced by live snapshot metadata. Dangling equality deletes from #12838 ARE still referenced by the live snapshot — that is precisely why they accumulate. Substantive technical error. Bug mechanism is also subtly misframed: #12838 is about cross-partition `minDataSequenceNumber` contamination, not just "partitions it skips." |
| Beginner clarity | 4.5 | Strong structure (core issue → workaround → engine syntax → long-term fix → diagnostic). Bolded callouts highlight key facts. Code blocks are well-organized. Loses 0.5 for unexplained terms like `dataSequenceNumber` and "MoR read-amplification." |
| Practical applicability | 2.5 | The recommended workaround will NOT solve the engineer's problem. After running both procedures nightly, `$files content=2` will continue to grow because `remove_orphan_files` does not touch files referenced by live snapshot delete-file sets. The engineer reports back next week still stuck. Trino `optimize(...)` snippet uses literal `(...)` placeholder text — non-pasteable. |
| Completeness | 3.5 | Covers #12838 + 1.8+ fix + no-standalone-procedure statement (the three iter353 must-haves that landed). Misses: (a) the real 1.5.2 mitigation path (broaden `rewrite_data_files` scope across all partitions, or use Spark `rewrite_position_delete_files` with `remove-dangling-deletes` for the position-delete subset); (b) CDC-specific cadence guidance (hourly vs nightly per Debezium write rate); (c) MoR read-amplification framing with a content=2 / content=0 RATIO threshold rather than arbitrary absolute counts; (d) explicit "remove_orphan_files is NOT for in-snapshot dangling deletes" callout. |
| **Average** | **3.25** | **FAIL** (below 4.0 pass bar) |

## What landed (iter353 → iter354 progress)

Three of the six iter353 teacher action items show up correctly:

- Iceberg 1.5.2 #12838 dangling-equality-delete bug is now CALLED OUT by name with the GitHub issue link.
- "No standalone `rewrite_equality_delete_files` procedure exists in Iceberg 1.5.2" is stated explicitly.
- `remove-dangling-deletes` option in Iceberg 1.8+ is named as the long-term fix.

These are real wins versus iter353. The responder is reading new content somewhere in `resources/`.

## What broke (new regression introduced)

**The two-step workaround in the answer is factually wrong.** Specifically:

```
1. rewrite_data_files first — applies equality deletes for partitions it rewrites
2. remove_orphan_files immediately after — sweeps the now-unreferenced equality delete files
```

`remove_orphan_files` does not "sweep the now-unreferenced equality delete files" because those files ARE still referenced — by the live snapshot's manifest's delete-file list. The orphan-files cleanup procedure compares physical files in object storage against the metadata graph and only deletes files NOT in the metadata graph. Files that are still in the metadata graph but logically dangling (the #12838 case) are invisible to it.

Verified via:
- Apache Iceberg DeleteOrphanFiles Javadoc: "A file is considered orphan if it physically exists in object storage but is not referenced by the table's metadata graph."
- AWS Glue orphan-file-deletion docs: "Orphan files are unreferenced files that exist in your data source under the specified table location, are not tracked by the Iceberg table metadata."
- The #12838 bug report itself: deletes remain in the manifest set because the pruning logic compares against a global `minDataSequenceNumber` rather than per-partition.

If the engineer executes the recommended two-step "workaround" nightly, `$files content=2` will keep growing exactly as it does today, because nothing in the workaround actually removes the dangling delete files from the live snapshot's manifest.

This is more dangerous than the iter353 answer's coverage gap, because the engineer now has confident-sounding bad advice with code snippets ready to paste. False positive on a high-stakes maintenance question.

## Secondary issues

1. **Bug mechanism misframed**: The answer says rewrite_data_files "only applies equality delete files for the partitions it actually rewrites. For partitions it skips (already well-sized), equality delete files stay around — and a bug in how Iceberg 1.5.2 compares `dataSequenceNumber` across partition boundaries can leave orphaned equality delete files." The cross-partition framing is right, but the mechanism is: Iceberg 1.5.2 prunes a delete file only if its sequence number is below the table's GLOBAL `minDataSequenceNumber` — not per-partition. So any single low-sequence-number data file anywhere keeps every partition's old equality deletes alive. The "partitions it skips" framing is the wrong mental model.

2. **Arbitrary diagnostic thresholds**: "<10 files: healthy / 10–50: investigate / >50: action required" — these are ungrounded absolute numbers. The MoR-correct framing is RELATIVE: `content=2 file count vs content=0 file count`, e.g., "if content=2 > 10× content=0, your reads are doing 10× merge work per data file." A small table might have 5 equality deletes and still be in trouble; a huge table might have 200 and be fine.

3. **CDC cadence guidance missing**: For a Debezium-ingested pipeline specifically, the cadence question is essential — high-write CDC tables (>100 UPDATEs/sec) need hourly compaction, not nightly. Iter353's teacher action #4 called this out explicitly and it didn't make it into the answer.

4. **Non-pasteable Trino snippet**: `ALTER TABLE iceberg.analytics.events EXECUTE optimize(...)` with literal `(...)` placeholder will fail in Trino. Should be `EXECUTE optimize(file_size_threshold => '256MB')`.

5. **`older_than` parameter form**: The Spark `older_than => current_timestamp - interval '3' day` is valid Spark. Trino's `EXECUTE remove_orphan_files` only accepts `retention_threshold => '7d'` as a duration string. The answer's Trino block does use the correct form, but flagging the engine asymmetry would help beginners.

## Teacher action required before iter355

1. **HIGH PRIORITY — Correct the workaround**: In `resources/17-iceberg-table-maintenance.md` (or wherever the new equality-delete section now lives), remove any guidance that says `remove_orphan_files` cleans up dangling equality deletes. Replace with:
   - Primary fix: upgrade to Iceberg 1.8+ and call `rewrite_data_files(options => map('remove-dangling-deletes', 'true'))`.
   - Mitigation on Iceberg 1.5.2: run `rewrite_data_files` with NO partition filter and `min-input-files=2` so every partition's data is rewritten — this resolves the cross-partition sequence-number comparison.
   - `rewrite_position_delete_files` (Spark, Iceberg 1.4+) has its own `remove-dangling-deletes` option but only cleans dangling POSITION deletes, not equality deletes.
   - Explicit "What `remove_orphan_files` is NOT for" callout: dangling delete files referenced by live snapshots (the #12838 case) are not orphans and `remove_orphan_files` will not touch them.

2. **Add precise #12838 mechanism**: "Iceberg 1.5.2 prunes a delete file only if its sequence number is below the table's GLOBAL `minDataSequenceNumber`. Because the comparison is global rather than per-partition, a single low-sequence-number data file in any partition keeps every partition's old equality deletes alive." This is the correct mental model and replaces the "skipped partitions retain their deletes" framing.

3. **Replace absolute content=2 thresholds with MoR-ratio thresholds**: tie the alarm threshold to `content=2 count / content=0 count > 10` (or similar), grounded in the read-time merge cost per data file.

4. **Add CDC cadence guidance**: hourly `rewrite_data_files` for Debezium tables with >100 UPDATEs/sec; nightly for <10/sec; with side note on `write.target-file-size-bytes` and Iceberg writer flush cadence tuning to reduce equality-delete fragmentation at write time.

## Iter355 judge re-probe targets

1. **Re-probe equality-delete cleanup with different phrasing**: e.g., "Do I have to upgrade Iceberg to fix the growing content=2 problem, or is there a maintenance workaround on 1.5.2?" — verify the corrected workaround lands and the `remove_orphan_files`-as-cleanup misconception is gone.
2. **Probe `remove_orphan_files` semantics directly**: e.g., "We ran `remove_orphan_files` and nothing got deleted — what does it actually clean up?" — verify the responder distinguishes orphans (unreferenced by metadata) from dangling delete files (referenced but invalid). This is the inverse-direction probe of the same conceptual confusion.

Avoid re-probing position-delete cleanup (durable since iter352), selector regex (durable since iter350+iter351), or cost/storage diagnostics (covered iter353 Q2).

## Sources (technical verification)

- [apache/iceberg#12838 — RewriteDataFiles with merging equality deletes](https://github.com/apache/iceberg/issues/12838)
- [Iceberg 1.8.0 Spark Procedures docs (remove-dangling-deletes option)](https://iceberg.apache.org/docs/1.8.0/spark-procedures/)
- [Iceberg latest Spark Procedures docs (rewrite_position_delete_files, no rewrite_equality_delete_files)](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Iceberg DeleteOrphanFiles Javadoc — orphan = not referenced by metadata](https://iceberg.apache.org/javadoc/1.2.0/org/apache/iceberg/actions/DeleteOrphanFiles.html)
- [AWS Glue — Deleting orphan files definition](https://docs.aws.amazon.com/glue/latest/dg/orphan-file-deletion.html)
- [Trino 481 Iceberg connector docs — remove_orphan_files 7d retention floor](https://trino.io/docs/current/connector/iceberg.html)
- [trinodb/trino#10810 — Trino remove_orphan_files implementation PR](https://github.com/trinodb/trino/pull/10810)
- [trinodb/trino#24086 — Delete files are not removed after running Iceberg maintenance ops](https://github.com/trinodb/trino/issues/24086)
- [Iceberg Releases page — 1.8.0 released 2026-02-13](https://iceberg.apache.org/releases/)

## Iter 354 End-of-Iteration Summary

**Date**: 2026-05-29
**Phase**: extended
**Iteration average**: 3.875 — **FAIL** (below 4.0 pass bar)

### Scores table

| Question | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Iceberg maintenance — equality-delete content=2 growing despite nightly `rewrite_data_files` (re-probe of iter353 Q1) | 3.25 | FAIL |
| Q2 | Iceberg maintenance — Trino-only compaction + snapshot cleanup on MinIO (no Spark) | 4.500 | STRONG PASS |
| **Iteration average** | | **3.875** | **FAIL** |

### Q1 root cause — `remove_orphan_files` mis-prescribed as workaround

`resources/17-iceberg-table-maintenance.md` section 1c (the new equality-delete coverage teacher added in iter354 to close the iter353 gap) prescribed a two-step workaround:

```
1. rewrite_data_files first — applies equality deletes for partitions it rewrites
2. remove_orphan_files immediately after — sweeps the now-unreferenced equality delete files
```

**This is technically wrong.** Dangling equality deletes from apache/iceberg#12838 are **still referenced** by the live snapshot's manifest delete-file lists — that is exactly why `$files content=2` keeps growing despite compaction. `remove_orphan_files` only removes files that exist in object storage but are NOT in the metadata graph. Files that ARE in the metadata graph but are logically dangling (the #12838 case) are **invisible to `remove_orphan_files`** and will not be touched.

Verified via:
- Apache Iceberg `DeleteOrphanFiles` Javadoc: "A file is considered orphan if it physically exists in object storage but is not referenced by the table's metadata graph."
- AWS Glue orphan-file-deletion docs: same definition.
- The #12838 bug report itself: delete files remain in the live manifest because Iceberg 1.5.2's pruning logic compares delete-file sequence numbers against a GLOBAL `minDataSequenceNumber` rather than per-partition.

The correct understanding: **there is no effective `remove_orphan_files`-based workaround on Iceberg 1.5.2.** The honest options are:
1. Upgrade to Iceberg 1.8+ and call `rewrite_data_files(options => map('remove-dangling-deletes', 'true'))`.
2. As a partial mitigation on 1.5.2, run `rewrite_data_files` with NO partition filter and `min-input-files=2` so every partition is rewritten — this resolves the cross-partition global-sequence-number contamination, but does NOT clean up already-dangling deletes from past runs.

Because the responder gave confident-sounding bad advice with pasteable code blocks, this is a **higher-risk failure** than the iter353 coverage gap — the engineer now believes they have a fix that will not work.

### Q2 win — engine-labeling fix from iter353 confirmed durable on new surface

The Trino-vs-Spark engine-labeling treatment that iter352 added to `resources/17-iceberg-table-maintenance.md` (and that iter353 teacher generalized to cost/storage flow per iter353 judge action) landed correctly on a Trino-only question framed without any Spark context. The responder:
- Stayed in Trino `ALTER TABLE ... EXECUTE` syntax throughout the compaction + cleanup steps.
- Flagged `rewrite_manifests` as Spark-only (per trinodb/trino#27371).
- Called out the `iceberg.expire_snapshots.min-retention` 7-day catalog floor.
- Did not silently switch to Spark `CALL iceberg.system.*` syntax mid-answer (the iter351 / iter353 Q2 defect).

This confirms the engine-labeling fix has generalized beyond its original resource surface. Score 4.500 (STRONG PASS).

### Teacher action for iter 355

**HIGH PRIORITY — Fix `resources/17-iceberg-table-maintenance.md` section 1c**:

1. **Remove** the `rewrite_data_files` + `remove_orphan_files` two-step workaround. Delete any guidance that implies `remove_orphan_files` cleans up dangling equality deletes.
2. **Replace** with honest "no effective workaround in Iceberg 1.5.2 — upgrade to 1.8+" guidance:
   - Primary fix: upgrade to Iceberg 1.8+ and call `rewrite_data_files(options => map('remove-dangling-deletes', 'true'))`.
   - Partial mitigation on 1.5.2: run `rewrite_data_files` with NO partition filter and `min-input-files=2` to address the cross-partition `minDataSequenceNumber` contamination going forward (does NOT remove already-accumulated dangling deletes).
   - Explicit "**What `remove_orphan_files` is NOT for**" callout: dangling delete files that are referenced by live snapshot manifests (the #12838 case) are not orphans and `remove_orphan_files` will not touch them. The orphan-files procedure only removes files that exist in object storage but are absent from the metadata graph.
3. **Sharpen #12838 mechanism**: replace "partitions it skips" framing with "Iceberg 1.5.2 prunes a delete file only if its sequence number is below the table's GLOBAL `minDataSequenceNumber`. Because the comparison is global rather than per-partition, a single low-sequence-number data file anywhere in the table keeps every partition's old equality deletes alive."

### Iter 355 judge re-probe targets

1. **Re-probe equality-delete cleanup with inverted framing**: "Do I have to upgrade Iceberg to fix the growing content=2 problem, or is there a maintenance workaround on 1.5.2?" — verifies the `remove_orphan_files`-as-workaround misconception is GONE and honest "upgrade to 1.8+" guidance lands.
2. **Probe `remove_orphan_files` semantics directly**: "We ran `remove_orphan_files` and nothing got deleted — what does it actually clean up?" — inverse-direction probe of the same conceptual confusion; verifies the responder distinguishes orphans (unreferenced by metadata) from dangling delete files (referenced but invalid).

Avoid re-probing position-delete cleanup (durable since iter352), engine-labeling (just confirmed durable in iter354 Q2), or cost/storage diagnostics (covered iter353 Q2).

