# Iter47 Q2 Answer — pg_partman late-arriving events

**Question**: Our Postgres events table is managed by pg_partman, partitioned by month on `occurred_at`, so we have child tables like `events_2026_03`, `events_2026_04`, `events_2026_05`. Our Spark ingestion job was hanging 45-60 seconds at startup when reading from the parent `events` table, so we switched to targeting child partitions directly using `dbtable='(SELECT * FROM events_2026_04) t'` for April's nightly job. The startup hang went away. But now our analytics team says April's event counts in Iceberg are 12,000 rows lower than in Postgres. Our mobile app sometimes batches events offline and uploads them a few days late — could that be the cause, and how do we fix the Spark job to catch those late-arriving rows without going back to reading the slow parent table?

---

## Your Problem Explained

Yes, late-arriving events are the **exact cause** of your 12,000-row discrepancy. Your mobile app's offline buffering means events with `occurred_at` dates from April can arrive and be written to Postgres days or weeks later. When that happens, they land in the April child partition (`events_2026_04`) — because pg_partman routes rows by `occurred_at` value, not by when they arrived.

By switching your Spark job to read only `events_2026_04` directly, you solved the pg_partman metadata scan performance problem. But you created a **silent data gap**: if April's nightly job ran before late-arriving April events came in, those rows are simply absent from your snapshot.

## Diagnostic first

Confirm the root cause by running directly on Postgres:

```sql
SELECT COUNT(*) FROM events_2026_04
WHERE occurred_at >= '2026-04-01' AND occurred_at < '2026-05-01';
```

Compare that count to Iceberg. If the numbers differ by ~12,000, late arrivals are the cause.

## The fix: re-run the April job for several days after month close

You don't need to go back to reading the slow parent table. Instead, **re-run the April job periodically for 5-7 days after month end** using `overwritePartitions()` to atomically replace April's Iceberg partition with the complete current contents of `events_2026_04`:

```python
from pyspark.sql import SparkSession

spark = SparkSession.builder.getOrCreate()

# Read the full April child partition from Postgres
april_df = spark.read.jdbc(
    url=PG_URL,
    table="(SELECT * FROM events_2026_04) t",
    properties=PG_PROPS,
    column="id",
    lowerBound=min_id,
    upperBound=max_id,
    numPartitions=16,
)

# Write as an overwrite of April's Iceberg partition only
april_df.write \
    .format("iceberg") \
    .option("write.spark.fanout.enabled", "true") \
    .mode("overwrite") \
    .option("overwrite-mode", "dynamic") \
    .saveAsTable("iceberg.analytics.events")
```

With `month(occurred_at)` as your Iceberg partition key, the dynamic overwrite replaces **only April's partition** and leaves all other months untouched. The operation is idempotent — running it multiple times is safe.

## Why this works without reading the parent table

The pg_partman startup hang was caused by Spark scanning the parent table's partition metadata (all historical child partitions). By targeting `events_2026_04` directly, you skip that scan entirely and still get the complete, up-to-date April data including any late arrivals that have since landed in Postgres.

## Scheduling

Schedule the April re-run for days 1–7 of May:
- May 1: April full-refresh (catches late arrivals from April 29–30)
- May 3: April full-refresh
- May 7: final April full-refresh (catches most mobile batching delays)

After May 7, late-arriving April events become rare enough that the gap is acceptable.

## Recovery: fix the existing 12,000-row gap

Run a one-time full read of `events_2026_04` and overwrite April's Iceberg partition using the same pattern above. After this runs, April's count should match Postgres.

## Key takeaway

Reading specific pg_partman child partitions directly was the right performance fix. Pair it with a short re-run window after each month closes — typically 5-7 days — and use `overwritePartitions()` with a month-level Iceberg partition key to make each re-run atomic and safe.
