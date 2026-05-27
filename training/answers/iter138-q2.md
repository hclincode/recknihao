# Iter138 Q2 — Answer

**Question**: "Our DevOps team accidentally deleted the Kafka consumer group that Debezium was using during a routine maintenance window last week. When Debezium restarted, it didn't fail or throw an obvious error — it just started consuming from the very beginning of the Kafka topic (we have a 90-day retention on the topic). This means it replayed about 3 months of CDC events into our Iceberg `events` table, and now we think we have millions of duplicate rows. The Postgres replication slot was fine the whole time, so that part isn't the issue. How do we figure out exactly what got duplicated and how bad the damage is, what's the cleanest way to deduplicate the Iceberg table without taking it fully offline, and is there something we should put in place so that if the consumer group gets deleted again Debezium doesn't silently start over from the beginning?"

---

## What Happened: Why Debezium Replayed Everything

Debezium tracks its Kafka progress via **consumer group offsets** stored in Kafka's internal `__consumer_offsets` topic. When the consumer group was deleted, those offsets were erased. On restart, Debezium had no record of where it left off and defaulted to `auto.offset.reset=earliest` — the beginning of the topic's retention window.

The **Postgres replication slot** survived because it's stored in Postgres itself, not in Kafka. The slot still knows where the WAL was last read. But Debezium checks Kafka offsets first; it doesn't consult the Postgres slot to recover its last-processed position. This is the gap that caused the silent replay.

---

## Step 1: Assess the Damage

First, quantify how many rows are duplicated.

**Find the last clean snapshot (before the replay):**

```sql
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 30;
```

Identify the snapshot committed just before the replay window (e.g., `snapshot_id = 4823511203987654321`, committed at `2026-05-15 10:00:00`).

**Compare row counts:**

```sql
-- Row count at the last clean snapshot
SELECT COUNT(*) AS clean_row_count
FROM iceberg.analytics.events
FOR VERSION AS OF 4823511203987654321;

-- Current (post-replay) row count
SELECT COUNT(*) AS current_row_count
FROM iceberg.analytics.events;
```

The difference is your duplicate count.

**Find duplicate event_ids:**

```sql
SELECT event_id, COUNT(*) AS occurrence_count,
       MIN(ingested_at) AS first_seen,
       MAX(ingested_at) AS last_seen
FROM iceberg.analytics.events
GROUP BY event_id
HAVING COUNT(*) > 1
ORDER BY occurrence_count DESC
LIMIT 100;
```

**Summarize the distribution:**

```sql
SELECT occurrence_count, COUNT(DISTINCT event_id) AS num_duplicated_ids
FROM (
    SELECT event_id, COUNT(*) AS occurrence_count
    FROM iceberg.analytics.events
    GROUP BY event_id
    HAVING COUNT(*) > 1
)
GROUP BY occurrence_count
ORDER BY occurrence_count;
```

This tells you: "3.1M event_ids appear exactly twice, 200K appear three times," etc.

---

## Step 2: Cleanup — Two Strategies

### Strategy A: Snapshot Rollback (Simplest — use if no legitimate writes since replay)

If no legitimate new CDC events landed in the `events` table between when the replay started and now, the fastest fix is to roll back to the last clean snapshot.

```sql
-- Trino 467 preferred syntax
ALTER TABLE iceberg.analytics.events
EXECUTE rollback_to_snapshot(snapshot_id => 4823511203987654321);
```

**What this does:** Moves the table's current snapshot pointer back to the pre-replay state. All the replayed rows become unreferenced. Queries immediately return clean data.

**What this does NOT do:** Delete the duplicate files from MinIO — they're orphaned but still on disk. After rollback, clean up:

```sql
-- Expire snapshots newer than the rollback point
ALTER TABLE iceberg.analytics.events
EXECUTE expire_snapshots(retention_threshold => '1d');

-- Remove the orphaned duplicate files from MinIO
ALTER TABLE iceberg.analytics.events
EXECUTE remove_orphan_files(retention_threshold => '1d');
```

**Limitation:** If any legitimate writes landed after the replay started (e.g., your Spark ETL ran, or Debezium resumed writing real new events), rolling back undoes those writes too. Use Strategy B in that case.

---

### Strategy B: Deduplicate-in-Place with ROW_NUMBER() (Use if legitimate writes occurred)

If legitimate events arrived after the replay started, you cannot safely roll back. Instead, deduplicate by keeping one copy of each `event_id`.

**For Spark (recommended for large tables):**

```python
from pyspark.sql.functions import row_number
from pyspark.sql.window import Window

# Read the full table
events_df = spark.table("iceberg.analytics.events")

# Define window: for each event_id, rank rows by ingested_at (keep most recent)
window = Window.partitionBy("event_id").orderBy(col("ingested_at").desc())

deduped_df = (
    events_df
    .withColumn("rn", row_number().over(window))
    .filter(col("rn") == 1)
    .drop("rn")
)

# Overwrite the table with the deduplicated set
deduped_df.writeTo("iceberg.analytics.events").overwritePartitions()
```

**For targeted partition deduplication (if replay only affected specific date ranges):**

