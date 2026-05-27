# Iter117 Q1 — Answer

**Question**: We use Debezium to stream changes from our Postgres database into Iceberg for analytics. Our events table has gotten so large that we partitioned it in Postgres using declarative partitioning — the parent table is `events` and Postgres automatically routes inserts into monthly child tables like `events_2025_01`, `events_2025_02`, and so on. We set up the Debezium connector pointing at the `events` table, but we're not sure if it's actually capturing changes. When I look at the Kafka topics being produced, I'm seeing some data but I can't tell if it's coming from the parent table or the child partitions — or both. Does Debezium capture from the parent `events` table and automatically pick up child partition inserts, or do we need to configure separate connectors for each child table?

---

## Answer

Debezium handles Postgres declarative partitions transparently through the publication mechanism — you do NOT need separate connectors for each child table. However, the behavior depends on how your publication was created, and there are specific gotchas worth verifying.

### How It Works

When you create a Postgres publication for the **parent table** (`events`), Postgres's logical decoding (`pgoutput`) publishes changes from **all child partitions automatically**. Your application inserts a row into the `events` parent, Postgres routes it to `events_2025_05` (the current month's child), and Debezium sees it in the WAL under the parent table's publication — all transparently. The Kafka topic (`app-db.public.events`) receives all writes regardless of which child partition they landed in.

You do NOT need to list `events_2025_01`, `events_2025_02`, etc. in your connector config. One publication entry for `public.events` is correct.

### Verify Your Publication Is Correct

```sql
-- On Postgres: check what tables are in your publication
SELECT pubname, tablename, schemaname
FROM pg_publication_tables
WHERE pubname = 'debezium_pub';
```

Expected result: **one row** with `tablename = 'events'`. If you see individual child tables listed instead of the parent, the publication was created against children — you'll need to recreate it:

```sql
-- Drop and recreate against the parent table only
DROP PUBLICATION debezium_pub;
CREATE PUBLICATION debezium_pub FOR TABLE events;
-- No need to list events_2025_01, events_2025_02, etc.
```

If you're using `pg_partman` to manage partition creation, also ensure new child partitions are included:

```sql
-- pg_partman creates new child partitions; check they're covered
SELECT * FROM pg_publication_tables WHERE pubname = 'debezium_pub';
-- Should still show only 'events' (the parent) — pg_partman children inherit automatically
```

### Verify the Replication Slot Is Active

```sql
-- On Postgres PRIMARY
SELECT slot_name, active, restart_lsn,
  pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS lag_bytes
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

- `active = true` when Debezium is connected and consuming
- `lag_bytes` should be small and decreasing toward zero during catch-up
- If `active = false` while you expect the connector to be running, check `kubectl describe kafkaconnector` for error messages

### Verify the Kafka Topic Data

Debezium always reports `source.table = 'events'` (the parent), even for inserts that physically land in `events_2025_05`. This is correct behavior. To verify the envelope:

```python
# Quick diagnostic: inspect source.table in Debezium events
df = spark.read.format("kafka") \
    .option("kafka.bootstrap.servers", "kafka:9092") \
    .option("subscribe", "app-db.public.events") \
    .option("startingOffsets", "latest") \
    .load()

from pyspark.sql.functions import from_json, col
schema = """
  after MAP<STRING, STRING>,
  op STRING,
  source STRUCT<table: STRING, lsn: BIGINT>
"""
parsed = df.select(from_json(col("value").cast("string"), schema).alias("d"))
parsed.select("d.source.table", "d.op").groupBy("d.source.table", "d.op").count().show()
```

You should see only `source.table = 'events'` (the parent). If you see child table names like `events_2025_05`, the publication was misconfigured — it was created against the children directly.

### Common Setup Problems

**Problem 1: `wal_level` not set to `logical`**

```sql
-- On Postgres
SHOW wal_level;
-- Must return 'logical'. If it returns 'replica' or 'minimal', 
-- set wal_level = logical in postgresql.conf and restart Postgres.
```

**Problem 2: Debezium user missing REPLICATION attribute**

```sql
-- Verify the Debezium user has REPLICATION
SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'debezium_user';
-- rolreplication must be true (t)
```

**Problem 3: Connector is using `snapshot.mode: always` (re-snapshots on restart)**

With declarative partitioned tables, `snapshot.mode: always` is expensive — it tries to snapshot every child partition. For steady-state CDC, use `no_data`:

```yaml
config:
  snapshot.mode: "no_data"
  table.include.list: "public.events"  # parent only
```

**Problem 4: `table.include.list` contains child partition names**

```yaml
# WRONG — causes Debezium to start separate Kafka topics for each child
table.include.list: "public.events_2025_01,public.events_2025_02,..."

# CORRECT — Debezium captures all children via the parent
table.include.list: "public.events"
```

### One-Time Iceberg Sink Configuration

Your Spark streaming consumer reading from `app-db.public.events` does not need any changes. It receives all events (from any child partition) under the same Kafka topic. The Iceberg MERGE handles everything:

```python
spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_cdc s ON t.event_id = s.event_id
    WHEN MATCHED AND s.op = 'd' THEN DELETE
    WHEN MATCHED AND s.op IN ('u', 'c', 'r') THEN UPDATE SET *
    WHEN NOT MATCHED AND s.op IN ('c', 'r', 'u') THEN INSERT *
""")
```

**Summary:** You set up the connector correctly by pointing at the parent table only. Postgres logical decoding handles child partition routing transparently. If you're seeing partial data, the most likely cause is a publication created against child tables rather than the parent — recreating against the parent (`events`) will fix it.
