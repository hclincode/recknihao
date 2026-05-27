# Iter82 Q2 — Answer

**Question**: Watermark-based incremental load from Postgres into Iceberg after initial full load. What happens to the old version of an updated row? Duplicates? Use updated_at or created_at? How to avoid missing rows?

---

## Answer

You're on the right track thinking about `updated_at` as your watermark (the column that tracks which rows changed). But your concern about duplicates and stale rows hits exactly the right problem — and there's a specific technique to handle it. Let me walk through what happens, which watermark to choose, and the lag buffer safety net.

### What Happens to Old Rows When They Change (The Core Problem)

Here's the scenario you're worried about: a user record exists in Iceberg from last week. Today, someone updates that user's email in Postgres. If you run your incremental job with `WHERE updated_at > last_watermark`, you'll pull that one row again (because its `updated_at` just changed). But what happens to the old copy in Iceberg?

**If you use `.append()`, you get duplicates.** The row gets inserted again, so Iceberg now has two copies of the same `user_id` — one with the old email, one with the new one. Queries will double-count it, or worse, show the wrong (old) email depending on which copy gets read.

**If you use MERGE INTO, it updates the existing row in place.** This is the right pattern. MERGE INTO is like a SQL `INSERT OR UPDATE` statement: it joins the delta (new rows from Postgres) against Iceberg on the primary key (`event_id`, `user_id`, etc.), then:
- For rows that already exist in Iceberg (matched), update all columns with the new values.
- For rows that don't exist yet (not matched), insert them.

This means updated rows stay at exactly one copy with fresh values — no duplicates, no stale data sitting around.

Here's what a MERGE INTO looks like:

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

This is idempotent too: if your Spark job crashes halfway and reruns, the second run remerges the same rows with the same result — no additional duplicates get created.

### Which Watermark Column: `updated_at` vs `created_at`

This is critical. Pick wrong and your pipeline silently misses data for weeks.

**Use `updated_at` (the default).** It catches both new inserts and updates to existing rows. So when a user updates their email, their subscription plan, or soft-deletes their account, that row's `updated_at` changes and your next incremental run picks it up. This is what an analytics replica actually needs — every meaningful change.

The catch: your application (or ORM) must reliably set `updated_at = now()` on every INSERT and UPDATE. Most frameworks do this automatically, but make sure. If you're worried, add a Postgres trigger so a buggy service can't silently break the pipeline:

```sql
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER events_touch_updated_at
BEFORE INSERT OR UPDATE ON events
FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
```

**Use `created_at` only if the table is append-only** — rows never change after insert. Examples: `page_views`, `webhook_events`, `audit_log`. For these immutable tables, `created_at` is simpler and usually indexed better (correlated with the primary key). But for any table where rows get updated (user profiles, orders, subscriptions, anything with a `status` column), using `created_at` is a trap: updates are invisible to your watermark, and Iceberg will have stale copies of every updated row forever. Then, three months later, someone discovers that user churn numbers are wrong because soft-deleted users never got re-synced.

### The Lag Buffer Safety Net (Catching Rows That Fall Through the Cracks)

Your worry about slow jobs and rows falling through the cracks is the right instinct. Here's why it matters:

If you're reading from a Postgres **read replica** (common for offloading analytics load), the replica might be lagging behind the primary by a few seconds or minutes. You run your incremental job at 2 AM, and the replica is 15 seconds behind. The job runs `WHERE updated_at > '2026-05-25 02:00:00'`, but three rows from that exact second are still in-flight on the primary — the replica hasn't replayed them yet. Your job runs, and those rows are missed. They'll never come back because the next run starts from a later watermark.

The fix: **before you save the new watermark, subtract a small safety buffer.** Instead of saving `max(updated_at)` from the rows you just read, save `max(updated_at) - 15 minutes`. This means the next run will re-read the last 15 minutes of data, recapturing any rows that were in flight.

```python
from datetime import timedelta

# Tune this to your observed P99 replica lag — measure it for a week first.
LAG_BUFFER = timedelta(minutes=15)

last_ts = read_watermark()  # e.g., from a JSON file in MinIO
df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM events WHERE updated_at > '{last_ts}') t",
    properties=PG_PROPS,
)

# ... MERGE INTO Iceberg ...

# Save the new watermark with the lag buffer subtracted.
max_ts = df.agg({"updated_at": "max"}).collect()[0][0]
new_watermark = max_ts - LAG_BUFFER
write_watermark(new_watermark)
```

Why this works: combined with MERGE INTO, re-reading the boundary window is safe. Rows that were successfully merged on the first run are matched by join key on the second run, so they get updated in place — no duplicates.

**How to size the buffer.** Check your actual Postgres replica lag for a week. Take the P99 (the 99th percentile — the worst lag that happens 1% of the time). Double it as a safety margin for transient spikes. For most healthy Postgres replicas, this comes out to 15–30 minutes. If your replica lag is under 5 minutes, a 15-minute buffer is a 3x safety margin, which is fine — you're re-reading 15 minutes per run, which is negligible on any table.

### The One Big Trap: Late-Arriving Rows

There's one scenario where your updated_at watermark can silently lose data: **late-arriving rows**. Here's the timeline:

1. **May 20**: your nightly job ingests all of May 20's events. Iceberg has 8,432 events.
2. **May 23**: a mobile app reconnects and uploads 12 events from May 20 (they happened on May 20, but `updated_at` is set to May 23 receive time). Postgres now has those 12 rows.
3. **May 23 nightly job**: your watermark filter `WHERE updated_at > '2026-05-22 23:59:00'` picks up the 12 late rows. You pull them from Postgres.
4. **MERGE INTO Iceberg**: the 8,432 existing May 20 rows match the primary key, so they stay. The 12 new rows don't match, so they insert. Total: 8,444 rows. Correct.

**But if you used `overwritePartitions()` instead of MERGE INTO**, step 4 would wipe all 8,432 rows and leave only the 12 late ones. Silent data loss.

This is why MERGE INTO is not just a best practice — it's the only safe pattern for incremental loads with an `updated_at` watermark.

### Tying It Together: Your First Incremental Job

```python
from datetime import timedelta

last_ts = read_watermark("events")  # e.g., from a JSON file in MinIO
LAG_BUFFER = timedelta(minutes=15)

# Read delta from Postgres with watermark + lag buffer
df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM events WHERE updated_at > '{last_ts}') t",
    properties={"pushDownPredicate": "true", "fetchsize": "10000", ...}
)

# MERGE INTO Iceberg — updates existing rows, inserts new ones, no duplicates
df.createOrReplaceTempView("events_delta")
spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_delta s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")

# Save watermark with lag buffer for next run
max_ts = df.agg({"updated_at": "max"}).collect()[0][0]
new_watermark = max_ts - LAG_BUFFER
write_watermark("events", new_watermark)
```

Before deploying: check that `updated_at` is indexed in Postgres (`SELECT indexname FROM pg_indexes WHERE tablename='events' AND indexdef LIKE '%updated_at%'`). An unindexed watermark column causes a full-table scan on every run.
