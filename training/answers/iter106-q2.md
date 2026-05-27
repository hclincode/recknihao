# Iter106 Q2 — Answer

**Question**: We have a Postgres `events` table that's partitioned by month using `pg_partman` — so there are about 36 child tables covering the last 3 years. Our nightly Spark job does a watermark-based incremental load using `WHERE updated_at > last_run_timestamp`. The job has been running fine for months, but we recently noticed that when we query Iceberg, events from 2-3 days ago sometimes show up, but events from the same time window are missing for certain customers. We haven't changed the job code. The Postgres side looks correct when we query it directly. What could be causing events to go missing or appear late in Iceberg from a partitioned Postgres source like this?

---

## Answer

The symptom — Postgres looks correct, Iceberg is missing rows, code hasn't changed — points to **replica lag** as the most likely cause, compounded by the absence of a lag buffer in your watermark logic. There are three other failure modes to rule out. Here's how to diagnose all four and recover already-missed rows.

---

## Root Cause 1: Replica Lag Without a LAG_BUFFER (Most Likely)

If your Spark job reads from a **Postgres read replica**, rows committed to the primary may not yet be visible on the replica when your watermark filter runs.

**Concrete scenario producing the bug:**

1. May 22, 3:00 AM — your nightly job runs. Reads `WHERE updated_at > '2026-05-21 23:59:00'`. Watermark advances to May 21, 11:59 PM.
2. May 22, 2:45 AM (before your job ran) — a customer syncs an event: `updated_at = May 22, 2:45 AM`. The primary commits it immediately.
3. May 22, 3:00 AM — the replica is 45 minutes behind. The replica hasn't replayed that commit yet. Your job doesn't see the row.
4. May 23, 3:00 AM — your next run watermarks from `May 21, 11:59 PM` → the boundary already passed May 22, 2:45 AM. **That event is permanently missed.**

"Postgres looks correct when queried directly" — yes, because you're querying the primary.

**Fix: LAG_BUFFER pattern**

Measure your replica's P99 lag (from monitoring or `pg_stat_replication.replay_lag`), double it, and back off the watermark by that amount:

```python
from datetime import timedelta

# Measure your replica's P99 lag for a week; double it as safety margin
LAG_BUFFER = timedelta(minutes=16)  # Example: P99=8 min, buffer=16 min

last_ts = read_watermark()

df = spark.read.jdbc(
    url=PG_REPLICA_URL,
    table=f"(SELECT * FROM events WHERE updated_at > '{last_ts}') t",
    properties=PG_PROPS,
)

max_updated_at = df.agg({"updated_at": "max"}).collect()[0][0]
safe_watermark = max_updated_at - LAG_BUFFER  # back off instead of advancing to max
write_watermark(safe_watermark)

# Next run overlaps the boundary window — in-flight rows get re-read.
# Safe ONLY if using MERGE INTO (not append).
```

Then use MERGE INTO instead of append to make re-reads safe:

