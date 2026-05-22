# Column-Oriented Storage: What It Is and Why Analytics Is Faster

> **Note:** The production environment in `prod_info.md` is not yet filled in. This resource gives advice for a generic SaaS setup. Once your stack is described, re-read this with your specific tools in mind.

---

## Concept in one sentence

**Columnar (column-oriented) storage** keeps all values of a single column together on disk, rather than keeping all columns of a row together — which makes reading a few columns across millions of rows dramatically faster.

---

## Why it matters for SaaS

When you add an OLAP system or data warehouse to your stack, you'll encounter this term immediately — BigQuery, Snowflake, ClickHouse, Redshift, and Parquet files all use columnar storage. Understanding *why* it's fast helps you write better queries, choose the right tool, and explain to your team why your new warehouse is so much faster than Postgres for certain workloads.

---

## Concrete example: row vs column storage

Imagine a simplified `events` table:

| id | user_id | event_name | timestamp | revenue |
|---|---|---|---|---|
| 1 | 101 | signup | 2024-01-01 | 0 |
| 2 | 102 | purchase | 2024-01-01 | 49 |
| 3 | 101 | purchase | 2024-01-02 | 99 |

**Row-oriented storage (Postgres, MySQL)** writes rows consecutively:
```
[1, 101, signup, 2024-01-01, 0]  [2, 102, purchase, 2024-01-01, 49]  [3, 101, purchase, 2024-01-02, 99]
```

**Columnar storage (BigQuery, ClickHouse)** writes each column consecutively:
```
id:         [1, 2, 3]
user_id:    [101, 102, 101]
event_name: [signup, purchase, purchase]
timestamp:  [2024-01-01, 2024-01-01, 2024-01-02]
revenue:    [0, 49, 99]
```

Now consider this query:
```sql
SELECT SUM(revenue) FROM events WHERE timestamp >= '2024-01-01';
```

- **Row storage**: must read every row — all 5 columns — even though only `revenue` and `timestamp` are needed. At 50 million rows, that's a lot of wasted I/O.
- **Column storage**: reads only the `timestamp` column to filter, then the `revenue` column to sum. Skips `id`, `user_id`, and `event_name` entirely. This can cut the data read by 60–80% or more.

---

## The compression bonus

Columnar storage gets a second big win: **compression**. When you store all values of a column together, they're the same data type and often have patterns:

- `event_name` might be 90% just a few values like `"purchase"`, `"pageview"`, `"click"` — these compress extremely well with run-length encoding
- `timestamp` values that are sequential compress down to almost nothing
- Integer columns with limited ranges can be stored in fewer bytes

Typical columnar databases achieve **5–10x compression** compared to row storage. Less data on disk = faster reads = lower storage costs.

---

## Vectorized execution

Modern columnar engines don't just read less data — they also process it differently. Instead of processing one row at a time, they process a *batch* of column values together using CPU instructions designed for arrays (called SIMD — Single Instruction, Multiple Data). This is "vectorized execution."

You don't need to know the internals, but the practical implication is: columnar databases get *much faster* when queries touch large numbers of rows, not slower. Their architecture is tuned for exactly that.

---

## The trade-off: columnar is slow for OLTP

Columnar storage is the wrong choice when you need to:
- Read a single row by ID (`SELECT * FROM users WHERE id = 12345`)
- Insert one row at a time (like your web app recording every HTTP request)
- Update individual fields frequently

For those operations, row storage wins. Fetching a single row means reading one contiguous block on disk. With columnar storage, that same fetch touches a different file/block for every column — much slower for single-row access.

This is the core reason why **you keep Postgres for your application** (row storage, fast single-row reads/writes) and **add a warehouse for analytics** (columnar storage, fast multi-row aggregations).

---

## What this means when writing analytical queries

Columnar storage rewards *selecting fewer columns*. Some practical habits:

- **Avoid `SELECT *`** in analytical queries — you pay for every column you read
- **Filter on partition columns first** (date ranges, etc.) — covered more in the partitioning resource
- **Wide tables are fine** in a columnar system — columns you don't query don't slow you down

---

## Where you'll encounter columnar storage

| System | Storage format |
|---|---|
| **BigQuery** | Capacitor (Google's columnar format) |
| **Snowflake** | Proprietary columnar format |
| **ClickHouse** | MergeTree columnar format |
| **Apache Parquet** | Open columnar file format; used by data lakes, dbt, Spark |
| **Amazon Redshift** | Columnar with user-defined sort keys |
| **DuckDB** | Columnar in-memory/on-disk format |
| **Postgres** | Row-oriented (OLTP default) — not columnar |

If you see `.parquet` files, you're dealing with columnar storage on disk.

---

## Key terms defined

| Term | Plain meaning |
|---|---|
| **Columnar storage** | Storing all values for one column together rather than storing all columns for one row together |
| **Row-oriented storage** | Storing all columns for each row together — how Postgres, MySQL work |
| **I/O** | Input/Output — reading data from disk; reducing I/O is the main reason columnar is faster |
| **Compression** | Shrinking data to take less space; columnar enables better compression because similar values are adjacent |
| **Run-length encoding** | A compression trick: instead of storing `["purchase","purchase","purchase"]`, store `["purchase" × 3]` |
| **Vectorized execution** | Processing a batch of column values together using CPU-level array instructions (SIMD) |
| **Parquet** | A popular open-source columnar file format, common in data lakes and pipeline tools |
| **Predicate pushdown** | An optimization where the engine filters rows *before* reading columns, skipping unnecessary data entirely |

---

## Summary

Columnar storage is the architectural reason why data warehouses and OLAP systems are so much faster than your application database for analytics. By storing column values together, they read only the data a query needs (often 5–20% of total), compress it aggressively, and process it using CPU-optimized batch instructions. The downside is that single-row lookups and frequent writes are slower — which is why you keep your OLTP database for the application and use columnar storage for analysis.
