# Column-Oriented Storage: What It Is and Why Analytics Is Faster

> **Production note:** Your stack uses Iceberg tables stored as Parquet files in MinIO, queried by Trino. Parquet is a columnar file format — every concept in this document applies directly to the files sitting in your MinIO buckets right now.

---

## Quick answer

1. **Layout.** Columnar storage puts all values of one column together on disk, instead of all columns of one row together.
2. **I/O reduction.** A query that touches 3 of 20 columns reads ~15% of the table instead of 100%.
3. **Compression.** Same-type values next to each other compress dramatically (RLE, dictionary encoding, delta, bit-packing) — usually 5-30x smaller, which directly speeds up queries because less data is read from MinIO.
4. **Vectorized execution + SIMD.** Engines process batches of 1,024–4,096 column values per operator call (vectorized batch model, software), and within each batch, the CPU executes 8–16 arithmetic operations per clock cycle (SIMD, hardware). These two layers work together to make aggregations over billions of rows fast.
5. **Trade-off.** Single-row reads and inserts are slow on columnar — which is why Postgres stays row-oriented for the app and Iceberg + Trino is columnar for analytics.

---

## Concept in one sentence

**Columnar (column-oriented) storage** keeps all values of a single column together on disk, rather than keeping all columns of a row together — which makes reading a few columns across millions of rows dramatically faster.

---

## Why it matters for SaaS

When you add an OLAP system or data warehouse to your stack, you'll encounter this term immediately — Trino, Iceberg/Parquet, BigQuery, Snowflake, ClickHouse, and DuckDB all rely on columnar storage. Understanding *why* it's fast helps you write better queries, choose the right tool, and explain to your team why a warehouse query that scans billions of rows finishes in seconds while the same query on Postgres would never finish.

---

## The toy table we'll use throughout

Imagine a tiny `user_events` table — just 5 columns, 4 rows. We'll trace exactly how the bytes land on disk in each storage style, then show why a real analytical query touches very different amounts of data depending on the layout.

| id | user_id | event_name | timestamp           | revenue |
|----|---------|------------|---------------------|---------|
| 1  | 101     | page_view  | 2024-01-01 10:00:00 | 0       |
| 2  | 102     | purchase   | 2024-01-01 10:05:00 | 49      |
| 3  | 101     | page_view  | 2024-01-02 09:00:00 | 0       |
| 4  | 103     | purchase   | 2024-01-02 11:30:00 | 99      |

---

## Before: row-oriented layout (Postgres, MySQL, your app DB)

Row-oriented databases store each row as one contiguous chunk of bytes. Conceptually, the disk looks like this:

```
DISK BLOCK 1
+------------------------------------------------------------------+
| [ 1 | 101 | page_view | 2024-01-01 10:00:00 | 0  ]  <- row 1     |
| [ 2 | 102 | purchase  | 2024-01-01 10:05:00 | 49 ]  <- row 2     |
| [ 3 | 101 | page_view | 2024-01-02 09:00:00 | 0  ]  <- row 3     |
| [ 4 | 103 | purchase  | 2024-01-02 11:30:00 | 99 ]  <- row 4     |
+------------------------------------------------------------------+
```

If you ask: "give me row id = 3", the database jumps to one location and reads one row. Fast.

If you ask: "sum the revenue across all rows", the database must still read every byte of every row — including `event_name`, `timestamp`, and `user_id` — because those columns are physically interleaved between the `revenue` values.

---

## After: column-oriented layout (Parquet, ClickHouse, BigQuery)

Columnar storage flips the picture. All values of one column are stored together in their own region on disk:

```
COLUMN: id
+-----------------+
| 1 | 2 | 3 | 4   |   <- one contiguous strip of bytes
+-----------------+

COLUMN: user_id
+---------------------+
| 101 | 102 | 101 | 103 |
+---------------------+

COLUMN: event_name
+-----------------------------------------------+
| page_view | purchase | page_view | purchase   |
+-----------------------------------------------+

COLUMN: timestamp
+-----------------------------------------------------------------------+
| 2024-01-01 10:00:00 | 2024-01-01 10:05:00 | 2024-01-02 09:00:00 | ...  |
+-----------------------------------------------------------------------+

COLUMN: revenue
+----------------+
| 0 | 49 | 0 | 99|   <- a single contiguous strip
+----------------+
```

