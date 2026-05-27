# Iter81 Q2 — Answer

**Question**: Initial full-load of a 200M-row Postgres table into Iceberg. Why does naive JDBC read cause OOM? How to configure safely? Can you parallelize? How to resume after a crash?

---

## Answer

Your teammate is right — the naive approach will crash. But the fix is straightforward once you understand why it fails.

### Why it crashes: the JDBC fetchsize trap

When you read from Postgres via JDBC without configuration, two problems stack up:

**Problem 1: No parallelism.** By default, Spark opens a single JDBC connection and sends one task to read the entire table sequentially. All 200M rows funnel through one Spark executor — no distributed reads, no multi-worker split.

**Problem 2: fetchsize defaults to 0.** The pgjdbc driver (which Spark uses for Postgres) interprets `fetchsize=0` as "fetch all rows at once into memory." For a 200M-row table, that means one executor tries to buffer potentially terabytes of data in heap — and OOM crashes before it reads even a third of the table.

Spark doesn't "stream data in chunks" automatically with JDBC. It does with file-based sources (Parquet, CSV), but JDBC is different: the chunking only happens if you explicitly configure it.

### The fix: three settings together

```python
df = (spark.read.format("jdbc")
    .option("url", "jdbc:postgresql://pg-primary:5432/app")
    .option("dbtable", "(SELECT * FROM events) t")
    .option("user", PG_USER)
    .option("password", PG_PASS)
    .option("partitionColumn", "id")        # Split by this column
    .option("lowerBound", "0")              # Lower bound of range
    .option("upperBound", "1000000000")     # Upper bound (overestimate is fine)
    .option("numPartitions", "16")          # 16 parallel JDBC connections
    .option("fetchsize", "10000")           # Fetch 10K rows per round-trip
    .option("pushDownPredicate", "true")
    .load()
)
```

**`partitionColumn` + `lowerBound` + `upperBound` + `numPartitions`:** Spark divides the ID range into 16 equal slices and opens 16 parallel JDBC connections — one per Spark task. Each worker reads its slice independently. Getting `upperBound` wrong (too low) causes partition skew (one task gets more rows) but not data loss; out-of-range rows fold into the boundary partitions.

**`fetchsize=10000`:** Tells pgjdbc to retrieve 10,000 rows per round-trip instead of all at once. This keeps memory usage flat regardless of table size — the critical memory safety valve for large tables.

**`pushDownPredicate=true`:** Ensures `WHERE` filters (date ranges, watermarks) execute on Postgres and only matching rows are sent to Spark. Without this, some driver versions pull every row and filter in-memory.

### Can you parallelize? Yes — and how much

Setting `numPartitions=16` gives you 16 parallel JDBC readers. For 200M rows this is reasonable. Higher values (32, 64) give more parallelism but also more concurrent connections on Postgres — check your Postgres `max_connections` setting before going above 32.

The `partitionColumn` must be numeric (or date-castable) and reasonably uniform. A sequential `id` column works well. Avoid columns with skewed distributions (e.g., a `tenant_id` where one tenant has 90% of rows) — that creates partition skew.

### How to resume if the job crashes at 80%

The crash recovery strategy depends on how you write to Iceberg.

**Dangerous approach: `.append()`** — not idempotent. If the job crashes at 80% and you re-run it, the 80% that wrote before the crash gets written again. You now have duplicate rows with no clean way to remove them.

**Safe approach: `overwritePartitions()` with a date-scoped batch**

Structure the migration as a loop of daily (or weekly) batches, each using `overwritePartitions()`:

```python
batch_date = "2023-01-15"  # loop over each date in range

df = (spark.read.format("jdbc")
    .option("url", PG_URL)
    .option("dbtable",
        f"(SELECT * FROM events WHERE DATE(created_at) = '{batch_date}') t")
    .option("user", PG_USER).option("password", PG_PASS)
    .option("partitionColumn", "id")
    .option("lowerBound", "0").option("upperBound", "1000000000")
    .option("numPartitions", "16")
    .option("fetchsize", "10000")
    .load()
)

df.writeTo("iceberg.analytics.events").overwritePartitions()
```

If the job crashes on January 15th, re-run it with `batch_date = "2023-01-15"` — `overwritePartitions()` replaces that day's partition in Iceberg with the re-read data, exactly once, with no duplicates. You never start over from scratch; you just retry the failed date.

This is idempotent: running the same date 10 times produces the same result as running it once.

### Migration checklist for 200M rows

1. **Estimate row count per day** — `SELECT DATE(created_at), COUNT(*) FROM events GROUP BY 1 ORDER BY 1`. If any day has >20M rows, split into weekly batches.
2. **Set `fetchsize=10000`** and `numPartitions=16` — non-negotiable for a table this size.
3. **Use `overwritePartitions()` with a date loop** — gives you free crash recovery.
4. **Run during off-hours** — a full historical load stresses both Postgres (read load) and Spark (write load). Don't do it during peak application traffic.
5. **After migration completes**, switch to incremental loads using `updated_at` watermark + `append()` or MERGE INTO for ongoing sync.
