# Iter121 Q2 — Answer

**Question**: We collect product usage events from our customers' apps and stream them into our data pipeline, but sometimes events show up 2, 3, or even 5 days late — maybe the customer's device was offline, or there was a delay in their backend. When those late events finally arrive, they have timestamps from days ago, but our Iceberg table is partitioned by the date events are ingested rather than when they actually happened. So a login event from last Tuesday might land in today's partition. Our customer-facing analytics then show artificially low numbers for last Tuesday. Is there a standard way to handle this, and does it mean we need to rethink how we partition the table?

---

# Late-Arriving Events in Iceberg: A Practical Fix Without Repartitioning

## The Core Problem

You've identified a real tension in streaming analytics: your Iceberg table is partitioned by **ingestion time** (when the data arrived), but your dashboards query by **event time** (when it actually happened). When events arrive days late, they land in a different partition than the one your dashboard already "closed." This makes historical metrics look artificially low.

This is so common that it has a name in the data world: the **late-arriving events problem**. The good news: there's a standard way to handle it, and **you do not need to repartition your table**.

---

## The Two-Timestamp Solution (Required Architecture)

Every event table in a SaaS analytics pipeline should have **two separate timestamp columns**:

1. **`occurred_at`** — when the event actually happened (user device time, business-meaningful)
2. **`ingested_at`** — when your system received and wrote it (server time, monotonic and predictable)

Your table schema should look like:

```sql
CREATE TABLE iceberg.analytics.user_events (
  event_id      VARCHAR,
  tenant_id     VARCHAR,
  user_id       VARCHAR,
  event_name    VARCHAR,
  occurred_at   TIMESTAMP(6),   -- when the user action happened
  ingested_at   TIMESTAMP(6),   -- when we received it (server time)
  plan_type     VARCHAR,
  country       VARCHAR
)
USING iceberg
PARTITIONED BY (day(ingested_at), tenant_id);
```

**Critical:** partition by `ingested_at` (predictable, monotonic, controls file layout cleanly), but **query and aggregate by `occurred_at`** (the business timeline).

---

## Why This Works

**Partitioning by `ingested_at`:**
- Iceberg always gets a clean, predictable partition structure — today's data lands in today's partition, yesterday's data landed in yesterday's partition.
- Your incremental ingestion jobs naturally produce one partition's worth of files per run.
- Compaction stays straightforward — files for a day cluster together.

**Querying by `occurred_at`:**
- Your dashboards ask "what happened last Tuesday?" using `WHERE occurred_at >= '2026-05-20' AND occurred_at < '2026-05-21'`.
- That query touches files from **multiple ingestion partitions** (Tuesday's on-time events, plus late arrivals from Wednesday, Thursday, Friday that occurred on Tuesday). Iceberg handles this automatically.
- The late-arriving Tuesday event from Friday's ingestion partition gets read correctly and counts toward Tuesday's total.

---

## Adding the Buffer Window to Dashboards

Your customer-facing dashboards must account for the fact that events are still trickling in. **Don't query yesterday's complete final data at 00:00:01 — wait until events have settled.**

Standard practice:
- **Billing and revenue queries:** use data "through 2 days ago" to ensure almost all events have arrived.
- **Real-time dashboards:** use data "through 1 hour ago" (for hourly ingestion) or "through 15 minutes ago" (for 15-minute micro-batches).
- **Label dashboards transparently:** "Data as of 2 hours ago" or "DAU through yesterday at 10 PM."

---

## Practical Implementation in Your Iceberg Job

Your Spark ingestion job should capture **both** timestamps:

```python
from pyspark.sql.functions import col, current_timestamp

events_with_times = events_df.select(
    col("event_id"),
    col("tenant_id"),
    col("user_id"),
    col("event_name"),
    col("payload.timestamp").cast("timestamp").alias("occurred_at"),  # from event
    current_timestamp().alias("ingested_at"),  # server time when we ingest
    col("payload.plan_type"),
    col("payload.country"),
)

# Write to Iceberg partitioned by ingestion time
events_with_times.writeTo("iceberg.analytics.user_events") \
    .partitionedBy("day(ingested_at)", "tenant_id") \
    .append()
```

---

## Your Analytics Queries Now Look Like This

**Wrong (what you might do today):**
```sql
-- Undercounts yesterday because late events haven't arrived yet
SELECT COUNT(*) FROM user_events
WHERE DATE(ingested_at) = '2026-05-21';
```

**Correct:**
```sql
-- All events that occurred on the 21st, even if they arrived later
SELECT COUNT(*) FROM user_events
WHERE occurred_at >= TIMESTAMP '2026-05-21 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-05-22 00:00:00';

-- With buffer window for live dashboards
SELECT COUNT(*) FROM user_events
WHERE occurred_at >= TIMESTAMP '2026-05-21 00:00:00'
  AND occurred_at <  TIMESTAMP '2026-05-22 00:00:00'
  AND ingested_at <  current_timestamp - INTERVAL '2' HOUR;
```

The second query does both: counts by business time (`occurred_at`) and waits for data to settle (`ingested_at` at least 2 hours old).

---

## Do You Need to Repartition?

**No.** Partitioning by `ingested_at` is exactly right — don't change it. The problem isn't the partition layout; it's the query logic.

If your table is currently partitioned by `day(occurred_at)`, you have two options:

1. **Easier path:** keep that partition spec and accept that daily jobs will scatter late-arriving files across multiple ingestion days. Run analytics queries with a buffer window as shown above.

2. **Cleaner long-term path:** change to `PARTITIONED BY (day(ingested_at), tenant_id)` via partition evolution. This is metadata-only for new writes. It makes incremental ingestion cleaner, but is not required if buffer-windowed queries are acceptable.

Most teams pick option 1 initially and only evolve the partition spec later if incremental ingestion jobs are creating too many small files.

---

## Monitoring Late Arrivals

To track how much data arrives late, add a simple daily metric:

```sql
SELECT 
  DATE(occurred_at) AS event_day,
  COUNT(*) AS total_events,
  SUM(CASE WHEN ingested_at - occurred_at <= INTERVAL '2' HOUR THEN 1 ELSE 0 END) AS on_time,
  ROUND(100.0 * SUM(CASE WHEN ingested_at - occurred_at <= INTERVAL '2' HOUR THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_on_time
FROM user_events
GROUP BY DATE(occurred_at)
ORDER BY event_day DESC
LIMIT 30;
```

This shows you how reliable your "2-hour buffer" assumption actually is. If 99% of events arrive within 2 hours, a 2-hour dashboard buffer is safe. If only 95% do, increase to 3 hours.

---

## Summary: What to Do Right Now

1. **Add `ingested_at` to your event schema** if it's not already there (capture `current_timestamp()` at write time).
2. **Partition by `day(ingested_at), tenant_id`** — this gives you clean, predictable file layout for incremental loads.
3. **Update dashboard queries to use `occurred_at`** for time filtering and add a buffer window (`ingested_at < current_timestamp - INTERVAL '2' HOUR`).
4. **Label dashboards** transparently: "Data through 2 hours ago" or "Last 24 hours' final counts."
5. **Run nightly compaction** on the `ingested_at` partitions to keep files healthy.
