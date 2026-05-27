# Iter79 Q1 — Answer

**Question**: How does Debezium CDC work mechanically? What does the data look like when it comes out? How do you apply inserts, updates, and deletes to Iceberg?

---

## Answer

CDC with Debezium is a great fit for large Postgres tables where full scans are too slow. Here's how it works end to end.

### How Debezium watches for changes

Debezium doesn't poll your Postgres tables. It **reads the Postgres write-ahead log (WAL)** — the internal ledger Postgres uses to track every committed operation. Think of the WAL as an immutable audit trail: every `INSERT`, `UPDATE`, and `DELETE` gets written there before it hits the actual data files.

Debezium connects as a Postgres replication client, tails the WAL, and emits each change as a message to **Kafka** (the message queue on your Kubernetes cluster). A separate **Spark Structured Streaming job** reads those Kafka messages in micro-batches and applies them to Iceberg.

### What the data looks like

Every Debezium change event includes all your table columns plus a special **`op` field** that identifies the type of change. For the Postgres connector, the `op` values are:

| op | Meaning |
|---|---|
| `'c'` | create (INSERT) — **not** `'i'`; this trips up a lot of people |
| `'u'` | update (UPDATE) |
| `'d'` | delete (DELETE) |
| `'r'` | read (initial snapshot — rows existing before Debezium connected) |
| `'t'` | truncate (TRUNCATE TABLE) |

So for an `events` table with columns `event_id`, `user_id`, `event_name`, Kafka messages look like:

```
{event_id: 123, user_id: 456, event_name: "login",    op: 'c'}  -- INSERT
{event_id: 123, user_id: 456, event_name: "login_v2", op: 'u'}  -- UPDATE
{event_id: 123, user_id: 456, event_name: null,       op: 'd'}  -- DELETE
```

### How to apply them to Iceberg: the MERGE INTO pattern

Your Spark Structured Streaming job reads these Kafka messages and applies them using a **MERGE INTO** statement — the standard pattern for handling all three operation types in one SQL expression:

```python
spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_delta s
    ON t.event_id = s.event_id
    WHEN MATCHED AND s.op = 'd' THEN DELETE
    WHEN MATCHED AND s.op = 'u' THEN UPDATE SET *
    WHEN NOT MATCHED AND s.op IN ('c', 'r') THEN INSERT *
""")
```

Breaking this down:

- **Inserts** (`op = 'c'`): `WHEN NOT MATCHED ... INSERT *` — if the primary key doesn't exist in Iceberg, insert the whole row. `'r'` events (initial snapshot reads) are handled the same way — they're existing Postgres rows that look like new inserts to Iceberg.
- **Updates** (`op = 'u'`): `WHEN MATCHED AND s.op = 'u' THEN UPDATE SET *` — find the row by primary key and overwrite it with the new values.
- **Deletes** (`op = 'd'`): `WHEN MATCHED AND s.op = 'd' THEN DELETE` — find the row by primary key and delete it. In Iceberg, this creates a small delete marker file rather than rewriting the full Parquet file.

### Why this solves your scan problem

With CDC, you never do a full table scan again. Only the stream of changes (a tiny fraction of total data volume) flows through. A table with 100M rows but 1,000 daily changes sends 1,000 events per day, not 100M rows.

You also get faster freshness: sub-minute latency (typically 10–30 seconds from Postgres commit to Iceberg write) compared to nightly or hourly batch jobs.

### The tradeoff: complexity

CDC adds ~3× more moving parts than a nightly batch job: Debezium (connector process), Kafka (message queue), and the Structured Streaming job (needs exactly-once semantics to avoid duplicates). On your on-prem Kubernetes stack, you operate all of it.

**Start with incremental append using watermarks first** — it covers most cases with far less operational overhead. Move to CDC only when you genuinely need sub-5-minute freshness, need to propagate hard deletes accurately, or your tables are so large that even watermark-based incremental reads are too slow.