Same 20 cells of data. Completely different physical arrangement.

---

## The query: `SELECT SUM(revenue) FROM user_events WHERE timestamp >= '2024-01-02'`

Now watch what each layout has to read:

### Row layout
Must walk every row, byte by byte:

```
[ 1 | 101 | page_view | 2024-01-01 10:00:00 | 0  ]   read all 5 fields
[ 2 | 102 | purchase  | 2024-01-01 10:05:00 | 49 ]   read all 5 fields
[ 3 | 101 | page_view | 2024-01-02 09:00:00 | 0  ]   read all 5 fields
[ 4 | 103 | purchase  | 2024-01-02 11:30:00 | 99 ]   read all 5 fields
```

Total bytes touched: 100% of the table. The engine has no choice — it can't skip `event_name` because `event_name` and `revenue` are physically next to each other on disk.

### Column layout
Reads only the strips it needs:

```
timestamp strip:  [2024-01-01..., 2024-01-01..., 2024-01-02..., 2024-01-02...]   <- read
revenue strip:    [0, 49, 0, 99]                                                  <- read
id strip:                                                                          <- SKIPPED
user_id strip:                                                                     <- SKIPPED
event_name strip:                                                                  <- SKIPPED
```

Total bytes touched: 2 out of 5 columns = 40% of the table — and only the rows in those columns that pass the filter.

At 4 rows the difference is small. At 4 billion rows in your `user_events` Iceberg table on MinIO, this is the difference between a query finishing in 3 seconds and never finishing.

---

## Compression: the second multiplier

Once values of the same type and similar pattern are stored together, they compress incredibly well. Columnar formats like Parquet apply compression *per column*, picking a different algorithm for each column based on what's in it. Two of the most common techniques you'll hear about:

### 1. Run-length encoding (RLE)

**The idea:** instead of repeating a value, store the value once and a count of how many times it repeats.

**Example from our table:**

The `event_name` column has values:
```
[page_view, purchase, page_view, purchase]
```

Now imagine the realistic case where the data is sorted or clustered by event type — perhaps a partition where 10,000 rows in a row all have `event_name = "page_view"`:

```
Uncompressed: [page_view, page_view, page_view, ... 10,000 times ...]
RLE-encoded:  (page_view, 10000)
```

That's 10,000 string values collapsed into one string plus one integer. The whole column might fit in a few hundred bytes instead of hundreds of kilobytes.

This is why Parquet/Iceberg tables stored *sorted* on a low-cardinality column (like `event_type` or `country`) are so much smaller and faster than the same data shuffled randomly.

### 2. Dictionary encoding

**The idea:** if a column has only a few distinct values that repeat, build a tiny lookup table mapping each value to a small integer, then store the small integers instead of the original values.

**Example from our table:**

The `event_name` column has only 2 distinct values across all rows: `page_view` and `purchase`. A dictionary encoder builds this:

```
Dictionary:
  0 -> "page_view"
  1 -> "purchase"

Stored column:
  [0, 1, 0, 1]
```

Now instead of storing four strings averaging ~10 bytes each (40 bytes), you store 4 tiny integers (often packed into 4 bits each = 2 bytes total) plus a one-time 20-byte dictionary. The savings explode when you have 10 million rows and only 5 distinct event types: storing 10M integers using 3 bits each = ~3.7 MB, versus storing 10M ten-byte strings = ~100 MB.

Parquet uses dictionary encoding *by default* for low-cardinality string columns, which is exactly why your Iceberg tables in MinIO are so much smaller than the raw JSON or CSV equivalent.

### Other compressions you'll see

