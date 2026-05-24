# Score: iter52-q1

**Topic**: Postgres-to-Iceberg ingestion: CDC schema evolution
**Score**: 4.25 / 5.0

## Dimension scores
- Technical accuracy: 4
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 4

## What the answer got right
- Correctly identifies that Debezium does NOT silently fail when a new column is added — it continues to emit events.
- Correctly states that Iceberg `ALTER TABLE ... ADD COLUMN` is a metadata-only operation that completes in milliseconds, with old rows returning NULL.
- Correct order of operations: add column in Iceberg first, then resume the consumer.
- Correctly notes that the Debezium connector itself does NOT need to be stopped — only the consumer writing to Iceberg.
- Correctly explains that Iceberg tracks columns by field ID (not position), enabling safe renames/reorders.
- Runnable Spark SQL `ALTER TABLE iceberg.analytics.events ADD COLUMN device_os VARCHAR` matches the expected fix.
- Mentions `schema.evolution=basic` as a Debezium 2.x configuration option for automating schema propagation.
- Anchored to the production stack (Spark/Flink consumer writing to Iceberg, Confluent/Apicurio as schema registry options).

## Gaps or errors
- **Technical imprecision on DDL detection mechanism**: The answer states "Debezium ... detects the DDL via a schema registry — either Confluent Schema Registry or Apicurio." This conflates two different mechanisms. Postgres does NOT emit DDL events through logical replication; instead, the WAL sends **relation messages** that describe table structure when row activity follows a schema change. The schema registry (Confluent/Apicurio) is for *serializing* Kafka message payloads (Avro/Protobuf), not for detecting DDL. An engineer reading this answer will form an incorrect mental model of how schema change detection actually works.
- **`schema.evolution=basic` attribution is imprecise**: This setting is a config option for the Debezium **Iceberg sink connector** (and similar sink connectors like JDBC sink), not the Postgres source connector. The answer presents it as a connector-level setting without distinguishing source vs sink — engineers searching for the option on the Postgres source connector docs won't find it.
- **Timing of new-column appearance not clearly explained**: The answer says "rows that existed before the ALTER TABLE have the new field missing" — this is technically accurate but understates the nuance: Debezium starts including the new field in *events* only after it sees a relation message (i.e., when a row in that table is changed post-ALTER). Pre-ALTER rows are NOT re-emitted automatically. An engineer expecting backfill of old rows with `device_os = NULL` in Kafka will be confused.
- **Consumer failure mode glossed over**: The answer says the consumer "will fail or silently drop the new field" but does not give concrete signals for which behavior to expect (depends on consumer code: schema-strict consumers fail loudly; permissive consumers drop fields silently). The engineer cannot tell from the answer which case they should expect to debug.
- **Missing beginner glosses**: WAL, logical replication slot, schema registry, schema evolution — all dropped without inline plain-English definitions.

## Verdict
A solid, actionable answer that delivers the correct fix and the right operational sequence — the engineer can act on it — but contains a technical misattribution (schema registry as DDL-detection mechanism) and an imprecise configuration claim (`schema.evolution=basic` is a sink-side, not source-side, setting) that will mislead an engineer who tries to apply them verbatim.
