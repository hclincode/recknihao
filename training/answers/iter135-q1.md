# Iter135 Q1 — Answer

**Question**: "We started pushing our Postgres event data to Parquet files on MinIO last month, and I noticed something I can't explain. Our Postgres pg_dump for the events table is about 40GB. When we write the same data to Parquet, the files on MinIO total only about 5GB — so roughly 8x smaller. But I checked and we're writing all the columns, not a subset. I thought Parquet was only faster because it 'skips columns you don't read,' but that doesn't explain why a full copy of the data is smaller. What is physically happening inside those Parquet files that makes them so much more compact? And does it matter what order the rows are in when you write the data — like, would sorting the data before writing make the files even smaller?"

---

## Why Parquet Is 8x Smaller: Columnar Layout Enables Aggressive Compression

The 8x compression comes from one fundamental architectural difference between Postgres and Parquet: **Parquet stores all values of a column together, not all columns of a row together.** This single change makes two types of compression possible that are nearly impossible with row-oriented storage.

Your Postgres `pg_dump` is row-oriented: every row is stored as one contiguous block. A typical record looks like bytes from `user_id` (UUID), then bytes from `event_name` (string), then bytes from `occurred_at` (timestamp), then bytes from `revenue` (decimal) — all interleaved. Compression algorithms see random bytes with no repeating patterns.

When you write the same data to Parquet, Spark rearranges the bytes: all `user_id` values sit together, all `event_name` values sit together, all `occurred_at` values sit together. Now compression algorithms can see patterns within each column and exploit them aggressively.

---

## The Physical Layout

### Row-oriented (Postgres)

```
Disk block 1:
[ user_id=101 | event_name=page_view | occurred_at=2024-01-01 | revenue=0   ]  ← row 1
[ user_id=102 | event_name=purchase  | occurred_at=2024-01-01 | revenue=49  ]  ← row 2
[ user_id=101 | event_name=page_view | occurred_at=2024-01-02 | revenue=0   ]  ← row 3
```

All columns interleaved. No patterns visible to compressors.

### Column-oriented (Parquet)

```
COLUMN: event_name
[page_view | purchase | page_view | page_view | feature_used | purchase | ...]

COLUMN: user_id
[101 | 102 | 101 | 103 | 101 | ...]

COLUMN: revenue
[0 | 49 | 0 | 0 | 0 | 99 | ...]
```

Same-meaning values are adjacent. Compressors can see long runs of identical values, small value ranges, and predictable patterns.

---

## Dictionary Encoding: The Biggest Compression Win

Dictionary encoding is the single biggest reason your data shrank 8x. Here's how it works:

**The idea:** if a column has only a few distinct values (e.g., `event_name` has 10 event types across 10 million rows), don't store the full string 10 million times. Store it once in a dictionary, then store a tiny integer code for each row.

```
Actual event_name column (10M rows):
[page_view, purchase, page_view, page_view, feature_used, ...]

Parquet builds a dictionary:
  0 → "page_view"     (10 bytes)
  1 → "purchase"      (8 bytes)
  2 → "feature_used"  (12 bytes)
  3 → "error"         (5 bytes)
  4 → "signup"        (6 bytes)
Dictionary total: ~50 bytes

Stored column — integer codes instead of strings:
[0, 1, 0, 0, 2, 0, 1, 3, 4, 0, ...]
Each code: 3 bits (only 5 distinct values → log₂(5) = ~3 bits)

Total storage: 10M rows × 3 bits = ~3.75 MB
```

Compare to storing the strings directly:
```
10M rows × ~10 bytes average = ~100 MB uncompressed
```

**That's 26x compression on one column.** Your events table probably has 10–20 low-cardinality string columns (event types, plan types, countries, device types, currencies). Dictionary encoding on all of them easily delivers 8x overall.

Parquet uses dictionary encoding by default for string columns — you don't configure anything. It Just Works.

---

## Run-Length Encoding: Why Sorted Data Compresses Even Better

Dictionary encoding handles low cardinality. Run-length encoding (RLE) goes further by collapsing repeated values into `(value, count)` pairs — and this is where **row order dramatically changes compression**.

**Unsorted data (arrival order):**
```
event_name column: [page_view, purchase, page_view, feature_used, signup, page_view, ...]
→ No long runs. RLE produces: (page_view,1), (purchase,1), (page_view,1), ...
→ Each code requires its own entry. Minimal RLE benefit.
```

**Sorted data:**
```
event_name column (sorted): [error × 200K, feature_used × 1.5M, page_view × 5M, purchase × 3M, signup × 300K]
→ RLE produces: (error, 200K), (feature_used, 1.5M), (page_view, 5M), (purchase, 3M), (signup, 300K)
→ 5 entries describe 10 million rows.
```

Typical compression gains from sorting:
- Unsorted: 8x overall (mostly dictionary encoding, minimal RLE benefit)
- Sorted by one low-cardinality column: 12–20x
- Sorted by multiple columns: 20–50x

