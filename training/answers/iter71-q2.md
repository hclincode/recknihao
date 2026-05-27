# Iter71 Q2 — Answer

**Question**: We're doing our first-ever sync of a large Postgres table into Iceberg. The table has around 500 million rows and is roughly 800 GB. We've been doing incremental syncs fine for smaller tables, but this is the first time we need to do the full initial copy of something this big.

The obvious approach — just read the whole table with Spark JDBC in one shot — feels like it's going to OOM our Spark cluster or just take forever. I also don't know what happens if the job crashes halfway through: does Iceberg end up with partial data that looks like a complete table, or is it smart enough to only show a complete snapshot once the whole load is done?

What's the right way to approach a load this big? I'm thinking there has to be some way to split the Postgres read into chunks so we're not pulling 800 GB into memory at once. And ideally if the job dies partway through I don't want to start from scratch — is there a way to make it resumable so we only re-read the chunks that didn't finish?

---

## Answer

All three of your concerns are solvable with existing Spark + Iceberg features. Let me walk through each.

### Part (a): Parallelizing the Postgres read to avoid OOM

Spark JDBC has built-in partitioned reading. You tell it how to split the table into independent numeric ranges, each read by a separate Spark task in parallel:

```python
df = spark.read.format("jdbc") \
    .option("url", "jdbc:postgresql://pg-primary:5432/app") \
    .option("dbtable", "public.large_table") \
    .option("user", PG_USER) \
    .option("password", PG_PASS) \
    .option("partitionColumn", "id") \
    .option("lowerBound", 1) \
    .option("upperBound", 500_000_000) \
    .option("numPartitions", 32) \
    .option("fetchsize", "10000") \
    .load()
```

What each option does:
- **`partitionColumn`**: the column Spark uses to split the table. Must be numeric; your primary key (`id`) is ideal.
- **`lowerBound` / `upperBound`**: the numeric range. Spark divides this into `numPartitions` equal slices. Wrong bounds cause skew (uneven partitions), not data loss — set `upperBound` conservatively higher than the real max if you're unsure.
- **`numPartitions=32`**: 32 concurrent JDBC connections each pulling 1/32 of the table. Adjust based on cluster size — typical range is 16–64. More parallelism helps throughput but adds Postgres connection load.
- **`fetchsize=10000`**: this is the critical one. **By default, pgjdbc fetches ALL rows at once into memory (`fetchsize=0`) before Spark can process them.** A single executor pulling 500M rows at `fetchsize=0` will OOM before it reads a single Spark partition. Setting `fetchsize=10000` streams 10K rows per round-trip, keeping executor heap bounded.

### Part (b): What happens if the job crashes halfway?

Iceberg uses **atomic snapshots** — a snapshot is a point-in-time version of the table's metadata pointing to which data files exist.

Here's the timeline during your Spark write:

1. Spark reads chunks from Postgres and writes Parquet files to MinIO.
2. Only after ALL Parquet files are written and checksummed does Spark attempt to **commit** — writing a new snapshot to the Hive Metastore.
3. If the job crashes *before* the commit, the written Parquet files are orphaned in MinIO and **Iceberg never sees them**. Queries read the old snapshot unchanged. No partial data is ever visible.
4. If the commit succeeds, readers see a complete new snapshot with all newly-written files atomically.

**Bottom line: Iceberg guarantees readers never see partial data.** They see either the old complete snapshot or the new complete snapshot, never an in-between state. A crashed job leaves orphaned Parquet files in MinIO that you clean up with `CALL iceberg.system.remove_orphan_files(...)` — but from a query perspective the table is always consistent.

### Part (c): Making the load resumable

For 800 GB you want to avoid restarting from zero. The recommended pattern is batching with `overwritePartitions()`.

**Recommended approach: batched load by ID range**

Split the load into smaller batches (e.g., 10 batches of 50M rows each). Each batch is a separate idempotent Spark job. If batch 7 fails, only batch 7 reruns:

```python
# Parameterize the job: spark-submit load.py --batch_start 300000000 --batch_end 350000000
batch_start = int(args.batch_start)
batch_end = int(args.batch_end)

df = spark.read.format("jdbc") \
    .option("url", "jdbc:postgresql://pg-primary:5432/app") \
    .option("dbtable", f"(SELECT * FROM large_table WHERE id >= {batch_start} AND id < {batch_end}) t") \
    .option("user", PG_USER) \
    .option("password", PG_PASS) \
    .option("partitionColumn", "id") \
    .option("lowerBound", batch_start) \
    .option("upperBound", batch_end) \
    .option("numPartitions", 8) \
    .option("fetchsize", "10000") \
    .load()

df.writeTo("iceberg.analytics.large_table").append()
```

Run 10 of these as separate Kubernetes Jobs or Airflow tasks. If job 7 fails, Airflow retries only job 7. Jobs 1–6 are already in Iceberg. The whole load is 60% done before you notice job 7 failed.

**Alternative: MERGE INTO for full idempotency**

If you'd rather run the entire load as one job that's safe to re-run without creating duplicates, use MERGE INTO:

```python
df = spark.read.format("jdbc") \
    .option("url", "jdbc:postgresql://pg-primary:5432/app") \
    .option("dbtable", "public.large_table") \
    .option("partitionColumn", "id") \
    .option("lowerBound", 1) \
    .option("upperBound", 500_000_000) \
    .option("numPartitions", 32) \
    .option("fetchsize", "10000") \
    .load()

df.createOrReplaceTempView("large_table_batch")

spark.sql("""
    MERGE INTO iceberg.analytics.large_table t
    USING large_table_batch s ON t.id = s.id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

Re-running the full job is safe: rows already in Iceberg match on `id` and UPDATE in place with identical values (no change). New rows INSERT. The result is the same regardless of how many times you run it.

The tradeoff: MERGE INTO on 500M rows is slower than a batched append because it must compare every source row against every target row. For a one-time historical load, the batching approach is usually faster.

### Summary

| Concern | Solution |
|---|---|
| OOM on 800 GB read | `numPartitions=32` + `fetchsize=10000` — 32 parallel JDBC connections, streaming 10K rows at a time |
| Partial data visible if job crashes | Iceberg atomicity — readers see old snapshot until full commit succeeds; no partial state visible |
| Resumability without restarting from zero | Batch by ID range (10 × 50M batches, each independently retryable) or MERGE INTO (idempotent full re-run) |

For a one-time 500M-row historical load, the recommended path is: **batched append** (10 batches, each as a separate Kubernetes Job with `fetchsize=10000` and `numPartitions=8`). Each batch completes in reasonable time, failures are cheap to retry, and Iceberg's atomicity ensures the table is always in a consistent state for anyone querying it during the load.
