# Iter56 Q2 — Answer

**Question**: Right now our Spark job does a full dump of our Postgres `events` table into Iceberg every night, but the table is getting big enough that this is taking hours. Someone on the team suggested we switch to only loading rows that changed or were added since the last run, by filtering on `updated_at > last_run_timestamp`. That sounds straightforward but I want to understand if there are traps before we build it. For example, some of our older event rows don't have an `updated_at` at all — it was added to the schema later. And I've heard that if a row gets written in Postgres right at the boundary of when we run the query, we could miss it or double-load it. How do we build this watermark-based incremental load safely?

---

## Answer

The watermark pattern is real and saves enormous time once your table passes 10–20 million rows. But there are four specific traps that will silently break your data freshness if you don't know about them.

### How the watermark pattern works

Instead of reading the entire table every night, you store a checkpoint — the maximum `updated_at` timestamp from your last successful load — and on the next run you only fetch rows newer than that.

```python
last_ts = read_watermark()  # e.g., from a file in MinIO

df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM events WHERE updated_at > '{last_ts}') sub",
    properties=PG_PROPS,
)

df.writeTo("iceberg.analytics.events").append()
new_ts = df.agg({"updated_at": "max"}).collect()[0][0]
write_watermark(new_ts)
```

Simple idea. The implementation has hidden complexity.

### Trap 1: rows with NULL updated_at (they vanish forever)

Rows created before the `updated_at` column was added have NULL for that field. A watermark filter `WHERE updated_at > X` is always false for NULL — these rows never appear in any incremental run. They stay in Postgres forever and never land in Iceberg.

**Fix:** Before deploying the incremental pattern, do one full-table refresh (overwrite mode) as a baseline. Then for the NULL rows:

**Option A (recommended):** Backfill once in Postgres:
```sql
UPDATE events SET updated_at = created_at WHERE updated_at IS NULL;
```

**Option B (if you can't modify Postgres):** Include NULLs in the first incremental run's filter:
```python
table=f"(SELECT * FROM events WHERE updated_at > '{last_ts}' OR updated_at IS NULL) sub"
```
These rows don't move after that, so they never appear in future incremental windows.

### Trap 2: late-arriving data (the boundary problem)

Your job runs at 2 AM and reads all rows where `updated_at > '01:59:30'`. The Spark job processes until 2:05 AM. At 2:02 AM — while Spark is processing — a mobile device syncs and writes a row with `updated_at = 02:02:15`. This row physically arrives during the job's window but Spark has already moved past reading that point. The row is missed.

**Fix: use a conservative watermark lag buffer.** Back off by 15–30 minutes from the maximum `updated_at` you saw:

```python
from datetime import timedelta

LAG_BUFFER = timedelta(minutes=15)  # calibrate to P99 replica lag
max_ts = df.agg({"updated_at": "max"}).collect()[0][0]
new_watermark = max_ts - LAG_BUFFER
write_watermark(new_watermark)
```

This means every run re-reads the last 15 minutes. Combined with deduplication (Trap 3 fix), this handles late arrivals correctly. Calibrate by checking `pg_stat_replication.replay_lag` P99 over a week and doubling it as a safety margin.

If reading from the Postgres **primary** (not a replica), lag is near zero and you can use a buffer of seconds, or omit it.

### Trap 3: duplicate rows from job retries

Your Spark job appends rows and then crashes before writing the new watermark. On retry, it re-reads the exact same window and appends all the same rows again. Event counts double silently. No error. You discover it three days later.

**Fix: use `MERGE INTO` instead of `append()`.** MERGE is idempotent — if a row already exists (matched by primary key), it updates it; if it's new, it inserts it. Re-running the same MERGE produces the same final state:

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

**Warning about `overwritePartitions()` with late arrivals:** If you use `overwritePartitions()` and a late-arriving row has `occurred_at` = May 20 but `updated_at` = May 25 (the device was offline), the MERGE will correctly insert just that row. But `overwritePartitions()` would replace the entire May 20 partition with just that one late-arriving row, discarding the 8,000+ events you loaded days earlier. MERGE INTO avoids this entirely.

### Trap 4: silent row-count drift

The pipeline runs fine for three weeks. Nobody notices that a few nights' windows were slightly off — maybe clock skew, maybe lag buffer miscalibrated. Postgres has 50 million rows; Iceberg has 49.2 million. Numbers keep returning; they're just wrong. You find out when someone rebuilds a report.

**Fix: add row-count reconciliation after each load:**

```python
yesterday = spark.sql("SELECT current_date() - INTERVAL 1 DAY").collect()[0][0]

iceberg_count = spark.sql(
    f"SELECT COUNT(*) FROM iceberg.analytics.events WHERE updated_at > '{yesterday}'"
).collect()[0][0]

pg_count = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT COUNT(*) FROM events WHERE updated_at > '{yesterday}') t",
    properties=PG_PROPS,
).collect()[0][0]

if iceberg_count != pg_count:
    alert_slack(f"Row count mismatch: Postgres {pg_count}, Iceberg {iceberg_count}")
```

### Preflight: index updated_at in Postgres

Before deploying, verify the column is indexed:

```sql
SELECT indexname FROM pg_indexes
WHERE tablename = 'events' AND indexdef LIKE '%updated_at%';
```

If empty, create it:

```sql
CREATE INDEX CONCURRENTLY idx_events_updated_at ON events (updated_at);
```

An unindexed watermark column causes a full-table sequential scan on every incremental run. For 50 million rows this is catastrophic — your "fast incremental" job now takes longer than the full refresh.

### Production-safe template

1. **Read with lag buffer:** `WHERE updated_at > (last_checkpoint - LAG_BUFFER)`
2. **Merge, not append:** `MERGE INTO` keyed on primary key
3. **Advance watermark conservatively:** `new_checkpoint = max(updated_at) - LAG_BUFFER`
4. **Monitor nightly:** row-count reconciliation catches drift early
5. **Index preflight:** ensure `updated_at` is indexed before the first run