```python
# Only overwrite partitions touched by the replay (e.g., 2026-02-14 to 2026-05-15)
events_df = spark.table("iceberg.analytics.events").filter(
    "event_ts >= '2026-02-14' AND event_ts < '2026-05-16'"
)

window = Window.partitionBy("event_id").orderBy(col("ingested_at").desc())

deduped_df = (
    events_df
    .withColumn("rn", row_number().over(window))
    .filter(col("rn") == 1)
    .drop("rn")
)

deduped_df.writeTo("iceberg.analytics.events").overwritePartitions()
```

**Trino SQL alternative (for smaller tables):**

```sql
-- Create a deduplicated staging table
CREATE TABLE iceberg.analytics.events_deduped AS
SELECT * FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY ingested_at DESC) AS rn
    FROM iceberg.analytics.events
)
WHERE rn = 1;

-- Validate counts match expectations
SELECT COUNT(*) FROM iceberg.analytics.events_deduped;

-- After validation, swap tables:
ALTER TABLE iceberg.analytics.events RENAME TO events_backup;
ALTER TABLE iceberg.analytics.events_deduped RENAME TO events;
-- Drop backup after confirming all is well
```

**Which row to keep:**
- `ORDER BY ingested_at DESC` → keep the most recently ingested version (usually correct for CDC, captures the latest state)
- `ORDER BY ingested_at ASC` → keep the first ingested version (safest if you suspect the replay brought stale data)

---

## Step 3: Prevent Future Silent Replays

### Fix 1: Set `snapshot.mode: never` in Debezium config

This is the most direct prevention. With `snapshot.mode: never`, Debezium will **only stream WAL changes** from the Postgres replication slot on startup — it never re-snapshots the table regardless of what the Kafka consumer group offset says.

```json
{
  "name": "postgres-events-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "pg-primary.internal",
    "database.port": "5432",
    "database.user": "debezium_user",
    "database.dbname": "app",
    "plugin.name": "pgoutput",
    "slot.name": "debezium_slot",
    "topic.prefix": "app-db",
    "snapshot.mode": "never",
    "consumer.group.id": "debezium-postgres-cdc"
  }
}
```

**Important:** `snapshot.mode: never` requires the Postgres replication slot to already exist and to have been positioned correctly. If the slot is dropped or was never created, Debezium will fail to start (an explicit error is much better than a silent replay).

### Fix 2: Protect the Kafka consumer group

Add operational controls so the consumer group is never deleted without explicit approval:

- **Document the Kafka consumer group name** (`debezium-postgres-cdc`) in your runbooks and mark it as protected.
- **Add a Kubernetes PodDisruptionBudget** to prevent accidental Debezium pod deletion during maintenance:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: debezium-pdb
  namespace: data-platform
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: debezium-connect
```

- **Require a checklist** before any Kafka consumer group deletion in production. Add Debezium consumer groups to a protected list in your team's runbooks.

### Fix 3: Add alerting on replay detection

Monitor for the specific failure mode: Debezium consumer group offset suddenly jumps backward (or resets to 0).

```sql
-- Check Iceberg snapshot growth rate (sudden spike = replay)
SELECT
  committed_at,
  operation,
  CAST(summary['added-records'] AS BIGINT) AS records_added
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 20;
```

If you see `records_added` spike to millions in a single micro-batch that should add thousands, that's a replay signal. Wire an alert on this query in your monitoring system.

Also monitor the Postgres replication slot to detect slot abandonment (which would compound the issue):

```sql
-- Run on Postgres primary
SELECT slot_name, active, restart_lsn, confirmed_flush_lsn, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

Alert if the slot becomes inactive (`active = false`) — that means Debezium disconnected and the slot is accumulating WAL but not being consumed.

---

## Why the Postgres Replication Slot Didn't Save You (And How to Use It Next Time)

The Postgres replication slot is the authoritative record of "what Debezium has read from the WAL." If the consumer group had not been deleted, Debezium would have re-synced to the slot position on restart. But because the Kafka consumer group offset was gone, Debezium didn't even reach the slot-check stage — it defaulted to Kafka's `earliest` offset first.

**For future manual recovery** (if you ever need to reset Debezium's position): you can reset the Kafka consumer group offset for the Debezium connector explicitly, pointing it to the message that corresponds to the Postgres WAL position you want. This is an advanced Debezium operational procedure that requires coordinating the Kafka offset with the Postgres slot LSN, and is documented in the Debezium documentation for offset manipulation.

---

## Summary

| Step | Action |
|---|---|
| **Assess damage** | Snapshot history + `GROUP BY event_id HAVING COUNT > 1` |
| **Clean up (no new writes)** | `ALTER TABLE EXECUTE rollback_to_snapshot` → expire → orphan cleanup |
| **Clean up (new writes present)** | Spark `ROW_NUMBER()` dedup + `overwritePartitions()` |
| **Prevent replay** | `snapshot.mode: never` in Debezium config |
| **Protect consumer group** | PodDisruptionBudget + protected-group runbook policy |
| **Add alerting** | Monitor `added-records` spike in `$snapshots` table |
