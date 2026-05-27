# Iter 113 Q1 — Judge Report

**Question topic**: Postgres-to-Iceberg ingestion — Debezium at-least-once delivery; duplicate cleanup and MERGE-based prevention after Kafka consumer fell behind by ~3 hours.

**Answer under review**: `/Users/hclin/github/recknihao/training/answers/iter113-q1.md`

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5 | All Debezium/Iceberg/Spark claims verified correct against official docs (see below). |
| Beginner clarity | 4 | Reads cleanly; one or two unexplained terms (`expired_snapshots`, `replication slot`, `LSN`, `op='r'` snapshot read, `_debezium_connect_offsets`) drop in without inline glosses for a SaaS engineer with zero OLAP background. |
| Practical applicability | 5 | Engineer can act immediately: detect, choose cleanup path (rollback vs overwrite), install MERGE, lower flush interval, and add `source_lsn`. Concrete SQL + PySpark provided for every step. |
| Completeness | 5 | Covers root cause, detection, two recovery paths, the standard MERGE-based prevention with LSN guard, the at-least-once flush-interval mitigation, and the schema change required to support the LSN guard. Explicit answer to the user's three sub-questions ("dedup after every batch?", "what does MERGE look like?", "fix at ingestion?"). |
| **Average** | **4.75** | **PASS** |

---

## Verdict

**PASS** (4.75 / 5.0). The answer is production-grade and accurately reflects the on-prem stack (Spark + Iceberg 1.5.2 + Trino 467 + Strimzi Connect + MinIO). It correctly tells the engineer that the right fix is **idempotency at the ingestion layer** (MERGE + LSN guard), not a post-batch dedup query — which is the structural answer the question actually deserves. Recovery options are correctly ordered (rollback first, overwritePartitions second) and match resource 13's recommended priority.

---

## What was verified correct (via WebSearch and resources/13)

1. **`offset.flush.interval.ms` default = 60000ms (60s)** — confirmed against Confluent + Apache Kafka Connect docs. The answer's claim that "by default, [offsets flush] every 60 seconds" is correct.
2. **At-least-once is the documented behavior** — Debezium FAQ and engine docs confirm "the number of duplicate records received after a crash depends on how frequently the engine flushes offsets via `offset.flush.interval.ms`". The answer paraphrases this correctly.
3. **`_debezium_connect_offsets` is the Strimzi default offset-storage topic name** — matches resource 13's prod-stack callout (line 1654-1657) and the Strimzi `KafkaConnect` CRD config example (line 1337). The answer chose the correct name for the production stack.
4. **`op='d'` event has a null `after` field** — confirmed against Debezium event-flattening docs: "the value of the after field is null, because the row no longer exists." The answer's warning that "collapsing DELETE into an UPDATE branch would null out all columns" is accurate.
5. **`op='r'` = snapshot read event** — confirmed against Debezium Postgres connector docs: snapshot reads are emitted as `op: r`. The answer correctly handles `'r'` in both MATCHED and NOT MATCHED branches.
6. **`CALL iceberg.system.rollback_to_snapshot(table => ..., snapshot_id => ...)` is the correct Iceberg 1.5.x Spark procedure signature** — verified against Iceberg 1.5.1 spark-procedures docs (1.5.2 uses identical procedure surface).
7. **`overwritePartitions()` semantics** — matches resource 13 (lines 55-75, 2539-2555) and is the correct safe call for partition-scoped re-ingest.
8. **`SELECT snapshot_id, committed_at, operation, summary FROM <table>.snapshots` metadata table** — valid Iceberg metadata-table query in Trino.
9. **Three-branch MERGE pattern with `source_lsn` idempotency guard** — matches the canonical pattern in resource 13 (lines 2266-2286) including the `s.source_lsn > t.source_lsn` guard. The answer's MERGE is structurally identical to the resource's authoritative example.
10. **`ALTER TABLE ... ADD COLUMN source_lsn BIGINT` is metadata-only in Iceberg 1.5.x** — correct (Iceberg schema evolution adds columns without rewriting data files; old rows return NULL on read).

---

## Errors or gaps found

### Minor accuracy nits (no points deducted, but worth flagging to teacher)

1. **"Debezium was still writing CDC events to Kafka (the replication slot on Postgres was holding them)"** — slightly conflates two stages. The replication slot on Postgres holds **WAL segments** until Debezium ACKs them; Debezium writes to Kafka only after it has consumed those WAL events. If the **Kafka consumer** (downstream Iceberg writer) fell behind, that's actually a consumer-group lag problem, not a Debezium-to-Kafka lag problem. The user's question is ambiguous about which layer fell behind, and the answer reads it as "Debezium → Kafka". This is plausibly what happened but the answer could be sharper: the at-least-once duplicate window from `offset.flush.interval.ms` is the **Connect → offset-topic** ack window, not the downstream Iceberg consumer's window. The advice (lower flush interval, use MERGE) is still correct for both interpretations.

