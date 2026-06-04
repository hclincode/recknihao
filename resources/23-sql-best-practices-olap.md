# SQL Query Best Practices for OLAP (Trino + Iceberg)

If you came from Postgres or MySQL, your SQL habits will work in Trino — but they will be **slow and expensive**. OLTP databases have B-tree indexes that let you find a single row in microseconds. Trino + Iceberg has no row-level indexes; every query reads chunks of Parquet files from MinIO over the network. The cost of a bad query is measured in **bytes scanned**, not milliseconds.

This guide is a practical checklist. Each section is one habit to keep or break.

**Production stack assumed**: Trino 467 OSS, Iceberg 1.5.2 with Hive Metastore, MinIO via S3, on-prem Kubernetes.

---

## Common myths — read FIRST (the confident-wrong claims that come up most often)

These are the five "X is not supported in Trino" / "Y can't be done on Iceberg" claims that AI assistants (and engineers transferring from other warehouses) most often produce as confident absolutes — and that are most often **wrong, or wrong-with-an-exception that flips the answer**. Lead with the TRUTH, then state the nuance.

| MYTH (commonly said wrong) | TRUTH (correct framing) | Authoritative pointer |
|---|---|---|
| "OSS Trino 467 can't push `ORDER BY ... LIMIT N` (TopN) to PostgreSQL — that's a Starburst Enterprise feature." | **TopN pushdown is in OSS Trino since release 353/354 (March 2021).** It is on by default in OSS Trino 467 (`topn_pushdown_enabled=true`). The canonical pushed-down EXPLAIN signature is `sortOrder=[...] limit=N` annotations INSIDE the `TableScan` with **no** separate `TopN` operator above. Specific plan shapes (ORDER BY on a computed aggregate, ORDER BY spanning multiple sources in a federated join, non-default collation, non-identity projection between TopN and TableScan — [#25138](https://github.com/trinodb/trino/issues/25138)) prevent pushdown for THAT query, but the feature itself is available. | [resource 22 §13.5](22-trino-federation-postgresql.md#135-topn--limit-pushdown--under-known-high-impact-reconciled--single-source-of-truth) |
| "`QUALIFY ROW_NUMBER() OVER (...) = 1` works on Trino — it's standard SQL." | **NOT supported in Trino 467.** Parse error. `QUALIFY` is a Snowflake / BigQuery / Databricks / Teradata extension, not standard SQL. The Trino-compatible rewrite is the `ROW_NUMBER()` subquery + outer `WHERE rn = 1` (or `<= N` for top-N-per-group). See § Trino 467 SQL-dialect anti-patterns below for the canonical rewrite. | [resource 23 § Trino 467 SQL-dialect anti-patterns](#trino-467-sql-dialect-anti-patterns--do-not-carry-these-over-from-other-warehouses) |
| "Iceberg branches are a Spark-only feature — Trino can't use them at all." | **Mixed.** Branch *DDL* (`CREATE BRANCH`, `DROP BRANCH`, `fast_forward`) and branch *writes* (`INSERT INTO` targeting a branch, `spark.wap.branch`) ARE Spark-only on Trino 467. But branch *reads* via `FOR VERSION AS OF '<branch-name>'` **do work** in Trino 467 (PR [trinodb/trino #16569](https://github.com/trinodb/trino/issues/16569) landed). On this stack (Spark + Trino), the canonical WAP pattern is: Spark creates/writes/fast-forwards the branch, Trino reads from the branch for the audit step. Don't tell an engineer "branches don't work on Trino" — they read from branches just fine. | [resource 17 § Write-Audit-Publish (WAP) with Iceberg branches](17-iceberg-table-maintenance.md#write-audit-publish-wap-with-iceberg-branches) |
| "`expire_snapshots` can orphan data files that an active branch or tag points at." | **No, by design.** While a named ref (branch or tag) points at a snapshot, that snapshot AND its exclusively-owned data files are **protected from `expire_snapshots`**, regardless of age and regardless of `retention_threshold`/`older_than`/`retain_last` arguments. Iceberg's documented behavior. The only legitimate exceptions: forgotten refs hold old data indefinitely, explicit `DROP BRANCH`/`DROP TAG`, `max-ref-age-ms` firing on the ref, and the [Iceberg #13568 multi-ref bug](https://github.com/apache/iceberg/issues/13568) which affects 1.6.1+ NOT prod 1.5.2. | [resource 17 § 2. `expire_snapshots`](17-iceberg-table-maintenance.md#2-expire_snapshots--run-weekly) leading callout, [resource 26 § 12](26-iceberg-concurrent-write-conflicts.md) |
| "Trino 467 can't run `MERGE INTO` on Iceberg tables / it requires a special connector flag." | **MERGE on Iceberg IS supported in Trino 467 by default — no flag.** MERGE is the canonical Trino-side upsert form for Iceberg tables. What MAY require flags is MERGE on **JDBC** connectors (PostgreSQL, MySQL — see [resource 22](22-trino-federation-postgresql.md) section 2A); MERGE on the Iceberg connector is on out of the box. | [trino.io Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html), [resource 13](13-postgres-to-iceberg-ingestion.md) |

> **Why these myths are dangerous.** Each is a load-bearing topic-specific claim about what Trino/Iceberg "can't do." When an engineer hears them stated confidently as absolutes, they redesign around a non-existent limitation — abandoning TopN pushdown, rewriting queries to avoid QUALIFY incorrectly, building Trino-only WAP workarounds that drop the protection branches provide, tightening retention to "protect" snapshots that were already protected, or building manual upsert pipelines because they think MERGE doesn't work. The correct mental discipline: when you find yourself about to write "Trino/Iceberg can't do X," check the docs (`trino.io/docs/current/connector/<x>`, `iceberg.apache.org/docs/latest/<x>`) AND verify the feature's release-note introduction. Most "can't" claims have an exception, a version cutoff, or a specific-plan-shape limitation that flips the answer.

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

- Missing `dynamicFilter` on a join — joins between fact and dim tables should show dynamic filters; if not, ensure both tables have stats (Trino syntax: bare `ANALYZE <table>`, NO `TABLE` keyword — `ANALYZE TABLE ...` is Spark/Hive and fails in Trino; see resource 24 §4 leading canonical statement).

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

If a join hangs or OOMs, check `EXPLAIN (TYPE DISTRIBUTED)` to see which side is being broadcast. Force the layout if needed with `SET SESSION join_distribution_type = 'PARTITIONED';` before the query (or `'BROADCAST'` / `'AUTOMATIC'`). **Do NOT write `/*+ DISTRIBUTION_TYPE(PARTITIONED) */` or any other `/*+ ... */` hint form — Trino 467 has NO query-hint syntax; per [trinodb/trino #9498](https://github.com/trinodb/trino/issues/9498) the `/*+ ... */` shape is silently treated as a block comment and the hint has zero effect.** See [resource 24 — CBO / ANALYZE § LEADING CANONICAL — How do I influence Trino's join distribution](24-trino-cbo-analyze.md) for the full lever set (primary `join_distribution_type`, secondary `join_max_broadcast_table_size`, tertiary `ANALYZE`).

---

## 10. IN subqueries vs JOINs — let Trino's optimizer decide

> **JARGON GLOSS — five terms you'll see in this section (and in EXPLAIN output).** Bookmark this if you're new to query plans:
>
> | Term | Plain-English meaning | What it looks like in EXPLAIN |
> |---|---|---|
> | **Semi-join** | "Did this left row match ANY right row? TRUE/FALSE per left row — never duplicates the left row." This is the physical operator Trino wants `IN (SELECT ...)` and non-correlated `EXISTS` / `NOT EXISTS` to lower to. | `SemiJoin[...]` |
> | **Anti-join** | "Return left rows that have NO match on the right." It's a semi-join with the output inverted. `NOT IN` and `NOT EXISTS` both compute this semantically. | `SemiJoin[..., FilterMode = ANTI]` |
> | **SemiJoinNode** | Trino's physical plan node implementing semi-join (and anti-join via FilterMode=ANTI). Hash-build the small side, probe the big side once, output TRUE/FALSE per probe row. Fast. | `SemiJoin[...]` |
> | **CorrelatedJoin** | Trino plan node when a subquery references the outer row and the optimizer COULDN'T decorrelate it. Means the subquery runs per outer row — usually catastrophic. You want to NEVER see this. | `CorrelatedJoin[...]` |
> | **LeftJoin (the plan node)** | A regular LEFT OUTER JOIN — enumerates EVERY matching right row per left row. When correlated `NOT EXISTS` decorrelates, it lowers to LeftJoin + Aggregation, not SemiJoin (the slow path documented in [trinodb/trino #21859](https://github.com/trinodb/trino/issues/21859)). | `LeftJoin[...]` followed by `Aggregation` + `Filter[not exists]` |
>
> **The whole section in one sentence:** you want `SemiJoin` in your EXPLAIN output for IN / EXISTS / NOT EXISTS / NOT IN. If you see `CorrelatedJoin` instead, the optimizer gave up — rewrite. If you see `LeftJoin` + `Aggregation` on a correlated NOT EXISTS, you're on the slow #21859 path — rewrite to non-correlated form. If you see `SemiJoin` already, leave it alone.

**The short answer**: you do NOT need to manually rewrite `IN (SELECT ...)` to a JOIN. Trino converts IN subqueries to efficient semi-joins automatically. Manual rewriting can produce wrong results.

**How it works**

When you write:
```sql
SELECT user_id, SUM(amount)
FROM events
WHERE user_id IN (SELECT user_id FROM premium_users)
  AND event_date = DATE '2026-05-26'
GROUP BY user_id;
```

Trino's optimizer applies the **"Semi-Join (IN) Decorrelation"** rule and converts this to a `SemiJoinNode` internally. You get `SemiJoin[...]` in the EXPLAIN output. This is the efficient path — Trino also applies precomputed hash optimization (`optimize-hash-generation`, default on) to SemiJoin nodes, making IN subqueries typically faster than manually-written JOINs.

**Why rewriting to an INNER JOIN can be wrong**

```sql
-- Looks "faster" but changes the semantics:
SELECT e.user_id, SUM(e.amount)
FROM events e
JOIN premium_users p ON e.user_id = p.user_id
WHERE e.event_date = DATE '2026-05-26'
GROUP BY e.user_id;
```

If `premium_users` has duplicate `user_id` rows (a common data quality issue), this JOIN multiplies the matching event rows. The IN subquery deduplicated correctly; the JOIN does not. The symptom is silently inflated SUM or COUNT values — no error, just wrong numbers.

**What to look for in EXPLAIN**

```sql
EXPLAIN
SELECT user_id, SUM(amount)
FROM events
WHERE user_id IN (SELECT user_id FROM premium_users)
  AND event_date = DATE '2026-05-26'
GROUP BY user_id;
```

| Node in EXPLAIN output | Meaning |
|---|---|
| `SemiJoin[...]` | Trino correctly handled IN as a semi-join. Good — leave it alone. |
| `InnerJoin[...]` | You wrote an explicit JOIN (may produce duplicates if the right side has dupes). |
| `CorrelatedJoin[...]` | Correlated subquery that couldn't be decorrelated — needs attention (see below). |

**When you actually need to act: correlated subqueries**

A correlated subquery references a column from the outer query inside the subquery:
```sql
-- Correlated: references e.event_date from the outer query
WHERE amount > (SELECT AVG(amount) FROM events WHERE event_date = e.event_date)
```

If Trino cannot decorrelate this (it will show `CorrelatedJoin[...]` in EXPLAIN), the subquery re-executes for every row. Before rewriting, check if the table has stats:

```sql
SHOW STATS FOR premium_users;
```

If `row_count` is NULL, run `ANALYZE iceberg.analytics.premium_users` first — the CBO needs row count estimates to decorrelate safely. After ANALYZE, re-EXPLAIN to see if `CorrelatedJoin` converts to `SemiJoin`. If it still shows `CorrelatedJoin`, then rewrite to an explicit JOIN or a pre-filtered CTE.

**Rule of thumb**: if EXPLAIN shows `SemiJoin`, your IN subquery is already optimal — do not touch it.

---

### The `NOT IN` + NULL gotcha — wrong-results trap (read this BEFORE you debug)

> **One-line jargon gloss before you start.** This section uses a few terms that beginners often haven't seen before. Skim these once so the rest reads cleanly:
> - **Anti-join** = rows from the LEFT side that have **NO match** on the right side. Opposite of an inner JOIN (which returns rows that DO match). `NOT EXISTS` and `LEFT JOIN ... WHERE right IS NULL` both compute anti-join semantics.
> - **Semi-join** = rows from the left side that have **at least one match** on the right side, returned **without duplication** (one output row per left row, even if there are 5 matches on the right). Trino's `IN (SELECT ...)` becomes a SemiJoin internally.
> - **FilterMode = ANTI** = a flag on Trino's `SemiJoin` physical operator that inverts its output — instead of "return rows that match" it returns "return rows that DON'T match." A `SemiJoin` with `FilterMode = ANTI` is just the physical realization of an anti-join.
> - **SemiJoin (the Trino plan node)** = the EXPLAIN output you want to see. It runs as a hash join, broadcasts the small side, probes the big side once, and returns exactly one TRUE/FALSE per probe row — no duplicates, no per-row subquery loops.
> - **LeftJoin (the Trino plan node)** = a regular left outer join. It enumerates **every** matching right-side row for each left row, so 5 matches on the right = 5 output rows. The downstream operator must dedupe. This is why correlated `NOT EXISTS` (which lowers to LeftJoin + Aggregation, not SemiJoin) can be slower than NOT IN.
>
> Keep these five terms in mind and the rest of this section reads as one consistent story: you always want SemiJoin in EXPLAIN; LeftJoin + Aggregation on a `NOT EXISTS` is the slow path that the rewrite-to-non-correlated trick avoids.

**Symptom you'll see in production**: a `NOT IN (SELECT ...)` query returns **zero rows**, but you can prove with your own eyes that matching rows exist. No error, no warning — just an empty result.

**Root cause**: SQL uses **three-valued logic** (TRUE / FALSE / UNKNOWN). When the right-hand subquery of `NOT IN` contains **even a single NULL**, every comparison `outer_value NOT IN (..., NULL, ...)` evaluates to UNKNOWN — never TRUE — so the WHERE clause filters out every row. This is **standard SQL semantics**, not a Trino bug; Postgres, MySQL, BigQuery, and Snowflake all behave the same way.

**Example that silently breaks**:

```sql
-- premium_users.user_id has one stray NULL row from a buggy ingestion job.
-- This query returns ZERO rows even though plenty of non-premium events exist.
SELECT user_id, event_id
FROM events
WHERE user_id NOT IN (SELECT user_id FROM premium_users)
  AND event_date = DATE '2026-05-26';
```

Why: as soon as the subquery contains one `NULL`, `events.user_id NOT IN (1, 2, NULL, ...)` evaluates to UNKNOWN for every row. UNKNOWN is not TRUE, so the WHERE filters everything out.

**Two safe rewrites — pick one**:

**Rewrite A: `NOT EXISTS` (recommended — works regardless of NULLs)**

```sql
SELECT e.user_id, e.event_id
FROM events e
WHERE NOT EXISTS (
  SELECT 1 FROM premium_users p WHERE p.user_id = e.user_id
)
  AND e.event_date = DATE '2026-05-26';
```

`NOT EXISTS` checks row-by-row whether a matching row exists. It returns TRUE/FALSE, never UNKNOWN — so NULLs in `premium_users.user_id` are simply ignored (they don't match anything). Trino decorrelates **non-correlated** `NOT EXISTS` into an **anti-join** (`SemiJoin` with FilterMode = ANTI) internally; in that case, EXPLAIN looks identical to the `NOT IN` plan and performance is comparable. **Correlated** `NOT EXISTS` is a different story — see the dedicated callout below.

> **Anti-join — what the term means.** An **anti-join** returns rows from the left side that have **NO matching row on the right side**. It's the relational-algebra opposite of a regular (inner) JOIN, which returns rows that DO have a match. `NOT EXISTS (SELECT 1 FROM right WHERE right.key = left.key)` and `LEFT JOIN right ON right.key = left.key WHERE right.key IS NULL` both produce anti-join semantics. For **non-correlated** subqueries, Trino's optimizer rewrites both into a single physical anti-join node (`SemiJoin`, FilterMode = ANTI), which is why their EXPLAIN plans look identical and they perform similarly. The "anti" is doing the same job as `NOT` in `NOT EXISTS`: keep the rows that did NOT find a match. Unlike `NOT IN`, an anti-join is **NULL-safe** — NULL rows on the right side simply don't match anything, instead of poisoning the WHERE clause via three-valued logic. This is exactly why the recommended fix for the `NOT IN` + NULL zero-rows bug is to switch to `NOT EXISTS` (which decorrelates to an anti-join), not just to add an `IS NOT NULL` filter to the subquery.

> **CRITICAL — correlated `NOT EXISTS` is NOT always as fast as `NOT IN`. Read this before claiming "performance should be identical."**
>
> The common shorthand "`NOT IN` and `NOT EXISTS` decorrelate to the same anti-join so performance is identical" is **only true for the non-correlated case**. For correlated `NOT EXISTS`, Trino's current implementation can be **measurably slower** than the equivalent `NOT IN` — and this is inherent executor cost, NOT a planner regression.
>
> **The two cases — be precise about which one you're looking at:**
>
> | Subquery shape | Lowered to | Performance characteristic |
> |---|---|---|
> | **Non-correlated** `NOT IN (SELECT col FROM t)` (no reference to outer row) | `SemiJoin` (FilterMode = ANTI) via the *Semi-Join (IN) Decorrelation* rule | Optimal anti-join. Hash-join, broadcast small side, probe big side, returns TRUE/FALSE per probe row. |
> | **Non-correlated** `NOT EXISTS (SELECT 1 FROM t WHERE <constant>)` (no outer-row reference inside the WHERE) | Same `SemiJoin` (FilterMode = ANTI) via the *Decorrelate Subqueries* rule | Comparable to NOT IN — both rules target the same physical operator. EXPLAIN plans look identical. |
> | **Correlated** `NOT EXISTS (SELECT 1 FROM t WHERE t.k = outer.k AND ...)` (the WHERE references the outer row) | `LeftJoin` + `Aggregation` + `Filter[not exists]` — **NOT** a SemiJoin | Can be **measurably slower** than the equivalent non-correlated NOT IN even when decorrelation succeeds. See below. |
>
> **Why the correlated NOT EXISTS path is slower** ([trinodb/trino #21859](https://github.com/trinodb/trino/issues/21859), still open as of mid-2026): the *Decorrelate Subqueries* rule rewrites a correlated `NOT EXISTS` into a plan shaped like `Filter[not exists] → Projection[exists] → Aggregation → LeftJoin(probe, build)`. The problem is the **`LeftJoin` enumerates ALL matches** — but for `NOT EXISTS`, a single match is enough to know the result is FALSE. The proposed optimization is to add a `singleMatch` flag to `JoinNode` so the LeftJoin can short-circuit on the first matching build row; **that optimization has not landed**. Result: a correlated NOT EXISTS produces many duplicate join rows that the downstream Aggregation must process and dedupe — work the `SemiJoin` operator avoids by construction (SemiJoin is built to return exactly one TRUE/FALSE per probe row, no duplicates ever).
>
> **What this looks like in EXPLAIN — the exact diagnostic that confirms the issue:**
>
> ```text
> -- Correlated NOT EXISTS in Trino — what you actually see, NOT a SemiJoin:
> Filter[not exists]
>   Project[exists := IS NOT NULL(p.user_id)]
>     Aggregate[group by e.event_id, e.user_id]   <- this aggregate dedupes the join blowup
>       LeftJoin[e.user_id = p.user_id]            <- enumerates all matches; cannot short-circuit
>         - TableScan[events e]
>         - TableScan[premium_users p]
> ```
>
> If EXPLAIN shows `LeftJoin` + `Aggregate` (without a `SemiJoin` node) on what you wrote as `NOT EXISTS`, you are hitting the #21859 path. **This is not a missing-stats problem and `ANALYZE` will not fix it** — it is the inherent shape of the current correlated-NOT-EXISTS plan.
>
> **Diagnostic flowchart when a user reports "NOT EXISTS is slower than NOT IN":**
>
> 1. **Is the subquery correlated?** Look at the subquery's WHERE clause — does it reference the outer table (e.g., `WHERE p.user_id = e.user_id`)? If NO (non-correlated), perf gap is unexpected — re-EXPLAIN and confirm both plans use `SemiJoin`; if so, the difference should be noise. If YES, continue.
> 2. **EXPLAIN both versions, compare physical operators.** `NOT IN` should show `SemiJoin` (FilterMode = ANTI). Correlated `NOT EXISTS` will show `LeftJoin` + `Aggregate` (without a SemiJoin). If you see this asymmetry, you are hitting [trinodb/trino #21859](https://github.com/trinodb/trino/issues/21859) — the correctness premium of NOT EXISTS comes at an executor cost.
> 3. **Pick a workaround based on nullability:**
>    - **Right-side column is `NOT NULL` (schema-enforced)**: stick with `NOT IN` — `SemiJoin` is the optimal physical operator and you don't need NOT EXISTS's NULL safety. This is the fastest option.
>    - **Right-side column is nullable but you want NOT EXISTS performance**: **rewrite as a non-correlated anti-join** — `LEFT JOIN ... ON ... WHERE right.key IS NULL` combined with `SELECT DISTINCT` on the inner side (see Rewrite B below and the "Worked example" section further down). This decorrelates back to `SemiJoin` (FilterMode = ANTI) and avoids the LeftJoin enumeration problem entirely.
>    - **You need correlated NOT EXISTS for correctness and can't rewrite**: accept the correctness premium. Document the cost. The fix has to come from Trino upstream — there is no user-side perf knob today.
>
> **Bottom line — what to tell a user who asks "I switched NOT IN to NOT EXISTS and it got slower, why?":** "Because Trino's executor for correlated NOT EXISTS uses a LeftJoin that cannot short-circuit on the first match (open Trino issue #21859), unlike NOT IN's SemiJoin which is built for one-true-or-false-per-probe-row semantics. EXPLAIN both — you'll see LeftJoin + Aggregate vs SemiJoin. If your column is NOT NULL, stay on NOT IN. If it's nullable, rewrite as `LEFT JOIN ... WHERE right IS NULL` with a `DISTINCT` on the inner side to get NULL-safe semantics AND SemiJoin performance." Do **not** tell users "perf should be identical" — that is the inaccuracy this section is here to correct.

**Rewrite B: `LEFT JOIN ... WHERE right IS NULL` (anti-join pattern)**

```sql
SELECT e.user_id, e.event_id
FROM events e
LEFT JOIN premium_users p ON e.user_id = p.user_id
WHERE p.user_id IS NULL
  AND e.event_date = DATE '2026-05-26';
```

This explicit anti-join is equivalent to `NOT EXISTS` and is what Trino produces internally after decorrelation. It's slightly more verbose but is sometimes easier to reason about when the matching condition is multi-column or has additional predicates.

**Defensive option: filter NULLs from the subquery before NOT IN**

If you really want to keep `NOT IN`, scrub NULLs out of the right side:

```sql
SELECT user_id, event_id
FROM events
WHERE user_id NOT IN (
  SELECT user_id FROM premium_users WHERE user_id IS NOT NULL
)
  AND event_date = DATE '2026-05-26';
```

This works, but it's fragile — every future `NOT IN` against this column needs the same `IS NOT NULL` guard. **Standardize on `NOT EXISTS`** instead.

**Rule of thumb**: never use `NOT IN` with a subquery on a nullable column. Always reach for `NOT EXISTS` first. The `IN`/`NOT IN` asymmetry is one of the most common silently-wrong-results bugs in real production SQL.

---

### When EXPLAIN shows `CorrelatedJoin` instead of `SemiJoin` — failed decorrelation remediation

**Symptom**: EXPLAIN shows a `CorrelatedJoin[...]` node where you expected `SemiJoin[...]`. This means **Trino's `Decorrelate Subqueries` optimizer rule could not transform your subquery into a flat join** — and the subquery will execute once per outer row at runtime. On a 100M-row outer table, that's 100M subquery executions.

**Two diagnostic paths in order**:

**Step 1 — Did stats cause the failure?** The CBO needs row count estimates to decorrelate safely. If the inner table has no stats, decorrelation rules sometimes bail out conservatively. Run `ANALYZE` and re-EXPLAIN:

```sql
SHOW STATS FOR iceberg.analytics.premium_users;
-- If row_count is NULL or data_size is NULL:
ANALYZE iceberg.analytics.premium_users;
-- Then re-run EXPLAIN. If CorrelatedJoin -> SemiJoin, you're done.
```

**Step 2 — If `CorrelatedJoin` persists after ANALYZE, rewrite by hand.** Trino can't decorrelate every shape — common blockers are aggregates with non-equality correlation, LIMIT inside the subquery without a strong unique-key signal, or NULL-sensitive predicates. Apply the LEFT JOIN + IS NOT NULL pattern below.

**Correlated `EXISTS` — manual rewrite to LEFT JOIN**

```sql
-- ORIGINAL: correlated EXISTS — EXPLAIN shows CorrelatedJoin.
SELECT e.user_id, e.event_id
FROM events e
WHERE EXISTS (
  SELECT 1
  FROM premium_users p
  WHERE p.user_id = e.user_id
    AND p.tier = 'gold'
);
```

```sql
-- MANUAL REWRITE: LEFT JOIN + IS NOT NULL — produces SemiJoin or InnerJoin in EXPLAIN.
SELECT e.user_id, e.event_id
FROM events e
LEFT JOIN (
  SELECT DISTINCT user_id FROM premium_users WHERE tier = 'gold'
) p ON p.user_id = e.user_id
WHERE p.user_id IS NOT NULL;
```

Why the `DISTINCT` matters: without it, if `premium_users` has duplicate `user_id` rows (a single user with two `tier='gold'` entries), the LEFT JOIN would multiply event rows — silently inflating any downstream COUNT or SUM. `EXISTS` doesn't multiply rows; `DISTINCT` on the inner side restores that semantic for the JOIN form.

#### Worked example end-to-end: BEFORE / AFTER with EXPLAIN snippets

Use this to convince yourself that the manual rewrite actually fixes the problem. Suppose `events` has 100M rows and `premium_users` has 200K rows (50K with `tier='gold'`).

**BEFORE — original correlated EXISTS, `ANALYZE premium_users` skipped, NO stats.**

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT e.user_id, e.event_id
FROM events e
WHERE EXISTS (
  SELECT 1 FROM premium_users p
  WHERE p.user_id = e.user_id AND p.tier = 'gold'
);
```

Trimmed EXPLAIN output (the diagnostic shape — leaf-level stats counts removed for clarity):

```
- Output[user_id, event_id]
    - CorrelatedJoin[type = INNER, correlation = [e.user_id]]
        - TableScan[iceberg:analytics.events]
            user_id := events.user_id
            event_id := events.event_id
        - Filter[p.user_id = e.user_id AND p.tier = 'gold']
            - TableScan[iceberg:analytics.premium_users]
                user_id := premium_users.user_id
                tier := premium_users.tier
```

The diagnostic word in this plan is **`CorrelatedJoin`**. That means Trino's `Decorrelate Subqueries` optimizer rule bailed out, so the subquery executes once for every row in `events` — 100M subquery scans of `premium_users`. Wall-clock time runs into hours; the query frequently exceeds the per-query time limit and gets killed.

**Diagnostic — run `SHOW STATS` first.** Before rewriting, see if missing stats are the cause:

```sql
SHOW STATS FOR iceberg.analytics.premium_users;
-- If row_count is NULL or distinct_values_count for user_id is NULL:
ANALYZE iceberg.analytics.premium_users;
-- Re-run the EXPLAIN above.
```

After `ANALYZE`, the CBO sometimes converts `CorrelatedJoin` to `SemiJoin` on its own — that's the cheapest fix and you're done. If EXPLAIN still shows `CorrelatedJoin`, proceed with the manual rewrite.

**AFTER — manual rewrite to LEFT JOIN + IS NOT NULL + DISTINCT.**

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT e.user_id, e.event_id
FROM events e
LEFT JOIN (
  SELECT DISTINCT user_id
  FROM premium_users
  WHERE tier = 'gold'
) p ON p.user_id = e.user_id
WHERE p.user_id IS NOT NULL;
```

Trimmed EXPLAIN output:

```
- Output[user_id, event_id]
    - Filter[p.user_id IS NOT NULL]
        - LeftJoin[e.user_id = p.user_id]
            - TableScan[iceberg:analytics.events]
                user_id := events.user_id
                event_id := events.event_id
            - Aggregate[group by p.user_id]
                - Filter[p.tier = 'gold']
                    - TableScan[iceberg:analytics.premium_users]
```

The structural change: the outer `CorrelatedJoin` node is gone. Trino sees this is a flat LEFT JOIN with a NULL-filter, recognizes the anti-join-complement pattern (rows that DID match), and may further rewrite the `LeftJoin + Filter[IS NOT NULL]` into a `SemiJoin` node:

```
- Output[user_id, event_id]
    - SemiJoin[e.user_id = p.user_id, output: SEMI]
        - TableScan[iceberg:analytics.events]
        - Aggregate[group by p.user_id]
            - Filter[p.tier = 'gold']
                - TableScan[iceberg:analytics.premium_users]
```

That `SemiJoin` is the optimal physical operator for "rows in `events` that have at least one match in filtered `premium_users`." It runs as a hash-join with the small filtered side broadcast to all workers, then probes the big `events` side once. Runtime collapses from hours to seconds.

**The three plan shapes you might see after the rewrite — and what each means:**

| EXPLAIN shape after rewrite | What happened | What to do next |
|---|---|---|
| `SemiJoin[...]` | Trino's `Transform Correlated Subquery to Join` rule fired and recognized the anti-pattern. Optimal. | Done. |
| `LeftJoin` + `Filter[IS NOT NULL]` (no SemiJoin) | Trino kept the literal LEFT JOIN shape (didn't further collapse it to SemiJoin). Still correct and still fast — the `Aggregate` (from DISTINCT) on the right side prevents row duplication. | Done. Optionally drop the DISTINCT and retry — Trino sometimes folds the join into SemiJoin only when it can prove the right side is unique-keyed. |
| `CorrelatedJoin` still present | Either you accidentally kept correlation (e.g., the rewrite still references `e.x` inside the subquery), or the inner side has stats missing on a column the planner needs. | Re-check the rewrite for residual correlation. Run `ANALYZE` on both tables. If still stuck, file the EXPLAIN in your ticket — this is a planner-edge-case escalation. |

**The exact same NOT EXISTS before/after pattern** — the manual rewrite changes the `WHERE p.user_id IS NOT NULL` to `WHERE p.user_id IS NULL` (the anti-join half: rows from `events` that did NOT match). EXPLAIN should produce the same SemiJoin physical operator, but with a "filter mode = ANTI" annotation or an equivalent inversion. The CorrelatedJoin → SemiJoin transformation is identical; only the post-join filter flips.

**Correlated `NOT EXISTS` — manual rewrite to LEFT JOIN + IS NULL**

```sql
-- ORIGINAL:
SELECT e.user_id
FROM events e
WHERE NOT EXISTS (
  SELECT 1 FROM blocked_users b WHERE b.user_id = e.user_id
);
```

```sql
-- MANUAL REWRITE:
SELECT e.user_id
FROM events e
LEFT JOIN blocked_users b ON b.user_id = e.user_id
WHERE b.user_id IS NULL;
```

**Correlated scalar subquery — manual rewrite to JOIN on pre-aggregated CTE**

```sql
-- ORIGINAL: correlated scalar (per-row average) — likely CorrelatedJoin.
SELECT e.event_id, e.amount
FROM events e
WHERE e.amount > (
  SELECT AVG(amount) FROM events WHERE event_date = e.event_date
);
```

```sql
-- MANUAL REWRITE: pre-aggregate then JOIN — fully decorrelated.
WITH daily_avg AS (
  SELECT event_date, AVG(amount) AS avg_amount
  FROM events
  GROUP BY event_date
)
SELECT e.event_id, e.amount
FROM events e
JOIN daily_avg d ON d.event_date = e.event_date
WHERE e.amount > d.avg_amount;
```

**The `Decorrelate Subqueries` rule**: this is the optimizer rule that handles correlated `EXISTS`, `NOT EXISTS`, and correlated scalar subqueries — the sibling of `Semi-Join (IN) Decorrelation` which handles uncorrelated `IN`. Both rules target the same goal (eliminate per-row subquery execution); they cover different subquery shapes.

**Quick triage table — what EXPLAIN told you and what to do**

| EXPLAIN node | What it means | Action |
|---|---|---|
| `SemiJoin[...]` | IN / EXISTS decorrelated into anti/semi-join — optimal. | Done. Leave it alone. |
| `InnerJoin[...]` | You wrote (or got rewritten to) a regular JOIN. | Check the right side for duplicates — JOIN does NOT dedupe like SemiJoin does. |
| `CorrelatedJoin[...]` | Decorrelation **failed** — subquery runs per outer row. | (1) ANALYZE inner table; re-EXPLAIN. (2) If still correlated, manually rewrite per patterns above. |

---

## 11. Use CTEs or subqueries — don't re-run the same expensive query twice

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

> **Terminology note — call this pattern by its right name.** The `aggregate(...) FILTER (WHERE <cond>)` form above and the equivalent `SUM(CASE WHEN <cond> THEN <metric> END)` form are both **conditional aggregation** — also called **manual pivot** or **crosstab** when you build a multi-column pivot (e.g., quarterly revenue as `q1_revenue, q2_revenue, q3_revenue, q4_revenue` columns). Trino has **no `PIVOT` keyword** — you write the conditional aggregation explicitly. The `FILTER (WHERE ...)` clause is supported on every Trino aggregate per [Trino aggregate functions docs](https://trino.io/docs/current/functions/aggregate.html).
>
> **DO-NOT-WRITE — banned mislabels:** "SCD-1 pivot", "Type-1 pivot", "SCD pivot pattern". SCD-1 (Slowly Changing Dimension Type 1) is an **unrelated Kimball dimension-modeling concept** — a strategy where new attribute values **overwrite** the old with no history retention (e.g., overwriting `customer_email` when a user updates it). It is **not** a pivot pattern. Conflating SCD-1 with conditional aggregation misleads anyone who later looks up the term. See [resource 07 § "Wide-pivot variant"](07-analytical-query-patterns.md) for the full quarterly-revenue worked example with both CASE-WHEN and FILTER forms side by side.

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
10. Does EXPLAIN show `SemiJoin` for any IN subqueries? (If yes, leave them — do not rewrite to a JOIN.)
11. If you wrote `NOT IN (SELECT ...)`, is the right-side column **guaranteed non-NULL**? (If not, rewrite to `NOT EXISTS` — otherwise you risk zero-row results.)
12. Does EXPLAIN show `CorrelatedJoin`? (If yes, ANALYZE the inner table; if still `CorrelatedJoin`, manually rewrite per the patterns in section 10.)
13. Are duplicate subqueries collapsed into a CTE or `FILTER (WHERE ...)`?

If you can answer "yes" to all thirteen, you avoid the most common 10x-cost mistakes that OLTP engineers make on their first day in Trino.

---

## Trino 467 SQL-dialect anti-patterns — do NOT carry these over from other warehouses

Trino has its own SQL dialect. A surprising number of features that "feel like standard SQL" because they exist in Snowflake / BigQuery / Databricks / Postgres are **NOT in Trino's grammar** and produce immediate parse errors when copy-pasted. Verify against [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) and the [release notes](https://trino.io/docs/current/release.html) before assuming a feature works on this stack.

### Anti-patterns and their Trino-compatible rewrites

| Feature you might reach for | Where it comes from | Status in Trino 467 | Trino-compatible rewrite |
|---|---|---|---|
| **`QUALIFY ROW_NUMBER() OVER (...) = 1`** (dedup / top-N-per-group) | Snowflake, BigQuery, Databricks, Teradata | **NOT supported.** Parse error. Long-standing feature request only (see [Starburst forum](https://www.starburst.io/community/forum/t/available-window-functions-and-qualify-statement/515/)). | Subquery + outer `WHERE rn = 1`: `SELECT * FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY k ORDER BY t DESC) AS rn FROM src) WHERE rn = 1;` |
| **`SELECT * EXCEPT (col1, col2)`** (column-exclusion projection) | BigQuery, Databricks, ClickHouse | **NOT supported.** Parse error. Open feature request [trinodb/trino #26969](https://github.com/trinodb/trino/issues/26969). | Spell out the columns you want. Use `DESCRIBE <table>` to list them, then copy/edit. |
| **`SELECT * REPLACE (expr AS col)`** (column-replacement projection) | BigQuery | **NOT supported.** Parse error. | Spell out columns: `SELECT col1, expr AS col2, col3 FROM t;` |
| **`LIMIT N BY col`** (per-group LIMIT) | ClickHouse | **NOT supported.** Parse error. | `ROW_NUMBER()` subquery + outer `WHERE rn <= N` (same pattern as the QUALIFY rewrite). |
| **`TOP N`** (Microsoft / Sybase row limit) | SQL Server, Sybase | **NOT supported.** Parse error. | `LIMIT N` (Trino's documented form) or `FETCH FIRST N ROWS ONLY` (also supported per Trino SELECT grammar). |
| **`DISTINCT ON (col)`** (Postgres' "one row per group") | PostgreSQL | **NOT supported.** Parse error. | `ROW_NUMBER()` subquery + outer `WHERE rn = 1` (same pattern as QUALIFY). |
| **`GENERATE_SERIES(...)`** as a table function | PostgreSQL | **NOT supported by that name.** Use Trino's `sequence(start, stop, step)` returning an array, then `UNNEST`. | `SELECT n FROM UNNEST(sequence(1, 10)) AS t(n);` |
| **`NOW() AT TIME ZONE 'UTC'`** | PostgreSQL syntax | **Different semantics.** Trino's `current_timestamp AT TIME ZONE 'UTC'` works on `TIMESTAMP WITH TIME ZONE`. | Use `current_timestamp AT TIME ZONE 'UTC'`, or `at_timezone(ts, 'UTC')`. |
| **`EXTRACT(EPOCH FROM ts)`** | PostgreSQL | **NOT supported as `EPOCH`.** | `to_unixtime(ts)` returns seconds-since-epoch as `DOUBLE`. |
| **`::cast` syntax** (`col::int`) | PostgreSQL, Snowflake, DuckDB | **NOT supported.** Parse error. Open feature request [trinodb/trino #23795](https://github.com/trinodb/trino/issues/23795). | Use ANSI `CAST(col AS INTEGER)` or Trino's `try_cast(col AS INTEGER)`. |
| **`/*+ HINT_NAME(...) */` query hints** (e.g., `USE_HASH_JOIN`, `BROADCAST`, `MAPJOIN`, `USE_PARTITIONED_JOIN`, `DISTRIBUTION_TYPE`) | Oracle, Spark, Hive | **SILENTLY IGNORED.** Trino has no query-hint mechanism — per [trinodb/trino #9498](https://github.com/trinodb/trino/issues/9498), open feature request, NOT implemented as of Trino 467/481. The `/*+ ... */` is parsed as a regular block comment; the "hint" never fires. **Failure mode: silent no-op, no error message.** | Use `SET SESSION <property> = <value>` before the query — e.g., `SET SESSION join_distribution_type = 'PARTITIONED';` (see [resource 24 § LEADING CANONICAL — How do I influence Trino's join distribution](24-trino-cbo-analyze.md)). |
| **`TO_CHAR(date, fmt)`** (Oracle date-to-string) | Oracle | **NOT a Trino built-in.** No `TO_CHAR` function exists. | `date_format(ts, '%Y-%m-%d')` (MySQL-style) or `format_datetime(ts, 'yyyy-MM-dd')` (Joda). See [resource 27 § 4.2A — Oracle TO_CHAR → Trino canonical](27-oracle-plsql-to-dbt-trino.md). |
| **`ANALYZE TABLE <t>`** (Spark / Hive stats DDL) | Spark, Hive, MySQL | **NOT supported.** Parse error. Trino's keyword is bare `ANALYZE`. | `ANALYZE iceberg.schema.table` — no `TABLE` keyword. See [resource 24 § 4.1](24-trino-cbo-analyze.md). |
| **`TIMESTAMPDIFF(MINUTE, a, b)`** | MySQL, SQL Server | **NOT supported.** | `date_diff('minute', a, b)` returns BIGINT. |
| **`DATE_FORMAT(d, '%Y-%m-%d')`** with MySQL specifiers | MySQL | **Format-string is different.** Trino uses Java/JodaTime patterns. | `format_datetime(d, 'yyyy-MM-dd')` or `date_format(d, '%Y-%m-%d')` — the second form accepts MySQL-style specifiers, but the recommended Trino form is `format_datetime` with Java patterns. |
| **`STRING_AGG(col, sep ORDER BY ...)`** | PostgreSQL | **NOT under that name.** | `listagg(col, sep) WITHIN GROUP (ORDER BY ...)` is Trino's ANSI-standard form. Added as a window function in Trino 467 release. |
| **`ARRAY_AGG` with implicit ORDER BY** | various | **No implicit ORDER BY** — Trino's `array_agg` is unordered unless specified. | `array_agg(col ORDER BY ts)` — always specify ORDER BY when order matters. |
| **`MERGE` on non-Iceberg connectors without flag** | various | **Per-connector gate.** Iceberg MERGE is supported by default; MySQL/PostgreSQL MERGE requires connector-specific flags (see resource 22 section 2A). | Check the connector's MERGE support matrix before assuming MERGE works. |
| **Postgres `RETURNING` clause** on INSERT/UPDATE/DELETE | PostgreSQL | **NOT supported.** Parse error. | Run a follow-up SELECT or use the `Trino transaction count(...) - count(...)` row-count diagnostics. |
| **`ILIKE`** (case-insensitive LIKE) | PostgreSQL | **Supported** — Trino has `ILIKE` as a keyword. But **pushdown** to PostgreSQL is conditional on `enable_string_pushdown_with_collate=true` + compatible column collation (see resource 22). | Use `col ILIKE 'pat%'` freely in Trino-evaluated filters; verify EXPLAIN for pushdown if the col is in a JDBC catalog. |
| **`GROUP BY ALL`** (group by every non-aggregate) | Snowflake, Databricks | **SUPPORTED** in Trino's SELECT grammar (`GROUP BY [ ALL | DISTINCT ] ...`). | Free to use, but explicit `GROUP BY col1, col2` is more grep-able. |
| **`FETCH FIRST N ROWS ONLY`** (ANSI) | ANSI SQL, DB2, Oracle | **SUPPORTED** alongside `LIMIT N`. | Either is fine; `LIMIT N` is shorter. |
| **Window function in WHERE** (`WHERE ROW_NUMBER() OVER (...) = 1`) | none — never legal in standard SQL | **NOT supported in any SQL dialect, including Trino.** | Wrap in a subquery: `SELECT * FROM (SELECT *, ROW_NUMBER() OVER (...) AS rn FROM t) WHERE rn = 1;` — same pattern as the QUALIFY rewrite. |

### The most-common Trino-dialect rewrite pattern

**90% of the dialect-mismatch errors a SaaS engineer hits on Trino can be fixed with one pattern**: the `ROW_NUMBER()` subquery + outer `WHERE rn = 1` (or `rn <= N` for top-N-per-group). Memorize this:

```sql
-- Generic top-N-per-group dedup pattern — works on Trino 467 for:
-- - "dedup before MERGE" (Snowflake's QUALIFY)
-- - "top-N-per-group" (ClickHouse's LIMIT N BY)
-- - "one row per group with max(ts)" (Postgres' DISTINCT ON)
-- - "TOP N per partition" (SQL Server's PARTITION BY in TOP)

SELECT col1, col2, col3   -- list real columns, avoid SELECT *
FROM (
    SELECT
        col1,
        col2,
        col3,
        ROW_NUMBER() OVER (PARTITION BY group_key ORDER BY ts DESC) AS rn
    FROM source_table
    WHERE <any_filters>
) WHERE rn <= 1   -- =1 for dedup; <=N for top-N
```

This is the canonical Trino form. Any "dedup" / "latest per group" / "top N per group" recipe you find online that uses `QUALIFY` / `LIMIT N BY` / `DISTINCT ON` / `TOP N PARTITION BY` translates 1:1 to this pattern.

### Why this matters for the prod stack

The production stack is **Trino 467 OSS + Iceberg 1.5.2**. dbt models compile to Trino SQL. Ad-hoc queries run through Trino. AI-assistant tools (including Cursor, Copilot, and ChatGPT) routinely suggest QUALIFY / LIMIT BY / DISTINCT ON because they pattern-match on more popular warehouses. **Every such suggestion fails immediately on this stack** — there is no graceful degradation, just a parse error at the coordinator. If a copy-pasted query fails with `mismatched input 'QUALIFY'` / `mismatched input 'BY'` / `mismatched input 'ON'`, reach for the `ROW_NUMBER()` subquery pattern above.

---

## Key terms

- **Predicate pushdown**: passing a WHERE condition down to the storage layer (Iceberg) so it can skip files instead of returning everything to Trino.
- **Partition pruning**: a form of predicate pushdown where Iceberg skips entire partition folders.
- **Broadcast join**: a join strategy where the smaller table is copied to every worker; fast for small-vs-big joins.
- **CBO (Cost-Based Optimizer)**: Trino's optimizer that reorders joins and chooses strategies using table statistics from `ANALYZE`.
- **HyperLogLog / T-Digest**: probabilistic sketch algorithms behind `approx_distinct` and `approx_percentile`.
- **ScanFilterProject vs TableScan with constraint**: in EXPLAIN, the former means filtering happens in Trino memory; the latter means Iceberg already filtered the files.
- **SemiJoin**: the join type Trino uses internally for `IN (SELECT ...)` subqueries. Unlike an INNER JOIN, a SemiJoin returns at most one output row per probe row (no duplication), which is the correct semantic for IN predicates. Trino's `optimize-hash-generation` property applies precomputed hashes to SemiJoin nodes by default.
- **CorrelatedJoin**: a subquery that references columns from the outer query. Trino tries to decorrelate these automatically; if it can't (shown as `CorrelatedJoin` in EXPLAIN), the subquery re-runs once per outer row — expensive. Fix by running ANALYZE on the subquery table first, then rewriting if needed.
- **Decorrelate Subqueries rule**: Trino's optimizer rule that converts correlated `EXISTS`, `NOT EXISTS`, and correlated scalar subqueries into flat joins (often LEFT JOIN + IS NOT NULL / IS NULL). Sibling of the `Semi-Join (IN) Decorrelation` rule which handles uncorrelated `IN`. **Important asymmetry:** the IN-decorrelation rule produces a `SemiJoin` (optimal anti/semi-join with one-true-or-false-per-probe-row semantics). The Decorrelate Subqueries rule for **correlated** `NOT EXISTS` produces a `LeftJoin + Aggregation` shape that enumerates all matches (cannot short-circuit on the first match) — see [trinodb/trino #21859](https://github.com/trinodb/trino/issues/21859). The proposed `singleMatch` JoinNode flag has not landed, so correlated `NOT EXISTS` can be measurably slower than the equivalent `NOT IN` even when decorrelation "succeeds." Workaround: rewrite as a non-correlated anti-join (`LEFT JOIN ... WHERE right IS NULL` with a `DISTINCT` inner subquery) to force the SemiJoin path while keeping NULL-safe semantics.
- **Anti-join**: a join that returns rows from the left side that have **no** match on the right side. The relational algebra operator behind `NOT EXISTS` and `LEFT JOIN ... WHERE right IS NULL`. Unlike `NOT IN`, anti-joins are NULL-safe: NULL rows on the right side are simply ignored, never returning UNKNOWN.
- **Three-valued logic (3VL)**: SQL's logical system with TRUE / FALSE / UNKNOWN. NULL comparisons produce UNKNOWN, which the WHERE clause treats as "exclude this row." The `NOT IN` + NULL gotcha (zero-row results when the right subquery has any NULL) is a direct consequence of 3VL.
