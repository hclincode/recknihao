# Iter112 Q2 — Answer

**Question**: We use Debezium to stream changes from Postgres into Iceberg. It's been running fine for a few months, but we recently started seeing duplicate rows appearing in our Iceberg tables — the same event showing up two or three times with identical timestamps. It seems to happen after our Debezium connector restarts, like after a deploy or a pod crash in Kubernetes. The rows aren't exactly the same — sometimes the `updated_at` field differs by a millisecond — so a simple `DISTINCT` doesn't clean them up easily. Is this a known problem with CDC pipelines, and what's the right way to handle it so our analytics queries don't double-count things?

---

## Answer

Yes, this is a known and well-understood failure mode in CDC pipelines with Debezium. The core problem is **at-least-once delivery combined with connector restarts triggering re-snapshotting**, and the fix is an **idempotent MERGE INTO** in your Spark consumer — not post-processing deduplication.

### Root Cause: Re-snapshots After Connector Restarts

When your Debezium connector restarts (pod crash, deploy, etc.), it may re-emit the **initial snapshot** of all rows. Each row comes through as an `op='r'` event (read/snapshot). If your downstream Spark consumer's MERGE INTO logic doesn't handle snapshot events correctly, the same `event_id` lands twice — first as `op='r'`, then later as `op='c'` or `op='u'` from the live WAL stream.

The millisecond timestamp differences appear because:
1. **Snapshot rows carry no LSN-based CDC metadata** — they arrive from a point-in-time Postgres read, slightly different from the WAL stream.
2. **Debezium captures `source.lsn` (log sequence number), not the application timestamp.** If your deduplication logic compares `updated_at`, those tiny differences slip through.

### Why Simple `DISTINCT` Doesn't Work

`DISTINCT` fails because the rows have slightly different field values. This is actually a symptom of using the wrong deduplication key — you should deduplicate by **primary key + operation**, not by timestamp. The right fix is in the consumer, not in cleanup queries.

### Fix 1: Idempotent MERGE INTO (mandatory)

The correct pattern is micro-batch deduplication *before* the MERGE, then a three-branch MERGE keyed on primary key:

```python
from pyspark.sql.functions import col, row_number
from pyspark.sql.window import Window

# CRITICAL: Deduplicate within each micro-batch by primary key.
# A restart can replay the same event_id multiple times in one batch.
# Keep only the latest event per key, ordered by LSN descending.
window_spec = Window.partitionBy("event_id").orderBy(col("source_lsn").desc_nulls_last())
events_dedup = (
    events_delta
    .withColumn("_rn", row_number().over(window_spec))
    .filter(col("_rn") == 1)
    .drop("_rn")
)

events_dedup.createOrReplaceTempView("events_delta")

spark.sql("""
    MERGE INTO iceberg.analytics.events AS t
    USING events_delta AS s
    ON t.event_id = s.event_id

    -- Branch 1: DELETE — op='d' has null after-image; never update
    WHEN MATCHED AND s.op = 'd' THEN DELETE

    -- Branch 2: UPDATE — covers live changes AND re-snapshot rows
    -- WHEN MATCHED AND op='r' rewrites the same values: idempotent
    WHEN MATCHED AND s.op IN ('u', 'c', 'r') THEN UPDATE SET *

    -- Branch 3: INSERT — new rows from snapshot or live inserts
    WHEN NOT MATCHED AND s.op IN ('c', 'r', 'u') THEN INSERT *
""")
```

**Why three branches matter:**
- `op='d'` events have a **null after-image** (`after` field is null in the Debezium envelope). If you collapse DELETE into an UPDATE branch, Spark writes null values to every column. Always separate DELETE into its own branch.
- `op='r'` (snapshot read) must be handled in both MATCHED (idempotent overwrite) and NOT MATCHED (initial insert). A re-snapshot of a row that already exists in Iceberg should update, not insert a duplicate.
- Omitting `'u'` from the NOT MATCHED branch causes missed inserts when a row arrives out of order (e.g., the CDC INSERT offset was lost and only the UPDATE was re-replayed).

### Fix 2: Set `snapshot.mode: no_data` to Prevent Re-snapshots

If you're past the initial bootstrap, configure Debezium to skip re-snapshotting on restart:

```yaml
# Strimzi KafkaConnector CRD
spec:
  config:
    snapshot.mode: "no_data"   # skip table snapshot on restart; read WAL from last offset
    plugin.name: "pgoutput"
    publication.autocreate.mode: "filtered"
    # ... rest of your config
```

`no_data` tells Debezium: "assume the table is already bootstrapped; on restart, resume from the saved Kafka offset without re-reading the table." This eliminates the re-snapshot as a source of duplicates entirely.

**Do NOT use** `snapshot.mode: always` — that re-snapshots the entire table on every pod restart, guaranteeing duplicates.
**Do NOT use** `snapshot.mode: never` — officially deprecated in Debezium 2.x; use `no_data` instead.

### Fix 3: Monitor the Kafka Offset Topic

Duplicates can also appear if the connector's Kafka offset topic (`__consumer_offsets` or the Connect internal `connect-offsets`) is lost or corrupted. Verify the offset is being persisted:

```bash
# Check the connector's stored offset in Kafka Connect's internal topic
kafka-console-consumer.sh \
  --bootstrap-server kafka:9092 \
  --topic connect-offsets \
  --from-beginning \
  --property print.key=true | grep debezium-connector-name
```

If the offset topic is empty or missing for your connector, Debezium will re-snapshot from scratch on next start. Fix: ensure `connect-offsets` has `replication.factor >= 2` and `cleanup.policy=compact` so offsets are never deleted.

### Fix 4: Preserve the Postgres Replication Slot

Confirm the replication slot is active and not lagging:

```sql
-- On the Postgres primary
SELECT
  slot_name,
  active,
  pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes,
  confirmed_flush_lsn
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

If `active = false`, the slot is orphaned — Debezium restarted but didn't reconnect. The slot has been retaining WAL since the last confirmed LSN, which is good for recovery but can fill disk. Set `max_slot_wal_keep_size` in `postgresql.conf` to cap WAL retention:

```sql
-- postgresql.conf (or ALTER SYSTEM)
max_slot_wal_keep_size = '10GB'
```

### Cleaning Up Existing Duplicates

For the duplicates already in your Iceberg table, use a backfill MERGE from the Postgres primary:

```sql
-- Step 1: Pull authoritative current state from Postgres (via Trino JDBC catalog)
CREATE TABLE iceberg.analytics.events_backfill AS
SELECT * FROM postgres.public.events
WHERE event_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-24';

-- Step 2: MERGE to deduplicate — the primary-key match will overwrite duplicates
MERGE INTO iceberg.analytics.events AS t
USING iceberg.analytics.events_backfill AS s
ON t.event_id = s.event_id
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *;

-- Step 3: Drop the backfill table
DROP TABLE iceberg.analytics.events_backfill;
```

### Summary of Fixes

| Fix | What it prevents |
|---|---|
| Three-branch MERGE INTO + micro-batch `row_number()` | Duplicate rows from replayed offsets |
| `snapshot.mode: no_data` | Full table re-snapshot on every restart |
| Monitor Kafka offset topic (`connect-offsets`) | Offset loss forcing re-snapshot |
| Monitor Postgres replication slot lag | Orphaned slot, WAL disk pressure |
| `max_slot_wal_keep_size` in postgresql.conf | Disk fill from unbounded WAL retention |

The MERGE INTO fix (Fix 1) is the load-bearing change — it makes your consumer idempotent regardless of how many times Debezium replays events. The other fixes prevent restarts from triggering unnecessary re-snapshots in the first place.
