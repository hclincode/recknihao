# Iter 332 Q2 — Judge Evaluation

**Topic**: Iceberg table maintenance (specifically `$history` vs `$snapshots` metadata tables for point-in-time reconstruction)
**Question**: "What's the difference between `$snapshots` and `$history`? For 'what did the table look like at 2pm yesterday,' which should I use?"

## Score Table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All column claims verified against Trino official docs. `$history` has `made_current_at`, `snapshot_id`, `parent_id`, `is_current_ancestor`. `$snapshots` has `committed_at`, `snapshot_id`, `parent_id`, `operation`, `manifest_list`, `summary`. `FOR VERSION AS OF <snapshot_id>` is correct Trino syntax. The conceptual claim — `$history` = ordered commit chain (captures rollbacks via reused snapshot_id with fresh made_current_at), `$snapshots` = all snapshots ever created — matches both the resource and Trino docs. |
| Beginner clarity | 5 | The rollback timeline (1:45 → 1:50 bad write → 1:51 rollback → 2:00 query) is concrete and shows exactly why `$snapshots` alone is insufficient. Jargon is minimal and explained inline ("the live version", "the ordered commit chain"). |
| Practical applicability | 5 | Gives the exact two-step SQL: (1) Query `$history` with `WHERE made_current_at <= TIMESTAMP '...'` ORDER BY DESC LIMIT 1; (2) `SELECT * FROM table FOR VERSION AS OF <snapshot_id>`. Engineer can copy-paste and run. Fully qualified table reference (`iceberg.analytics."our_events$history"`) with the required quoting around the `$` is correct for Trino. |
| Completeness | 4.5 | Covers the key difference, when to use each (with a clean comparison table), and the exact query pattern. Minor gaps: (a) does not mention the `is_current_ancestor` boolean in `$history`, which is genuinely useful for filtering out snapshots that were rolled out of the current chain; (b) does not mention `FOR TIMESTAMP AS OF` as an alternative one-shot option (and the gotcha that it resolves to "latest snapshot with committed_at <= T," covered in the resource). Both omissions are small relative to the question asked. |

**Average: (5 + 5 + 5 + 4.5) / 4 = 4.875**

## What Worked

- **Correct framing of the conceptual difference.** The answer leads with "$snapshots = every snapshot ever created" vs "$history = ordered commit chain showing which snapshot was current" — this is the right mental model and matches the Trino docs almost verbatim.
- **The rollback example.** Concrete timestamps (1:45, 1:50, 1:51, 2:00) and the explicit statement "at 2pm, readers saw Snapshot B's state" make the abstract distinction tangible. This is exactly the kind of example the rubric rewards.
- **Two-step SQL pattern.** Step 1 finds the right snapshot from `$history`; Step 2 time-travels to it via `FOR VERSION AS OF`. The engineer doesn't need to combine ideas across multiple sources.
- **Correct Trino metadata-table quoting.** `iceberg.analytics."our_events$history"` correctly quotes the `$`-suffixed table name — a common syntax trap that the responder navigated correctly.
- **Decision table.** The "When to Use Each" matrix is well-targeted: it not only answers the question asked but anticipates "what is each one good for?" — exactly what a SaaS engineer needs to internalize the choice for future questions.

## What Missed

- **No mention of `is_current_ancestor`.** This is the fourth column in `$history` and is directly relevant to the audit-reconstruction story: filtering `WHERE is_current_ancestor = true` excludes snapshots that were rolled out of the current chain. The answer's narrative is correct, but omitting this column leaves a piece of `$history` undiscussed.
- **No mention of `FOR TIMESTAMP AS OF` as a one-shot alternative.** The resource explicitly covers this and warns about its "latest snapshot with `committed_at <= T`" resolution. The two-step approach the answer gives is more precise, but mentioning that `FOR TIMESTAMP AS OF TIMESTAMP '2026-05-26 14:00:00 UTC'` exists (with its caveat) would have given the engineer a faster option for non-audit-grade work.
- **"Unmerged branch" phrasing is slightly loose.** Saying a snapshot in `$snapshots` "might exist only on an unmerged branch" is directionally correct (branch-tip snapshots do appear in `$snapshots`), but the more accurate distinction for the 2pm question is simply that `$snapshots` lacks the `made_current_at` ordering. Minor — does not affect the conclusion.

## Technical Accuracy Verification

Verified against Trino current docs (https://trino.io/docs/current/connector/iceberg.html):

- **`$history` columns**: `made_current_at` (TIMESTAMP(3) WITH TIME ZONE), `snapshot_id` (BIGINT), `parent_id` (BIGINT), `is_current_ancestor` (BOOLEAN). Answer's claim about `made_current_at` is correct.
- **`$snapshots` columns**: `committed_at` (TIMESTAMP(3) WITH TIME ZONE), `snapshot_id`, `parent_id`, `operation` (VARCHAR — append, replace, overwrite, delete), `manifest_list`, `summary` (map). Answer's claims about `committed_at`, `operation`, and `parent_id` are all correct.
- **`FOR VERSION AS OF <snapshot_id>`**: confirmed as standard Trino time-travel syntax.
- **Behavioral claim** (`$history` captures rollbacks via the same snapshot_id reappearing with fresh `made_current_at`): confirmed — this is documented behavior and matches the resource at line 768.
- **Both metadata tables exist in Trino Iceberg connector**: confirmed.

No technical errors identified.

## Topic and Rubric Update

- **Topic**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup
- **Prior avg**: 4.568 across 27 questions
- **New avg**: (4.568 × 27 + 4.875) / 28 = (123.336 + 4.875) / 28 = 128.211 / 28 ≈ **4.579 across 28 questions**
- **Status**: PASSED (well above 3.5 threshold; tested from many angles including rollback semantics, expire_snapshots safety, Trino vs Spark engine boundaries, history.expire.* properties, and now metadata-table choice for audit reconstruction).

## Sources Consulted

- [Iceberg connector — Trino current docs](https://trino.io/docs/current/connector/iceberg.html)
- /Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md (lines 750–774 cover `$history` vs `$snapshots` and `FOR TIMESTAMP AS OF` resolution)
