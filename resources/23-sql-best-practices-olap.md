# SQL Query Best Practices for OLAP (Trino + Iceberg)

If you came from Postgres or MySQL, your SQL habits will work in Trino — but they will be **slow and expensive**. OLTP databases have B-tree indexes that let you find a single row in microseconds. Trino + Iceberg has no row-level indexes; every query reads chunks of Parquet files from MinIO over the network. The cost of a bad query is measured in **bytes scanned**, not milliseconds.

This guide is a practical checklist. Each section is one habit to keep or break.

**Production stack assumed**: Trino 467 OSS, Iceberg 1.5.2 with Hive Metastore, MinIO via S3, on-prem Kubernetes.

---

## 1. Always include the partition column in WHERE

**Why**: Iceberg tables are split into partitions (folders of Parquet files in MinIO). A predicate on the partition column lets Trino **skip entire folders**. Without it, Trino lists and reads every file in the table.

**Bad** — scans the entire table (could be terabytes):
```sql
SELECT user_id, SUM(amount)
FROM events
WHERE event_type = 'purchase'
GROUP BY user_id;
```

**Good** — Iceberg prunes to one day's partition:
```sql
SELECT user_id, SUM(amount)
FROM events
WHERE event_date = DATE '2026-05-26'      -- partition column
  AND event_type = 'purchase'
GROUP BY user_id;
```

**How to verify**: In the Trino Web UI (`http://<coordinator>:8080`), open the query and look at **"Input: X rows (Y bytes)"**. If you forgot the partition filter, the bytes will be enormous. Use `EXPLAIN` (see section 4) to confirm partition pruning is happening.

---

## 2. Avoid SELECT * on wide Iceberg tables

**Why**: Parquet is **columnar**. Trino reads only the columns you reference. `SELECT *` forces Trino to open every column from MinIO, even ones you don't use. A 50-column table queried with `SELECT *` is roughly 25x more bytes than querying 2 columns.

**Bad** — fetches all 80 columns:
```sql
SELECT * FROM events WHERE event_date = DATE '2026-05-26' LIMIT 100;
```

**Good** — names only what you need:
```sql
SELECT event_id, user_id, amount
FROM events
WHERE event_date = DATE '2026-05-26'
LIMIT 100;
```

Even for ad-hoc exploration, prefer `SELECT col1, col2, col3` over `SELECT *`. If you need to see all columns, use `DESCRIBE events` to list them, then pick what you actually want.

---

## 3. Use approximate functions when exactness isn't required

**Why**: Exact distinct counts and percentiles require shuffling all unique values across the cluster. Approximations use sketch algorithms (HyperLogLog, T-Digest) that work in a single pass with tiny memory. Typical speedup is **10x to 50x**, with error around 2%.

**Replace `COUNT(DISTINCT ...)` with `approx_distinct()`**:
```sql
-- Slow (exact): shuffles every distinct user_id
SELECT event_date, COUNT(DISTINCT user_id) AS dau
FROM events GROUP BY event_date;

-- Fast (~2% error): HyperLogLog sketch
SELECT event_date, approx_distinct(user_id) AS dau
FROM events GROUP BY event_date;
```

**Replace exact percentiles with `approx_percentile()`**:
```sql
-- Slow: full sort
SELECT approx_percentile(latency_ms, 0.95) FROM api_logs;   -- p95
SELECT approx_percentile(latency_ms, ARRAY[0.5, 0.95, 0.99]) FROM api_logs;
```

**When to use exact**: billing, compliance, audit reports. **When to use approximate**: dashboards, monitoring, exploration, dashboards refreshed every minute.

---

## 4. Verify your plan with EXPLAIN

**Why**: SQL that looks correct can still scan the whole table. `EXPLAIN` shows what Trino will actually do.

**Basic usage**:
```sql
EXPLAIN
SELECT user_id, SUM(amount)
FROM events
WHERE event_date = DATE '2026-05-26'
GROUP BY user_id;
```