| Technique | What it does | Best for |
|---|---|---|
| **Bit-packing** | Stores small integers in fewer bits than a full byte | Integer columns with limited range |
| **Delta encoding** | Stores differences between adjacent values | Sorted timestamps, sequential IDs |
| **Snappy / Zstd / Gzip** | General-purpose byte compression applied on top | Default block compression in Parquet |

---

## How compression makes queries faster (not just smaller)

This is the key insight beginners miss: **compression isn't just about saving disk space — it directly speeds up queries.**

The chain of cause and effect:

```
1. Compressed columns are physically smaller on disk.
2. Reading from disk (or from MinIO over the network) is the slowest step in a query.
3. Fewer bytes to read = fewer I/O operations = the query gets data faster.
4. Fast codecs (Snappy, LZ4, Zstd) decompress data faster than disk can deliver it,
   so decompression is rarely the bottleneck — but it does consume CPU cycles. The
   practical effect is that compressed data arrives at the CPU faster than uncompressed
   data would, even accounting for decompression work. On CPU-constrained pipelines or
   heavily loaded Trino clusters, decompression overhead can be measurable.
5. In many cases the engine can even operate on the compressed form directly
   (e.g., count occurrences in an RLE-encoded column without expanding it).
```

A concrete way to think about it: if your `event_name` column would have been 100 MB uncompressed and is 3 MB after dictionary + RLE + Snappy, then a query scanning that column reads ~33x less data from MinIO. Even before any clever query optimization, the query is already roughly 33x faster on that step alone.

This is why "columnar storage is fast" and "columnar storage compresses well" are really the same statement — compression *is* the speedup.

---

## How Trino reads Parquet (the file-skipping bridge)

The speedup from columnar storage is only half the story. The other half is that Trino, with help from Iceberg, learns to skip entire files it doesn't need to open. Here's the chain:

### Layer 1: Parquet row groups and column statistics

Every Parquet file is internally divided into **row groups** (typically ~128 MB each). For every column inside every row group, the Parquet writer stores small **statistics**: `min`, `max`, `null_count`, and (sometimes) a Bloom filter.

Example: a row group in `user_events_2026_01_15.parquet` might have these stats for the `event_time` column:
```
min = 2026-01-15 00:00:00
max = 2026-01-15 23:59:59
null_count = 0
```

If a query has `WHERE event_time >= '2026-02-01'`, Trino reads only those stats (a few bytes), sees the row group's max is before Feb 1, and **skips the entire 128 MB row group without reading it**.

### Layer 2: Iceberg file-level statistics (manifest files)

Iceberg goes one level higher. It maintains **manifest files** — small index files listing every data file in the table along with per-column min/max stats *aggregated across the whole file*.

When Trino plans a query, it first reads the manifest. For a query filtering on Jan 15, the manifest might say "out of 5,000 Parquet files in this table, only 1 file has `event_time` overlapping Jan 15." Trino now knows to open exactly 1 file instead of listing all 5,000.

### Layer 3: Trino's predicate pushdown

When Trino opens the file, it pushes the `WHERE` clause down into the Parquet reader. The reader uses the row-group stats from Layer 1 to skip row groups, then dictionary-decodes only the columns the query asked for.

### The full skipping cascade

```
Query: SELECT SUM(revenue) FROM user_events
       WHERE event_time >= '2026-01-15' AND event_time < '2026-01-16'

1. Trino reads Iceberg manifest -> 5,000 files exist, 1 is in range. Skip 4,999 files.
2. Open that 1 file. It has 8 row groups. 1 row group's min/max overlaps.
3. Skip 7 row groups via Parquet stats. Read the 1 matching row group.
4. From that row group, read only `event_time` and `revenue` columns. Ignore the other 18.
5. SIMD-sum the revenue values.
```

The query that looked like "scan a 5 TB table" actually touched maybe 50 MB. That's the real reason Trino + Iceberg + Parquet is fast — and it only works because the storage is columnar with per-column statistics.

---

## Why GROUP BY can trigger a full table scan

