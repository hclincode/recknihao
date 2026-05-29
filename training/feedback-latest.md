# Judge Feedback — Iter 393

**Date**: 2026-05-30
**Phase**: extended
**Overall score**: (4.75 + 4.75) / 2 = **4.75 — STRONG PASS (>= 4.0)**

## Summary

Two consecutive strong passes after iter392's 4.625. Both answers hit the technically-correct inversion / version-pin patterns that distinguish a deeply-informed responder from generic-LLM regurgitation. Iter392+393 together close the Trino-vs-Spark CDC retrieval gap that triggered iter389-391 punts.

---

## Q1 — Trino `system.table_changes` (Trino CDC pattern)

Responder correctly states: Trino has NO `system.table_changes` equivalent (the Iceberg-Spark CDC TVF does not exist in Trino's Iceberg connector); `start-snapshot-id`/`end-snapshot-id` are Spark-only DataFrameReader options; the Trino-side alternative is a timestamp watermark on an `updated_at` column with SQL filter `WHERE updated_at > :last_watermark AND updated_at <= :now`; limits — backdated timestamps (rows arriving late with old updated_at miss the watermark window) and timestamp skew (clock drift across writers).

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Correctly inverts the common LLM misconception that "system.table_changes exists in Trino too"; the Spark-only constraint on start-snapshot-id is upstream-accurate; timestamp-skew/backdated caveats are exactly the failure modes of the watermark pattern. |
| Beginner clarity | 4.5 | SQL example with `updated_at` makes the abstract watermark pattern concrete; "timestamp skew" is OLAP-adjacent jargon but acceptable in context. |
| Practical applicability | 5.0 | Engineer can copy the SQL filter directly; fits Trino 467 prod stack exactly (no Spark dependency for the CDC read path). |
| Completeness | 4.5 | Covers (a) the gap (Trino lacks the TVF), (b) the alternative (timestamp watermark), (c) the two main limits. Could mention `$snapshots` metadata table as a corroboration check but not required. |
| **Average** | **4.75** | |

**Iter 393 Q1: 4.75 — STRONG PASS**

The Trino-side counterpart to iter392's Q1 (which was the Spark-side `start-snapshot-id` answer). Together iter392+393 close the incremental-reads gap that dragged across iter389+390+391. The teacher's resources/13 patch is now retrievable from both angles.

---

## Q2 — Position vs equality deletes

Responder correctly distinguishes: **Position deletes** = MoR tables, row-position pointer (file_path + row position), `content=1` in the delete manifest, compacted via `rewrite_position_delete_files` procedure in Spark when delete count exceeds ~50 per data file; **Equality deletes** = produced by CDC/Debezium upserts, column-value matching (delete row where pk=X), `content=2` in the delete manifest, NO built-in equality-delete compaction in Iceberg 1.5.2, dangling-delete bug #12838 affects 1.5.x, upgrade to Iceberg 1.8+ for the real fix; **CoW default** = produces neither type (rewrites whole data files).

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | content=1/content=2 manifest distinction is upstream-correct; `rewrite_position_delete_files` is the actual Spark procedure name; dangling-delete bug #12838 is real and affects Iceberg 1.5.x; the 1.8+ fix line is accurate; CoW=neither is correct (CoW rewrites, doesn't delete-file). |
| Beginner clarity | 4.0 | Heavy jargon load (MoR, CoW, CDC, Debezium, manifest, content flag, dangling delete) — these are necessary but represent a steep ramp for a beginner. Bug-number references add a layer of complexity but also signal credibility. |
| Practical applicability | 5.0 | Engineer on prod stack (Iceberg 1.5.2) gets the exact threshold (50 deletes per file), the exact procedure name, the exact upgrade target (1.8+), and the exact bug to track. Maps directly to prod_info.md Iceberg 1.5.2 version pin. |
| Completeness | 5.0 | Covers both delete types + CoW default + version-specific gap + bug reference + Spark-procedure-only constraint. Could mention Trino-side handling but the question is about delete-file semantics which is primarily a Spark maintenance concern. |
| **Average** | **4.75** | |

**Iter 393 Q2: 4.75 — STRONG PASS**

Textbook-grade detail on delete-file semantics. The bug reference (#12838) and version-pin (1.8+) are exactly the kind of details that prove the responder is not generic-LLM-paraphrasing. The CoW=neither caveat closes a common misconception (engineers often assume CoW = "no delete files = no problem", but the question is whether the table is MoR-configured in the first place).

---

## Pattern observation iter370-393

4.625 -> 4.375 -> 4.47 -> 3.98 FAIL -> 4.5625 -> 4.75 -> 4.1875 -> 4.4375 -> 4.40625 -> 4.5625 -> 3.25 FAIL -> 4.71875 -> 4.8125 -> 4.78125 -> 4.375 -> 4.094 -> 4.4375 -> 4.4375 -> 4.4375 -> 4.25 -> 3.125 FAIL -> 4.75 PASS -> 4.125 PASS -> 3.9375 FAIL -> 4.625 PASS -> **4.75 PASS**.

Two consecutive strong passes; the iter392-393 pair closes the Trino-vs-Spark CDC retrieval gap that triggered iter389-391 punts.

## Topic score updates

- **Iceberg table maintenance**: 4.4698/54 -> 4.4753/55 (rise from Q2 strong pass on delete file compaction semantics)
- **Postgres-to-Iceberg ingestion**: 4.5193/138 -> 4.5208/139 (rise from Q1 strong pass on Trino CDC-watermark pattern as alternative when Iceberg-side TVF unavailable)

## Teacher actions next (iter394)

1. **LOW** — Trino `system.table_changes` inversion landed clean from both Spark side (iter392) and Trino side (iter393); no action.
2. **LOW** — Q2 delete-file detail (content=1/2 + bug #12838 + 1.8+ upgrade target) is textbook-grade; no action.
3. **OPTIONAL** — verify resources/13 has the timestamp-skew and backdated-timestamps caveats explicitly listed under the Trino CDC section to lock in the iter393 retrieval pattern.

## Judge probe targets next (iter394)

1. **MED** — Incremental reads FIFTH angle (e.g. backfill restart from snapshot history, or Spark Structured Streaming with Iceberg source).
2. **MED** — Delete-file compaction SECOND angle to confirm not one-off (e.g. equality-delete buildup symptoms in query latency, or how to detect dangling deletes operationally).
3. Carry-forward standard backlog: HMS->Nessie no-downtime, SPILL_FAILED at 60GB / 200GB cap, MERGE INTO rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO + VALIDATE, result caching, Iceberg branches fast_forward, bucket sizing, JWT+OPA concurrency, partition spec migration, Iceberg tagging 3rd angle, fs.cache 3rd angle JMX.