**What to look for in the output**:

- `TableScan[table = iceberg:db.events, ... constraint on [event_date]]`
  Good — the predicate was **pushed down** to Iceberg. Only matching partitions will be read.

- `ScanFilterProject` with the predicate inside `filterPredicate = ...`
  Bad — the predicate was **not pushed down**. Trino is scanning all rows and filtering in memory. Usually caused by wrapping the column in a function (see section 6) or a type mismatch (section 5).

- `CrossJoin` — you forgot a join condition. Almost always a bug.

- `RemoteExchange` with a huge `Estimates: {rows: 10B}` — a giant intermediate result is being shuffled. Add filters or reduce columns first.

- Missing `dynamicFilter` on a join — joins between fact and dim tables should show dynamic filters; if not, ensure both tables have stats (`ANALYZE TABLE`).

**For deeper inspection** use `EXPLAIN (TYPE DISTRIBUTED)` or `EXPLAIN ANALYZE` (runs the query and reports actual rows/time per stage).

---

## 5. Use type-safe predicates — Trino does NOT auto-cast like Postgres

**Why**: Postgres will quietly convert `WHERE id = '123'` to integer comparison. Trino is strict — type mismatches either **fail with an error** or **silently disable predicate pushdown**, which means a full scan.

**Bad** — `account_id` is VARCHAR in the table, but the literal is INTEGER:
```sql
SELECT * FROM orders WHERE account_id = 12345;
-- Error: '=' cannot be applied to varchar, integer
```

**Good** — match the column type exactly:
```sql
SELECT * FROM orders WHERE account_id = '12345';
```

**The silent killer** — implicit casts on date/timestamp columns:
```sql
-- BAD: if event_date is DATE, this casts every row's date to varchar
WHERE CAST(event_date AS VARCHAR) = '2026-05-26'

-- GOOD: compare DATE to DATE literal
WHERE event_date = DATE '2026-05-26'
```

**Rule of thumb**: check column types with `DESCRIBE table_name`. Always use typed literals: `DATE '...'`, `TIMESTAMP '...'`, `VARCHAR` for string columns, no quotes for numeric columns.

---

## 6. Don't wrap partition or filter columns in functions

**Why**: Most functions applied to a column in WHERE block Iceberg from using that column for partition pruning or Parquet min/max statistics — the predicate cannot be **pushed down**. There are important exceptions in Trino 467, but the safe habit is to filter the raw column directly.

**Important nuance for Trino 467**: Trino has an optimizer rule called `UnwrapCastInComparison` (shipped in 2022) that rewrites simple casts on the column side back into typed literals on the value side. So `WHERE CAST(event_ts AS DATE) = DATE '2026-05-26'` (and its alias `WHERE DATE(event_ts) = DATE '2026-05-26'`) is typically rewritten to a range predicate on `event_ts` and **does** prune partitions correctly. See Trino's blog post "Just the right time date predicates with Iceberg" (trino.io/blog/2023/04/11/date-predicates.html).

Even so, the explicit TIMESTAMP range form below is the recommended defensive pattern: it always works, it's obvious to readers, and it doesn't depend on optimizer rules that can have edge cases.

**Bad** — `date_trunc` is truly non-invertible (many timestamps map to the same day), so the optimizer cannot unwrap it and pruning is lost:
```sql
SELECT * FROM events
WHERE date_trunc('day', event_ts) = DATE '2026-05-26';
```

**Good** — express the same condition as a range against the raw column:
```sql
SELECT * FROM events
WHERE event_ts >= TIMESTAMP '2026-05-26 00:00:00'
  AND event_ts <  TIMESTAMP '2026-05-27 00:00:00';
```

**Functions Trino 467 CAN unwrap (pruning usually works)**:

- `CAST(col AS DATE)` and its alias `DATE(col)` against a `DATE` literal
- `CAST(col AS some_type)` for simple, monotonic, invertible casts on the column side
- Comparisons like `=`, `<`, `<=`, `>`, `>=` against a typed literal