This is one of the most common production surprises on Trino + Iceberg: a query that used to finish in 2 seconds suddenly takes 30 seconds (or 15x slower) the moment you add `GROUP BY country`. The instinct is to blame the GROUP BY itself — high cardinality, shuffle cost, memory pressure for the hash table. On this stack, that's almost always wrong. **The real culprit is usually that the new query no longer benefits from file skipping.**

### The mechanism, in one paragraph

The file-skipping cascade described above (Iceberg manifest → Parquet column stats → predicate pushdown) only fires when there's a **WHERE predicate on a partitioned or sorted column**. Adding `GROUP BY <some_column>` does **not** add a WHERE clause — it just tells Trino how to bucket rows once they're already read. So if your previous query relied on an implicit filter to prune files (often a date filter you forgot to include explicitly), and you "simplified" the new query by dropping that filter while adding GROUP BY, you've quietly removed the only thing that was making the query fast. Trino now has to open every file in the table.

### EXPLAIN ANALYZE: file count before and after

The fastest way to confirm this is to look at the planner output. Compare two queries on the same `user_events` table partitioned by `(day(event_time), tenant_id)`:

**Fast query (good filter — uses partition pruning):**
```sql
EXPLAIN ANALYZE
SELECT country, COUNT(*) FROM user_events
WHERE event_time >= DATE '2026-05-01'
  AND event_time <  DATE '2026-05-08'
GROUP BY country;
```

Trino's output (illustrative — actual format varies by version):
```
ScanFilterProject[table = iceberg:analytics.user_events]
  ...
  Input: 14,200,000 rows (185 MB), Files: 7
  CPU: 1.2s, Wall: 1.8s
```

**Slow query (no filter, same GROUP BY):**
```sql
EXPLAIN ANALYZE
SELECT country, COUNT(*) FROM user_events
GROUP BY country;
```

Output:
```
ScanFilterProject[table = iceberg:analytics.user_events]
  ...
  Input: 2,840,000,000 rows (37 GB), Files: 4,860
  CPU: 28s, Wall: 27s
```

**The diff is the whole story.** The GROUP BY did not change. The data did not change. What changed is the `Files:` count — 7 files vs 4,860 files. That's a 700x scan amplification, and it accounts for essentially all of the slowdown. The aggregation work itself (hashing 150 country values into accumulators) is microseconds. The bottleneck is reading 37 GB from MinIO that the engine could have skipped.

### Why people get this wrong (and reach for the wrong fix)

The intuitive story — "GROUP BY is slow because the engine has to keep all the groups in memory and shuffle them between workers" — is true for *very* high-cardinality groupings (e.g., `GROUP BY user_id` over 50 million users). But for low-cardinality columns like `country` (~150 values), `plan_type` (3–5 values), or `event_name` (a few dozen values), the hash table and shuffle are essentially free.

Trino uses **two-phase aggregation** under the hood: each worker computes a partial hash aggregation locally (one tiny hash table per worker, keyed by `country`), then a final phase merges the partial results. For 150 country keys, each worker's partial table is well under a kilobyte, and the network shuffle between phases is a few KB total. That cost is invisible against the 37 GB MinIO read.

**The diagnostic mantra:** when a Trino query gets dramatically slower after a small SQL change, look at the `Files:` and input-bytes count in `EXPLAIN ANALYZE` first. The shuffle/memory story is almost never the answer on a well-partitioned Iceberg table — file skipping is.

### The fix — restore the partition filter

99% of the time the fix is to put the partition filter back:

```sql
-- Add back the date range you dropped.
SELECT country, COUNT(*) FROM user_events
WHERE event_time >= DATE '2026-05-01'
  AND event_time <  DATE '2026-05-08'
GROUP BY country;
```

If the dashboard genuinely needs all-time totals across all countries, the right answer is **not** to scan everything on every dashboard load — build a small rollup table (nightly Spark job or dbt model) keyed by `country` so the dashboard query reads a few hundred rows instead of 2.8 billion. See `09-lakehouse-schema-design.md` for the rollup-table pattern.

