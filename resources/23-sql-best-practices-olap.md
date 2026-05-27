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

**Why `COUNT(DISTINCT)` is expensive — the real mechanism**

A common misconception is that `COUNT(DISTINCT)` is slow because "all values are shipped to a single node." That is **not** how Trino implements it. Trino distributes distinct aggregation across workers. The real cost has three sources:

1. **Multi-shuffle overhead.** For a query like `SELECT event_date, COUNT(DISTINCT user_id) FROM events GROUP BY event_date`, Trino first shuffles rows partitioned by the GROUP BY key (`event_date`) so different workers handle different days. Then, for each distinct column, it performs an **additional** shuffle partitioned by `(event_date, user_id)` so duplicate user_ids land on the same worker and can be deduplicated. This is the **MarkDistinct** strategy. The extra shuffle is the dominant network cost.
2. **Per-group memory pressure.** Each worker must hold all distinct values within its assigned groups in memory at the same time to detect duplicates (a hash set per group). For a query like "12 months × user_id with high NDV (number of distinct values)," each worker's hash sets can blow past the per-query memory limit.
3. **Multiple distinct expressions multiply the shuffles.** `SELECT COUNT(DISTINCT user_id), COUNT(DISTINCT session_id) FROM events GROUP BY event_date` triggers a separate shuffle pass for each distinct column. A query with three `COUNT(DISTINCT ...)` calls can perform three full re-shuffles of the input.

Approximations (HyperLogLog for distinct counts, quantile sketches for percentiles) sidestep all three: each worker builds a tiny fixed-size sketch in a single pass, then sketches are merged with one cheap shuffle. Typical speedup is **10x to 50x** (see resource 07 for the precise error model).

**Replace `COUNT(DISTINCT ...)` with `approx_distinct()`**:
```sql
-- Slow (exact): multi-shuffle + per-group hash sets in memory
SELECT event_date, COUNT(DISTINCT user_id) AS dau
FROM events GROUP BY event_date;

-- Fast (2.3% standard error): per-worker HyperLogLog sketches, single cheap merge shuffle
SELECT event_date, approx_distinct(user_id) AS dau
FROM events GROUP BY event_date;
```

The **2.3%** is a relative *standard deviation*, not a hard ceiling: ~68% of estimates fall within ±2.3% of the true count, ~95% within ±4.6%. For internal dashboards this is invisible; for billing or customer-facing counts use `COUNT(DISTINCT)`.

**Replace exact percentiles with `approx_percentile()`**:
```sql
-- Multi-percentile in one pass — no separate queries needed:
SELECT approx_percentile(latency_ms, 0.99) AS p99 FROM api_logs;
SELECT approx_percentile(latency_ms, ARRAY[0.5, 0.95, 0.99]) AS percentiles FROM api_logs;
```

`approx_percentile` uses a quantile-sketch algorithm with **2.3% standard error** (per Trino docs). Trino does NOT support `PERCENTILE_CONT WITHIN GROUP (ORDER BY ...)` — that is Postgres/Snowflake syntax. Always use `approx_percentile(col, fraction)` in Trino.

**When to use exact**: billing, compliance, contractual SLA values, audit reports. **When to use approximate**: internal dashboards, monitoring, trend charts, queries refreshed every minute.

### Before giving up exactness, try a different distinct-aggregation strategy

Trino has multiple strategies for executing distinct aggregation. The default is `automatic`, but if your specific query shape performs poorly you can override it for a single session:

```sql
SET SESSION distinct_aggregations_strategy = 'pre_aggregate';
-- other valid values: 'mark_distinct', 'single_step', 'split_to_subqueries', 'automatic'
```

- `mark_distinct` — classic MarkDistinct: extra shuffle per distinct column. Good for one distinct expression with many groups.
- `pre_aggregate` — pre-aggregates partial counts on each worker before the final shuffle. Often a big win for multiple distinct expressions in the same query.
- `single_step` — no pre-aggregation at all; relies on parallelism across the GROUP BY keys. Wins when group cardinality is high.
- `split_to_subqueries` — rewrites each `COUNT(DISTINCT ...)` into its own subquery, then joins the results. Maximizes parallelism when you have several distinct expressions.

Try each strategy with `EXPLAIN ANALYZE` and pick the one with the lowest CPU/wall time before reaching for approximation. Sometimes you can keep the exact answer just by switching strategy. See the Trino "Optimizer properties" docs for the full list of values.

### Pre-aggregated HLL sketches: the production pattern for rolling windows

When the SaaS product needs WAU (weekly active users) or MAU (monthly active users) computed daily across a 500M-row events table, re-scanning the raw events for every window is wasteful. The production pattern is to **build a tiny daily HLL sketch table once**, then merge sketches at query time.

