# Iter97 Q2 — Answer

**Question**: We started streaming Postgres changes into our data lake using Debezium, and for INSERT events everything seems to work fine. But UPDATE events are more complicated — Debezium sends both the old version of the row and the new version. I found references to something called MERGE INTO in Spark that's supposed to handle this, but I'm not clear on what actually happens under the hood. Specifically, what happens if Debezium sends an UPDATE for a row that doesn't exist in the destination yet — because that row was inserted in Postgres before we turned on CDC? Does the merge just fail silently, or do we end up with missing or corrupted data?

---

## Answer

## How MERGE INTO works with Debezium before/after images

Debezium sends UPDATE events with both the old row (`before` field) and the new row (`after` field). Your Spark job's MERGE INTO does a join between the incoming events and the Iceberg table:

```python
spark.sql("""
    MERGE INTO iceberg.analytics.events AS t
    USING events_delta AS s
    ON t.event_id = s.event_id
    WHEN MATCHED AND s.op = 'd' THEN DELETE
    WHEN MATCHED AND s.op = 'u' THEN UPDATE SET *
    WHEN NOT MATCHED AND s.op IN ('c', 'r') THEN INSERT *
""")
```

For each incoming row, Spark evaluates the `ON` condition:
- **Row found in Iceberg (MATCHED)** → execute UPDATE or DELETE
- **Row NOT found in Iceberg (NOT MATCHED)** → execute INSERT

This is **upsert semantics** — the merge does not fail when a row is missing. It treats the missing row as NOT MATCHED and inserts it.

## What happens when the target row doesn't exist

Here's the exact scenario you described:

1. Postgres has 10 million rows before you enable Debezium
2. You start Debezium with `snapshot.mode=no_data` (skipping the bootstrap snapshot)
3. Debezium streams only changes that happen after this moment
4. An UPDATE comes for `event_id=42` — a row created months ago in Postgres
5. Your Spark MERGE INTO looks for `event_id=42` in Iceberg... it doesn't exist

**Result:** MERGE INTO executes the `WHEN NOT MATCHED` branch and **inserts the row with the new values** (the `after` image). The row now appears in Iceberg with its updated state, but:
- Iceberg has no record of the row's original state
- The row looks like it was always in the updated state
- **No error is raised — the pipeline runs green**

This is silent data corruption, not a failure. You won't see exceptions. But your Iceberg table now contains a row that appears to have been created with `status='processed'` when in reality it was updated from `status='pending'`.

## Why this matters in practice

1. **Lost history**: A row modified 100 times in Postgres appears in Iceberg with only its final state during the gap period. Audits and temporal queries see incomplete data.

2. **Broken analytics**: Funnels and cohort analyses based on "when did this row first appear" are wrong — rows inserted during the gap look newer than they are.

3. **Inconsistent counts**: During the bootstrap gap period, row counts in Iceberg are behind Postgres. Reports run during this window show incorrect numbers.

## The fix: don't create the gap in the first place

### Option A (Recommended): Use `snapshot.mode=initial` (the default)

When Debezium first starts, it does an initial snapshot of every existing row and emits them as `op='r'` (read) events in Kafka **before** any live change events arrive. Your MERGE INTO handles them as inserts:

```python
spark.sql("""
    MERGE INTO iceberg.analytics.events AS t
    USING events_delta AS s
    ON t.event_id = s.event_id
    WHEN MATCHED AND s.op = 'd' THEN DELETE
    WHEN MATCHED AND s.op = 'u' THEN UPDATE SET *
    WHEN NOT MATCHED AND s.op IN ('c', 'r') THEN INSERT *
""")
```

All 10 million pre-existing rows land in Iceberg from the initial snapshot. Then live changes stream through the same MERGE. No missing rows, no gap. Cost: the initial snapshot reads the entire source table (can take hours for very large tables), but it's one-time.

### Option B: Manual bootstrap + `snapshot.mode=no_data`

For very large tables where an initial Debezium snapshot is operationally expensive, bootstrap manually first:

```python
# Step 1: Load the full table from Postgres via JDBC
df = spark.read.jdbc(url=PG_URL, table="public.events", properties=PG_PROPS)
df.writeTo("iceberg.analytics.events").createOrReplace()

# Step 2: Record the timestamp when bootstrap completes
bootstrap_ts = datetime.utcnow()

# Step 3: Start Debezium AFTER bootstrap, with snapshot.mode=no_data
```

With `snapshot.mode=no_data`, Debezium skips the snapshot and streams only changes that occur after the replication slot was created. The slot must have been created before the bootstrap completed, or you'll have a gap.

**Critical check before starting Debezium:**

```sql
-- Verify the replication slot's LSN covers your bootstrap completion time
SELECT slot_name, confirmed_flush_lsn, restart_lsn
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

The `restart_lsn` must be at or before the LSN corresponding to when your bootstrap job finished reading. If the slot was created after the bootstrap completed, any changes made during the bootstrap window are lost.

## The pattern that causes the problem

The dangerous combination is: `snapshot.mode=no_data` + **no manual bootstrap**. This is the "skip the snapshot and hope CDC picks everything up" mistake. The pipeline runs, metrics look fine, and you have silently missing rows for any row that existed before CDC started and was later updated.

## Bottom line

- **`snapshot.mode=initial` (default)**: safe, no gap, Debezium bootstraps for you. Use this unless your table is so large that the snapshot is impractical.
- **`snapshot.mode=no_data` + manual Spark JDBC bootstrap**: safe if the timing is airtight. Advanced option for very large tables.
- **`snapshot.mode=no_data` + no manual bootstrap**: silently corrupts data for pre-existing rows that get updated. Never do this in production.

For your stack (Debezium 2.x + Spark + Iceberg 1.5.2), `snapshot.mode=initial` is the right default. The initial snapshot runs once and gives you a clean baseline; after that, only deltas flow.