### Quick checklist when GROUP BY suddenly gets slow

1. Run `EXPLAIN ANALYZE` on the slow query and read the `Files:` and input-bytes line.
2. Compare to the previous fast version. If `Files:` jumped 100x+, file skipping is broken — partition filter is missing or the filter was on a non-partition column.
3. Confirm the column you're grouping by is **not** the cause: count its distinct values (`SELECT COUNT(DISTINCT country) FROM user_events`). If it's under ~10,000, two-phase aggregation handles it cheaply.
4. Add the partition filter back. Re-run `EXPLAIN ANALYZE` and confirm `Files:` drops back to the small number.
5. If you genuinely need an all-time aggregation, build a rollup table instead of scanning raw events.

---

## Vectorized execution (the third multiplier)

After reading less data and decompressing it, columnar engines process the values in a fundamentally different way than row-oriented databases. There are two distinct layers here that are often conflated — they work together, but they are different things.

> **Two distinct layers — always explain them separately:**
>
> - **Layer A — Vectorized batch processing (software):** The query engine (Trino) groups column values into batches of 1,024–4,096 and passes them to each operator as a chunk. This eliminates per-row function dispatch overhead. This is a query engine design choice.
> - **Layer B — SIMD (hardware):** The CPU executes the same arithmetic instruction on 8–16 values in a single clock cycle using wide registers (AVX-256, AVX-512). This is a CPU hardware feature.
> - **How they work together:** Vectorized batch execution feeds SIMD. Trino hands a contiguous array of column values to the CPU; SIMD processes 8–16 of them per instruction. Without Layer A, Layer B cannot operate at scale; without Layer B, Layer A is still faster than row-at-a-time but leaves hardware parallelism on the table.
>
> When explaining columnar speed to a beginner, always name both layers and distinguish them explicitly.

### Layer A: Vectorized batch model (software layer)

The query engine processes column values in **batches of 1,024–4,096 values per operator call**, instead of calling operator logic once per row.

In a row-at-a-time model, the engine's inner loop looks roughly like: "call the SUM function for row 1, call it again for row 2, call it again for row 3..." — each call has function-dispatch overhead and causes the CPU instruction pipeline to stall waiting for the next call to be set up. For 1 billion rows, that's 1 billion overhead events.

In a vectorized batch model, the engine instead calls the SUM operator once with a pointer to a contiguous array of 4,096 `revenue` values, the operator runs a tight inner loop over those values, then the engine calls again with the next 4,096. The per-call overhead shrinks from 1 per row to 1 per 4,096 rows. The CPU instruction pipeline stays full because the inner loop is a simple, predictable sequence.

**This is a software design choice.** Trino and DuckDB are built on this model. Spark adopted it via Project Tungsten and later the Photon engine.

### Layer B: SIMD instructions (hardware layer)

Within each batch, modern CPUs can execute **one instruction that operates on 8–16 values simultaneously** using wide registers. This is called SIMD — Single Instruction, Multiple Data.

For example, with AVX2 (a common x86 CPU feature), a single ADD instruction can add 8 pairs of 32-bit integers in one CPU clock cycle. Without SIMD, adding 8 pairs would require 8 separate instructions.

**This is a CPU hardware feature**, not an engine feature. The engine cannot choose to have SIMD — the CPU either has it or doesn't. Modern Intel and AMD server CPUs have had AVX2 since roughly 2013; AVX-512 (16 × 32-bit values per instruction) is common in current data-center hardware.

### How they work together

Vectorized batches and SIMD are complementary. The batch model (software) is what makes SIMD (hardware) effective at scale:

- The engine hands a batch of 4,096 contiguous, same-type column values to the CPU.
- The CPU's SIMD units operate on 8–16 of those values per clock cycle.
- The tight inner loop repeats until the full batch of 4,096 is processed.
- The engine then loads the next batch.

Without the batch design, SIMD would still exist but couldn't operate at scale — the per-row function-call overhead would dominate. Without SIMD, the batch loop is still faster than row-at-a-time processing, but it doesn't exploit the CPU's hardware parallelism within each iteration.

