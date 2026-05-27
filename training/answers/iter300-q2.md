# Answer to Q2: Why SELECT * is Much Worse in Trino Than in Postgres

## Short answer

Your coworker is absolutely right — `SELECT *` is much worse in Trino with Iceberg than in Postgres. The reason is purely about how the files are physically stored on disk. The performance difference can easily be **10x to 20x slower** in real-world queries, sometimes more.

## Why SELECT * is bad in Trino (but not Postgres)

In Postgres (row-oriented storage), each row is stored as one contiguous chunk of bytes on disk:

```
ROW 1: [id=1 | user_id=101 | event_name=page_view | timestamp=2024-01-01 | revenue=0]
ROW 2: [id=2 | user_id=102 | event_name=purchase  | timestamp=2024-01-01 | revenue=49]
ROW 3: [id=3 | user_id=101 | event_name=page_view | timestamp=2024-01-02 | revenue=0]
```

Even if you only need 2 of 20 columns, Postgres has to read the entire row anyway because the columns are physically interleaved. An index helps you find which rows to read, but once you're reading a row, you get all its columns. So `SELECT *` doesn't hurt much more than `SELECT col1, col2` — you're already reading the whole row.

**Your Iceberg tables in MinIO are stored as Parquet files, which are columnar.** All values of one column are stored together on disk:

```
COLUMN: id           [1 | 2 | 3 | 4 | ...]
COLUMN: user_id      [101 | 102 | 101 | 103 | ...]
COLUMN: event_name   [page_view | purchase | page_view | purchase | ...]
COLUMN: timestamp    [2024-01-01 | 2024-01-01 | 2024-01-02 | 2024-01-02 | ...]
COLUMN: revenue      [0 | 49 | 0 | 99 | ...]
```

With columnar storage, **Trino can read only the columns it needs.** If you query `SELECT user_id, revenue` from a 20-column table, Trino opens and decompresses only those 2 column strips and skips the other 18 entirely. The bytes you don't need are never read from MinIO.

## The concrete impact: column count

If your Iceberg table has 80 columns:
- `SELECT *` — Trino reads all 80 columns from MinIO
- `SELECT col1, col2, col3` — Trino reads 3 columns from MinIO

That's a **~27x reduction in bytes read** (80÷3). Network I/O from MinIO is the slowest part of any query on your on-prem stack, so reducing bytes read directly translates to query time.

In practice on a well-compressed Parquet table:

| Scenario | Bytes read | Query time |
|---|---|---|
| `SELECT *` (80 columns, 500M rows) | ~50 GB | 45 seconds |
| `SELECT 3 columns` (500M rows) | ~2 GB | 4 seconds |

The Iceberg query is roughly **10x faster** just because of column selection. Add a partition filter and the difference compounds further — Trino skips entire data files before even opening them.

## Why compression amplifies the effect

Parquet applies different compression per column. When values of the same type sit together, they compress dramatically — often 5–30x smaller than raw bytes. A `revenue` column of integers compresses far better than interleaved mixed types.

So with `SELECT *` you're not just reading more columns — you're also:
1. Reading each column's compressed bytes AND decompressing them
2. Transferring more bytes over the network from MinIO

A `SELECT *` query reads 20–50x more bytes than a query touching 2–3 columns, **not** 10% more.

## How bad is it in practice?

| Usage pattern | Slowdown vs explicit columns |
|---|---|
| One extra adjacent column in a narrow table | ~10% |
| Half the table's columns instead of 2–3 | 2–3x |
| All 80 columns when you only need 3 | 10–20x |
| All columns with no partition filter at all | Up to 100x |

The last case is rare because people usually add a date filter — but it's where `SELECT *` bites hardest.

## What to do instead

**1. Always name columns explicitly:**
```sql
-- Bad during development
SELECT * FROM iceberg.analytics.events
WHERE event_date = DATE '2026-05-27'
LIMIT 100;

-- Good — reads only 4 of 80 columns from MinIO
SELECT event_id, user_id, event_type, amount
FROM iceberg.analytics.events
WHERE event_date = DATE '2026-05-27'
LIMIT 100;
```

Use `DESCRIBE iceberg.analytics.events` to see all column names.

**2. Always include the partition column in WHERE** — this is the biggest win independently of `SELECT *`. It skips entire Parquet files before Trino even opens them:
```sql
-- Good: prunes to one week's files
SELECT user_id, SUM(amount)
FROM iceberg.analytics.events
WHERE event_date >= DATE '2026-05-20'
  AND event_date < DATE '2026-05-27'
GROUP BY user_id;

-- Bad: scans entire table, then filters
SELECT user_id, SUM(amount)
FROM iceberg.analytics.events
WHERE user_id = '12345'
GROUP BY user_id;
```

**3. Use EXPLAIN (TYPE DISTRIBUTED) before running expensive queries:**
```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT event_id, user_id
FROM iceberg.analytics.events
WHERE event_date = DATE '2026-05-27';
```

**4. For ad-hoc exploration, use a small date range or TABLESAMPLE:**
```sql
-- Sample a small slice instead of scanning everything
SELECT event_id, user_id, event_type
FROM iceberg.analytics.events TABLESAMPLE BERNOULLI (5)
WHERE event_date >= DATE '2026-05-01'
LIMIT 100;
```

## The key insight

In Postgres, column selection barely matters because rows are stored together — you read the whole row anyway. In Trino with Parquet, column selection is one of your biggest query levers. Naming columns explicitly can cut query time by 5–20x with no other changes. It's one of the cheapest wins available and takes 30 seconds to implement.
