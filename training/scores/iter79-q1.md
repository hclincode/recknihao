# Iter 79 Q1 — Judge Score

**Topic**: Postgres-to-Iceberg ingestion (CDC mechanics, op field, MERGE INTO)
**Score date**: 2026-05-25

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All op codes correct (`c`/`u`/`d`/`r`/`t`); WAL mechanism described correctly; MERGE INTO routing semantically correct; on-prem Kafka context acknowledged. Minor pedantic note: a `'d'` event's row would be the row-before-delete (with values), but the simplification in the example doesn't undermine the MERGE pattern. |
| Beginner clarity | 4.75 | "WAL = immutable audit trail," op table with explicit `'c'` not `'i'` callout, runnable Python/SQL example, and the "100M rows → 1,000 events" intuition all land cleanly. No unexplained jargon. Trivial nit: `events_delta` source name isn't explained as the staging DataFrame. |
| Practical applicability | 5 | Engineer gets: mechanism (WAL→Debezium→Kafka→Spark→Iceberg), exact MERGE INTO with op routing, snapshot handling via `'r'`-as-insert, and explicit "start with watermarks first" guidance for the on-prem k8s stack. Tradeoff section is concrete (3× moving parts, exactly-once requirement). |
| Completeness | 5 | All 7 rubric checks covered: WAL mechanism, op values (including `'r'` and `'t'`), MERGE INTO routing, snapshot row handling, CDC freshness advantage, complexity tradeoff, and when NOT to use CDC. |
| **Average** | **4.94** | |

## Points covered
1. WAL mechanism (not polling) — correct, with the "immutable audit trail" framing.
2. op field values — all 5 correct: `c`/`u`/`d`/`r`/`t`. Explicit "NOT `'i'`" callout is exactly the trap users fall into.
3. MERGE INTO with correct op routing — `'d'` → DELETE, `'u'` → UPDATE SET *, `'c'`/`'r'` → INSERT. The `IN ('c','r')` collapse for snapshot rows is the right idiom.
4. Snapshot rows handled — `'r'` rows go through the NOT MATCHED INSERT path; explained explicitly.
5. CDC freshness advantage — sub-minute latency vs nightly batch; concrete 100M→1K example.
6. Tradeoffs — Debezium + Kafka + Streaming = ~3× moving parts; exactly-once concern; on-prem k8s operator burden mentioned.
7. When NOT to use — "start with incremental + watermarks first" is the correct on-prem guidance; CDC only when sub-5-minute / hard-delete fidelity / very large tables justify it.

## Issues
- Minor: the example `'d'` event shows `event_name: null`, which is misleading — Debezium delete events carry the row-before-delete in the `before` block (so values would be the deleted row's values), not nulls. In the flattened MERGE staging frame this typically doesn't matter since the join uses the primary key, but a beginner could read this as "delete events have no payload."
- Minor: doesn't mention `REPLICA IDENTITY FULL` on the Postgres side (needed for UPDATE/DELETE before-images of non-key columns) — important for production Debezium setup, but slightly beyond the scope of the question.
- Minor: doesn't mention that `t` (truncate) is skipped by default via `skipped.operations` in Debezium — not strictly required but a useful nuance.

## Accuracy verification (WebSearch)
- Verified `c`/`u`/`d`/`r`/`t` op values are correct for Debezium Postgres connector via debezium.io documentation and corroborating Medium/Confluent/RedHat references.
- Verified `c` (not `i`) is the canonical INSERT code — answer correctly flags this.
- Verified `r` = snapshot read, `t` = truncate.
- Verified MERGE INTO with WHEN MATCHED / WHEN NOT MATCHED is the documented Iceberg pattern for CDC-style upserts.

## Resource fix needed?
**No critical fixes.** Two small enhancements would polish the resource:
1. In `resources/13-postgres-to-iceberg-ingestion.md` (or the CDC subsection), clarify that Debezium delete events carry the `before` row payload (not nulls), and explain how to map `before.*` into the MERGE staging frame.
2. Add a one-liner about `REPLICA IDENTITY FULL` requirement for Postgres tables that need full UPDATE/DELETE before-images.

Neither is a blocker — the answer is production-quality for a SaaS engineer starting from zero.

## Updated topic average
Prior: 4.428 / 74 questions
New: (4.428 × 74 + 4.94) / 75 = (327.672 + 4.94) / 75 = 332.612 / 75 ≈ **4.435 / 75 questions**
Status: **PASSED** (>= 3.5 threshold; 75 questions of multi-angle coverage)
