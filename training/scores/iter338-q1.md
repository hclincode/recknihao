# Score: Iter 338 Q1 — Crashed Write Files vs expire_snapshots

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Core technical distinction is correct and matches official Iceberg docs. `expire_snapshots` deletes both metadata AND physically deletes data files uniquely owned by expired snapshots; `remove_orphan_files` handles files never referenced by any snapshot (the crashed-write case). Minor imprecision: the answer says `remove_orphan_files` "does a full directory scan of MinIO" — this is correct for the Spark-native procedure, but in Trino 467 the procedure also defaults to a 7-day retention (`retention_threshold`) safety floor, which the answer never mentions. Also, the answer states "Running `remove_orphan_files` before `expire_snapshots` creates a race condition risk" — correct in spirit (canonical order is expire→orphan, per IOMETE/Dremio runbook), but the sentence appears as a closing aside without explaining why (in-flight writes within the retention window). |
| Beginner clarity | 5.0 | Excellent. Opens with a clear yes/no verdict, uses a concrete narrative ("uploaded a Parquet file, then crashed before writing the commit"), and provides a two-column comparison table. Zero unexplained jargon — "snapshot," "manifest," "orphan" all framed in plain language. |
| Practical applicability | 4.5 | Engineer knows exactly what to do: add `remove_orphan_files` as a separate step, run after `expire_snapshots`. Schedule cheat sheet is included with all four maintenance ops in correct canonical order. Missing: no Trino 467 vs Spark syntax shown (prod stack uses both); no mention of the 7-day `retention_threshold` floor in Trino, which would be the most important operational gotcha here — if the crash was last night, a default-config `remove_orphan_files` will NOT clean it up for 7 days unless `older_than` is set. This is a meaningful actionable gap given the engineer's "last night" framing. |
| Completeness | 4.0 | Core question fully answered. Schedule expanded beyond what was asked (good). Gaps: (1) no concrete CALL/EXECUTE syntax (Spark `CALL system.remove_orphan_files(...)` or Trino `ALTER TABLE ... EXECUTE remove_orphan_files`); (2) no mention of the 7-day floor on Trino 467 `remove_orphan_files` which directly affects whether last night's crash files get cleaned; (3) no mention that `dry_run` is available in Spark but NOT in Trino — important on prod stack; (4) doesn't explicitly call out that an aborted Spark commit may also leave metadata files (manifest lists) orphaned, not just data files, though `remove_orphan_files` handles both. |
| **Average** | **4.50** | **STRONG PASS** |

## What Worked
- Clear, direct verdict in the first sentence ("Your teammate is absolutely right").
- Correct mental model: `expire_snapshots` deletes files that WERE in snapshots; `remove_orphan_files` deletes files that NEVER made it into a snapshot.
- Concrete narrative of the crash scenario — "uploaded a Parquet file, then crashed before writing the Iceberg commit" — grounds the concept.
- Two-column comparison table makes the distinction memorable.
- Canonical maintenance ordering (compaction → expire → orphan → manifests) given as a schedule.
- Correctly notes that running orphan-cleanup before snapshot-expire has race risk (canonical order is expire→orphan).

## What Missed
- **No Trino 467 7-day `retention_threshold` floor warning.** This is the single most impactful operational gap. The engineer's crash was "last night" — they will run `remove_orphan_files` and it will silently skip those fresh files unless they override `older_than`. Resources/17 covers this; responder didn't surface it.
- **No concrete syntax.** Neither Spark `CALL` form nor Trino `ALTER TABLE ... EXECUTE` form shown. Production stack uses both.
- **No mention of `dry_run` asymmetry** (Spark supports, Trino does not) — useful safety guidance the responder has surfaced in prior iterations.
- **Doesn't explicitly note metadata-file orphans** (manifest, manifest-list) — a crashed write can leave orphaned manifests too, though the procedure handles them.

## Technical Accuracy Verification
- **Claim**: `expire_snapshots` "physically deletes any data files that snapshot exclusively owned." **Verified correct.** Per https://iceberg.apache.org/docs/latest/maintenance/ — "expire_snapshots ... will remove old snapshots and data files which are uniquely required by those old snapshots." This corrects an earlier responder bug (iter337) where expire_snapshots was framed as metadata-only.
- **Claim**: `remove_orphan_files` "does a full directory scan" for files no current snapshot points to. **Verified correct.** Per https://iceberg.apache.org/docs/latest/spark-procedures/ — the procedure lists all files under the table location and compares against metadata references.
- **Claim**: Crashed-write files are orphans because they were never committed into a snapshot. **Verified correct.** This is the canonical orphan-file scenario per IOMETE runbook (https://iomete.com/resources/blog/iceberg-maintenance-runbook) and Dremio's maintenance blog.
- **Claim**: Maintenance order = compaction → expire_snapshots → remove_orphan_files → rewrite_manifests. **Verified correct.** Matches official Iceberg maintenance doc and IOMETE/Dremio runbooks ("expire snapshots → remove orphan files → rewrite manifests").
- **Claim**: Running `remove_orphan_files` before `expire_snapshots` is a race risk. **Partially verified / imprecise.** The canonical guidance is expire-then-orphan to avoid considering expired-but-not-yet-deleted files as orphans. The bigger race risk is removing in-flight write files within the retention window — the answer doesn't articulate which race it's referring to. Per https://iceberg.apache.org/docs/latest/maintenance/, "It is dangerous to remove orphan files with a retention interval shorter than the time expected for any write to complete."
- **Not stated but should be**: Trino 467 `remove_orphan_files` defaults to a 7-day `retention_threshold` floor. Per https://trino.io/docs/current/connector/iceberg.html — this is the operational reality on prod stack. Missing this affects practical applicability for the engineer's specific "last night" timeline.

Sources verified:
- https://iceberg.apache.org/docs/latest/maintenance/
- https://iceberg.apache.org/docs/latest/spark-procedures/
- https://trino.io/docs/current/connector/iceberg.html
- https://iomete.com/resources/blog/iceberg-maintenance-runbook
