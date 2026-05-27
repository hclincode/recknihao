# Iter128 Q2 — Judge Score

**Score**: 4.6 / 5 (Tech 4.5, Clarity 5, Practical 5, Completeness 4)

## Verdict
Excellent answer. It correctly reframes the question (pull vs push, not "more often"), gives the engineer a concrete on-prem complexity and cost picture, and ends with the right operational guidance: ask the customer first, try hourly batch before full streaming, and only then commit to the full Debezium/Kafka/Spark Structured Streaming stack. Technical claims about the stack (Debezium 2.x WAL CDC, `wal_level = logical`, Iceberg streaming writes, hourly compaction) are accurate. The "10x complexity per tier" framing is a useful pedagogical heuristic — not a literal industry constant, but consistent with how the industry talks about freshness tiers. Minor gaps around streaming write specifics keep this from a perfect 5.

## What was verified correct (via WebSearch)
- **Iceberg 1.5.2 + Spark Structured Streaming writes**: Iceberg supports `writeStream.format("iceberg")` with append/complete output modes; this is well-documented and present in 1.5.x (the docs cover 1.4.2, latest, and 1.7.2). Sample code in the answer is structurally correct.
- **Debezium 2.x + Postgres WAL CDC**: Debezium uses Postgres logical replication slots reading the WAL; `wal_level=logical` is the correct and required setting, along with `max_wal_senders` and `max_replication_slots`. Answer's Postgres side instructions are accurate.
- **WAL recycling / lost-slot failure mode**: Real and well-known operational hazard — if WAL is recycled faster than Debezium consumes, the slot can fail.
- **Small-files problem with 30s micro-batches**: Documented industry pain point; the answer's daily file estimate (2,880–5,760 files/day from 30s triggers) and recommendation for hourly compaction match real-world guidance. (Some sources recommend even more careful tuning — wait-and-compact, cold-partition-only compaction — but the answer's direction is right.)
- **Iceberg streaming write best practice**: Official Iceberg docs recommend trigger intervals of at least 1 minute for streaming writes; the answer's 30s example is on the aggressive end but not wrong.
- **`CALL iceberg.system.rewrite_data_files(...)` syntax**: Correct as Spark syntax with named-arg `options => map(...)`. Engine labeling is clean.

## Errors or gaps
- **MEDIUM**: The Spark Structured Streaming code sample writes Kafka events directly to Iceberg with `.format("iceberg")` — but Debezium emits a complex JSON envelope (`{before, after, op, source, ts_ms, ...}`). In reality there must be a parsing/transformation step (e.g., `from_json` with a schema, then projecting `after` or applying `op` semantics for D/U/I), plus typically a MERGE INTO for upserts/deletes if the target table is not append-only. The sketch as shown would write raw Kafka payload bytes to Iceberg.
- **MEDIUM**: Append-only `writeStream` does not handle UPDATEs and DELETEs from CDC. For a Postgres mirror, the engineer needs MERGE INTO via `forEachBatch` (or an Iceberg upsert pattern). The answer mentions "applying changes" but the code shown is append-only.
- **LOW**: Iceberg streaming docs explicitly recommend trigger interval >= 1 minute; the answer uses 30s in the example. Not wrong, but worth flagging as the lower bound.
- **LOW**: "10x complexity per tier" is a useful heuristic but is the responder's framing, not an industry standard — the answer presents it slightly more definitively than the literature supports. The 1000x for 5-minute streaming may overstate the gap from 15-minute streaming (both use the same architecture).
- **LOW**: No mention that Kafka itself must be deployed and operated on-prem (a major new ops burden), only that it is "a new dependency." Iter127 Q1 feedback flagged this same gap.
- **LOW**: `checkpointLocation` on `s3a://` against MinIO works but is a known fragility point (S3 listing consistency, checkpoint compaction). Worth a one-line caveat.
- **LOW**: Hive Metastore is mentioned ("more Hive Metastore connections") but the answer does not flag that streaming commits to HMS at high frequency can become an HMS bottleneck on-prem.

## Resource fix recommendations
- In `resources/13-postgres-to-iceberg-ingestion.md` (or wherever the CDC section lives): expand the Spark Structured Streaming + Debezium example to show the realistic shape:
  1. Parse Debezium envelope: `from_json(col("value").cast("string"), debezium_schema)`.
  2. Extract op-type and after-image.
  3. Use `forEachBatch` with `MERGE INTO target USING staging ON pk WHEN MATCHED ... WHEN NOT MATCHED ...` for upserts/deletes.
- Add a one-paragraph callout: "Iceberg recommends trigger intervals >= 1 minute; aggressive sub-minute triggers compound the small-files problem and stress Hive Metastore."
- Add a one-line warning that on-prem Kafka deployment (3-broker HA, ZooKeeper or KRaft, monitoring, backup) is itself a ~4 engineer-week project before the CDC pipeline can even start.
- Optionally add a "compaction strategy for streaming Iceberg" section: cold-partition-only rewrites, wait-and-compact (e.g., compact every N micro-batches), and the risk of compaction taking longer than the write interval.

## Topic state
- **Real-time vs batch analytics trade-offs**: prior avg 4.812 across 4 questions; new running avg (4.812 × 4 + 4.6) / 5 = **4.770** across 5 questions. Status: **PASSED** (>= 3.5).
- **Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling**: this answer also exercised CDC pipeline mechanics; co-tag at 4.6 if topic is updated.
