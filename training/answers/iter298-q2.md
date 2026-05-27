# Answer to Q2: Why Parquet/Iceberg Filters Faster Than Postgres Indexes

## Short answer

Yes, Parquet/Iceberg is genuinely better for your use case — but not because it works like an index. Postgres B-tree indexes locate individual rows; Parquet/Iceberg **skips entire files and row groups** before reading any data. On an 80M-row table filtering by `event_type`, that difference is why one query takes 45 seconds and the other takes 2-5 seconds.

## Why your B-tree index isn't helping

Two things break the B-tree on a low-cardinality bulk filter:

1. **B-trees solve point lookups, not bulk filters.** A B-tree finds "row ID 12345" in 3 disk seeks. When you ask "give me all rows where `event_type = 'page_view'`", the index gives Postgres 40M row IDs. Postgres then has to fetch those 40M rows from random positions in the heap — that random I/O is the bottleneck, not the index traversal.

2. **The planner correctly ignores the index.** When Postgres estimates that 50% of the table matches a predicate (page_view on a 4-value column), it calculates that reading the index + fetching 40M heap pages will be slower than one sequential scan. Selecting sequential scan is correct. This isn't a planner bug.

## How Parquet/Iceberg is fundamentally different

Parquet stores data column by column, and Iceberg wraps every Parquet file with **per-file and per-row-group column statistics**. Filtering happens in three stacked layers before any row data is read:

### Layer 1: File-level skipping (Iceberg manifests)

Iceberg maintains manifest files — small metadata listing every Parquet file plus **min and max values per column** for each file. Before Trino opens a single Parquet file, it reads the manifest and checks: "does this file contain any 'page_view' rows?"

**Unsorted data (random insertion order):** Each of your 500 files (80M rows ÷ 500) mixes all event types. Each file's min/max might span the entire range (min='click', max='purchase'). Trino must open all 500 files — 'page_view' falls within every file's range. No skipping.

**Sorted by `event_type`:** Files now contain one or two event types:
- Files 1–50: only 'click' (min=max='click')
- Files 51–100: only 'page_view' (min=max='page_view')
- Files 101–150: only 'purchase' (min=max='purchase')

Trino proves "files 1–50 contain only 'click' — 'page_view' is not in [click, click], skip." Only 50 of 500 files are opened: **10x I/O reduction before reading a single data byte.**

### Layer 2: Row-group pruning (Parquet footer statistics)

Inside each Parquet file Trino opens, the file is split into row groups (~128 MB chunks), each with its own per-column min/max in the Parquet footer. Trino applies the same check again — row groups that prove the predicate can't match are skipped. On sorted data, this eliminates 50–80% of row groups within the files that were opened.

### Layer 3: Column-only I/O (Parquet columnar layout)

Even within row groups Trino reads, it reads **only the `event_type` column** — not your other 19 columns. Postgres reads every column of every row together, then discards unused ones. Parquet reads only the bytes for columns in your SELECT and WHERE clauses.

## Concrete numbers

**Postgres sequential scan (80M rows):**
- Row size: ~1 KB → table: ~80 GB
- Must read all 80 GB
- Query time: 30–60 seconds

**Parquet/Iceberg (well-sorted data, 500 × 300 MB files):**
- File pruning: 500 → 50 files = 15 GB compressed
- Dictionary encoding on low-cardinality `event_type`: ~10x compression
- Effective bytes: 15 GB ÷ 10 = 1.5 GB on disk
- Column-only I/O (1 of ~20 columns): ~75 MB of actual event_type data
- Query time: 2–5 seconds on Trino + MinIO

The speedup stacks from three independent reductions:
1. File skipping: 500 → 50 files (10x)
2. Compression: 15 GB → 1.5 GB (10x)
3. Column-only read: 1 of 20 columns (20x)

Real-world speedups are 10x–100x (perfect assumptions don't hold), but the layered mechanism is accurate.

## Is it an index? No — it's a different problem

| | Postgres B-tree index | Parquet/Iceberg statistics |
|---|---|---|
| Problem solved | Find specific rows by key | Skip whole files that can't match |
| Cost reduction | Fewer heap page fetches | Less total bytes to read from disk |
| Best for | Point lookups, small result sets | Bulk filters on millions of rows |
| Worst for | Low-cardinality bulk filters | Single-row lookups by ID |

## How to unlock the speedup: sort the data at write time

By default, Iceberg data arrives in insertion order — each file mixes all event types and the manifest min/max ranges are useless. To enable file skipping, sort by `event_type` either at ingestion time or in a one-time `rewrite_data_files` run (requires Spark):

```sql
CALL iceberg.system.rewrite_data_files(
  table      => 'analytics.events',
  strategy   => 'sort',
  sort_order => 'event_type ASC NULLS LAST, occurred_at ASC'
);
```

After this, rows with the same `event_type` cluster together. File min/max ranges tighten to min=max='page_view' for page_view files. File-level pruning skips 90% of files in milliseconds. No ongoing maintenance — it's the physical layout on disk.

## The trade-off: OLAP wins on bulk, OLTP wins on single-row

- "Count all `page_view` events in the last 7 days" → **Parquet wins by 100x**
- "Fetch the single event with `event_id = 'abc123'"` → **Postgres wins** (index + one heap page = 3 seeks; Parquet still needs file skipping and decompression)

This is why your SaaS app uses Postgres for the application (single-row OLTP lookups) and Iceberg + Trino for analytics (bulk OLAP aggregations). The B-tree index is still correct for the app; Parquet's layered statistics are correct for analytics. They're optimizing different problems.
