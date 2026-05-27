# Iter115 Q1 — Answer

**Question**: We use Debezium to stream changes from Postgres into Iceberg, and it's been working fine for our smaller tables. But our `events` table is huge — around 800 million rows — and we need to bootstrap it into Iceberg for the first time without breaking the ongoing CDC stream that's already running. When I tried doing a full dump-and-load from a Postgres snapshot, by the time the load finished the Debezium connector had moved so far ahead in the WAL that I didn't know where to safely resume without either missing rows or replaying duplicates. Is there a standard way to do an initial load of a table this large while keeping Debezium running, so that when the backfill finishes I can stitch it together cleanly with the live CDC feed?

---

## Answer

Yes, this is a well-solved problem — the key is doing the handoff in the correct order: **create the replication slot FIRST, then bootstrap, then start Debezium with `snapshot.mode=no_data`.** Reversing this order silently loses rows. "Pausing writes" is a costly outage and is unnecessary — this pattern keeps production live the entire time.

### Why Your Approach Silently Loses Data

The gap window problem: Spark reads a snapshot of 800M rows (takes hours). During that window, Postgres commits new changes. When Spark finishes and you try to connect Debezium, where should it start? Any LSN you pick either:
- Starts too early → replays rows Spark already loaded (duplicates you'll have to deduplicate)
- Starts too late → skips commits that happened after Spark's read (silent data loss, no error)

The slot-first pattern eliminates this uncertainty entirely.

### The Canonical Bootstrap → CDC Handoff (Slot-First Sequence)

**Step 1: Create the replication slot FIRST (on Postgres PRIMARY)**

```sql
-- Run on the Postgres PRIMARY (not a replica — slots live only on primaries)
SELECT * FROM pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
-- Returns: slot_name | lsn
```

This single command creates a permanent WAL bookmark. The slot's `consistent_point` LSN means: **every change committed at or after this LSN will be available to Debezium when it connects.** Production writes continue normally — they land in WAL and are retained by the slot. No downtime, no paused writes.

For transactional consistency (Spark snapshot and Debezium's start position see the same database state):

```sql
BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT * FROM pg_create_logical_replication_slot('debezium_slot', 'pgoutput', false, true);
SELECT pg_export_snapshot();
-- Returns snapshot name like '00000003-0000001B-1'
-- Keep transaction open while Spark runs; commit after Spark finishes
```

**Step 2: Bootstrap with Spark JDBC (production stays live)**

```python
from pyspark.sql.functions import lit

# Read from a replica to avoid I/O load on the primary during the long read
# At 800M rows, use numPartitions to parallelize across your cluster
df = spark.read.jdbc(
    url=PG_URL,
    table="public.events",
    properties={**PG_PROPS, "fetchsize": "10000"},
    numPartitions=16,
    partitionColumn="id",
    lowerBound=1,
    upperBound=800_000_000_000
)

# CRITICAL: tag bootstrap rows with op='r' (snapshot read)
# This lets the downstream MERGE handle bootstrap and live CDC events uniformly
df = (
    df
    .withColumn("op", lit("r"))                        # matches Debezium snapshot convention
    .withColumn("source_lsn", lit(None).cast("long"))  # bootstrap rows have no WAL LSN
    .withColumn("source_ts_ms", lit(None).cast("long"))
)

# append() is safe here — the MERGE in step 3 will absorb any overlap
df.writeTo("iceberg.analytics.events").append()
```

At 800M rows this takes 1–6 hours depending on cluster size. Production writes continue the entire time — no outage.

**Step 3: Start Debezium with `snapshot.mode=no_data`**

Once Spark finishes writing, configure your connector:

```yaml
# Strimzi KafkaConnector CRD
spec:
  config:
    slot.name: "debezium_slot"     # MUST match the slot from Step 1
    snapshot.mode: "no_data"       # skip per-row snapshot; slot has all the history
    publication.name: "debezium_pub"
    table.include.list: "public.events"
    plugin.name: "pgoutput"
    # ... rest of standard config
```

Debezium opens the slot created in Step 1 and streams every WAL change committed since the slot was created. Every commit during the bootstrap window is captured — nothing is lost.

### Why Order Matters

| Sequence | Result |
|---|---|
| **Slot → Spark → Debezium (correct)** | Slot retains every WAL change from creation onward. Spark reads rows. Debezium streams all changes since slot creation. Zero data loss. |
| **Spark → Debezium (wrong)** | Gap window exists between Spark's last read and Debezium's slot creation. Commits in the gap are permanently lost, with no error or warning. |
| **Pause writes → Spark → Debezium** | Unnecessary production outage for hours. The slot-first pattern gives exact capture without downtime — never do this. |

### Handling Overlap Idempotently (the MERGE Pattern)

Some rows will appear in both the bootstrap load and CDC events (rows committed during the Spark read window). The MERGE absorbs them:

```python
# Spark Structured Streaming consumer
events_cdc.createOrReplaceTempView("events_cdc")
spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_cdc s
    ON t.id = s.id

    -- DELETE: op='d' has null after-image — always separate from UPDATE
    WHEN MATCHED AND s.op = 'd' THEN DELETE

    -- UPDATE: advance only if this event is newer (LSN guard prevents stale overwrites)
    -- Also handles op='r' re-snapshots idempotently
    WHEN MATCHED AND s.source_lsn > t.source_lsn AND s.op IN ('u', 'c', 'r') THEN
        UPDATE SET *

    -- INSERT: new rows from CDC or snapshot
    WHEN NOT MATCHED AND s.op IN ('c', 'r', 'u') THEN INSERT *
""")
```

The `source_lsn > t.source_lsn` guard ensures that if a bootstrap row (NULL LSN) and a CDC row for the same primary key both arrive, the CDC row (with a real LSN) wins on the UPDATE branch, and the NULL-LSN bootstrap row is silently skipped.

### Monitor the Replication Slot

During and after the bootstrap, watch slot health:

```sql
-- On Postgres PRIMARY
SELECT
  slot_name,
  active,
  pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes,
  confirmed_flush_lsn
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

`active` must be `true` and `lag_bytes` should decrease toward zero as Debezium catches up. If `lag_bytes` grows unbounded and the slot is inactive, the slot is retaining WAL without anyone consuming it — this fills Postgres disk. Set a cap:

```sql
-- postgresql.conf
max_slot_wal_keep_size = '10GB'
```

### Verify No Rows Were Lost

After Debezium catches up, run a per-day count comparison:

```sql
-- Trino (requires Postgres catalog registered)
WITH pg_counts AS (
    SELECT DATE(created_at) AS d, COUNT(*) AS pg_n
    FROM postgres.public.events GROUP BY 1
),
ice_counts AS (
    SELECT DATE(created_at) AS d, COUNT(*) AS ice_n
    FROM iceberg.analytics.events GROUP BY 1
)
SELECT
  COALESCE(p.d, i.d) AS day,
  COALESCE(p.pg_n, 0) AS pg_n,
  COALESCE(i.ice_n, 0) AS ice_n,
  COALESCE(i.ice_n, 0) - COALESCE(p.pg_n, 0) AS delta
FROM pg_counts p FULL OUTER JOIN ice_counts i ON p.d = i.d
WHERE COALESCE(p.pg_n, 0) != COALESCE(i.ice_n, 0)
ORDER BY day;
```

Non-zero `delta` in mid-window is a bug; small positive deltas at the boundary (Debezium caught up faster than the check ran) are expected and will resolve on the next check.

**The key insight:** The slot-first pattern eliminates all guesswork about WAL positions. By creating the slot before the bootstrap starts, Postgres commits a permanent bookmark that answers "where should Debezium start?" definitively — regardless of how long the 800M-row read takes.
