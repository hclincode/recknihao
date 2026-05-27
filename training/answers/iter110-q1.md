# Iter110 Q1 — Answer

**Question**: We're doing the initial data load from Postgres into Iceberg for a table that has about 200 million rows and is actively being written to in production — orders are still coming in while we're copying. My plan was to just do a big SELECT * and write it all out to Iceberg, but I'm realizing that's going to take several hours, and by the time it finishes the data will already be stale. Meanwhile I want Debezium to eventually take over and stream the ongoing changes. How do I handle this handoff cleanly? Like, where does the initial snapshot end and the CDC stream begin — and how do I make sure I don't end up with duplicates or gaps in between?

---

## Answer

The clean handoff between a Spark JDBC bootstrap and Debezium CDC is one of the most error-prone operations in data pipelines — silent data loss is the typical failure mode, not an error you'll see on a dashboard. Here's the production-ready approach.

### The two-phase strategy

**Phase 1: Bootstrap the Iceberg table via Spark JDBC (one-shot)**

Write a Spark job to load the full table into Iceberg. This captures every row up to a specific point-in-time — call it the **snapshot watermark**.

**Phase 2: Start Debezium CDC with `snapshot.mode: no_data`**

Configure Debezium to skip the initial snapshot (don't re-SELECT 200M rows) and instead stream only changes that happened after the snapshot watermark. `snapshot.mode: no_data` does exactly this.

### The critical requirement: close the handoff gap

The gap between the Spark load finishing and Debezium opening its replication slot is where data is silently lost. Any rows committed in Postgres during this gap will never appear in Iceberg: Spark already finished, and Debezium starts streaming from the slot's creation point.

**The exact procedure:**

1. **Spark bootstrap job completes** — 200M rows written to Iceberg
2. **Pause application writes** to the Postgres table (30 seconds maximum)
3. **Create the Debezium replication slot** in Postgres (instantaneous):
   ```sql
   SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
   ```
4. **Resume application writes** — from this moment, all INSERTs/UPDATEs/DELETEs flow to the slot
5. **Start the Debezium connector** immediately

### Debezium connector configuration

```json
{
  "name": "postgres-debezium-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "postgres-primary",
    "slot.name": "debezium_slot",
    "publication.name": "debezium_pub",
    "snapshot.mode": "no_data",
    "table.include.list": "public.orders"
  }
}
```

`snapshot.mode: no_data` tells Debezium: "The target is already populated — skip the SELECT and start streaming changes from the current WAL position."

### Concrete timeline for an 8-hour load

```
10:00 AM   — Spark JDBC SELECT * starts (200M rows, ~8 hours)
6:00 PM    — Spark finishes writing to Iceberg
6:00:30 PM — Application pauses writes to orders table
6:00:35 PM — DBA creates replication slot (instantaneous)
6:00:35 PM — Application resumes writes (new orders flowing)
6:00:45 PM — Debezium connector starts, consuming WAL from slot

Result:
  All orders before 6:00:30 PM → in Iceberg from Spark
  All orders after 6:00:35 PM  → in Iceberg from Debezium
  No rows committed during the 5-second pause → no gap
```

### MERGE INTO consumer (idempotent, handles duplicates)

Use MERGE INTO in your Debezium → Iceberg Spark job so re-processing the same events is safe:

```python
events_delta.createOrReplaceTempView("events_delta")

spark.sql("""
    MERGE INTO iceberg.analytics.orders t
    USING events_delta s
    ON t.order_id = s.order_id
    WHEN MATCHED AND s.op IN ('u', 'd') THEN
        UPDATE SET * = s.*
    WHEN NOT MATCHED AND s.op IN ('c', 'r') THEN
        INSERT *
""")
```

The `ON t.order_id = s.order_id` match ensures a row arriving twice (e.g., during a Debezium restart) updates the existing row rather than creating a duplicate.

### `snapshot.mode` values — don't confuse them

| Mode | Behavior | Use when |
|---|---|---|
| `initial` (default) | SELECT all rows as `op='r'`, then stream CDC | Iceberg target is empty |
| `no_data` | Skip SELECT, start CDC from current WAL position | Iceberg already bootstrapped via Spark |
| `never` | Same as `no_data` | Alias; `no_data` is preferred in Debezium 2.x |
| `recovery` | **NOT valid for Postgres** | MySQL/MariaDB/SQL Server only — causes an error on Postgres |

For your case: `snapshot.mode: no_data`.

### Verify the handoff succeeded

After a few days of CDC streaming, check for gaps:

```sql
-- In Trino — confirms no row was silently dropped between Spark load and CDC start
SELECT
  COUNT(*) AS total_rows,
  MIN(updated_at) AS earliest,
  MAX(updated_at) AS latest
FROM iceberg.analytics.orders;
```

Compare `total_rows` to the Postgres source count. If they match and `latest` is recent (reflecting ongoing CDC), the handoff was clean.