**The practical implication:** columnar databases get *much faster* on queries that touch large numbers of rows. That's the opposite of OLTP databases, which slow down as row counts grow.

---

## The trade-off: columnar is slow for single-row access

Columnar storage is the wrong choice when you need to:

- Read a single row by ID (`SELECT * FROM users WHERE id = 12345`)
- Insert one row at a time (your web app recording every HTTP request)
- Update individual fields frequently

For those operations, row storage wins. Fetching one row from a row store means reading one contiguous block. With columnar storage, that same fetch touches **different byte offsets within the same Parquet file** — one column chunk per column you select. All the columns of a single row group live inside one `.parquet` file; they are just laid out as separate, contiguous byte ranges (column chunks) within the file, not in separate files. The reader has to seek to each column chunk's offset, decode the row group's encoding/compression, and pick out the value at the target position for each column individually. For a wide table that's many small reads instead of one contiguous read, plus per-column decode cost — that overhead is why single-row lookups by primary key are 10–100x slower on columnar storage than on a row store with an index.

This is exactly why your SaaS product keeps a transactional database (Postgres/MySQL) for application traffic, and your Iceberg + Trino layer handles analytics. They are good at opposite things, by design.

### Iceberg mitigations when you DO need point lookups on a fact table

Sometimes you legitimately need a single-row or small-range lookup against your Iceberg table — debugging a customer issue ("show me event_id `abc123`"), powering a "view raw event" feature in your admin UI, or a low-frequency operational query. You can't make columnar as fast as Postgres for this, but you can avoid the worst case (full table scan). Two Iceberg-native features dramatically reduce the I/O for these queries:

**1. Bloom filter index on the lookup column.** A Bloom filter is a tiny probabilistic data structure (a few KB per row group) that answers "is this value possibly in this row group?" in microseconds without reading the column data. If the filter says no, Trino skips the entire row group. Configure per-column as an Iceberg table property:

```sql
-- Spark SQL (Trino does not expose write-side bloom-filter properties through SET PROPERTIES)
ALTER TABLE iceberg.analytics.user_events SET TBLPROPERTIES (
  'write.parquet.bloom-filter-enabled.column.event_id' = 'true',
  'write.parquet.bloom-filter-fpp.column.event_id'     = '0.01'
);
```

After this, every new Parquet file written embeds a Bloom filter for `event_id` in each row group. When Trino runs `WHERE event_id = 'abc123'`, the Parquet reader checks each row group's filter first; row groups whose filter rejects `'abc123'` are skipped entirely — no column data read. The typical speedup for equality lookups on non-partition columns is **10–100x** depending on selectivity. Bloom filters add ~1–5% to file size. **They apply only to NEW writes** — to retrofit, run `rewrite_data_files` (Spark) after enabling the property.

**2. Sort order on the lookup column.** Iceberg supports a per-table sort order that clusters rows within each Parquet file by the sort key. Combined with per-row-group min/max statistics (which every Parquet file already has), this lets Trino skip row groups whose `[min, max]` range doesn't include the target value:

```sql
-- Trino DDL — at table creation time
CREATE TABLE iceberg.analytics.user_events (
  event_id    VARCHAR,
  tenant_id   VARCHAR,
  occurred_at TIMESTAMP(6),
  ...
)
WITH (
  partitioning = ARRAY['day(occurred_at)', 'tenant_id'],
  sorted_by    = ARRAY['event_id ASC'],
  format       = 'PARQUET'
);

-- Or on an existing table:
ALTER TABLE iceberg.analytics.user_events
SET PROPERTIES sorted_by = ARRAY['event_id ASC'];
```

