# Iter138 Q2 — Judge Score

## Score Summary
- **Technical accuracy**: 2/5
- **Clarity**: 4/5
- **Practical utility**: 4/5
- **Completeness**: 4/5
- **Overall**: **3.50/5**

## Verdict
**FAIL** (below 4.0 pass threshold)

The answer is well-organized, beginner-friendly, and gives mostly correct Iceberg operational guidance. However, the **root-cause explanation is factually wrong** in a way that propagates into the prevention recommendation. The whole "what happened" framing is built on a misunderstanding of how Debezium (a Kafka Connect source connector) stores its offsets. Because the user explicitly asked "how do we prevent this from happening again," getting the mechanism wrong is high-impact.

---

## What Was Verified Correct

1. **Postgres replication slot survives Debezium restart** — correct. Slots are stored in Postgres and persist across Debezium outages until the slot itself is dropped.
   - Source: [Debezium PostgreSQL connector docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)

2. **`snapshot.mode: never` is a valid option for the PostgreSQL connector** — correct. Valid values are `always`, `initial`, `initial_only`, `never`, `when_needed`, and `custom`.
   - Source: [Debezium Snapshot Modes (Conduktor)](https://kafka-options-explorer.conduktor.io/debezium/snapshot-modes/)

3. **`snapshot.mode: never` behavior** — substantially correct. With `never`, the connector resumes from a stored offset if one exists, otherwise streams from the point where the replication slot was created. The answer's claim that it "only streams WAL changes from the Postgres replication slot on startup" is directionally right but oversimplified.

4. **Trino `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id => <id>)` syntax** — correct. This is the newer, preferred Trino syntax; the older `CALL iceberg.system.rollback_to_snapshot` is deprecated.
   - Source: [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html), [PR #24580 deprecation](https://github.com/trinodb/trino/pull/24580)

5. **`ALTER TABLE ... EXECUTE expire_snapshots` and `remove_orphan_files`** — correct Trino syntax.

6. **`ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY ingested_at DESC)` deduplication** — correct and idiomatic for CDC deduplication.

7. **PySpark `deduped_df.writeTo("iceberg...").overwritePartitions()` syntax** — correct DataFrameWriterV2 syntax for Iceberg, available in Spark 3.0+.
   - Source: [Apache Iceberg Writes docs](https://iceberg.apache.org/docs/latest/spark-writes/)

8. **`events$snapshots` metadata table queries** — correct Trino/Iceberg syntax.

9. **PodDisruptionBudget YAML structure** — syntactically valid.

---

## Errors and Gaps

### HIGH — Wrong mechanism: Debezium does NOT use `__consumer_offsets` (lines 9, 260)

The answer's central explanation is:
> "Debezium tracks its Kafka progress via consumer group offsets stored in Kafka's internal `__consumer_offsets` topic. When the consumer group was deleted, those offsets were erased."

This is **factually incorrect for Debezium source connectors**.

- Debezium runs as a **Kafka Connect source connector**. Source connectors store their offsets in a dedicated Kafka topic configured via `offset.storage.topic` (typically `connect-offsets`), NOT in `__consumer_offsets` and NOT via Kafka consumer groups at all.
- The `__consumer_offsets` topic and consumer-group mechanism are used by **sink connectors** and by regular Kafka consumers — not by Debezium source connectors.
- Debezium offsets (the LSN for Postgres) and Kafka consumer-group offsets are independent concepts.
- Sources: [Debezium offset storage docs](https://debezium.io/documentation/reference/stable/configuration/storage.html), [MSK Connect offset.storage.topic docs](https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect-manage-connector-offsets.html)

**Implication**: The premise "DevOps deleted a Kafka consumer group and Debezium replayed everything" is, on a strict reading of how Debezium works, mechanistically suspect. A more plausible real scenario is one of:
  - DevOps deleted the **`connect-offsets` topic** (or the entry for this connector), not a consumer group.
  - DevOps deleted the **replication slot** and Debezium re-snapshotted (but the user said the slot was fine).
  - Someone reset the connector via the Kafka Connect REST API.
  - The downstream consumer (e.g., Spark Structured Streaming reading from the Kafka topic) had its consumer group deleted — in which case the replay is in the Spark consumer, not in Debezium.

The most likely real reading of the user's report — given they said the replication slot is fine — is that the **downstream Spark Structured Streaming consumer's group was deleted**, and Spark replayed from `earliest`. The answer should have surfaced this ambiguity, distinguished the two layers, and reframed the fix accordingly. Instead it took the user's framing at face value with an incorrect mechanism.

### HIGH — Prevention advice misses the real lever

Because the answer misidentifies the source of the replay, the prevention section also misses the most important fix:
- For the **downstream Spark consumer** scenario: set `startingOffsets="latest"` on the Spark Kafka source and protect the consumer-group name; or use a non-default `auto.offset.reset=none` to fail loudly when offsets are missing instead of silently resetting.
- For the **Kafka Connect connector** scenario: protect the `connect-offsets` topic and the connector's offset entries; use Kafka Connect's offset management REST API rather than ad-hoc topic deletion.
- `snapshot.mode: never` is a reasonable defense for one specific scenario (slot exists but offsets lost in connect-offsets) but it is NOT the right fix for the most likely real cause.

### MEDIUM — `consumer.group.id` is not a Debezium PostgreSQL connector config (line 199)

The example config includes `"consumer.group.id": "debezium-postgres-cdc"`. This is not a recognized configuration property of the Debezium PostgreSQL source connector. It would be silently ignored or cause a warning. The answer suggests this is a meaningful protection, but it isn't.

### MEDIUM — "Debezium defaults to `auto.offset.reset=earliest`" is misleading

`auto.offset.reset` is a Kafka **consumer** configuration. It does not apply to a Debezium source connector's offset recovery. The actual recovery behavior depends on the `snapshot.mode` setting and whether the `connect-offsets` topic has an entry for the connector. If no offset entry exists, the connector behaves per `snapshot.mode`: with `initial` (default), it performs a fresh snapshot of the database (a Postgres SELECT, not a Kafka topic replay).

### LOW — Strategy A (rollback) doesn't address the streaming source

If the user rolls back the Iceberg table to the pre-replay snapshot, the Spark streaming job will continue reading from its current Kafka offset position. The next batch will be fine, but the user still needs to address WHY the replay happened or it will recur on the next restart. The answer touches on prevention but doesn't sequence "stop the streaming job → fix the source → roll back → restart with corrected offsets."

### LOW — Spark dedup partition-overwrite caveat not stated

`overwritePartitions()` requires the DataFrame's data to cover entire partitions; partial-partition overwrites are not safe. For a date-partitioned table being de-duplicated across a multi-month window, this works, but the answer should note that the DataFrame must contain ALL rows for ALL affected partitions, not a subset.

### LOW — Missing mention of equality deletes / MERGE INTO for in-place dedup

An alternative to the rewrite-everything approach is `MERGE INTO ... WHEN MATCHED THEN DELETE` keyed on the rows that should be removed. Not strictly required, but it's the more surgical pattern for "remove specific duplicate rows" workflows.

---

## Resource Fix Recommendations

1. **`resources/14-real-time-vs-batch.md`** — add a section explicitly distinguishing:
   - Debezium connector offsets (stored in `connect-offsets`, a compacted Kafka topic) vs. Postgres replication slot LSN vs. downstream consumer-group offsets (in `__consumer_offsets`).
   - What happens on each layer if its state is lost.
   - The correct way to reset / preserve Debezium connector offsets via the Kafka Connect REST API, not via direct topic manipulation.

2. **Add to `resources/14-real-time-vs-batch.md` or a new `resources/18-debezium-operations.md`** — operational runbook for CDC pipelines:
   - What to do when Debezium silently re-snapshots
   - What to do when the downstream streaming consumer replays
   - `snapshot.mode` decision matrix
   - How to safely reset offsets without losing data

3. **`resources/17-iceberg-table-maintenance.md`** — already covers `rollback_to_snapshot` and dedup. Confirm the dedup section calls out `overwritePartitions()` partition-completeness requirement and offers `MERGE INTO ... DELETE` as the surgical alternative.

4. **Beginner clarity caveat**: any resource that mentions "Kafka consumer group" in the context of Debezium should disambiguate source-vs-sink connector behavior. This is a notorious confusion.

---

## Dimension Reasoning

- **Technical accuracy 2/5**: The root-cause mechanism is wrong. `__consumer_offsets` is the wrong topic, `auto.offset.reset` is the wrong concept for a source connector, and `consumer.group.id` is not a valid Debezium config. The Iceberg/Spark/Trino syntax is mostly correct, which prevents a 1.
- **Clarity 4/5**: Well-structured, jargon explained, code is readable, decision tables are useful.
- **Practical utility 4/5**: The dedup and rollback procedures are directly executable and correct. The prevention section gives the engineer specific things to do, even if it's defending against the wrong attack vector.
- **Completeness 4/5**: All three sub-questions answered (assess, dedup, prevent), summary table, monitoring queries. Missing: alternative real causes, MERGE INTO dedup option, sequencing of stop-stream / roll-back / restart.