And it's not just the sorted column that benefits — correlated columns improve too. If `event_name = 'purchase'` always correlates with `revenue > 0`, then after sorting by `event_name`, the `revenue` column automatically clusters into `[0, 0, 0, ..., 49, 99, ...]` — long runs of zeros followed by long runs of purchase amounts. Both compress better.

Timestamps also benefit: after sorting by event type, within each type the `occurred_at` values tend to be monotonically increasing (all purchases happen in chronological order within their sorted block). Parquet uses **delta encoding** for monotonic sequences — store the first timestamp and then the differences between consecutive values. Deltas for adjacent events might all be "5 seconds" — stored as a tiny integer instead of a full 64-bit timestamp.

---

## Concrete Spark Examples: How to Sort Before Writing

### Pattern 1: Sort within partitions (most common)

```python
df = spark.read.jdbc(
    url="jdbc:postgresql://pg-replica:5432/app_db",
    table="(SELECT * FROM events WHERE created_at >= current_date - INTERVAL '1 day') AS q",
    properties={"user": "spark_reader", "password": "...", "fetchsize": "10000"}
)

# Repartition so all rows of the same event_name go to the same Spark task,
# then sort within each task — this creates long runs within each Parquet file.
df_sorted = df.repartition(64, "event_name").sortWithinPartitions("event_name", "occurred_at")

# Each of the 64 Spark tasks writes one Parquet file.
# Each file contains only a few event types (one or two), sorted.
df_sorted.writeTo("iceberg.analytics.events").append()
```

**What this does:** `repartition(64, "event_name")` ensures all `page_view` rows go to the same 1–2 tasks, all `purchase` rows to other tasks, etc. `sortWithinPartitions` then sorts each task's data before writing, maximizing RLE runs within each file.

### Pattern 2: Sort by multiple columns (for multi-tenant tables)

```python
df_sorted = df.repartition(128, "tenant_id", "event_name") \
              .sortWithinPartitions("tenant_id", "event_name", "occurred_at")

df_sorted.writeTo("iceberg.analytics.events").append()
```

**Why this also speeds up queries:** after sorting by `tenant_id`, each Parquet file tends to contain rows from only one or a few tenants. Iceberg stores the per-column min/max range for `tenant_id` in its manifest file. A query `WHERE tenant_id = 'acme'` can then skip entire files where the `tenant_id` range doesn't include 'acme' — even though `tenant_id` is not a partition column. This is how sorting enables file-level pruning beyond the partition spec.

### Pattern 3: Deferred sorting via `rewrite_data_files` (for historical data or fast initial loads)

If your initial ingestion needs to be fast and you don't want to pay the sort cost at write time:

```python
# Run as a nightly maintenance job after the ingestion job completes
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table      => 'analytics.events',
        strategy   => 'sort',
        sort_order => 'event_name ASC NULLS LAST, occurred_at ASC',
        options    => map('target-file-size-bytes', '268435456')
    )
""")
```

This re-reads existing files and rewrites them sorted. It's especially useful for historical data that was loaded unsorted before you started optimizing.

---

## The Full Picture: Three Compression Mechanisms at Work

| Mechanism | What it requires | Compression gain |
|---|---|---|
| Dictionary encoding | Low-cardinality columns (< 1000 distinct values) | 10–50x on string columns |
| Run-length encoding (RLE) | Consecutive identical values in the column | 5–100x when data is sorted |
| Delta encoding | Monotonically increasing numbers (timestamps, IDs) | 3–10x for sequential timestamps |
| Zstd codec (final pass) | All of the above as input | Additional 2–5x on top |

All four stack on top of each other. Dictionary encoding reduces `event_name` from 10-byte strings to 3-bit codes; RLE then collapses those codes into (code, count) pairs; the Zstd codec does a final entropy pass on whatever bytes remain.

Your observed 8x compression comes primarily from dictionary encoding. Sorting before write can push that to 15–30x by enabling RLE on top.

---

## Practical Takeaways for Your Stack

Your production stack uses Iceberg 1.5.2 with Parquet and Zstd compression (the default in recent Iceberg versions). You don't need to configure anything special — dictionary encoding, RLE, and Zstd are all applied automatically.

To improve compression beyond 8x:

1. **Sort before writing** using `repartition(N, sort_col).sortWithinPartitions(sort_col)`. Start with one low-cardinality column — `event_name` or `tenant_id`.
2. **Run `rewrite_data_files` with `strategy='sort'`** for existing historical data that was loaded unsorted.
3. **Check your file sizes** after adding sorting. Run `SELECT AVG(file_size_in_bytes)/1e6 AS avg_mb, COUNT(*) AS files FROM iceberg.analytics."events$files"`. Target 128–256 MB per file. Smaller files mean more files and more metadata overhead; larger files are harder to query in parallel.

The 8x compression you're already seeing is the dictionary encoding benefit. Sorting can conservatively get you to 15x and with good column choices potentially 25x — reducing your 5 GB to 1.5–2 GB with the same data.
