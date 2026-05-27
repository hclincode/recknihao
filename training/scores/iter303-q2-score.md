# Iter 303 Q2 Judge Score

## Topic
Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup

## Scores
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | 4.75 |

## Pass/Fail
PASS (threshold: 3.5)

## Technical accuracy verification
- `FOR TIMESTAMP AS OF TIMESTAMP '...'` — VERIFIED correct Trino Iceberg connector syntax. Resolves to the latest snapshot committed at or before the given timestamp.
- `FOR VERSION AS OF <snapshot_id>` — VERIFIED correct Trino Iceberg time-travel syntax.
- `$snapshots` metadata table with columns `snapshot_id`, `committed_at`, `operation`, `summary` — VERIFIED correct.
- `$history` metadata table with `made_current_at` column — VERIFIED correct.
- 7-day minimum retention floor on `expire_snapshots` `retention_threshold` — VERIFIED correct. Trino rejects with "Retention specified (X.00d) is shorter than the minimum retention configured in the system (7.00d)" (default `iceberg.expire-snapshots.min-retention=7d`).
- `CALL iceberg.system.rollback_to_snapshot('schema','table', <snapshot_id>)` — VERIFIED. Note: this is also valid as the deprecated Trino procedure form; the answer labels it as Spark but it actually works in Trino too (a minor mislabel; Spark form is technically `CALL <catalog>.system.rollback_to_snapshot(table => '...', snapshot_id => ...)`). The recommendation to use Spark on Trino 467 is still correct because the new `ALTER TABLE ... EXECUTE rollback_to_snapshot` is the modern replacement.
- `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id => ...)` only on Trino 469+ — VERIFIED. PR #24580 was merged January 7, 2025 and released in Trino 469 (Jan 27, 2025). The answer correctly states 469+ and that the user's Trino 467 does not support it.
- Tag creation via Spark (`ALTER TABLE ... CREATE TAG ... AS OF VERSION ... RETAIN ... DAYS`) and the claim that Trino cannot create tags — VERIFIED correct for current Trino versions.

The only minor accuracy nit is the labeling of `CALL iceberg.system.rollback_to_snapshot(...)` as "Spark-only" — that exact positional form is actually also the legacy Trino procedure syntax. The intent (use Spark on Trino 467 for rollback) is right, but the engine label is slightly muddied. Not enough to drop a point given the rest is solid and the practical guidance is correct.

## What worked
- Direct, confident YES to the time-travel question with both timestamp and snapshot-ID forms.
- Correct semantics of `FOR TIMESTAMP AS OF` (latest snapshot at-or-before).
- Practical 2-step workflow: find snapshots via `$snapshots`, then run before/after diff via FULL OUTER JOIN — directly answers "which rows were affected".
- Correctly addresses both retention dimensions (Trino floor AND table property `history.expire.max-snapshot-age-ms`).
- Strong incident-specific framing: tells engineer to check `$snapshots` right now to confirm the snapshots are still alive given last-week timing and 30-day default.
- Two recovery options (fix in place vs. hard rollback) with correct trade-offs.
- Correctly distinguishes Trino 467 vs 469 for the EXECUTE rollback syntax — environment-aware.
- Forensic preservation via tags called out (with Spark-only caveat) — good for audit/legal context.
- Fits the production stack (Trino 467, Iceberg 1.5.2, Spark, MinIO).

## What was wrong or missing
- Minor: `CALL iceberg.system.rollback_to_snapshot(...)` labeled "Spark-only" — that form has historically also been the Trino legacy procedure call; cleaner would have been "use Spark on Trino 467; Trino's own `CALL` form is deprecated".
- Beginner clarity: the FULL OUTER JOIN diff query is dense and assumes the table has a stable primary key `id` — a one-line note like "you need a stable row identifier; if your table doesn't have one, use a composite key of business columns" would help a beginner.
- No plain-English gloss of "snapshot" up front (assumed the reader already knows it's an Iceberg point-in-time pointer).
- Did not mention that querying old snapshots requires the underlying data files still to exist in MinIO — if anyone had manually run `remove_orphan_files` or aggressive cleanup, the answer would no-op silently. A one-line caveat would have helped.

## Suggested topic score update
Old: 4.637 / 18 questions
New avg if this scores 4.75: (4.637 × 18 + 4.75) / 19 = (83.466 + 4.75) / 19 = 88.216 / 19 ≈ **4.643 across 19 questions** (PASSED — stable/slight improvement)