```python
df.createOrReplaceTempView("events_delta")
spark.sql("""
    MERGE INTO iceberg.analytics.events AS t
    USING events_delta AS s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

MERGE INTO matched rows update in place — no duplicates on re-read.

---

## Root Cause 2: Late-Arriving Rows + `overwritePartitions()` Data Loss

If your Iceberg table partitions by `day(occurred_at)` but you watermark by `updated_at`, late-arriving rows can silently destroy legitimate data.

**Concrete scenario:**
1. May 20 nightly job inserts 8,432 events into `day = 2026-05-20` partition.
2. May 23: a mobile user syncs 12 events backdated to `occurred_at = May 20` but `updated_at = May 23`.
3. May 23 nightly job: watermark filter picks up those 12 rows.
4. Job calls `df.writeTo("iceberg.analytics.events").overwritePartitions()`.
5. Iceberg replaces the entire May 20 partition with 12 rows. **8,432 events deleted silently.**

**Fix: use MERGE INTO instead of `overwritePartitions()`**

```python
df.createOrReplaceTempView("events_delta")
spark.sql("""
    MERGE INTO iceberg.analytics.events AS t
    USING events_delta AS s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

MERGE INTO only touches matched rows. The 8,432 unmatched rows stay intact.

---

## Root Cause 3: Missing Indexes on pg_partman Child Partitions

With 36 child tables, some older ones may lack an index on `updated_at`. Without it, Spark JDBC does a full sequential scan of the entire child table instead of an index-bounded range scan. On a 3-year-old partition, this can cause the driver to time out or skip rows.

**Check for missing indexes:**

```sql
SELECT tablename, COUNT(*) AS index_count
FROM pg_indexes
WHERE tablename LIKE 'events_%'
  AND indexdef LIKE '%updated_at%'
GROUP BY tablename
HAVING COUNT(*) = 0;  -- Returns children missing the index
```

**Fix:**

```sql
-- For each missing child (CONCURRENTLY avoids locking writers):
CREATE INDEX CONCURRENTLY idx_events_2024_01_updated_at ON events_2024_01 (updated_at);

-- Or use pg_partman's helper:
SELECT partman.reapply_indexes('public.events');
```

Also ensure `pushDownPredicate=true` in your JDBC props so WHERE clauses execute on Postgres (not after pulling all rows to Spark):

```python
PG_PROPS = {
    "user": PG_USER, "password": PG_PASS,
    "driver": "org.postgresql.Driver",
    "pushDownPredicate": "true",  # critical — WHERE runs on Postgres
    "fetchsize": "10000",
}
```

---

## Root Cause 4: Backdated `updated_at` (Permanent Silent Loss)

If your app or a migration ran `UPDATE events SET updated_at = '2024-01-01' WHERE ...`, those rows are permanently invisible to your watermark — their timestamp is in the past.

**Check for this:**

```sql
SELECT min(updated_at) AS earliest, max(created_at) AS latest_create
FROM events;
-- If earliest_update << min(created_at), backdating happened
```

**Prevention:** add a trigger so the database always sets `updated_at`:

```sql
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER events_touch_updated_at
BEFORE INSERT OR UPDATE ON events
FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
```

**Recovery:** weekly full-snapshot MERGE (see below).

---

## Detection & Recovery: Backfilling Already-Missed Rows

Don't do a full reload. Use this targeted three-step recipe.

**Step 1: Find the gap** (compare against PRIMARY, not replica)

```python
iceberg_max = spark.sql(
    "SELECT max(updated_at) AS ts FROM iceberg.analytics.events"
).collect()[0].ts

pg_max = spark.read.jdbc(
    url=PG_PRIMARY_URL,  # PRIMARY — not replica
    table="(SELECT max(updated_at) AS ts FROM events) t",
    properties=PG_PROPS,
).collect()[0].ts

gap_minutes = (pg_max - iceberg_max).total_seconds() / 60
print(f"Iceberg is {gap_minutes:.1f} minutes behind PRIMARY")
```

**Step 2: Read the missed window from PRIMARY**

```python
from datetime import date, timedelta
this_month = date.today().strftime("%Y_%m")
last_month = (date.today().replace(day=1) - timedelta(days=1)).strftime("%Y_%m")

missed_df = spark.read.jdbc(
    url=PG_PRIMARY_URL,
    table=(
        f"(SELECT * FROM events_{this_month} "
        f" WHERE updated_at BETWEEN '{iceberg_max}' AND '{pg_max}' "
        f" UNION ALL "
        f" SELECT * FROM events_{last_month} "
        f" WHERE updated_at BETWEEN '{iceberg_max}' AND '{pg_max}') t"
    ),
    properties=PG_PROPS,
)
```

**Step 3: MERGE INTO idempotently**

```python
missed_df.createOrReplaceTempView("events_backfill")
spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_backfill s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")

# Reset watermark after successful backfill
write_watermark(pg_max - LAG_BUFFER)
```

Safe to re-run — matched rows update in place, no duplicates.

---

## Immediate Checklist

1. **Check if you're reading from a replica AND have no LAG_BUFFER** — this is the most common cause of 2-3 day intermittent gaps.
2. **Check all 36 child partitions for `updated_at` indexes** — `SELECT tablename FROM pg_indexes WHERE tablename LIKE 'events_%' AND NOT indexdef LIKE '%updated_at%'`
3. **Verify `pushDownPredicate=true`** is in your JDBC properties
4. **Switch from `overwritePartitions()` to MERGE INTO** if using overwrite
5. **Run the detection recipe** to find and backfill already-missed rows
6. **Add a weekly full-snapshot MERGE** as a safety net to catch backdated updates and other edge cases