Without a sort order, `event_id` values are scattered randomly across every row group in every file — the row group min/max for `event_id` covers basically the full ID range, so the pruner can't skip anything. With `sorted_by = ARRAY['event_id ASC']`, each row group covers a tight slice of the ID space (e.g., row group 1 holds `event_id` in `[a000..., a127...]`, row group 2 holds `[a128..., a255...]`, etc.) — so a query for one specific ID hits exactly one row group instead of all of them. **Like bloom filters, sort order applies to NEW writes only** — to apply it to existing data, run Spark's `rewrite_data_files` with `strategy => 'sort'` (see `resources/10-lakehouse-partitioning.md` for the exact recipe).

**Combine both for maximum effect.** The two mechanisms complement each other: sort order narrows which row groups *could* contain the value (via min/max), and the Bloom filter eliminates false positives on row groups where the target falls inside the min/max range but isn't actually present.

**Caveat — these reduce I/O, not the columnar tax.** Even with both enabled, point lookups stay meaningfully slower than the same lookup against an indexed Postgres row store, because the columnar layout still pays the per-column-chunk seek cost for every column you `SELECT`. The mitigations are for "make occasional point lookups tolerable" (sub-second instead of multi-second), not "replace your OLTP database." If you find yourself doing thousands of point lookups per second against an Iceberg table, that workload belongs in Postgres or a key-value store, not in the lakehouse.

---

## The complete production-stack chain (Spark / Iceberg / Trino / Parquet)

All the mechanisms in this document chain together in your production stack. Here is what actually happens when Trino executes `SELECT SUM(revenue) FROM user_events WHERE event_time >= '2026-05-01'` on MinIO:

```
Step 1 — Iceberg manifest pruning (file planning time)
  Trino reads Iceberg's manifest files (small index files, not data files).
  Each manifest entry records the min/max of event_time per Parquet file.
  Files whose event_time range does not overlap May 2026 are eliminated entirely.
  Result: of 5,000 Parquet files, Trino plans to open 31.

Step 2 — Columnar file layout (I/O time)
  Trino opens those 31 Parquet files and reads only the column chunks for
  event_time and revenue — skipping the bytes for every other column on disk.
  The other columns are not read from MinIO at all.

Step 3 — Row-group pruning via Parquet min/max statistics (I/O time)
  Inside each Parquet file, Trino reads per-row-group column statistics.
  Row groups whose event_time range falls entirely outside the WHERE range are
  skipped — no row data read from those row groups.

Step 4 — Decompression (CPU time)
  The selected column chunks (event_time and revenue) are decompressed using
  Snappy or Zstd. Fast codecs: decompression throughput typically exceeds the
  network read rate from MinIO, so this step rarely adds wall-clock time — but
  it does consume CPU cycles. On a loaded Trino cluster, factor this in.

Step 5 — Vectorized batch processing (CPU time)
  Trino passes the decompressed column values to its SUM operator in batches
  of 1,024–4,096 values per call. The operator runs a tight inner loop over
  each batch, keeping the CPU instruction pipeline full.

Step 6 — SIMD arithmetic (CPU time, inside each batch)
  Within each batch, the CPU executes AVX2/AVX-512 instructions that add
  8–16 revenue values per clock cycle. The 4,096-value batch is processed in
  ~256–512 CPU clock cycles instead of 4,096 separate ADD instructions.

Result: billions of rows summed in seconds.
```

**Where engineers actually see this in practice:**

- Add a `WHERE event_time >= DATE '2026-05-01'` and query time drops from minutes to seconds: that is Steps 1–3 (file and row-group pruning) in action.
- A query with no WHERE clause but touching only 2 of 20 columns is still meaningfully faster than the same query on Postgres: that is Step 2 (columnar I/O skip) plus Steps 5–6.
- A query that uses Snappy-compressed Parquet is faster to read off MinIO than an equivalent uncompressed CSV, even after paying decompression cost: that is the combined effect of Steps 2–4.

Understanding this chain tells you where to look when a query is slow: use `EXPLAIN ANALYZE` in Trino to find the `Files:` and input-bytes count. If the file count is unexpectedly high, the problem is in Steps 1–3 (partition filter missing or wrong). If the file count is correct but the query is still slow, the bottleneck is in Steps 4–6, which typically means CPU pressure or a very large column data volume after pruning.

