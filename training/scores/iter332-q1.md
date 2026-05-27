# Iter 332, Q1 — Evaluation

**Topic**: Postgres-to-Iceberg ingestion (focus: Kafka Connect / Debezium duplicate window + MERGE INTO idempotency)
**Rubric avg before this score**: 4.496 across 117 questions

## Score table

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5 | All load-bearing claims verified against official docs. |
| Beginner clarity | 4.5 | Concrete numeric example with explicit "worst case is just before next flush"; minor implicit jargon (LSN, WAL, micro-batch) used without first-mention definitions. |
| Practical applicability | 5 | Engineer leaves with: store `source_lsn` BIGINT, add LSN guard in MERGE, do pre-MERGE ROW_NUMBER() dedup, optionally lower flush interval with named tradeoff. |
| Completeness | 4.75 | Covers window, MERGE protection, both edge cases (stale overwrite + intra-batch multi-update), and how to reduce window. Minor: does not mention Kafka producer-side `producer.override.*` or the source-task-specific commit nuance (commit happens after `poll()` cycles, not strictly on a wall clock), and does not flag the OPA/Trino-on-MERGE catalog interaction. None of these are required by the question. |
| **Average** | **4.81** | |

## What worked

- **Window framing is exact**: explicitly calls out the window as **time-based**, not event-count-based, and gives the burst-of-100k-events-in-one-second example showing why a single offset commit window can contain wildly varying event counts. This directly addresses the engineer's literal question.
- **Two-part edge case** (LSN guard + pre-MERGE dedup) is the correct production answer. Both are real failure modes; either omission causes silent corruption.
- **The "without LSN guard, LSN3 gets overwritten by replayed LSN1" walkthrough** is the kind of concrete failure scenario that makes the abstract risk land for a beginner.
- **Pre-MERGE dedup uses `ROW_NUMBER().over(window.orderBy(source_lsn.desc()))`** — the correct ordering key (LSN, not arrival time). Many incorrect answers use timestamp here.
- **Tradeoff named explicitly** when recommending lower flush interval (higher offset-topic write load).
- **8-byte storage cost** for `source_lsn` is mentioned — concrete, lets the engineer estimate impact.
- **Resource citation present.**

## What missed

- **Did not surface the on-prem stack explicitly**: question is environment-agnostic so this is not a deduction, but a small mention that Spark Structured Streaming on the on-prem k8s + Iceberg 1.5.2 catalog supports this pattern would have made the answer feel anchored. Production stack from `prod_info.md` is not contradicted anywhere.
- **Beginner-clarity nit**: "LSN", "WAL", "micro-batch", and "source.lsn field" appear without first-use definitions. A SaaS engineer with no OLAP background would benefit from one inline gloss (e.g., "LSN — Log Sequence Number, Postgres's monotonically-increasing position pointer in the WAL"). The question text shows the engineer already knows Debezium basics, so this is minor.
- **Did not explicitly distinguish source-connector commits from sink-connector commits**: Debezium is a source connector and the offset commit semantics are slightly different from the SinkTask.flush() path. The answer's mechanics are correct, but a precise statement that for source connectors `offset.flush.interval.ms` triggers `OffsetStorageWriter.beginFlush()` on the source offsets topic (`connect-offsets`) would have been the maximally rigorous framing.
- **Did not mention that `MERGE INTO` against Iceberg in Spark requires the `merge-on-read` or `copy-on-write` mode setting** to be explicit when write performance matters at the scale implied by 100 events/sec. Not core to the question.
- **No mention of `__debezium_unavailable_value` or tombstones**, which can also cause duplicate-looking rows; out of scope for this specific question.

## Technical accuracy verification

- **`offset.flush.interval.ms` default = 60,000 ms (60 seconds)** — VERIFIED via Apache Kafka and Confluent docs.
- **At-least-once delivery window is time-based, not event-count-based** — VERIFIED. The runtime relies on periodic offset commits triggered by the wall-clock interval; a high-volume burst followed by silence still consumes only one commit window, exactly as the answer states.
- **LSN guard `s.source_lsn > t.source_lsn` is correct idempotency pattern** — VERIFIED via Debezium PostgreSQL docs. LSNs are monotonically increasing per WAL position; comparing against the max stored LSN is the canonical consumer-side dedup hook Debezium itself documents.
- **Pre-MERGE ROW_NUMBER() dedup is required for Spark/Iceberg MERGE INTO** — VERIFIED. Iceberg MERGE throws on multiple source rows matching the same target row (the engine cannot decide which source wins). ROW_NUMBER() PARTITION BY join key, ORDER BY source_lsn DESC, filter rn=1 is the standard mitigation.
- **No fabricated claims found.** The 8-byte BIGINT storage cost is accurate.

## Pattern observation

Postgres-to-Iceberg topic is at 4.496/117 going in. This 4.81 answer continues the upward drift (consistent with iter331's 4.6875 trend) and is the strongest CDC-idempotency answer in recent iterations — the LSN-guard + pre-MERGE dedup pairing has been explained correctly without any of the historical fabrications (e.g., earlier iterations claimed timestamp-based ordering or skipped the multi-match constraint).

**New running avg** for Postgres-to-Iceberg ingestion: (4.496 × 117 + 4.81) / 118 ≈ **4.499 across 118 questions**. Status: **PASSED**.

## Sources

- [Apache Kafka Connect Configs](https://kafka.apache.org/42/configuration/kafka-connect-configs/)
- [Confluent Kafka Connect Worker Configuration Properties](https://docs.confluent.io/platform/current/connect/references/allconfigs.html)
- [Debezium PostgreSQL connector documentation](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- [Apache Iceberg Spark Writes — MERGE INTO](https://iceberg.apache.org/docs/latest/spark-writes/)
- [Iceberg issue #7005 — Duplicate records with MERGE command](https://github.com/apache/iceberg/issues/7005)
