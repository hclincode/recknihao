# Iter62 Q2 — Answer

**Question**: We're running Iceberg on MinIO and I just learned that Iceberg keeps old "snapshots" around so you can do time-travel queries. That sounds useful, but I'm worried about storage costs. Right now we have maybe 200GB of active data, but we're writing new events every hour. How much extra storage do those old snapshots actually add — is it like 2x your data size, or more like 10%? And how do I know when it's safe to expire them without breaking anything? We have a few dashboards that query "last 7 days" but nothing that explicitly does historical rollback.

---

## Answer

Snapshots themselves are cheap — it's the data files they pin that cost you. Without maintenance, the overhead is roughly **30% of active data per year** (you'd go from 200 GB to ~260 GB in 12 months). With weekly expiration set to 30-day retention, the overhead drops to a few percent. Your use case makes aggressive expiration safe.

### What a snapshot actually stores

An Iceberg snapshot is a metadata record — a manifest list pointing to manifest files, which in turn list data file paths and their statistics. The snapshot itself is a few KB to a few MB of JSON/Avro. That's not the cost.

The cost is the **data files that old snapshots pin in place**. Iceberg will never delete a data file that any live snapshot references, even if that file has been superseded by compaction. So:

- **Hour 0**: Write 100 MB of events → 1 data file + snapshot S1 referencing it.
- **Hour 1**: Write another 100 MB → 1 more data file + snapshot S2 referencing both files.
- **Night**: Compaction runs. Merges 24 small hourly files into 1 large 2.4 GB file. Creates snapshot S25 pointing to the big file.
- **But**: The 24 old small files (2.4 GB total) are still on MinIO because snapshots S1–S24 still reference them.

After compaction, you're holding **twice the data** until you expire the old snapshots. This is why compaction temporarily increases storage before expiration cleans it up.

### The numbers for your 200 GB table

Without any expiration, old data files accumulate indefinitely. Typical overhead over 12 months with hourly writes and weekly compaction: **25–30% extra storage** = 50–60 GB of pinned-but-replaced files for your 200 GB table.

With 30-day retention (the recommended setting): Iceberg can delete files that only the expired snapshots referenced. At 30-day retention, overhead is typically **2–8% of active data** = 4–16 GB for your table.

It's not "2x your data size." The compaction cycle keeps active data files efficiently sized. The snapshot overhead is primarily the window of time between when files are replaced and when old snapshots expire.

### Is it safe to expire snapshots in your case?

Yes, and the reasoning is straightforward:

**Your dashboards query "last 7 days."** They never ask for data from two weeks ago via `AS OF` syntax — they just filter by a date column. That's not time-travel; that's a normal WHERE clause. Those queries work the same regardless of snapshot history.

**You have no explicit time-travel queries.** Time-travel requires `SELECT * FROM events FOR SYSTEM_TIME AS OF TIMESTAMP '...'`. You're not using that. So you don't need to keep old snapshot metadata for query compatibility.

**Your only real rollback need** is "a bad ingestion job wrote bad data." Iceberg's `rollback_to_snapshot()` lets you undo this — but only if the good snapshot (from before the bad write) is still alive. Keeping 7–30 days of snapshots covers any incident where you'd realistically notice a data problem and need to rollback.

### The expiration procedure

Run in Spark (not Trino — these CALL statements use Spark SQL syntax for the Iceberg catalog):

```python
# In your Spark job or spark-sql shell
spark.sql("""
  CALL iceberg.system.expire_snapshots(
    table       => 'analytics.events',
    older_than  => current_timestamp - interval 30 days,
    retain_last => 10
  )
""")
```

`older_than` and `retain_last` work together: Iceberg expires anything older than 30 days, but always keeps at least the 10 most recent snapshots regardless of their age. For your hourly writes, you'll usually keep roughly 10 hours of snapshots from `retain_last`, plus everything in the last 30 days — giving you a comfortable rollback window.

### Critical: run compaction before expiration

The order matters each week:

1. **Compaction first** (nightly recommended, after your hourly ingestion window):
   ```python
   spark.sql("""
     CALL iceberg.system.rewrite_data_files(
       table   => 'analytics.events',
       options => map(
         'target-file-size-bytes', '268435456',
         'min-input-files', '5'
       )
     )
   """)
   ```

2. **Expiration after** (weekly, e.g., Sunday morning):
   ```python
   spark.sql("""
     CALL iceberg.system.expire_snapshots(
       table       => 'analytics.events',
       older_than  => current_timestamp - interval 30 days,
       retain_last => 10
     )
   """)
   ```

If you reverse the order: compaction creates new consolidated files but the old small files are still pinned by recent snapshots. Expiration needs the old snapshots to age out before it can release the old files. Running expiration before compaction is not wrong, but you're not freeing as much space per cycle.

### What you'll see on MinIO

- **Day 1 after compaction**: Storage goes slightly UP (new big files + old small files still there). This is normal.
- **Day after expiration**: Storage goes DOWN noticeably (old small files deleted — they were the only references remaining).
- **Steady state**: Storage roughly tracks your active data size × ~1.05–1.08 (5–8% overhead at 30-day retention).

### Recommended settings for your setup

| Setting | Value | Rationale |
|---|---|---|
| `older_than` | 30 days | Covers rollback window; longer than dashboard lookback |
| `retain_last` | 10 | Safety net for quiet periods or recently-written snapshots |
| Compaction cadence | Nightly | Keeps file sizes healthy for hourly writes |
| Expiration cadence | Weekly | Releases storage from the past week's compactions |

If storage becomes a concern, drop `older_than` to 7 days — safe for your use case since your dashboards only need 7 days of data and you have no time-travel queries.