**Functions that definitely break pruning (no unwrap possible)**:

| Bad | Good |
|---|---|
| `WHERE date_trunc('day', event_ts) = DATE '2026-05-26'` | `WHERE event_ts >= TIMESTAMP '2026-05-26 00:00:00' AND event_ts < TIMESTAMP '2026-05-27 00:00:00'` |
| `WHERE year(event_ts) = 2026` | `WHERE event_ts >= TIMESTAMP '2026-01-01 00:00:00' AND event_ts < TIMESTAMP '2027-01-01 00:00:00'` |
| `WHERE month(event_ts) = 5` | Range predicate on `event_ts` for the desired month(s) |
| `WHERE day_of_week(event_ts) = 1` | Pre-compute a `dow` column at ingest if you need this filter often |
| `WHERE hour(event_ts) = 9` | Range predicate, or pre-compute an `hour` column |
| `WHERE LOWER(email) = 'me@x.com'` | Store email lowercased at ingest, then `WHERE email = 'me@x.com'` |
| `WHERE SUBSTR(country, 1, 2) = 'US'` | `WHERE country LIKE 'US%'` (LIKE with a leading literal can use pushdown) |
| `WHERE CAST(user_id AS VARCHAR) = '42'` | `WHERE user_id = 42` (use correct type — section 5) |

These functions are either **non-invertible** (multiple inputs map to the same output, e.g. `date_trunc`, `LOWER`) or **non-monotonic over ranges** (e.g. `year`, `month`, `day_of_week`) — there is no general way for the optimizer to translate them back into a range on the raw column.

**Edge case — `timestamp with time zone` columns**: `UnwrapCastInComparison` has known limitations with TZ-normalized timestamp types. A `CAST(tz_col AS DATE)` predicate may not always unwrap cleanly. If your column is `timestamp(6) with time zone` and pruning is critical, use the explicit TIMESTAMP range form — and verify with `EXPLAIN`.

Always test with `EXPLAIN` — if the predicate ends up inside a `ScanFilterProject` instead of as a `constraint` on the `TableScan`, the pushdown was lost.

---

## 7. LIMIT does NOT reduce scan cost

**Why**: In Postgres, `LIMIT 10` with an index scan stops after 10 rows. In Trino against Iceberg, the scan still reads every Parquet file that matches the predicates. `LIMIT` only trims the final result; it doesn't make the scan cheaper.

**Bad** — full table scan, then trims to 10 rows:
```sql
SELECT * FROM events LIMIT 10;
```

**Good** — combine LIMIT with a partition filter so the scan is small:
```sql
SELECT event_id, user_id, event_type
FROM events
WHERE event_date = DATE '2026-05-26'
LIMIT 10;
```

For "give me a sample" exploration, use `TABLESAMPLE BERNOULLI (1)` after a partition filter, not bare `LIMIT`.

---

## 8. Filter with WHERE before GROUP BY, not HAVING

**Why**: `WHERE` is evaluated before aggregation, so rows are dropped before they enter the expensive GROUP BY. `HAVING` runs after aggregation — every row contributes to the group, then the group is discarded.

**Bad** — aggregates every event, then throws most away:
```sql
SELECT event_type, COUNT(*) AS c
FROM events
GROUP BY event_type
HAVING event_type IN ('purchase', 'signup');
```

**Good** — filters at scan time:
```sql
SELECT event_type, COUNT(*) AS c
FROM events
WHERE event_type IN ('purchase', 'signup')
  AND event_date = DATE '2026-05-26'
GROUP BY event_type;
```

Use `HAVING` only for conditions on aggregates themselves, e.g. `HAVING COUNT(*) > 100`.

---

## 9. JOIN ordering matters — and ANALYZE makes the CBO do it for you

**Why**: Trino's default is **broadcast join**: the smaller table is sent to every worker. If you put the big table second and it gets broadcast by mistake, the cluster runs out of memory or stalls. The Cost-Based Optimizer (CBO) can reorder joins automatically — but only if it has table statistics.

