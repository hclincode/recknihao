# Iter113 Q1 — Answer

**Question**: We are using Debezium to stream changes from our Postgres `accounts` table into Iceberg, and it has been running fine for a few weeks. But last night our Kafka consumer fell behind by about 3 hours due to a network blip, and when it caught up, we ended up with duplicate rows in the Iceberg table for roughly 12,000 account records. My understanding is Debezium is supposed to give us "at least once" delivery, so I expected duplicates to be possible in theory — but I have no idea how to actually clean them up or prevent them from mattering in query results. Do we need to run some kind of deduplication query after every batch lands, and if so, what does that actually look like against an Iceberg table? Is there a standard pattern for this, like using MERGE, or should we be doing something differently at the ingestion layer?

---

## Answer

Your situation is exactly what the Debezium documentation expects — "at least once" delivery means duplicates are not just possible, they're **guaranteed to happen** on any restart or network blip. The good news: Iceberg and Spark are specifically built to handle this, and there's a standard pattern.

### Why You Got Duplicates

When your Kafka consumer fell behind for 3 hours, Debezium was still writing CDC events to Kafka (the replication slot on Postgres was holding them). When the network recovered and your consumer caught up, it re-delivered all those buffered events. **This is not a bug — it's the documented behavior of at-least-once delivery.** Debezium's offset position (tracked in Kafka's `_debezium_connect_offsets` topic) only advances when the offset is explicitly flushed, which by default happens every 60 seconds (`offset.flush.interval.ms=60000`). If your Kafka consumer restarted or was unreachable during the catch-up, those events were re-delivered.

### Detect the Extent of Duplicates

Before cleaning up, verify how many accounts have duplicates:

```sql
-- In Trino: count total vs distinct
SELECT
  COUNT(*) AS total_rows,
  COUNT(DISTINCT account_id) AS distinct_accounts
FROM iceberg.analytics.accounts;
-- If total_rows > distinct_accounts, duplicates exist.

-- Find which accounts are duplicated
SELECT account_id, COUNT(*) AS cnt
FROM iceberg.analytics.accounts
GROUP BY account_id
HAVING COUNT(*) > 1
ORDER BY cnt DESC
LIMIT 20;
```

### Cleanup: Two Options Depending on Snapshot State

#### Option A: Rollback (fastest — if expired_snapshots hasn't run yet)

Find the last clean snapshot and roll back — this is metadata-only and instant:

```sql
-- Find the snapshot ID from just before the bad ingestion run
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics.accounts.snapshots
ORDER BY committed_at DESC
LIMIT 10;
```

```python
# Roll back to the last clean snapshot (metadata-only, no data movement)
spark.sql("""
    CALL iceberg.system.rollback_to_snapshot(
        table => 'analytics.accounts',
        snapshot_id => 4823511203987654321   -- use the pre-duplicate snapshot ID
    )
""")
```

Then re-run your ingest pipeline with the idempotent MERGE pattern below to fill back in any events that happened after that clean snapshot.

#### Option B: Dedup and Overwrite (if expired_snapshots already ran)

If older snapshots were already cleaned up, re-read from Postgres primary and overwrite the affected partition:

```python
from pyspark.sql.window import Window
from pyspark.sql.functions import col, row_number

# Re-read the affected data from Postgres PRIMARY (not a replica)
clean_df = spark.read.jdbc(
    url=PG_PRIMARY_URL,
    table="(SELECT * FROM accounts WHERE updated_at >= '2026-05-24') t",
    properties={"driver": "org.postgresql.Driver", **PG_PROPS},
)

# Defensive dedup in case Postgres itself has app-level retries
w = Window.partitionBy("account_id").orderBy(col("updated_at").desc())
clean_df = (
    clean_df
    .withColumn("_rn", row_number().over(w))
    .filter(col("_rn") == 1)
    .drop("_rn")
)

# Overwrite only the affected partition
clean_df.writeTo("iceberg.analytics.accounts").overwritePartitions()
```

### Prevent Future Duplicates: Idempotent MERGE INTO

The fix at the ingestion layer is a MERGE-based pipeline with per-key LSN ordering. This makes the at-least-once duplicate window harmless because the MERGE absorbs retries as no-ops:

```python
from pyspark.sql.window import Window
from pyspark.sql.functions import col, row_number

# Step 1: Deduplicate within the micro-batch.
# If Kafka re-delivers the same account_id event twice, keep only the latest by source_lsn.
w = Window.partitionBy("account_id").orderBy(col("source_lsn").desc_nulls_last())
events_dedup = (
    events_delta
    .withColumn("_rn", row_number().over(w))
    .filter(col("_rn") == 1)
    .drop("_rn")
)
events_dedup.createOrReplaceTempView("accounts_cdc")

# Step 2: Three-branch MERGE — handles inserts, updates, and deletes idempotently
spark.sql("""
    MERGE INTO iceberg.analytics.accounts t
    USING accounts_cdc s
    ON t.account_id = s.account_id

    -- Branch 1: DELETE — op='d' has a null after-image; NEVER collapse into UPDATE
    WHEN MATCHED AND s.op = 'd' THEN DELETE

    -- Branch 2: UPDATE — only advance if this event is newer than what we have
    -- Handles re-delivered duplicate events (same source_lsn → no-op on second delivery)
    WHEN MATCHED AND s.source_lsn > t.source_lsn AND s.op IN ('u', 'c', 'r') THEN
        UPDATE SET *

    -- Branch 3: INSERT — new rows from live inserts and snapshot reads
    WHEN NOT MATCHED AND s.op IN ('c', 'r', 'u') THEN INSERT *
""")
```

**Why three branches matter:**
- `op='d'` events have a **null after-image** in the Debezium envelope. Collapsing DELETE into an UPDATE branch would null out all columns in Iceberg. Always separate DELETE into its own branch.
- The `source_lsn > t.source_lsn` guard on the UPDATE branch ensures that if an older version of the same row arrives again (due to at-least-once re-delivery), it's silently skipped without writing anything.
- `op='r'` (snapshot read) appears in both MATCHED (idempotent overwrite) and NOT MATCHED (initial insert) — a re-snapshot writes the same values over the existing row, not a new duplicate row.

### Reduce the Duplicate Window

Lower `offset.flush.interval.ms` to shrink how many events fall in the re-delivery window on restart:

```yaml
# In your Strimzi KafkaConnect CRD
spec:
  config:
    offset.flush.interval.ms: "10000"   # down from default 60000; re-delivers ~10s of events on crash
```

With a 10-second flush window instead of 60 seconds, a crash means re-delivering at most ~10 seconds of events — not 12,000 account records.

### Make Sure source_lsn Is Persisted

The LSN guard in the MERGE only works if your Iceberg `accounts` table stores `source_lsn`. Add the column if it's missing:

```python
from pyspark.sql.functions import col

events_with_lsn = events.select(
    col("after.*"),
    col("source.lsn").cast("long").alias("source_lsn"),
    col("op"),
)
```

And add the column to the Iceberg table (metadata-only, old rows return NULL):

```sql
ALTER TABLE iceberg.analytics.accounts
ADD COLUMN source_lsn BIGINT;
```

The idempotent MERGE + LSN guard means you never need to run a post-batch deduplication query — duplicates are absorbed at write time, and your analytics queries can read `accounts` directly without any dedup wrapper.
