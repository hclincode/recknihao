# Iter 8 Q1 — Iceberg table maintenance: inherited setup with two months of skipped maintenance

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | All four procedures and their SQL are correct and match `resources/17-iceberg-table-maintenance.md`. Ordering recommendation (compaction → expire → orphan → manifests) is right. Two inaccuracies: (1) "288+ files per day per partition just from writes alone" is only true for 5-minute streaming pipelines — the resource explicitly ties this to micro-batch ingestion, not daily ETL; the question describes daily ingestion, so citing 288/day is misleading. (2) The stated danger of running `remove_orphan_files` before `expire_snapshots` — "you risk deleting a file that a snapshot still references" — is technically wrong: files that are referenced by any snapshot are by definition not orphans and `remove_orphan_files` will not touch them. The real danger (documented in the resource) is the race condition with an in-flight write when `older_than` is set too aggressively. The ordering recommendation is still correct; only the stated reason is wrong. |
| Beginner clarity | 5 | Strongest clarity in the session. Opens with a concrete "what two months of skipped maintenance looks like" scenario before naming any procedure. Manifest files are defined inline on first use. SQL options are commented. Week-by-week degradation narrative is highly accessible. "Partition pruning" is used once without inline definition and "Parquet" is assumed known, but these are minor nits that do not obscure the main message. |
| Practical applicability | 5 | Four runnable CALL statements with options and comments, correct schedule (nightly 4 AM / Sunday 3 AM), explicit ordering, and a "run all four now" one-time recovery plan. Grounded in Trino 467 + Iceberg 1.5.2 + MinIO throughout. An engineer can act on this today without additional research. |
| Completeness | 4 | Covers all four operations, their SQL, the ordering, and the week-by-week degradation narrative the question asked about. Missing: (a) the 3-day `older_than` protection rationale for `remove_orphan_files` (protects in-flight writes, not just "leftover from failed writes"); (b) concurrency safety note (compaction is safe to run concurrently with ad-hoc queries due to snapshot isolation; ingestion and compaction can conflict); (c) per-table tuning guidance (dim table vs high-volume fact table target sizes); (d) emergency rollback (`rollback_to_snapshot`) as the first-resort cleanup tool when a bad ingestion job runs — the question explicitly asks "what do I need to set up to fix it" and the rollback is part of the answer in the resource. |
| **Average** | **4.50** | |

## Topic updated

**Topic**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup
**Prior question count**: 0 (brand new)
**New average**: 4.50 (first question, single-question average)
**Status**: needs 2nd angle before it can be marked PASSED

## Key finding

The answer is operationally solid and beginner-friendly — the four procedures, correct ordering, and runnable SQL are all present. The main weakness is two related technical imprecisions: the 288-files/day figure applies to streaming pipelines, not daily ETL (misleading for the daily-ingestion scenario described), and the stated danger of running `remove_orphan_files` before `expire_snapshots` inverts the actual failure mode (referenced files are not orphans; the real risk is a race with an in-flight write when `older_than` is too aggressive).

## Resource gap

`resources/17-iceberg-table-maintenance.md` is well-constructed and the responder used it accurately. One addition would help: add an inline callout in the `remove_orphan_files` section explicitly stating that "referenced files are never deleted — only truly unreferenced files are candidates" to prevent the responder from repeating the inverted-danger framing in future answers. Also add a one-sentence clarification in the "Why maintenance is needed" table that the 288-files/day figure assumes a 5-minute micro-batch ingestion schedule, not daily ETL.
