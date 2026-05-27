# Score: Iter 337 Q1 — Orphan File Removal vs expire_snapshots

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Order, orphan-file definition, 7d Trino floor, and example syntax are correct. BUT the central framing that "`expire_snapshots` only removes metadata references" and "actual files stay put until you explicitly tell Iceberg to delete them" is misleading/wrong. Per Trino and Iceberg docs, `expire_snapshots` removes both expired snapshots AND the data files exclusively referenced by them. `remove_orphan_files` exists for files that were *never linked* by metadata (failed writes, abandoned compactions), not for files freed by snapshot expiration. The "concrete scheduling example" closing line "expire old snapshots, then sweep the files they freed up" reinforces this misconception. Also internally inconsistent on retention default (says 3 days, then says Trino 7d floor without distinguishing Iceberg Spark vs Trino defaults). |
| Beginner clarity | 4.5 | Clear structure, plain-language analogies (snapshot A vs snapshot B), well-organized headings, concrete failure scenarios for orphan files (Spark/Trino crashes), explicit "do this in this order" guidance with code. No unexplained jargon. |
| Practical applicability | 4.5 | Engineer gets exact Trino syntax, scheduling cadence, ordering guidance, and a maintenance-window suggestion ("Sunday 3 AM when ingestion is paused"). Trino 467 7d floor is correctly called out — directly applicable to prod stack. |
| Completeness | 4.0 | Covers what each procedure does, why both are needed, order, scheduling, and prod-version constraints. Missing: (a) the safety reason orphan removal needs a generous threshold (concurrent in-flight writes can be wrongly classified as orphans if threshold < write duration), (b) the fact that running orphan removal against a table being actively written to is risky, (c) brief mention that `remove_orphan_files` is expensive (full directory listing of MinIO) so weekly cadence is appropriate. |
| **Average** | **4.125** | **PASS** |

## What Worked
- Correct ordering (expire_snapshots → remove_orphan_files) matches official guidance.
- Correct identification of orphan file sources (mid-write crashes, failed commits, abandoned compaction temp files).
- Correctly flagged Trino 467's 7-day floor for both procedures — production-relevant.
- Trino `ALTER TABLE ... EXECUTE` syntax is correct for both procedures.
- Sunday 3 AM ingestion-paused maintenance window is sensible practical guidance.
- Clear pedagogical structure (what / when / order / example / bottom line).

## What Missed
- **Misframes `expire_snapshots` as metadata-only.** Both Trino and Iceberg docs are explicit that `expire_snapshots` deletes data files no longer referenced by any live snapshot. This is the central technical claim of the answer and it's wrong. The correct framing: `expire_snapshots` reclaims storage for files orphaned BY snapshot expiration; `remove_orphan_files` reclaims storage for files orphaned by failed writes / aborted commits — a separate class of garbage that snapshot expiration cannot see.
- Internal inconsistency on default retention: states 3 days for `remove_orphan_files` (Iceberg Spark default) then says Trino enforces 7d floor. Should clarify Trino's default IS 7d (not 3d), so the 3d Iceberg default never applies on prod.
- Missing safety note that `remove_orphan_files` retention should exceed the longest expected concurrent write duration to avoid deleting in-flight commits.
- No mention that `remove_orphan_files` is expensive on large MinIO buckets (full directory listing).

## Technical Accuracy Verification
- **Claim**: "`expire_snapshots` cleans up metadata; `remove_orphan_files` cleans up orphaned Parquet files on disk." — **PARTIALLY WRONG**. Per Trino docs: "The expire_snapshots command removes all snapshots and all related metadata AND data files." Source: https://trino.io/docs/current/connector/iceberg.html
- **Claim**: "the Parquet data files those old snapshots pointed to are still sitting on MinIO. expire_snapshots only removes the metadata references." — **WRONG**. expire_snapshots deletes data files no longer referenced by any live snapshot.
- **Claim**: Orphan files come from "Spark or Trino write job crashes mid-upload" / "compaction dies partway." — **CORRECT** per Iceberg maintenance docs.
- **Claim**: Order should be expire_snapshots → remove_orphan_files. — **CORRECT**. Per Iceberg/Trino guidance: expire snapshots → remove orphan files → rewrite manifests. Source: https://iceberg.apache.org/docs/latest/maintenance/
- **Claim**: `remove_orphan_files` default `older_than` is 3 days. — **MIXED**. 3d is the Apache Iceberg (Spark) default. Trino's `retention_threshold` defaults to 7d and the catalog min-retention also defaults to 7d. Source: https://trino.io/docs/current/connector/iceberg.html
- **Claim**: Trino 467 minimum retention threshold is 7d for both operations. — **CORRECT**. `iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention` both default to 7d.
- **Claim**: `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '30d')` syntax. — **CORRECT** per Trino Iceberg connector docs.
- **Claim**: `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` syntax. — **CORRECT**.

Sources:
- [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html)
- [Apache Iceberg Maintenance docs](https://iceberg.apache.org/docs/latest/maintenance/)
- [Apache Iceberg Spark Procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [DeleteOrphanFiles javadoc (3-day default rationale)](https://iceberg.apache.org/javadoc/1.2.0/org/apache/iceberg/actions/DeleteOrphanFiles.html)