**Run ANALYZE on each table after large ingests**:
```sql
ANALYZE iceberg.db.events;
ANALYZE iceberg.db.users;
```

**Manual order rule of thumb** — small (or filtered) table first, big table last:
```sql
-- Good: users (10k rows) joined against events (10B rows)
SELECT u.name, COUNT(*) AS event_count
FROM users u
JOIN events e ON e.user_id = u.id
WHERE e.event_date = DATE '2026-05-26'
GROUP BY u.name;
```

If a join hangs or OOMs, check `EXPLAIN` to see which side is being broadcast. Force the layout if needed with `/*+ DISTRIBUTION_TYPE(PARTITIONED) */` style session properties (`join_distribution_type = 'PARTITIONED'`).

---

## 10. Use CTEs or subqueries — don't re-run the same expensive query twice

**Why**: A common Postgres habit is to run a heavy query once, store the result in the app, and reuse it. In Trino you don't have a session-scoped temp result, but you can let the planner share a subquery within a single statement using a CTE (`WITH`). Avoid pasting the same expensive subquery in two places — Trino will execute it twice.

**Bad** — same scan runs twice:
```sql
SELECT (SELECT COUNT(*) FROM events WHERE event_date = DATE '2026-05-26') AS today_total,
       (SELECT COUNT(*) FROM events WHERE event_date = DATE '2026-05-26' AND event_type = 'purchase') AS today_purchases;
```

**Good** — single scan, aggregated once:
```sql
SELECT
  COUNT(*) AS today_total,
  COUNT(*) FILTER (WHERE event_type = 'purchase') AS today_purchases
FROM events
WHERE event_date = DATE '2026-05-26';
```

**For multi-step pipelines**, use a CTE:
```sql
WITH recent_events AS (
  SELECT user_id, event_type, amount
  FROM events
  WHERE event_date = DATE '2026-05-26'
)
SELECT user_id, SUM(amount)
FROM recent_events
WHERE event_type = 'purchase'
GROUP BY user_id;
```

**If you need to reuse a result across multiple queries**, materialize it once with `CREATE TABLE temp.my_extract AS SELECT ...` (the team's "ad-hoc extract" pattern documented for this environment), then query the small table multiple times. Drop it when done.

---

## Quick checklist before you hit Run

1. Is the **partition column** in WHERE?
2. Is `SELECT *` replaced with named columns?
3. Could `COUNT(DISTINCT)` or percentile become approximate?
4. Did you `EXPLAIN` to confirm predicate pushdown (`constraint on [...]`)?
5. Do your literals **match column types** (`DATE`, `TIMESTAMP`, `VARCHAR`)?
6. Are any **functions wrapped around** filter or partition columns?
7. If you used `LIMIT`, did you also add a partition filter?
8. Are filters in `WHERE`, not `HAVING`?
9. Is the **smaller table on the left** of the JOIN, and was `ANALYZE` run?
10. Are duplicate subqueries collapsed into a CTE or `FILTER (WHERE ...)`?

If you can answer "yes" to all ten, you avoid the most common 10x-cost mistakes that OLTP engineers make on their first day in Trino.

---

## Key terms

- **Predicate pushdown**: passing a WHERE condition down to the storage layer (Iceberg) so it can skip files instead of returning everything to Trino.
- **Partition pruning**: a form of predicate pushdown where Iceberg skips entire partition folders.
- **Broadcast join**: a join strategy where the smaller table is copied to every worker; fast for small-vs-big joins.
- **CBO (Cost-Based Optimizer)**: Trino's optimizer that reorders joins and chooses strategies using table statistics from `ANALYZE`.
- **HyperLogLog / T-Digest**: probabilistic sketch algorithms behind `approx_distinct` and `approx_percentile`.
- **ScanFilterProject vs TableScan with constraint**: in EXPLAIN, the former means filtering happens in Trino memory; the latter means Iceberg already filtered the files.
