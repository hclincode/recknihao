# Iter334 Q2 Score — Iceberg `FOR TIMESTAMP AS OF`

**Topic**: Iceberg table maintenance (time travel sub-topic)
**Question**: Timestamp-based time travel — syntax + "what if no snapshot lines up" semantics
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter334-q2.md`

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5 | All claims verified against Trino docs and Iceberg docs |
| Beginner clarity | 5 | "Commit crossed midnight" example makes the semantics concrete and visceral |
| Practical applicability | 5 | Both simple syntax AND the precision fallback path provided, with a decision matrix |
| Completeness | 5 | Syntax, semantics gotcha, when to use each approach all addressed |
| **Average** | **5.00** | |

## Technical accuracy verification results

(a) **`FOR TIMESTAMP AS OF TIMESTAMP '...'` is the correct Trino syntax** — VERIFIED. The Trino Iceberg connector docs and Starburst examples confirm `FOR TIMESTAMP AS OF TIMESTAMP '2022-03-23 09:59:29.803 Europe/Vienna'` is the canonical form. The answer's example with `TIMESTAMP '2026-05-26 00:00:00 UTC'` matches.

(b) **"Latest snapshot committed at or before T" is the correct resolution semantic** — VERIFIED. Search results explicitly state: "it retrieves the first snapshot on or before the given timestamp" and "Iceberg time travel performs best match snapshot resolution by finding the most recent snapshot that was created on or before the specified timestamp." The answer's phrasing matches exactly.

(c) **`$history` table with `made_current_at` column is the right table for "what readers saw at time T"** — VERIFIED. Trino docs confirm the `$history` table includes a `made_current_at` column and that it "reveals when each snapshot became the current version of the table." The answer's two-step query (find snapshot via `$history`, then `FOR VERSION AS OF`) is the recommended audit-grade pattern.

(d) **`FOR VERSION AS OF <snapshot_id>` is the correct fallback syntax** — VERIFIED. Trino's Iceberg connector documentation confirms `FOR VERSION AS OF <snapshot_id>` as the snapshot-pinning form.

(e) **Trino 467 supports `FOR TIMESTAMP AS OF` natively** — VERIFIED. The time travel syntax has been in the Trino Iceberg connector since the original PR #10258; both forms work on Trino 467 (the production version).

Additional production-fit check: the answer uses `iceberg.analytics.events` as the catalog/schema/table form (matches the prod stack — Trino with Iceberg catalog). The `"events$history"` quoting syntax is correct Trino quoting for metadata tables containing `$`.

## What worked

- **The midnight-crossing example is excellent.** A nightly report that starts at 23:58 and commits at 00:03 → querying `FOR TIMESTAMP AS OF '2026-05-26 00:00:00'` returns pre-report data. This is the exact failure mode the engineer needs to internalize, and the example makes it visceral.
- **Two-tier decision matrix** at the end (approximate vs exact audit) gives the engineer immediate guidance on which path to pick for their situation.
- **`$history` vs `$snapshots` correctly distinguished.** The answer explicitly states `$history` tracks "what readers actually saw" (including rollbacks), which is the right framing for audit reconstruction — and is more precise than `$snapshots.committed_at`.
- **Concrete business scenarios** (billing audits, compliance snapshots) ground the semantics in real engineer concerns.
- **Production fit**: syntax shown is Trino 467-compatible; no version-incompatible features invoked.

## What missed

- Nothing material. Minor optional additions that would not change the score:
  - Could note that `FOR TIMESTAMP AS OF DATE '2026-05-26'` is also accepted as a short form (the search results showed this), but `TIMESTAMP '...'` is the more explicit and recommended form for billing audits.
  - Could mention timezone handling — that the session timezone is used to derive the actual instant — but the answer already shows an explicit `UTC` suffix which is the safer practice anyway.

## Current rubric avg before this score

4.579 across 28 questions (Iceberg table maintenance topic).

## Topic update

After Q2 score of 5.00: (4.579 × 28 + 5.00) / 29 = **4.594 across 29 questions.** Status: PASSED.