2. **`offset.flush.interval.ms` on `KafkaConnect` CRD** — the YAML snippet is correct but the value should be a string in Strimzi config (`"10000"`), which the answer does correctly quote. Good.

3. **`source_lsn` cast** — `col("source.lsn").cast("long")` is correct (Debezium emits LSN as a numeric type that fits in a long; Postgres LSN is a 64-bit value).

### Clarity gaps

1. **`expire_snapshots` introduced without definition** — Option A vs Option B hinges on whether `expire_snapshots` has run, but a beginner reading this answer does not know what that procedure does or how to check whether it ran. A one-line gloss ("`expire_snapshots` is the Iceberg maintenance job that deletes old snapshot metadata after a retention window — if it has not run since the bad ingest, you can still roll back; otherwise the pre-duplicate snapshot is gone") would close this.

2. **`source_lsn` / `LSN`** — used 6+ times without ever defining what a Postgres Log Sequence Number is. A SaaS engineer with no OLAP background does not know that LSN is a monotonically increasing WAL position. One sentence ("LSN = Postgres's monotonically increasing write-ahead-log position; later events have higher LSN, so `s.source_lsn > t.source_lsn` means 'this event is newer than the row we already have'") would land it.

3. **`op='r'` (snapshot read)** — mentioned in the MERGE comment but the engineer asked about a steady-state CDC stream, so they will not have encountered `'r'` yet. A short note that `'r'` only shows up during the initial bootstrap of the connector would orient them.

4. **`_debezium_connect_offsets`** — named correctly but no explanation that this is Strimzi's name for the Connect offset-storage topic (not `__consumer_offsets`, not `connect-offsets`). Resource 13 has this exact disambiguation block (line 1654-1663) and the answer should have either named it or skipped the topic name entirely.

### Completeness gaps

None material. The answer addresses every sub-question asked. Possible additions that were correctly omitted as out-of-scope: dead-letter queue setup, schema-registry handling, exactly-once with Kafka transactions (which the answer correctly does not promise).

---

## Resource fix recommendations

### LOW priority

1. **`resources/13-postgres-to-iceberg-ingestion.md` — add inline glosses near the three-branch MERGE section** for the terms `LSN`, `op='r'`, `expire_snapshots`, and `_debezium_connect_offsets`. The resource already defines all of these in OTHER sections (lines 1654, 1911, 2507, 1641-1648), but they are not adjacent to the canonical MERGE pattern, so an answer generator that pulls only the MERGE block does not get the definitions. Consider either:
   - A 4-line glossary block immediately above the three-branch MERGE example (lines ~2266), OR
   - A `> **Plain-English glossary for this section**` callout at the top of the duplicate-cleanup decision matrix.
   Priority is LOW because the missing-gloss issue cost only 1 point on clarity (4 / 5), and the answer is still above pass threshold by a wide margin.

### No HIGH or MEDIUM fixes recommended

The MERGE pattern, the rollback-vs-overwrite decision matrix, the `offset.flush.interval.ms` framing, and the LSN-guard idempotency story are all already in resource 13 in a form the responder used correctly. No structural gaps.

---

## Sources verified

- [Kafka Connect Worker Configuration Properties (Confluent)](https://docs.confluent.io/platform/current/connect/references/allconfigs.html) — `offset.flush.interval.ms` default = 60000ms
- [Kafka Connect Configs (Apache Kafka 3.8)](https://kafka.apache.org/38/configuration/kafka-connect-configs/) — Connect worker config reference
- [Debezium Engine documentation](https://debezium.io/documentation/reference/stable/development/engine.html) — duplicate-window dependency on offset flush interval
- [Debezium FAQ](https://debezium.io/documentation/faq/) — at-least-once delivery semantics
- [Debezium event-flattening / Delete event structure](https://debezium.io/documentation/reference/stable/transformations/event-flattening.html) — `after` is null on `op=d`
- [Debezium Postgres connector documentation](https://debezium.io/documentation/reference/stable/connectors/postgresql.html) — snapshot reads emitted as `op=r`
- [Apache Iceberg 1.5.1 Spark Procedures](https://iceberg.apache.org/docs/1.5.1/spark-procedures/) — `rollback_to_snapshot` signature confirmed
- [Apache Iceberg Spark Writes](https://iceberg.apache.org/docs/latest/spark-writes/) — MERGE INTO and overwritePartitions semantics