---

## What this means when writing analytical queries

Columnar storage rewards *selecting fewer columns* and *filtering early*. Practical habits:

- **Avoid `SELECT *`** in analytical queries — you pay for every column you read. List only the columns you need.
- **Filter on partition columns first** (date ranges, tenant IDs) — Trino + Iceberg will skip entire files.
- **Wide tables are fine** in a columnar system — columns you don't query don't slow you down.
- **Sort or cluster on low-cardinality columns** at write time when possible — this maximizes RLE and dictionary compression.

---

## Where you'll encounter columnar storage

| System / Format | Notes |
|---|---|
| **Apache Parquet** | The columnar file format used by your Iceberg tables on MinIO. Open standard. |
| **Apache Iceberg** | A table format that organizes Parquet files; your production storage layer. |
| **Trino** | Query engine; reads Parquet's columnar layout efficiently. Your production query layer. |
| **ClickHouse** | Columnar database; MergeTree storage format. |
| **DuckDB** | Embedded analytics database; columnar in-memory and on-disk. |
| **BigQuery / Snowflake / Redshift** | Cloud warehouses, all columnar internally. |
| **Postgres / MySQL** | Row-oriented (OLTP default) — not columnar. |

If you see `.parquet` files in MinIO, you're looking at columnar storage on disk.

---

## Key terms defined

| Term | Plain meaning |
|---|---|
| **Columnar storage** | Storing all values for one column together rather than storing all columns for one row together. |
| **Row-oriented storage** | Storing all columns for each row together — how Postgres, MySQL work. |
| **I/O** | Input/Output — reading data from disk or over the network; reducing I/O is the main reason columnar is faster. |
| **Compression** | Shrinking data to take less space. Columnar enables better compression because similar values are adjacent. |
| **Run-length encoding (RLE)** | Compression that replaces repeated values with a single value + a count. E.g., `[A,A,A,A]` -> `(A, 4)`. |
| **Dictionary encoding** | Compression that maps each distinct value to a small integer, then stores the integers. Great for low-cardinality strings. |
| **Delta encoding** | Storing differences between adjacent values; great for sorted numbers/timestamps. |
| **Bit-packing** | Storing small integers in fewer bits than a full byte. |
| **Snappy / Zstd / Gzip** | General byte-compression algorithms applied on top of column encodings in Parquet. |
| **Vectorized execution (batch model)** | Software design where the query engine processes 1,024–4,096 column values per operator call instead of one row at a time. This is an engine design choice (Trino, DuckDB use it). |
| **SIMD (Single Instruction, Multiple Data)** | Hardware CPU feature where one instruction operates on 8–16 values simultaneously using wide registers (AVX2, AVX-512). The engine's vectorized batches supply SIMD with correctly-sized, contiguous blocks of values to process. |
| **Parquet** | A popular open columnar file format; the storage format underneath your Iceberg tables. |
| **Predicate pushdown** | An optimization where the engine pushes filters down to the storage layer so it can skip entire files or column chunks. |
| **Cardinality** | The number of distinct values in a column. Low cardinality (few distinct values) compresses dramatically. |

---

## Summary

Columnar storage is the architectural reason data warehouses and OLAP systems are so much faster than application databases for analytics. By storing column values together, they (1) read only the data a query needs — often 5–20% of the table; (2) compress that data aggressively using RLE, dictionary encoding, bit-packing, and delta encoding, which both shrinks storage and reduces bytes read at query time; (3) decompress quickly using fast codecs (Snappy, LZ4, Zstd) that rarely become the bottleneck — though they do consume CPU; and (4) process the data using two complementary CPU mechanisms: a vectorized batch model (software) that processes 1,024–4,096 values per operator call, and SIMD instructions (hardware) that execute 8–16 arithmetic operations per clock cycle within each batch. The downside is single-row lookups and per-row writes are slower — which is why your application database stays row-oriented and your analytics layer (Iceberg + Parquet + Trino) is columnar.
