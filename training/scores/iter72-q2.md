# Iter72 Q2 Score

## Scores
| Dimension | Score |
|---|---|
| Completeness | 5 |
| Accuracy | 3.5 |
| Clarity | 5 |
| No hallucination | 4 |
| **Final** | **4.375** |

## Points covered
1. **Full nightly reload as simple alternative** — Covered well. Leads with "the simpler answer might just be a nightly full reload." Concrete Spark JDBC example (`fetchsize=10000`, `createOrReplace`), explicit "zero changes to Postgres, zero new infrastructure" framing, and a sizing rule (~10M rows). Names the three triggers for moving to CDC (table size, latency requirement, hard-delete capture).
2. **What Postgres WAL / logical replication is** — Covered. Plain-language explanation: WAL is "internal transaction journal" recording every INSERT/UPDATE/DELETE before applying to the table; logical replication is the feature exposing it as structured change events; Debezium reads the stream "without needing any `updated_at` column."
3. **Debezium setup** — Covered. Shows (a) `CREATE ROLE ... WITH REPLICATION LOGIN`, (b) `GRANT SELECT`, (c) `CREATE PUBLICATION user_prefs_pub FOR TABLE public.user_preferences`, (d) connector JSON with `plugin.name=pgoutput`, `publication.name`, `slot.name`, `topic.prefix`, and `tables.include.list`. All config keys verified against current Debezium documentation.
4. **Spark Structured Streaming + MERGE INTO Iceberg** — Covered. Full code: Kafka source with `subscribe="postgres.public.user_preferences"`, `from_json` parsing, `foreachBatch` MERGE INTO with WHEN MATCHED AND op='u' UPDATE / op='d' DELETE / NOT MATCHED INSERT. Checkpoint to MinIO for resumability. Production-stack-fit (Hive catalog, s3a://, no cloud services).
5. **Honest complexity comparison** — Covered. Side-by-side table on infrastructure, Postgres changes, Spark job type, freshness, deletes, ops overhead. Recommendation is explicit and correct: "Start with the nightly full reload" with three named conditions to revisit CDC. Matches the production-stack reality (Kafka and Debezium would be new on-prem services to operate).

## Issues found

1. **Incorrect `op` field value for INSERT (Accuracy bug, ‑1.5 Accuracy)** — The answer states `op` values are `i` (insert), `u` (update), `d` (delete). For the Debezium **PostgreSQL** connector, INSERT is emitted as `c` (create), not `i`. Confirmed via Debezium docs (debezium.io/documentation/reference/stable/connectors/postgresql.html) and multiple secondary sources (Confluent Platform docs, NamiLink/Medium "Operation Codes explained"). The Debezium event-records reference enumerates: `c` create/insert, `u` update, `d` delete, `r` read (snapshot), `t` truncate, `m` message. The value `i` is used by some non-PG connectors (e.g., Cassandra) but **not** by PostgresConnector. This propagates into the MERGE statement:
   ```sql
   WHEN NOT MATCHED AND s.op IN ('i', 'u') THEN INSERT ...
   ```
   In production this branch would silently never fire for actual INSERTs from Postgres (the events arrive with `op='c'`), causing missed rows and a hard-to-diagnose drift between source and target. This is a real correctness bug an engineer copy-pasting the example would ship. Source: https://debezium.io/documentation/reference/stable/transformations/event-changes.html

2. **Stray/awkward cross-reference to a "Trino resource" config (Hallucination/scope, ‑1 No-hallucination)** — The answer inserts:
   > "Important Debezium config for your Iceberg sink: Trino resource `resources/13-postgres-to-iceberg-ingestion.md` notes the correct config property for schema evolution in the Iceberg sink is `debezium.sink.iceberg.allow-field-addition=true` (not `schema.evolution=basic`, which is the JDBC sink connector property)."
   This is out of scope for the question (engineer is using a Spark Structured Streaming consumer of Kafka, not the Debezium Iceberg sink connector), it leaks an internal-resource reference into the answer (a SaaS engineer reading the response does not have `resources/13-...`), and the framing "Trino resource" is incorrect — the property is for the Debezium Iceberg sink connector, not Trino. Whether the property name is current/spelled correctly was not verifiable without further search and is not load-bearing for the engineer's question.

3. **Snapshot vs. streaming-only behavior not explained (minor, sub-threshold)** — Debezium does an initial snapshot of the table on first connection (by default `snapshot.mode=initial`), emitting all existing rows as `op='r'` (read). The answer's MERGE statement does not handle `op='r'`, so the initial backfill would be skipped by the streaming consumer. Not enough on its own to dock further, but compounds with issue #1 above.

4. **`tables.include.list` is the modern key but `topic.prefix` example chain not fully demoed (very minor)** — Answer correctly uses `topic.prefix=postgres` and references the resulting Kafka topic `postgres.public.user_preferences`, which matches Debezium's naming convention (`<topic.prefix>.<schema>.<table>`). Correct, just worth flagging the dependency is implicit.

## Accuracy verification (WebSearch)
- `CREATE PUBLICATION ... FOR TABLE` is correct DDL for pgoutput-based logical replication setup; verified against postgresql.org/docs/current/sql-createpublication.html and Debezium PG connector docs.
- Debezium PG connector config keys `plugin.name=pgoutput`, `publication.name`, `slot.name`, `topic.prefix` are all current and correct; defaults are `publication.name=dbz_publication`, `slot.name=debezium`. Verified against Debezium stable docs and Confluent Platform reference.
- Debezium PostgreSQL `op` field value for INSERT is **`c`** (not `i`). Verified via Debezium event-records reference and multiple secondary sources. **The answer's claim that insert is `i` is wrong for the PG connector.**

## Resource fix needed?

**Yes — small but important.** Update `resources/13-postgres-to-iceberg-ingestion.md` (or wherever the Debezium PostgreSQL CDC section lives) to:

1. **Correct the `op` field values for the PostgreSQL connector**: `c` = create/insert, `u` = update, `d` = delete, `r` = read (snapshot), `t` = truncate. Explicitly call out that some other Debezium connectors (e.g., Cassandra) use `i` for insert, but PostgresConnector uses `c`. Any worked MERGE INTO example for Debezium-from-Postgres must use `op IN ('c', 'u')` for the upsert branch (or include `'r'` if the streaming job is expected to absorb the initial snapshot).
2. **Add a one-line note on `snapshot.mode=initial`** and that snapshot events arrive with `op='r'`, so the consumer's merge logic must either handle `'r'` as an upsert or rely on a separate batch backfill before turning on streaming.
3. **Remove or rephrase** the "Trino resource" / `debezium.sink.iceberg.allow-field-addition` aside — it confuses the Debezium Iceberg sink connector with the Trino Iceberg connector and isn't relevant to a Spark-consumer architecture. If kept anywhere, it belongs in a separate "Debezium Iceberg sink connector (alternative to Spark consumer)" subsection with a clear label that the property is for the sink connector, not Trino.