```sql
-- Step 1: nightly job — one row per day, one HLL sketch column.
-- approx_set(col) builds a HyperLogLog sketch (a fixed-size binary blob,
-- typically a few KB) instead of an integer count.
-- IMPORTANT: cast to varbinary before storing in Iceberg. The Iceberg
-- connector (Parquet under the hood) does not know about Trino's native
-- HyperLogLog type, so you must serialize the sketch to binary first.
-- The on-disk column type is varbinary.
CREATE TABLE iceberg.analytics.daily_user_hll
WITH (partitioning = ARRAY['event_date'])
AS SELECT
    event_date,
    CAST(approx_set(user_id) AS varbinary) AS user_id_hll
FROM iceberg.analytics.events
GROUP BY event_date;

-- Step 2: rolling 7-day WAU without re-scanning raw events.
-- IMPORTANT: cast varbinary back to HyperLogLog before merge() —
-- merge() and cardinality() do not accept varbinary directly.
SELECT
    s1.event_date AS window_end,
    cardinality(merge(CAST(s2.user_id_hll AS HyperLogLog))) AS wau_7d
FROM iceberg.analytics.daily_user_hll s1
JOIN iceberg.analytics.daily_user_hll s2
  ON s2.event_date BETWEEN s1.event_date - INTERVAL '6' DAY
                       AND s1.event_date
GROUP BY s1.event_date
ORDER BY s1.event_date;
```

