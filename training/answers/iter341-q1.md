# Answer to Q1: Lag Buffer Sizing for Incremental Postgres Sync (Iter 341)

The lag buffer is a safety delay you subtract from your watermark before saving it. It protects against missing rows caused by replication lag between your Postgres primary and read replica.

## Why rows go missing without a lag buffer

When your incremental sync reads from a Postgres read replica, that replica lags behind the primary. A row committed to the primary at 4:59:45 might not yet be visible on the replica at 5:00:01. If you save `5:00:00` as your new watermark, that row falls between the cracks permanently — the next run starts from `5:00:00` and never re-reads the window where that row was missing.

The duplicates you're seeing come from the opposite direction: if you're appending instead of merging, re-read rows create duplicate entries.

## How to size the lag buffer

1. Query your Postgres primary for `pg_stat_replication.replay_lag` over 7 days
2. Find the P99 (99th percentile value — the lag you see 99% of the time)
3. Double it as a safety margin for transient spikes
4. That's your `LAG_BUFFER`

A practical reference table:

| Observed P99 replica lag | Recommended LAG_BUFFER |
|---|---|
| < 5 minutes | 15 minutes |
| 5–15 minutes | 30 minutes |
| 15–60 minutes | 2 hours (and fix the replica) |
| > 1 hour | Replica is broken — don't sync until fixed |

For most healthy Postgres replicas, **15–30 minutes** is the right number.

## How to apply it in code

```python
from datetime import timedelta

LAG_BUFFER = timedelta(minutes=15)  # calibrate to your measured P99 replica lag

# Pull delta rows from Postgres (read replica)
new_rows = spark.read.jdbc(
    url=...,
    query=f"SELECT * FROM events WHERE updated_at > '{last_watermark}'"
)

# Write with MERGE — safe for re-reads (matched rows update in place, not duplicate)
new_rows.writeTo("iceberg.analytics.events").merge()

# Advance watermark with safety margin
max_ts = new_rows.agg({"updated_at": "max"}).collect()[0][0]
new_watermark = max_ts - LAG_BUFFER
write_watermark(new_watermark)
```

Two critical requirements:
- **Use MERGE INTO, not append** — MERGE makes overlapping re-reads safe; matched rows update in place rather than creating duplicates.
- **Index `updated_at` in Postgres** — without an index, every sync run will trigger a full-table scan.

## Why MERGE fixes duplicates

The lag buffer intentionally causes the next run to re-read a small overlap window. Without MERGE, those re-read rows get appended again as new records. With MERGE, rows that already exist in Iceberg are matched by primary key and updated in place — no duplicates.

## Key takeaway

Buffer size = P99 replica lag × 2, typically 15–30 minutes. Pair it with MERGE INTO writes. The overlap this creates is intentional, safe, and prevents the "disappearing row" problem from replication lag.

**Resources cited:** `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md` (lines 245–268)
