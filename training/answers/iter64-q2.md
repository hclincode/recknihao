# Iter64 Q2 — Answer

**Question**: We have a Postgres table with about 500 million rows that we're pulling into Iceberg via a JDBC connector in Spark. Right now we do a full refresh — basically read the whole table and overwrite — and it takes over 4 hours. That's way too slow. Someone suggested we can parallelize the JDBC read using the `id` column, which is a bigint that's mostly sequential (auto-increment, with some gaps). How does parallelizing a JDBC read actually work? What parameters do we set in Spark to make it happen? And are there any gotchas we should know about — things that can go wrong or make it slower instead of faster?

---

## Answer

Yes, you can parallelize this. Four parameters tell Spark to split the read into concurrent JDBC connections. Done correctly, a 4-hour job typically drops to 20–40 minutes.

### How parallel JDBC reads work

Without the parallelization parameters, Spark opens **one** JDBC connection and streams all 500M rows through it serially. With the parameters, Spark **divides your ID range into N equal strides and opens N parallel connections**, each reading its slice independently.

Example: with `numPartitions=16`, `lowerBound=0`, `upperBound=500_000_000`:
- Spark calculates stride = (500M - 0) / 16 = ~31.25M IDs per partition
- It issues 16 concurrent queries: `WHERE id >= 0 AND id < 31_250_000`, `WHERE id >= 31_250_000 AND id < 62_500_000`, …
- Each query runs on a separate Spark executor in parallel
- All 16 slices stream concurrently to Spark workers

**Critical**: these bounds are parallelization hints, not data filters. Every row in your table is returned regardless. Rows with IDs below `lowerBound` go into the first partition; rows above `upperBound` go into the last. Nothing is dropped — just unevenly distributed.

### The four parameters

```python
PG_PROPS = {
    "user": PG_USER,
    "password": PG_PASS,
    "driver": "org.postgresql.Driver",
    "pushDownPredicate": "true",
    "fetchsize": "10000",
}

# Estimate bounds from the actual table before reading
bounds = spark.read.format("jdbc") \
    .option("url", PG_URL) \
    .option("dbtable", "(SELECT MIN(id) AS lo, MAX(id) AS hi FROM public.events) t") \
    .options(**PG_PROPS).load().collect()[0]

df = spark.read.format("jdbc") \
    .option("url", PG_URL) \
    .option("dbtable", "(SELECT * FROM public.events) t") \
    .option("partitionColumn", "id") \
    .option("lowerBound", bounds.lo) \
    .option("upperBound", bounds.hi) \
    .option("numPartitions", 16) \
    .options(**PG_PROPS) \
    .load()

df.writeTo("iceberg.analytics.events").using("iceberg").createOrReplace()
```

**`partitionColumn`**: The column to split on. Must be numeric (int, bigint) or date. Your auto-increment `id` is ideal — it's indexed, monotonically increasing, and evenly distributed enough to produce balanced partitions. Don't use UUIDs or non-numeric columns.

**`lowerBound` / `upperBound`**: The range Spark uses to calculate strides. Query `MIN(id)` and `MAX(id)` from Postgres once before the main read to get accurate values. Wrong bounds cause skew (one partition reads most of the data), not data loss.

**`numPartitions`**: How many parallel slices — and how many simultaneous JDBC connections to Postgres. Start with 16. Tune based on:
- Spark executor count (aim for 1–2 partitions per executor)
- Postgres connection limit — each partition holds one connection; keep `numPartitions` well below `max_connections` (typically 100–200)

**`fetchsize`** (in JDBC properties): pgjdbc defaults to very few rows per network round-trip. Set `"fetchsize": "10000"` to batch 10,000 rows per round-trip instead. This alone often cuts job time in half.

**`pushDownPredicate=true`** (in JDBC properties): ensures WHERE clauses execute on Postgres, not Spark. Without it, Spark may pull all 500M rows before applying any filter — defeating parallelization if your JDBC subquery has a WHERE clause.

### Gotchas that can make it slower

**Partition skew from bad bounds.** If `upperBound` is much lower than your real max ID, the last partition's query covers an enormous range and does most of the work. Symptom: 15 tasks finish in 2 minutes, then 1 task runs for 30+ minutes. Fix: always query `MAX(id)` dynamically before the read — don't hardcode a stale value.

**Large gaps in sequential IDs causing skew.** If your IDs have a big jump (e.g., 1 to 1,000 then 5,000,000 to 6,000,000), many partitions in the gap will read zero rows while partitions covering the dense range are overloaded. Fix: use a date column (e.g., `occurred_at`) as the `partitionColumn` instead, with date-based bounds. Date columns produce naturally balanced partitions for event tables.

**Too many partitions → Postgres connection exhaustion.** Setting `numPartitions=128` on a Postgres with `max_connections=100` causes the job to fail with connection errors. Keep `numPartitions` ≤ 32 for most setups; check your Postgres `SHOW max_connections` before tuning higher.

**Low fetchsize.** If you forget to set `fetchsize`, pgjdbc uses its default (often 10–50 rows). On 500M rows, this creates millions of network round-trips. The job completes but takes 3–4 hours instead of 30 minutes. Postgres CPU is high and the Spark executors are mostly idle waiting for data.

**Executor memory exhaustion from high fetchsize.** Conversely, setting `fetchsize=500000` on wide rows (5+ KB each) can exhaust executor heap. Start at 10,000 and increase only if memory metrics show significant headroom.

### Expected results

| Configuration | Estimated time |
|---|---|
| No parallelization (current) | 4+ hours |
| `numPartitions=8`, `fetchsize=10000` | ~60–90 minutes |
| `numPartitions=16`, `fetchsize=10000` | ~25–40 minutes |
| `numPartitions=32`, `fetchsize=10000` | ~15–25 minutes (Postgres connection limit permitting) |

Actual speedup depends on your Postgres hardware, Spark cluster size, and network bandwidth. Measure your first few runs with Spark UI open — check that task completion times are roughly equal (no one partition taking 10× longer than the others). Unequal times = skew = tune your bounds.