**Why the casts are mandatory.** `HyperLogLog` is a Trino in-engine type — it has no native encoding in Parquet/ORC, and the Iceberg connector does not know how to persist it. The [official Trino docs](https://trino.io/docs/current/functions/hyperloglog.html) prescribe this exact round-trip pattern: serialize to `varbinary` on write (`CAST(approx_set(...) AS varbinary)`), deserialize on read (`CAST(... AS HyperLogLog)`) before passing to `merge()` or `cardinality()`. Forget the write-side cast and the CTAS errors with `Unsupported type: HyperLogLog`. Forget the read-side cast and the query errors with `Unexpected parameters (varbinary) for function merge`.

Why this works (and why it's the standard pattern):
- `approx_set(column)` — builds a HyperLogLog sketch for a column. Returns a `HyperLogLog` type value, not a `BIGINT`. Cast to `varbinary` to persist.
- `merge(hll_column)` — aggregate function that unions multiple HLL sketches into one. Input must be `HyperLogLog`; if reading from a stored sketch table, cast `varbinary` -> `HyperLogLog` first. Merging sketches and then taking cardinality gives the same answer (within HLL error) as running `approx_distinct` on the union of all underlying rows.
- `cardinality(hll)` — extracts the approximate distinct count from a sketch.

You pay the sketch-building cost once per day (a single GROUP BY on the new partition). Every WAU/MAU/30D-active query after that reads at most 30 small rows from the sketch table and does a cheap merge — no scan of the 500M-row events table. This is the standard solution for rolling window cardinality in Trino, Snowflake, BigQuery, and DuckDB; they all expose the same three primitives.

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

**`EXPLAIN ANALYZE` is the right tool for verifying optimizations actually worked.** Plain `EXPLAIN` shows the planner's *estimated* costs; `EXPLAIN ANALYZE` runs the query and reports **actual bytes read, actual row counts per stage, and real wall time**. When you rewrite `COUNT(DISTINCT)` to `approx_distinct`, or swap a raw scan for a rollup/sketch table, run both versions with `EXPLAIN ANALYZE` and compare the "Input" bytes — that's the ground-truth proof that you reduced I/O. Estimates can be wrong; actuals from `EXPLAIN ANALYZE` cannot.

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

**Important nuance for Trino 467**: Trino ships **two** optimizer rules that unwrap common timestamp/date predicates so partition pruning still works:

- **`UnwrapCastInComparison`** (Trino PR #13567, 2022): rewrites simple casts on the column side back to typed literals on the value side. So `WHERE CAST(event_ts AS DATE) = DATE '2026-05-26'` (and its alias `WHERE DATE(event_ts) = DATE '2026-05-26'`) is rewritten to a timestamp range predicate on `event_ts` and **does** prune partitions correctly.
- **`UnwrapDateTruncInComparison`** (Trino PR #14011, 2022): handles `date_trunc('day', ts) = DATE '...'` (and the analogous `<`, `<=`, `>`, `>=` shapes) by rewriting it to the same kind of timestamp range predicate. So `WHERE date_trunc('day', event_ts) = DATE '2026-05-26'` also prunes partitions correctly on Trino 467.

See the Trino team's blog post "Just the right time date predicates with Iceberg" (trino.io/blog/2023/04/11/date-predicates.html), which walks through both rewrites.

Even so, the explicit TIMESTAMP range form below is the recommended defensive pattern: it always works, it's obvious to readers, and it doesn't depend on optimizer rules that can have edge cases (see below).

**OK on Trino 467** — both of these unwrap to a timestamp range and prune correctly:
```sql
SELECT * FROM events WHERE CAST(event_ts AS DATE) = DATE '2026-05-26';
SELECT * FROM events WHERE DATE(event_ts)        = DATE '2026-05-26';
SELECT * FROM events WHERE date_trunc('day', event_ts) = DATE '2026-05-26';
```

**Recommended** — express the same condition as a range against the raw column. Guaranteed prunable on any Trino version, no optimizer dependency:
```sql
SELECT * FROM events
WHERE event_ts >= TIMESTAMP '2026-05-26 00:00:00'
  AND event_ts <  TIMESTAMP '2026-05-27 00:00:00';
```

**Functions Trino 467 CAN unwrap (pruning works)**:

- `CAST(col AS DATE)` and its alias `DATE(col)` against a `DATE` literal — via `UnwrapCastInComparison`
- `date_trunc('day', col) = DATE '...'` (and `<`, `<=`, `>`, `>=`) — via `UnwrapDateTruncInComparison`
- `CAST(col AS some_type)` for simple, monotonic, invertible casts on the column side
- Comparisons like `=`, `<`, `<=`, `>`, `>=` against a typed literal

**Functions that truly break pruning (no unwrap rule exists)**:

These are either **non-monotonic** (the value jumps around as `ts` increases, so the predicate cannot be expressed as a single contiguous timestamp range) or **non-invertible on strings**:

| Bad | Good |
|---|---|
| `WHERE year(event_ts) = 2026` | `WHERE event_ts >= TIMESTAMP '2026-01-01 00:00:00' AND event_ts < TIMESTAMP '2027-01-01 00:00:00'` |
| `WHERE month(event_ts) = 5` | Range predicate on `event_ts` for the desired month(s) |
| `WHERE day_of_week(event_ts) = 1` | Pre-compute a `dow` column at ingest if you need this filter often |
| `WHERE hour(event_ts) = 9` | Range predicate, or pre-compute an `hour` column |
| `WHERE LOWER(email) = 'me@x.com'` | Store email lowercased at ingest, then `WHERE email = 'me@x.com'` |
| `WHERE SUBSTR(country, 1, 2) = 'US'` | `WHERE country LIKE 'US%'` (LIKE with a leading literal can use pushdown) |
| `WHERE CAST(user_id AS VARCHAR) = '42'` | `WHERE user_id = 42` (use correct type — section 5) |

`year`, `month`, `day_of_week`, and `hour` are all **non-monotonic over time** — `month(ts) = 5` matches May of every year, which is not a single timestamp range, so there's no general rewrite. `LOWER` and `SUBSTR` are non-invertible (many inputs collapse to the same output), so the optimizer cannot recover the original column predicate.

**Edge cases where even the unwrap rules can fail** — fall back to the explicit TIMESTAMP range form and verify with `EXPLAIN`:

- **`timestamp with time zone` columns**: both unwrap rules have known limitations with TZ-normalized timestamp types. `CAST(tz_col AS DATE)` or `date_trunc('day', tz_col)` may not always unwrap cleanly when the column is `timestamp(6) with time zone`.
- **The unwrap rules are always-on in Trino 467**: the `unwrap_casts` session toggle was removed in Release 364 (PR #9550). There is no session property to disable these rules — they run unconditionally.
- **Predicates that combine multiple columns or wrap the unwrappable expression in further arithmetic**: e.g. `date_trunc('day', event_ts) + INTERVAL '1' DAY = DATE '...'` is not recognized.

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

For exploration, use `TABLESAMPLE BERNOULLI (N)` after a partition filter, not bare `LIMIT`:

```sql
-- N is a percentage: BERNOULLI (5) keeps ~5% of rows randomly
SELECT feature_name, COUNT(*) AS events
FROM events TABLESAMPLE BERNOULLI (5)
WHERE occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY feature_name;
```

**Important nuance — BERNOULLI vs SYSTEM scan cost:**
- `TABLESAMPLE BERNOULLI (N)`: Trino reads all the physical Parquet blocks from the matched partitions, then randomly drops rows during filtering. **It does NOT reduce I/O.** The speedup comes from the partition filter reducing files scanned, plus reduced post-scan aggregation work over fewer rows.
- `TABLESAMPLE SYSTEM (N)`: Trino skips whole splits (file segments) at the storage level, reducing I/O. Results are less evenly random (whole chunks of rows are included or excluded together).

**Rule**: pair `BERNOULLI` with a tight partition filter (so the I/O is already small) for representative random samples during prototyping. Use `SYSTEM` only when you truly want to reduce file I/O at the cost of cluster-level sampling bias.

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
