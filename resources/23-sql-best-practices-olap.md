# SQL Query Best Practices for OLAP (Trino + Iceberg)

If you came from Postgres or MySQL, your SQL habits will work in Trino — but they will be **slow and expensive**. OLTP databases have B-tree indexes that let you find a single row in microseconds. Trino + Iceberg has **no user-creatable secondary indexes** of any kind — no `CREATE INDEX`, no `ADD INDEX`, no implicit indexing on `PRIMARY KEY` (the Iceberg connector accepts `PRIMARY KEY` only as documentation metadata; nothing is enforced or indexed). Every query reads chunks of Parquet files from MinIO over the network. The cost of a bad query is measured in **bytes scanned**, not milliseconds. For the canonical "how do I make filters fast in Trino without indexes" answer (partition transforms → `sorted_by` + `EXECUTE optimize` → `ANALYZE` → Parquet bloom filters), see **[resource 03 § Iceberg mitigations when you DO need point lookups](03-columnar-storage.md#iceberg-mitigations-when-you-do-need-point-lookups-on-a-fact-table)** LEADING CANONICAL.

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

> **Cross-ref — dbt snapshots / SCD2 / timestamp vs check strategy / check_cols / dbt_valid_from / dbt_valid_to / dbt_scd_id / dbt_is_deleted:** see **[resource 09 § Slowly Changing Dimensions — Option 1 dbt snapshot (§1a `strategy='timestamp'`, §1b `strategy='check'`)](09-lakehouse-schema-design.md#slowly-changing-dimensions-scd)** — the SINGLE source of truth on this stack. Snapshot mechanics (the four `dbt_*` metadata columns, the `WHERE dbt_valid_to IS NULL` current-rows pattern, the parse-error matrix for missing `updated_at` / missing `check_cols` / list-wrapped `['all']` / non-existent strategies) are NOT duplicated here.

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

### LEADING CANONICAL — multiple `COUNT(DISTINCT col)` in ONE `SELECT` (Trino native — NO subqueries / NO self-join needed)

> **Keyword anchors:** multiple COUNT DISTINCT Trino, COUNT DISTINCT two columns one query, COUNT DISTINCT multiple columns same SELECT, count distinct users and sessions same query, distinct count without subquery, COUNT DISTINCT three columns Trino, multi-column distinct count, conditional COUNT DISTINCT FILTER, distinct_aggregations_strategy.

- **Trino natively supports multiple `COUNT(DISTINCT ...)` aggregates on DIFFERENT columns in ONE `SELECT` (with or without `GROUP BY`). You do NOT need to write two subqueries and JOIN them.** Just list them as separate select-list expressions:

  ```sql
  -- One SELECT, multiple distinct counts on different columns — fully supported:
  SELECT
    COUNT(DISTINCT user_id)    AS unique_users,
    COUNT(DISTINCT session_id) AS unique_sessions,
    COUNT(DISTINCT page_url)   AS unique_pages
  FROM iceberg.analytics.events
  WHERE event_date = DATE '2026-05-26';

  -- With GROUP BY — also fully supported:
  SELECT
    event_date,
    COUNT(DISTINCT user_id)    AS dau,
    COUNT(DISTINCT session_id) AS sessions
  FROM iceberg.analytics.events
  GROUP BY event_date
  ORDER BY event_date;

  -- Conditional distinct counts in the same SELECT — use the standard FILTER clause
  -- (NOT a subquery; not a CASE WHEN inside DISTINCT):
  SELECT
    event_date,
    COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'login')    AS distinct_loggers,
    COUNT(DISTINCT user_id) FILTER (WHERE event_name = 'purchase') AS distinct_buyers
  FROM iceberg.analytics.events
  GROUP BY event_date;
  ```

- **Performance note:** multiple `COUNT(DISTINCT)` calls in one query ARE more expensive than a single one — each distinct column typically forces an extra shuffle pass (Trino's `MarkDistinct` strategy). When the query is slow, **first** try the `distinct_aggregations_strategy` session knob (real values: `automatic` (default), `mark_distinct`, `single_step`, `pre_aggregate`, `split_to_subqueries` — verified at [trino.io/docs/current/admin/properties-optimizer.html](https://trino.io/docs/current/admin/properties-optimizer.html); `pre_aggregate` and `split_to_subqueries` often win for multi-distinct queries — see the strategy section below). **Then** if exactness is optional, replace each `COUNT(DISTINCT col)` with `approx_distinct(col)` (HLL, ~2.3% standard error, one cheap merge shuffle regardless of how many distinct columns you ask for).

**DO-NOT-WRITE (banned framings — each is FALSE on Trino):**
- "You must write a separate subquery for each `COUNT(DISTINCT col)` and JOIN them together" — **FALSE.** Trino supports multiple distinct aggregates in one SELECT natively. The `split_to_subqueries` strategy implements that JOIN internally as a planner choice — you don't write it by hand.
- "Trino can only do one `COUNT(DISTINCT)` per query" / "multiple distinct aggregations aren't supported in a single SELECT" — **FALSE.**
- "Use `COUNT(DISTINCT (col1, col2))` to count distinct pairs" — Trino requires a function-style call; the supported form for distinct PAIRS is `COUNT(DISTINCT ROW(col1, col2))` (or pre-concat to a single key). The multi-column-distinct discussion above is about MULTIPLE INDEPENDENT distinct aggregates on different columns, not about composite-key DISTINCT.

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

> **`approx_percentile` signature family — the FOUR official Trino 467/481 overloads** (verified verbatim at [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html)). **Keyword anchors:** approx_percentile signature, approx_percentile weight parameter, approx_percentile array of percentages, multiple percentiles one pass, p50 p95 p99 Trino, exact percentile Trino, PERCENTILE_CONT Trino, approx_percentile accuracy parameter.
> 1. `approx_percentile(x, percentage) -> [same as x]` — single percentile of `x`.
> 2. `approx_percentile(x, percentages) -> array<[same as x]>` — **multiple percentiles in ONE pass**, returns an array aligned to the input `ARRAY[...]` (e.g. `ARRAY[0.5, 0.95, 0.99]`). Always prefer this over running three separate `approx_percentile` calls — one sketch, one shuffle, three numbers out.
> 3. `approx_percentile(x, w, percentage) -> [same as x]` — **per-row weight** `w` (a positive bigint). Use when each row in `x` represents `w` underlying observations (e.g. a pre-aggregated row of `latency_ms` that already counts `w` events). `w` must be the **2nd** positional arg, percentage the 3rd.
> 4. `approx_percentile(x, w, percentages) -> array<[same as x]>` — weighted form of #2: per-row weight `w` plus an array of percentages, multiple weighted percentiles in one pass.
>
> **DO-NOT-WRITE — pre-empt the two most common fabrications:**
> - `approx_percentile(x, percentage, accuracy)` or `approx_percentile(x, w, percentage, accuracy)` — **does NOT exist on current Trino `approx_percentile`.** The `accuracy` parameter lives on a **different function**, `qdigest_agg(x, w, accuracy) -> qdigest([same as x])` (see `qdigest` family on the same page). If a caller needs tunable accuracy, they must build a qdigest explicitly with `qdigest_agg(..., accuracy)` and then call `value_at_quantile(qdigest, percentage)` — they do **not** pass `accuracy` to `approx_percentile`. Older Presto (pre-Trino fork) had an accuracy overload on approx_percentile; current Trino 467/481 does not.
> - `PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY latency_ms)` and `PERCENTILE_DISC(...) WITHIN GROUP (...)` — **Postgres / Snowflake / Oracle syntax**, NOT Trino. Trino has no `WITHIN GROUP` clause. For approximate, use the four `approx_percentile` overloads above. For an exact-ish per-row percentile, use the window function `PERCENT_RANK() OVER (ORDER BY latency_ms)` (returns the fraction `[0.0, 1.0]` per row — see resource 07 Pattern C2).
>
> **Accuracy note — do NOT confuse with `approx_distinct`'s 2.3% figure.** The 2.3% standard-error number that Trino docs publish belongs specifically to **`approx_distinct`** (HyperLogLog) — it is NOT the documented error for `approx_percentile`. Trino's [`approx_percentile`](https://trino.io/docs/current/functions/aggregate.html) page does not publish a single fixed-percentage error bound; the accuracy is fixed by the T-Digest sketch the function builds internally (you cannot tune it from `approx_percentile`'s signature — see DO-NOT-WRITE above). For most analytical-dashboard use cases the error on p50/p95/p99 is very small (typically well under a percent for well-conditioned distributions), but if you need a doc-grade guarantee you cite it as "T-Digest sketch-based; accuracy depends on the underlying sketch, not a user-supplied parameter to `approx_percentile`" — never as "2.3%".

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

> **`approx_set` precision is FIXED at ~2.3% — there is NO `approx_set(x, e)` overload** (verified at [trino.io/docs/current/functions/hyperloglog.html](https://trino.io/docs/current/functions/hyperloglog.html); the only signature is `approx_set(x) -> HyperLogLog`). **Keyword anchors:** approx_set precision, tune HLL sketch error, approx_set no second argument, approx_distinct vs approx_set precision, tighter than 2.3% distinct sketch. The stored sketch is fixed at ~2.3% and every sketch you persist and later `merge()` shares the one fixed precision; for a tighter one-off (non-mergeable) count, use the SCALAR `approx_distinct(visitor_id, 0.01)` ≈ 1% standard error (valid range `[0.0040625, 0.26000]`) — see the `approx_distinct(x, e)` canonical above — or fall back to exact `COUNT(DISTINCT)`. **DO NOT WRITE:** `approx_set(x, e)` with a 2nd precision arg (does NOT exist — only `approx_distinct` takes `e`).

You pay the sketch-building cost once per day (a single GROUP BY on the new partition). Every WAU/MAU/30D-active query after that reads at most 30 small rows from the sketch table and does a cheap merge — no scan of the 500M-row events table. This is the standard solution for rolling window cardinality in Trino, Snowflake, BigQuery, and DuckDB; they all expose the same three primitives.

---

## 3.1A. Trino string-split family reference — `split` / `split_part` / `split_to_map` / `split_to_multimap`

**Keyword anchor:** split_to_map, split_to_multimap, split_part, SPLIT function Trino, split comma-separated string, key=value string parse, extract value by key from delimited string, parse key-value pairs from string, MAP from delimited string, tags array count per tag (SPLIT then UNNEST).

**Why this section exists.** Trino 467 has a **family of four** string-split functions — and the iter505 responder fab claimed "Trino has NO `split_to_map`", which is **false**. All four are documented at [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html) verbatim. Here are the exact signatures and one-line use cases.

### The four functions (verified at trino.io/docs/current/functions/string.html)

| Function | Signature | Returns | One-line use case |
|---|---|---|---|
| **`split`** | `split(string, delimiter)` | `ARRAY(VARCHAR)` | Split `'a,b,c'` into `ARRAY['a','b','c']`. Most common — pair with `CROSS JOIN UNNEST(...)` to explode into rows. |
| **`split` (3-arg, with limit)** | `split(string, delimiter, limit)` | `ARRAY(VARCHAR)` | Same as 2-arg but stops at `limit` elements; the last element contains the unsplit remainder. `split('a,b,c,d', ',', 2)` → `['a','b,c,d']`. |
| **`split_part`** | `split_part(string, delimiter, index)` | `VARCHAR` | Return the **N-th** piece (1-indexed). `split_part('acme.ourapp.com', '.', 1)` → `'acme'`. **Returns `NULL` if `index` is out of range** (NOT empty string — see [resource 27 §4.3](27-oracle-plsql-to-dbt-trino.md)). |
| **`split_to_map`** | `split_to_map(string, entryDelimiter, keyValueDelimiter)` | `MAP(VARCHAR, VARCHAR)` | Parse a string like `'k1=v1;k2=v2'` into a map. `split_to_map('k1=v1;k2=v2', ';', '=')` → `MAP{'k1':'v1','k2':'v2'}`. Access values with `element_at(m, 'k1')`. |
| **`split_to_multimap`** | `split_to_multimap(string, entryDelimiter, keyValueDelimiter)` | `MAP(VARCHAR, ARRAY(VARCHAR))` | Like `split_to_map` but **groups repeated keys into an array of values** — use when the same key may appear multiple times. `split_to_multimap('a=1;a=2;b=3', ';', '=')` → `MAP{'a':['1','2'],'b':['3']}`. |

### Worked examples

```sql
-- 1. split + UNNEST: explode a comma-separated VARCHAR column into rows.
--    "Count occurrences per tag, where tags is stored as 'a,b,c' in a single column."
SELECT TRIM(tag) AS tag, COUNT(*) AS n
FROM iceberg.analytics.events
CROSS JOIN UNNEST(split(tags, ',')) AS t(tag)
WHERE event_date = DATE '2026-05-26'
GROUP BY TRIM(tag)
ORDER BY n DESC;
-- See resource 07 §1a.1 for the SQL clause-order rule
-- (CROSS JOIN UNNEST must appear BEFORE the WHERE clause).

-- 2. split_part: extract the N-th delimited piece as a scalar.
--    "Pull the subdomain from a hostname."
SELECT split_part(host, '.', 1) AS subdomain
FROM iceberg.analytics.requests;

-- 2a. split_part for "the part AFTER (or BEFORE) a single delimiter" — the clean idiom.
--     "Pull the domain (everything after the '@') from an email address."
--     "Pull the local-part (everything before the '@') from an email address."
SELECT
  split_part(email, '@', 2) AS domain,      -- 'jane@acme.com' -> 'acme.com'  (field index 2 = part AFTER the '@')
  split_part(email, '@', 1) AS local_part   -- 'jane@acme.com' -> 'jane'      (field index 1 = part BEFORE the '@')
FROM iceberg.analytics.users;
-- Trino's split_part is 1-indexed: index 1 = the piece BEFORE the (first) delimiter,
-- index 2 = the piece AFTER it. Same idiom works for any single-delimiter split:
--   split_part(code,  '-',  2)   -- 'US-CA-94107'  -> 'CA'       (middle piece)
--   split_part(ts,    ':',  1)   -- '14:32:09'     -> '14'       (hour, part before first ':')
--   split_part(url,   ':',  2)   -- 'https://acme' -> '//acme'   (part after first ':')
-- For "the LAST piece" of a multi-delimiter string (split_part does NOT accept
-- negative indexes), use element_at(split(...), -1) instead:
--   element_at(split(path, '/'), -1)   -- '/var/log/app.log' -> 'app.log'

-- 3. split_to_map: parse a 'k1=v1;k2=v2' string and read a key.
--    "Pull the 'utm_source' value out of a semicolon-separated query-string blob."
SELECT
  element_at(split_to_map(qs, ';', '='), 'utm_source') AS utm_source,
  COUNT(*) AS n
FROM iceberg.analytics.page_views
WHERE event_date = DATE '2026-05-26'
GROUP BY element_at(split_to_map(qs, ';', '='), 'utm_source')
ORDER BY n DESC;

-- 4. split_to_multimap: when the same key can appear multiple times.
--    "Parse a 'tag=a;tag=b;tag=c' string; tag is a multi-valued attribute."
SELECT split_to_multimap('tag=a;tag=b;tag=c', ';', '=') AS m;
-- Result: MAP{'tag': ['a','b','c']}
```

### `split_part` for "the part AFTER (or BEFORE) a single delimiter" — the clean Trino-native idiom

**Keyword anchors:** domain from email, everything after the @, the part after a character/delimiter, the part before a character, pull the local-part / domain, split on a single delimiter and take a field, cleaner than strpos+substr, part after the colon/dash/slash, extract substring after a character Trino, clean way to get part of a string Trino.

**The clean idiom.** For "give me everything AFTER (or BEFORE) a single-character delimiter", prefer **`split_part(s, delim, n)`** over `substr(s, strpos(s, delim) + 1)`. It's the direct, readable form — one function call, no offset arithmetic, no off-by-one risk.

| Goal | Clean idiom (PREFER) | Messy equivalent (avoid) |
|---|---|---|
| Part AFTER the `@` (the domain) | `split_part(email, '@', 2)` → `'acme.com'` | `substr(email, strpos(email, '@') + 1)` |
| Part BEFORE the `@` (the local-part) | `split_part(email, '@', 1)` → `'jane'` | `substr(email, 1, strpos(email, '@') - 1)` |
| Part AFTER the `:` (e.g. minutes from `'HH:MM'`) | `split_part(ts, ':', 2)` | `substr(ts, strpos(ts, ':') + 1)` |
| Part BEFORE the first `/` of a path | `split_part(path, '/', 1)` | `substr(path, 1, strpos(path, '/') - 1)` |

**Why `split_part` is the lead.** Per [trino.io/docs/467/functions/string.html](https://trino.io/docs/current/functions/string.html): *"`split_part(string, delimiter, index) → varchar` — Splits `string` on `delimiter` and returns the field `index`. Field indexes start with 1."* and *"If the index is larger than the number of fields, then null is returned."* That is — index `1` is the piece **before** the (first) delimiter; index `2` is the piece **after** it; an out-of-range index returns `NULL` (NOT empty string — see `DO NOT WRITE` table below). The `strpos` + `substr` form is correct but unnecessarily verbose, fragile (off-by-one on the `+1` / `-1`), and silently produces a garbage long string if the delimiter is missing (whereas `split_part` returns the original string when there's no match at index 1, or `NULL` for higher indexes).

**Note on multi-delimiter strings.** `split_part` always takes the **N-th** piece. For "the LAST piece" (e.g., filename from a path with an unknown number of `/`), `split_part` does **NOT** accept a negative index — use `element_at(split(path, '/'), -1)` instead (`element_at` on an array supports negative indexing from the tail; verified at [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html)).

### DO NOT WRITE

| False claim | Reality |
|---|---|
| "Trino has no `split_to_map`." | **FALSE.** `split_to_map(string, entryDelimiter, keyValueDelimiter) -> MAP(VARCHAR, VARCHAR)` is a documented Trino 467 built-in — see [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html). |
| "Use `regexp_extract` to parse `k=v;k=v` strings — Trino has no map-from-string function." | **FALSE.** Reach for `split_to_map` (or `split_to_multimap` for repeated keys) first; regex is the wrong tool. |
| "`split_to_map` returns a JSON string." | **FALSE.** It returns a true `MAP(VARCHAR, VARCHAR)` — read keys with `element_at(m, 'key')` or iterate with `map_entries(m)`. |
| "`split_part` returns empty string when the index is out of range." | **FALSE.** It returns `NULL` (Trino #14460). See [resource 27 §4.3](27-oracle-plsql-to-dbt-trino.md) for the canonical row. |
| "`split_to_map` works on duplicate keys." | **FALSE.** Duplicate keys raise an error — use `split_to_multimap` instead, which groups duplicates into an array per key. |
| "`contains(split(col, ','), 'web')` is whitespace-safe for tag-membership tests." | **FALSE — exact array-element match.** `split('mobile, web, api', ',')` returns `ARRAY['mobile', ' web', ' api']` (note the leading spaces), so `contains(..., 'web')` returns **`FALSE`** because `' web'` != `'web'`. Fix by either splitting on the literal `', '` (`split(col, ', ')`) when the delimiter is consistent, or by trimming each element after the split: `contains(transform(split(col, ','), x -> trim(x)), 'web')`. The `UNNEST` worked example above already calls `TRIM(tag)` for the same reason. |

**Cross-reference.** For the canonical `CROSS JOIN UNNEST` + WHERE-clause-order rule (the iter505 trap where engineers place `WHERE` BEFORE the JOIN), see [resource 07 §1a.1](07-analytical-query-patterns.md). For Oracle migration mapping `INSTR` / `SUBSTR` / `REGEXP_*` → Trino, see [resource 27 §4.3](27-oracle-plsql-to-dbt-trino.md).

---

### LEADING CANONICAL — Trino `format(format_string, args...)` — printf / Java-Formatter-style string building

> **Keyword anchors:** Trino format function, printf Trino, build display string, format string Trino, String.format Trino, format number with commas, format vs concat, format thousands separator, format percent, zero-pad integer Trino, formatted display string Trino. Verified at [trino.io/docs/467/functions/string.html](https://trino.io/docs/current/functions/string.html).

**Signature.** `format(format_string, args...) -> varchar` — Java `String.format` / `printf`-style. Per the Trino docs: *"Returns a formatted string using the specified format string and arguments"* — the format string follows Java's `java.util.Formatter` syntax. Common specifiers:

| Specifier | Meaning | Example | Output |
|---|---|---|---|
| `%s` | String (any type — formats whatever's there) | `format('hi %s', name)` | `hi alice` |
| `%d` | Integer / bigint | `format('%d orders', cnt)` | `42 orders` |
| `%,d` | Integer with thousands grouping | `format('%,d', 1234567)` | `1,234,567` |
| `%05d` | Zero-padded integer (width 5) | `format('%05d', 42)` | `00042` |
| `%.2f` | Float with 2 decimal places | `format('%.2f', 3.14159)` | `3.14` |
| `%,.2f` | Float with thousands grouping + 2 decimals | `format('%,.2f', 1234567.89)` | `1,234,567.89` |
| `%.1f%%` | Float with 1 decimal + literal `%` (escape `%` as `%%`) | `format('%.1f%%', 87.5)` | `87.5%` |

**Worked example — multi-field display string:**
```sql
SELECT format('User %s made %d purchases totaling $%,.2f',
              user_id, purchase_count, total_amount) AS summary
FROM customer_summary;
-- => 'User U-1234 made 17 purchases totaling $1,234.56'
```

**Why prefer `format()` over long `||` chains.** `format()` handles the type conversion automatically — `%d` takes a BIGINT directly, `%.2f` takes a DOUBLE/DECIMAL directly. The `||` / `concat()` operator in Trino REQUIRES all-VARCHAR arguments (does NOT auto-coerce numerics), so building the same string via `||` requires `CAST(...)` on every numeric piece: `'User ' || user_id || ' made ' || CAST(purchase_count AS VARCHAR) || ' purchases totaling $' || CAST(total_amount AS VARCHAR)` — uglier AND loses the comma-grouping / decimal-precision formatting.

**Distinguish from related "format" functions — DIFFERENT functions, different uses:**

| Function | Use it for | Format string style |
|---|---|---|
| **`format(fmt, args...)`** | **General printf-style string building** (numbers, strings, dates via `%t` specifiers) | Java `Formatter` / `printf` |
| `format_datetime(ts, pattern)` | Format a timestamp/date using **Joda-Time** patterns | Joda (`yyyy-MM-dd HH:mm:ss`) |
| `date_format(ts, pattern)` | Format a timestamp/date using **MySQL-style** specifiers | MySQL (`%Y-%m-%d %H:%i:%s`) |
| `json_format(json_value)` | Serialize a JSON value to its string representation | N/A — takes a JSON, returns VARCHAR |

For ordinary date-to-string formatting, prefer `date_format` or `format_datetime` (they take a single timestamp and a single pattern — cleaner than `format('%1$tY-%1$tm-%1$td', ts)`). For general-purpose printf-style **multi-arg** string building (a number + a string + a percent + a currency amount in ONE call), `format()` is the right answer.

### DO NOT WRITE

| False claim | Reality |
|---|---|
| "Trino has no `format()` function — you have to use `||` / `concat()` for string building." | **FALSE.** `format(format_string, args...) -> varchar` is a documented Trino 467 built-in string function — see [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html). |
| "Trino has no printf-style formatter." | **FALSE.** `format()` IS Trino's printf. It uses Java `Formatter` syntax: `%s`, `%d`, `%.2f`, `%,d`, `%05d`, `%%`. |
| "Use `format_datetime` to build a multi-field display string with numbers and a percent sign." | **WRONG FUNCTION.** `format_datetime(ts, pattern)` formats ONE timestamp using a Joda pattern. For a multi-arg `'User %s made %d purchases totaling $%,.2f'`-style string, use `format(fmt, args...)`. |
| "Use `date_format` to build a numeric display string with a thousands separator." | **WRONG FUNCTION.** `date_format(ts, pattern)` is for date/time formatting (MySQL-style). For numeric formatting (`%,.2f`, `%,d`), use `format(fmt, n)`. |
| "Use `json_format` to print a number with 2 decimal places." | **WRONG FUNCTION.** `json_format(json)` serializes a JSON value to its text form. For printf-style numeric formatting, use `format('%.2f', n)`. |

**Cross-reference.** For the Oracle `||` implicit-coerce trap that drives engineers to look for a printf-style alternative, see [resource 27 §7A.3.1](27-oracle-plsql-to-dbt-trino.md) — that section's "option B: use `format()`" worked example is migration-specific; THIS section is the generic Trino SQL canonical for any printf-style string building.

---

## 3.1B. `SUM(DECIMAL)` auto-widens to `decimal(38, s)` — you do NOT need to CAST, and Trino does NOT silently truncate

**Keyword anchors:** SUM decimal precision Trino, sum looks too small, decimal overflow Trino, decimal 38 auto widen, NUMERIC_VALUE_OUT_OF_RANGE, money sum precision, DECIMAL(10,2) overflow SUM, CAST DECIMAL 38 sum aggregate.

**The one-line rule (verified at [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html)):** Trino's `sum(decimal(p, s)) -> decimal(38, s)` and `avg(decimal(p, s)) -> decimal(38, s)`. **Precision is auto-widened to 38 (Trino's maximum); scale is retained.** A `DECIMAL(10, 2)` column summed over 400M rows reaches at most ~4e16 (~17 digits), comfortably below precision 38 (which holds ~1e38). **You do NOT need to write `SUM(CAST(x AS DECIMAL(38, 2)))` to avoid row-count overflow — the engine already does the widening for you.**

**If the result actually overflows precision 38**, Trino raises a hard error (`NUMERIC_VALUE_OUT_OF_RANGE` in current versions; older versions surfaced an `ArithmeticException: Decimal overflow` — see [trinodb/trino #20227](https://github.com/trinodb/trino/issues/20227)). **Trino does NOT silently truncate or return a wrong number** — silent truncation is a folklore claim from cloud-warehouse migration guides, not Trino behavior.

### "SUM looks too small / numbers are truncated" — the REAL causes (troubleshooting checklist)

When a `SUM(decimal)` result looks smaller than expected, the cause is NEVER silent decimal truncation. Walk this list in order:

1. **Unintended `WHERE` filter** narrowing rows — re-run the count: `SELECT COUNT(*) FROM t WHERE <your-where>` and compare to `SELECT COUNT(*) FROM t`. A typo'd date predicate or `event_type = 'PURCASE'` (typo) drops 99% of rows silently.
2. **A `JOIN` dropping rows (inner join, key mismatch) or fanning rows (right-side duplicates inflate, then the SUM is over an inflated denominator after a DISTINCT)** — verify join keys with `SELECT COUNT(*), COUNT(DISTINCT k) FROM right_table` and check whether you expect `INNER`, `LEFT`, or `SEMI` semantics.
3. **An upstream `CAST` to a smaller scale truncating cents** — e.g., `CAST(amount_usd AS DECIMAL(10, 0))` drops the decimal cents BEFORE the SUM, so `99.99 + 99.99 = 198.00` becomes `99 + 99 = 198`. Look for `CAST(... AS DECIMAL(p, 0))` or `CAST(... AS BIGINT)` on a money column upstream.
4. **NULL-heavy column** — `SUM` skips NULLs (treats them as zero contribution). Run `SELECT COUNT(*), COUNT(amount), SUM(amount) FROM t` — if `COUNT(*) > COUNT(amount)`, the gap is NULLs. This is correct ANSI SQL behavior; not a bug.
5. **Integer division upstream** — `SELECT SUM(a / b) FROM t` where `a` and `b` are `BIGINT` does INTEGER division per row (truncates each ratio to 0 if `a < b`), THEN sums. Cast at least one operand: `SUM(CAST(a AS DOUBLE) / b)` or `SUM(CAST(a AS DECIMAL(18, 4)) / b)`.

**Diagnose with:** `SHOW CREATE TABLE iceberg.<schema>.<table>` (verify the column's declared `DECIMAL(p, s)`), `SELECT COUNT(*), COUNT(<col>), MIN(<col>), MAX(<col>), SUM(<col>) FROM <t> WHERE <your-filter>` (see what the optimizer actually scans), and re-EXPLAIN to confirm no upstream `Cast` to a narrower type.

### DO NOT WRITE

| False claim | Reality |
|---|---|
| "Trino's `SUM` does not widen the DECIMAL result — it stays at the input precision and you get silent overflow on large sums." | **FALSE.** `sum(decimal(p, s))` returns `decimal(38, s)`. Documented at [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html). |
| "Summing a `DECIMAL(10, 2)` column over millions of rows silently truncates / wraps around." | **FALSE.** Trino raises `NUMERIC_VALUE_OUT_OF_RANGE` (a hard ERROR) on actual overflow of `decimal(38, s)`. No silent truncation. See [trinodb/trino #20227](https://github.com/trinodb/trino/issues/20227). |
| "You must write `SUM(CAST(amount AS DECIMAL(38, 2)))` to prevent row-count overflow on a `DECIMAL(10, 2)` money column." | **UNNECESSARY.** The engine already widens to `decimal(38, 2)`. Adding the CAST adds no protection and adds noise. (CAST only when the input column is `DOUBLE` and you want fixed-precision summation — different problem.) |
| "Trino silently truncates DECIMAL aggregate results." | **FALSE.** Overflow is a hard error; under-precision-38 results are exact. The "looks too small" symptom is always one of the 5 causes in the checklist above, never silent decimal truncation. |

**Sources:** [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) — `sum(decimal(p, s)) -> decimal(38, s)`, `avg(decimal(p, s)) -> decimal(38, s)`. [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) — DECIMAL maximum precision = 38. [trinodb/trino #20227](https://github.com/trinodb/trino/issues/20227) — decimal SUM overflow is an error, NOT silent truncation.

---

## 3.1C. `CAST(DOUBLE/REAL AS DECIMAL)` uses **HALF_UP** rounding (NOT banker's / NOT HALF_EVEN) — billing-critical canonical

**Keyword anchors:** Trino DECIMAL cast rounding, banker's rounding Trino, round half to even Trino, round half up Trino, Trino billing decimal rounding, HALF_UP vs HALF_EVEN, cast double to decimal rounding, RoundingMode.HALF_UP Trino, cast real to decimal rounding.

**The one fact (source-verified — docs are silent on the mode).** Trino casts `DOUBLE` → `DECIMAL` and `REAL` → `DECIMAL` using **`RoundingMode.HALF_UP`** (round half **away from zero**), NOT banker's rounding (round-half-to-even / `HALF_EVEN`). Verified in the Trino source: `core/trino-spi/src/main/java/io/trino/spi/type/DecimalConversions.java` uses `BigDecimal.valueOf(value).setScale(intScale(scale), HALF_UP)` for `DOUBLE → DECIMAL`, and `core/trino-main/src/main/java/io/trino/type/DecimalCasts.java` uses `bigDecimal.setScale(DecimalConversions.intScale(scale), HALF_UP)` in `numberToShortDecimal` / `numberToLongDecimal`. **The trino.io docs page for DECIMAL casts is SILENT on the rounding mode — the source is authoritative.**

**Tie-case worked examples** (the difference between HALF_UP and banker's rounding is visible only at exact 0.5 ties):

```sql
-- Trino 467: HALF_UP behavior (verified by source)
SELECT CAST(DOUBLE '0.5'   AS DECIMAL(1, 0));   -- 1     (banker's would give 0)
SELECT CAST(DOUBLE '2.5'   AS DECIMAL(2, 0));   -- 3     (banker's would give 2)
SELECT CAST(DOUBLE '0.005' AS DECIMAL(3, 2));   -- 0.01  (banker's would give 0.00)
SELECT CAST(DOUBLE '0.015' AS DECIMAL(3, 2));   -- 0.02  (banker's would give 0.02 — same here)
SELECT CAST(DOUBLE '0.025' AS DECIMAL(3, 2));   -- 0.03  (banker's would give 0.02)
SELECT CAST(REAL   '1.5'   AS DECIMAL(2, 0));   -- 2     (banker's would give 2 — same here)
SELECT CAST(REAL   '2.5'   AS DECIMAL(2, 0));   -- 3     (banker's would give 2)
```

**Billing example — in-line signal (corrective comment on the line the responder will copy):**

```sql
-- Convert a DOUBLE amount column to a billing-grade DECIMAL(18, 2)
SELECT CAST(amount_dbl AS DECIMAL(18, 2)) AS amount_billed  -- HALF_UP rounding (NOT banker's; 0.005 -> 0.01)
FROM   iceberg.billing.invoices;
```

**Overflow behavior (unchanged from §3.1B).** If the magnitude of the value (after rounding) does not fit in the target `DECIMAL(p, s)` precision, Trino throws **`NUMERIC_VALUE_OUT_OF_RANGE`** — a hard error, no silent wrap-around. Verified in `DecimalCasts.java`: `if (overflows(result, precision)) { throw new TrinoException(NUMERIC_VALUE_OUT_OF_RANGE, format("Cannot cast ... to DECIMAL(%s, %s)", ...)); }`. **`DECIMAL(18, 2)` is the sensible billing default** on this stack — 16 digits before the decimal (up to ~9.99e15) is plenty for any realistic invoice line; 2 digits after covers cents exactly.

### DO NOT WRITE

| False claim | Reality |
|---|---|
| "Trino's `CAST(DOUBLE AS DECIMAL)` uses banker's rounding (round-half-to-even)." | **FABRICATION.** Source-verified `HALF_UP` (round half away from zero). `CAST(DOUBLE '0.5' AS DECIMAL(1,0))` = **1**, not 0. (`core/trino-spi/.../DecimalConversions.java`, `core/trino-main/.../DecimalCasts.java`.) |
| "Trino uses `RoundingMode.HALF_EVEN` for DECIMAL casts." | **FABRICATION.** The source uses `RoundingMode.HALF_UP`. `HALF_EVEN` is the Java BigDecimal default, but Trino does not adopt that default for casts. |
| "Trino's DECIMAL cast follows IEEE-754 round-half-to-even (banker's rounding)." | **FABRICATION.** IEEE-754's default rounding mode is round-half-to-even, but Trino explicitly overrides this in its source with `setScale(..., HALF_UP)`. The casted DECIMAL result follows HALF_UP, not the IEEE-754 default. |
| "If a `DECIMAL` cast overflows the target precision, Trino silently wraps around or truncates." | **FALSE.** `NUMERIC_VALUE_OUT_OF_RANGE` is raised as a hard error — same behavior as §3.1B overflow on aggregates. |
| "Use `ROUND(x, 2)` to control the rounding mode of a `CAST(... AS DECIMAL(18, 2))`." | **MISLEADING.** `ROUND(x, n)` on Trino is also `HALF_UP` (verified at [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html) — `round(x, d)` rounds to `d` decimal places). It produces the same result as the CAST in HALF_UP terms; it does NOT give you a banker's-rounding option. Trino has no built-in `HALF_EVEN` cast function. If you specifically need banker's rounding (rare — most billing systems require HALF_UP for regulatory consistency), you must do it in application code, not in SQL. |

> **Symptom→cause→fix — "my SUM returns `12.300000000000007` instead of `12.30`" / "weird trailing digits on a money sum" / "ROUND(amount, 2) still shows `12.30000001`" / "decimal looks wrong" / "floating point error in my totals".** *(Keyword anchors so the responder lands here on the artifact symptom, not just on the rounding-mode question above.)* This is a **DOUBLE binary-float artifact**, NOT a Trino bug and NOT a rounding-mode bug. Per [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) verbatim: *"A double is a 64-bit inexact, variable-precision implementing the IEEE Standard 754 for Binary Floating-Point Arithmetic."* Decimal values like `0.1`, `0.2`, `12.3` have **no exact binary representation** in IEEE 754, so `SUM(DOUBLE)` accumulates tiny representation errors that surface as trailing digits like `12.300000000000007`. Wrapping the symptom in `ROUND(SUM(amount), 2)` only hides the artifact at display time — it does NOT fix the underlying inexactness, and downstream `WHERE total = 12.30` comparisons still fail. **The fix is to change the COLUMN TYPE, not the rounding mode**: either (a) **store the money column as `DECIMAL(p, s)` at ingest** — e.g., `DECIMAL(18, 2)` for cents-grade billing — so the SUM is exact fixed-point arithmetic (per §3.1B, `SUM(DECIMAL(p, s)) -> DECIMAL(38, s)` auto-widens and is exact), or (b) **CAST per-row at query time** — `SUM(CAST(amount_dbl AS DECIMAL(18, 2)))` — which forces each row to HALF_UP-round to cents BEFORE the SUM, giving an exact `DECIMAL(38, 2)` result with no trailing-digit artifact. Cast the column ONCE at ingest if you can; cast at query time only for ad-hoc reads of legacy DOUBLE columns. **Same fix for `format('%.2f', sum_double)`** — formatting hides the artifact in the rendered string but the underlying value is still inexact; downstream arithmetic and equality joins on it remain broken. **For non-money DOUBLEs where exactness does NOT matter** (latency percentiles, ratios, scientific measurements), the artifact is harmless — ignore it or display-round with `ROUND(x, 2)`. **For money / billing / contractual totals, the rule is simple: never SUM DOUBLE.** See [§3.1B](#31b-sumdecimal-auto-widens-to-decimal38-s--you-do-not-need-to-cast-and-trino-does-not-silently-truncate) for the `SUM(DECIMAL)` exactness guarantee and [§3.1C above](#31c-castdoublereal-as-decimal-uses-half_up-rounding-not-bankers--not-half_even--billing-critical-canonical) for the HALF_UP rounding mode the CAST uses.

**Sources:**
- Trino source — `core/trino-spi/src/main/java/io/trino/spi/type/DecimalConversions.java` — `setScale(intScale(scale), HALF_UP)` for `DOUBLE → DECIMAL` and `REAL → DECIMAL` ([github.com/trinodb/trino](https://github.com/trinodb/trino/blob/master/core/trino-spi/src/main/java/io/trino/spi/type/DecimalConversions.java)).
- Trino source — `core/trino-main/src/main/java/io/trino/type/DecimalCasts.java` — `numberToShortDecimal` / `numberToLongDecimal` both call `setScale(..., HALF_UP)`; overflow check throws `NUMERIC_VALUE_OUT_OF_RANGE` ([github.com/trinodb/trino](https://github.com/trinodb/trino/blob/master/core/trino-main/src/main/java/io/trino/type/DecimalCasts.java)).
- [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) — DECIMAL type definition. Page does NOT document the cast rounding mode (silent — source is authoritative).
- [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html) — `round(x, d)` reference.

---

### DO NOT WRITE — the PostgreSQL `::` cast shorthand is **NOT** supported in Trino 467 (parse error) — iter571 PIN

> **Keyword anchors (route here on any of these):** double colon cast Trino, `::` cast operator, Postgres cast syntax Trino, `::timestamp` `::bigint` `::int` `::date`, `'1900-01-01'::timestamp`, `col::bigint`, `created_at::date`, `expr::type`, `mismatched input '::'`, Trino does not support `::` cast.

**The one-line rule.** The PostgreSQL `expression::type` cast shorthand (`'1900-01-01'::timestamp`, `col::bigint`, `created_at::date`, `id::int`, `payload::json`) is **NOT** supported in Trino 467 — it is a **parse error**. The cast operator was requested in [trinodb/trino issue #23795](https://github.com/trinodb/trino/issues/23795) (opened 2024-10-15: *"Add support for `x::type` cast operator as an alternative syntax for `CAST(x AS type)`"*) and [PR #25259](https://github.com/trinodb/trino/pull/25259) was opened to implement it, but as of Trino 467 **both the issue and the PR are OPEN — NOT merged**. The `::` token simply does not exist in Trino's grammar; the parser fails with `mismatched input '::'`. Use **`CAST(x AS type)`** (or **`TRY_CAST(x AS type)`** for NULL-on-failure semantics), or a **typed literal** like `TIMESTAMP '1900-01-01 00:00:00'` / `DATE '2026-03-01'` / `UUID 'a1b2c3d4-...'` instead.

**Worked translation table — the most common `::` patterns and the Trino-compatible rewrite:**

| WRONG (Postgres `::` — Trino parse error) | RIGHT (Trino 467) |
|---|---|
| `'1900-01-01'::timestamp` | `CAST('1900-01-01' AS TIMESTAMP)` — or, preferred, the typed literal `TIMESTAMP '1900-01-01 00:00:00'` |
| `col::bigint` | `CAST(col AS BIGINT)` — or `TRY_CAST(col AS BIGINT)` if a bad row should become NULL instead of erroring |
| `col::int` / `col::integer` | `CAST(col AS INTEGER)` |
| `created_at::date` | `CAST(created_at AS DATE)` — or alias `date(created_at)` |
| `'2026-03-01'::date` | `DATE '2026-03-01'` (typed literal, preferred) |
| `payload::json` | `CAST(payload AS JSON)` |
| `id::varchar` / `id::text` | `CAST(id AS VARCHAR)` (Trino has no `TEXT` type) |
| `col::decimal(18,2)` | `CAST(col AS DECIMAL(18, 2))` |
| `NULL::timestamp` (typed NULL in UNION / MERGE branch) | `CAST(NULL AS TIMESTAMP)` |
| `col::uuid` | `CAST(col AS UUID)` — or typed literal `UUID 'a1b2c3d4-...'` |

**Why this section lives in the cast zone (above §3.1D).** Engineers carrying Postgres / Snowflake / DuckDB / Redshift muscle memory reflexively type `::type` when building a CAST expression in Trino SQL or in a dbt model targeting Trino. The compile / parse failure surfaces as `mismatched input '::'` — which is **NOT** an obvious clue that the token is unsupported (the engineer often assumes a stray quote or paren). Routing every `::`-shaped question here gives the immediate fix.

**Cross-references.** [Resource 27 §4.4A — TRINO-CAST-SYNTAX GUARDRAIL](27-oracle-plsql-to-dbt-trino.md) for the Oracle/Postgres migration-specific version (typed NULLs in MERGE soft-delete models, etc.). [Resource 13 § Postgres → Trino translation table](13-postgres-to-iceberg-ingestion.md) for `ts::DATE` → `CAST(ts AS DATE)`. The one place `::` IS legitimate in this stack: inside the query string passed to `system.query('...')` Postgres-passthrough on the Postgres connector — that string is forwarded verbatim to Postgres and runs in **Postgres's** parser, not Trino's. Outside passthrough (and outside Spark JDBC `dbtable` subqueries that run on the Postgres side), treat `::` as a **banned token** in Trino 467.

---

## 3.1D. `arbitrary` / `any_value` (pick ONE value per group) and `max_by` / `min_by` (deterministic representative-value pick)

**Keyword anchors:** arbitrary Trino, any_value aggregate, pick one value per group, representative value group by, functionally dependent column, "column is not part of GROUP BY", max_by min_by latest value, latest status per user, value associated with max date, one representative row per group, status as of latest update.

**Why this section exists.** When you `GROUP BY` a key (e.g. `user_id`) and the SELECT also references a column that is **constant per key** (e.g. `user_name` — every row for the same `user_id` has the same name), Trino will refuse the query unless you either (a) add the column to `GROUP BY`, or (b) wrap it in an aggregate. The right aggregate here is **`arbitrary(x)`** (or the SQL-standard alias **`any_value(x)`**) — it tells the engine "this column is constant per group; just give me one value." For a **deterministic** pick by an ordering column (e.g. "the status as of the latest update"), use **`max_by(x, y)` / `min_by(x, y)`**.

### `arbitrary(x)` and `any_value(x)` — pick ANY non-null value per group (NON-deterministic)

**Signature** (verified at [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html)):
- `arbitrary(x) -> [same as input]` — *"Returns an arbitrary non-null value of `x`, if one exists. Identical to `any_value()`."* (Trino docs verbatim.)
- `any_value(x) -> [same as input]` — SQL-standard **alias** for `arbitrary`. Identical behavior. Use whichever your team's style guide prefers; the engine treats them as the same function.

**Behavior:**
- **Ignores NULLs** — returns a non-null value if any exists in the group; returns NULL only when every row in the group is NULL (or the group is empty).
- **NON-deterministic** — Trino is free to return ANY non-null value from the group. If you re-run the same query the next day, after compaction, or on a different cluster size, you may get a different non-null value. **Only use `arbitrary` / `any_value` when the column is CONSTANT (functionally dependent on the GROUP BY key) — i.e., it does not matter which value you pick because they're all the same.**

**Worked example — one representative `user_name` per `user_id`:**

```sql
-- CORRECT — user_name is constant per user_id, so arbitrary() is safe.
SELECT user_id,
       arbitrary(user_name) AS user_name,    -- or: any_value(user_name)
       COUNT(*)             AS event_count
FROM iceberg.analytics.events
WHERE event_date = DATE '2026-06-01'
GROUP BY user_id;
```

**Why prefer `arbitrary` over `MAX` / `MIN` for this case:** when the column is constant per group, `MAX(user_name)` and `MIN(user_name)` both work but they (a) signal the WRONG intent (a reader thinks "we want the lexically largest name — why?"), and (b) cost more — they must compare every value. `arbitrary` signals "this column is constant per group" and lets the engine pick the first non-null value it sees.

### `max_by(x, y)` / `min_by(x, y)` — DETERMINISTIC pick of `x` by the ordering column `y`

When the column is **NOT** constant per group and you want a specific representative value (e.g., "the `status` as of the latest `updated_at`"), reach for `max_by` / `min_by`. **Do NOT use `arbitrary`** for this — `arbitrary` picks ANY non-null value and will return inconsistent results.

**Signature** (verified at [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html)):
- `max_by(x, y) -> [same as x]` — *"Returns the value of `x` associated with the maximum value of `y` over all input values."* (Trino docs verbatim.)
- `min_by(x, y) -> [same as x]` — symmetric: value of `x` paired with the MIN of `y`.
- 3-arg variants `max_by(x, y, n) -> array<[same as x]>` and `min_by(x, y, n) -> array<[same as x]>` return the top/bottom `n` values of `x` ranked by `y`.

**Worked example — latest status per order (deterministic by `updated_at`):**

```sql
-- CORRECT — pick the status from the row with the MAX updated_at per order.
SELECT order_id,
       max_by(status, updated_at) AS latest_status,
       min_by(status, updated_at) AS first_status,
       MAX(updated_at)            AS last_updated_at
FROM iceberg.analytics.order_status_history
GROUP BY order_id;
```

This is the canonical "value as of latest event" idiom — much shorter than a window-function + `QUALIFY ROW_NUMBER() = 1` pattern (and `QUALIFY` does **not** exist in Trino 467 anyway). For ties in the ordering column `y`, Trino does not guarantee which tied row's `x` is returned — if `updated_at` could tie, add a tiebreaker via `max_by(status, (updated_at, event_id))` over a ROW or use a window function with an explicit deterministic ORDER BY.

> **DO NOT WRITE — `MAX(value)` when you mean "the value AS OF the latest timestamp" (iter573 PIN — largest ≠ latest).** *Keyword anchors:* end of week balance, end of day reading, latest value per group not largest, max_by vs MAX, value as of latest timestamp, last reading per bucket, last count of the day not highest, balance at end of week not maximum balance, end-of-week balance, end-of-day reading, latest status per bucket. When the question is *"what was the **balance at the end of each week**"*, *"what was the **last reading per device per minute**"*, *"what was the **status at the close of each day**"*, the right aggregate is **`max_by(value, ts)`** — **NOT** `MAX(value)`. `MAX(value)` returns the **LARGEST** value in the group; `max_by(value, ts)` returns the value associated with the **MAXIMUM `ts`** in the group — i.e. the chronologically LATEST value. They differ whenever the series is **not monotonically increasing**: a checking-account balance dips down after withdrawals; a CPU reading falls after a spike; an inventory count drops when items ship. **WRONG ❌:** `SELECT account_id, date_trunc('week', posted_date) AS week_start, MAX(balance) AS balance_eow FROM ledger GROUP BY account_id, date_trunc('week', posted_date)` — returns the **highest** balance within each week, NOT the balance on the last day of the week. **RIGHT ✅:** `SELECT account_id, date_trunc('week', posted_date) AS week_start, max_by(balance, posted_date) AS balance_eow FROM ledger GROUP BY account_id, date_trunc('week', posted_date)` — returns the balance from the row with the latest `posted_date` in each week. Same fix for *"last count of the day"* (`max_by(count_val, recorded_at)` not `MAX(count_val)`), *"closing price per day"* (`max_by(price, traded_at)`), *"final status per session"* (`max_by(status, event_ts)`). Mnemonic: **if the answer must be "the value at a specific point in time," use `max_by(value, time)`. Reserve `MAX(value)` for "the maximum across the period" — peak balance, peak CPU, high-water-mark.** Verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) — `max_by(x, y) -> [same as x]`: *"Returns the value of `x` associated with the maximum value of `y` over all input values."*

### Picking between `arbitrary` / `any_value` and `max_by` / `min_by`

| Situation | Use |
|---|---|
| Column is **constant per group** (functionally dependent on the GROUP BY key — e.g. `user_name` per `user_id`, `product_name` per `product_id`). | `arbitrary(x)` or `any_value(x)`. Cheapest, signals intent. |
| You want the value of `x` associated with the **largest / smallest** value of a sortable column `y` (e.g. latest status by `updated_at`, top-revenue product per category). | `max_by(x, y)` / `min_by(x, y)`. Deterministic by `y`. |
| You want **all** values of `x` per group (de-duped or not). | `array_agg(x)` (+ optional `array_distinct(...)`); see resource 07 §1a.3. |
| You want the **most common** value per group. | `approx_most_frequent(buckets, x, capacity)` — see [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html). Not `arbitrary`. |

### DO NOT WRITE

| False claim | Reality |
|---|---|
| "`arbitrary(x)` returns the FIRST row's `x` (e.g. by scan order)." | **FALSE.** `arbitrary` is explicitly NON-deterministic — Trino is free to return any non-null value. Two runs of the same query can return different values when the column is not constant per group. |
| "`any_value` is a different function from `arbitrary` (different behavior)." | **FALSE.** Trino docs verbatim: *"`any_value(x)` ... Identical to `arbitrary()`."* They are aliases — identical behavior. |
| "`arbitrary` returns NULL if ANY row in the group is NULL." | **FALSE.** `arbitrary` IGNORES NULLs — it returns a non-null value if one exists in the group, and only returns NULL when every row in the group is NULL. |
| "Use `arbitrary(status)` for the latest status per `user_id`." | **WRONG TOOL.** `status` is not constant per `user_id` (it changes over time). `arbitrary` picks any value non-deterministically. Use `max_by(status, updated_at)` for the deterministic "latest by `updated_at`" pick. |
| "Trino has no SQL-standard `any_value` — use `MAX` instead." | **FALSE.** `any_value(x)` IS a Trino aggregate (alias of `arbitrary`). `MAX(x)` is the wrong tool for "this column is constant per group" — it signals "lexically largest" intent and costs more. |
| "`max_by(x, y)` returns `y` from the max-`x` row." | **BACKWARDS.** `max_by(x, y)` returns `x` (the first arg) from the row with the maximum `y` (the second arg). Mnemonic: "the value of x, by max y." |
| "Use `QUALIFY ROW_NUMBER() OVER (PARTITION BY k ORDER BY y DESC) = 1` to get the latest row per group in Trino." | **PARSE ERROR.** Trino 467 does **NOT** support `QUALIFY`. Either nest the window function in a subquery and filter `WHERE rn = 1`, or use `max_by(x, y)` directly when you only need a few columns from the latest row. |

**Cross-references.** For the rest of the Trino aggregate family (`approx_distinct`, `approx_percentile`, `listagg`, `array_agg` with `FILTER (WHERE ...)`), see [§3 above](#3-use-approximate-functions-when-exactness-isnt-required) and [resource 07 §1a.2 + §5](07-analytical-query-patterns.md). For the GROUP BY rules that force you to wrap the column in an aggregate in the first place, see [resource 07 §"Trino GROUP BY rules"](07-analytical-query-patterns.md#trino-group-by-rules-anchor--apply-to-every-group-by-query).

---

## 3.1E. Trino `if()` vs `CASE WHEN` and `count_if` — the conditional-expression family

### LEADING CANONICAL — Trino IF() vs CASE WHEN (equivalent; IF is the 2-3 arg shorthand)

> **READ THIS FIRST if your question contains any of these keywords: `Trino IF function`, `IF vs CASE`, `CASE WHEN equivalent`, `conditional expression Trino`, `count_if`, `ternary Trino`, `IIF Trino`, `DECODE Trino`, `Trino if() else`, `count where boolean is true`, `count of true rows`, `count true values`, `count of trues per group`, `conditional count`, `count rows flagged true`, `count rows matching condition`, `how many rows match a condition`, `how many orders shipped late`, `how many flagged`, `per-customer count of X where Y is true`, `boolean count`, `count of rows where flag = true`, `count records where bool = true`.** Verified at [trino.io/docs/current/functions/conditional.html](https://trino.io/docs/current/functions/conditional.html) on 2026-06-06.

**The one-fact summary.** Trino's `if(...)` is a **single-condition shorthand** for `CASE WHEN`; the two are **equivalent** at the planner level. Use `if(...)` for 1 condition + 1 ELSE; use `CASE WHEN` when you need multiple `WHEN ... THEN` branches.

- `if(condition, true_value)` — Trino docs verbatim: *"Evaluates and returns `true_value` if `condition` is true, otherwise null is returned and `true_value` is not evaluated."* Equivalent to `CASE WHEN condition THEN true_value END` (no `ELSE` → returns `NULL`).
- `if(condition, true_value, false_value)` — Trino docs verbatim: *"Evaluates and returns `true_value` if `condition` is true, otherwise evaluates and returns `false_value`."* Equivalent to `CASE WHEN condition THEN true_value ELSE false_value END`.
- `count_if(predicate)` — the idiomatic count-of-matching-rows aggregate. Trino docs: *"Returns the number of `TRUE` input values. This function is equivalent to `count(CASE WHEN x THEN 1 END)`."* Also equivalent to `sum(if(predicate, 1, 0))`. Prefer `count_if` — shortest + clearest intent.

**Worked equivalence pair (all three lines produce identical results + identical query plans):**

```sql
-- Trino 467 — three equivalent forms, pick the one that reads best in context:
SELECT if(status = 'active', 1, 0)                              AS active_flag FROM users;
SELECT CASE WHEN status = 'active' THEN 1 ELSE 0 END            AS active_flag FROM users;
SELECT count_if(status = 'active')                              AS active_count FROM users;  -- aggregate form
```

**Per-group "count rows where boolean is true" — `count_if` LEADS, three equivalent forms (rank order: prefer `count_if`).** When the question is "**count how many orders shipped late (`shipped_late = true`) per customer**" — or any "count rows where a boolean / condition is true, grouped by X" shape — the **idiomatic Trino-native form is `count_if(bool)`**. Reach for `count_if` first; the `FILTER (WHERE ...)` and `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` forms are equivalent but less idiomatic.

```sql
-- Trino 467 — "how many orders shipped late per customer" — three equivalent forms (rank order):

-- 1. count_if(bool) — IDIOMATIC TRINO. Shortest, clearest intent.
--    Trino docs verbatim: count_if(x) -> bigint, "Returns the number of TRUE input values."
SELECT customer_id,
       COUNT(*)               AS total_orders,
       count_if(shipped_late) AS late_orders            -- boolean column passed directly
FROM orders
GROUP BY customer_id;

-- 2. COUNT(*) FILTER (WHERE bool) — ANSI-standard, also clear. Equivalent plan.
SELECT customer_id,
       COUNT(*)                              AS total_orders,
       COUNT(*) FILTER (WHERE shipped_late)  AS late_orders
FROM orders
GROUP BY customer_id;

-- 3. SUM(CASE WHEN bool THEN 1 ELSE 0 END) — portable fallback (works on every SQL engine).
--    Verbose; not the Trino-native form. Use only when the SQL must run on Oracle/MySQL/etc. too.
SELECT customer_id,
       COUNT(*)                                          AS total_orders,
       SUM(CASE WHEN shipped_late THEN 1 ELSE 0 END)     AS late_orders
FROM orders
GROUP BY customer_id;
```

All three produce **identical row counts and identical query plans** on Trino 467. The `count_if(shipped_late)` form is what the Trino docs call out as the canonical "count of TRUE values" aggregate; reach for it first for any "count rows where condition is true" or "count rows flagged true per group" question. Predicate form is also valid: `count_if(status = 'shipped' AND shipped_at > due_at)` — any boolean expression works, not just a stored boolean column.

**When to reach for which.** Use `if()` for the 1-condition ternary. Use `CASE WHEN ... WHEN ... ELSE ... END` for **multi-branch** logic (`if()` does NOT chain — there is no `elseif` in the expression form; `CASE` is the only path). Use `count_if(p)` over `count(CASE WHEN p THEN 1 END)` and over `SUM(CASE WHEN p THEN 1 ELSE 0 END)` for COUNT-of-matching — the `count_if` form is the **idiomatic Trino-native** lead; `COUNT(*) FILTER (WHERE p)` is the ANSI-standard equivalent; `SUM(CASE WHEN p THEN 1 ELSE 0 END)` is the portable fallback.

> **DO NOT WRITE.**
> 1. **`DECODE(col, 'A', 1, 'B', 2, 0)`** — Oracle-only. Trino has no `DECODE`. Translate to `CASE WHEN col = 'A' THEN 1 WHEN col = 'B' THEN 2 ELSE 0 END`, OR to a chain of `if()` if it's a single condition. **CRITICAL NULL-MATCHING NUANCE on the `DECODE` → CASE translation: see [resource 27 §4.1A LEADING CANONICAL — Oracle DECODE → Trino CASE](27-oracle-plsql-to-dbt-trino.md) — DECODE treats NULL=NULL as a match, simple CASE does NOT.**
> 2. **`IIF(condition, true_value, false_value)`** — SQL-Server-only. Trino is **`if(condition, true_value, false_value)`** (lowercase `if`, NOT `IIF`). Pasting `IIF(...)` into Trino produces `Function 'iif' not registered`.
> 3. **`if(condition, true_value, ELSEIF other_condition, other_value, ...)`** — there is **no `ELSEIF` in the `if()` expression**. For multi-branch, use `CASE WHEN ... WHEN ... ELSE ... END`. (The `IF / ELSEIF / END IF` keyword form exists ONLY inside Trino **SQL routines / UDFs**, NOT in regular SELECTs — see [trino.io/docs/current/routines/if.html](https://trino.io/docs/current/routines/if.html); that's a different surface.)
> 4. **`SUM(CASE WHEN p THEN 1 ELSE 0 END)` as the default "count matching rows" idiom.** Works, but verbose; **`count_if(p)` is the canonical Trino-native form** and reads as the intent. Both produce the same plan.

**Cross-references.** Resource 07 §"Wide-pivot variant" uses both the `CASE WHEN` and the `FILTER (WHERE ...)` forms for conditional aggregation (the multi-column manual-pivot pattern). Resource 27 §4.1A is the canonical for the Oracle `DECODE` → searched-`CASE WHEN` NULL-matching nuance.

---

## 3.1F. `UNION` vs `UNION ALL` — the dedupe-vs-concatenate canonical (default to `UNION ALL` for analytics)

### LEADING CANONICAL — UNION vs UNION ALL (UNION dedupes = expensive; default to UNION ALL for analytics)

> **READ THIS FIRST if your question contains any of these keywords: `UNION vs UNION ALL`, `combine result sets Trino`, `UNION dedupe`, `UNION ALL performance`, `default union analytics`, `INTERSECT`, `EXCEPT`, `merge two SELECTs`, `stack queries`.** Verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) on 2026-06-06.

**The one-fact summary.** Trino's bare `UNION` is `UNION DISTINCT` — it removes duplicates via an **implicit global DISTINCT** over the combined result (a sort or hash-aggregate over every output row). `UNION ALL` concatenates the two inputs **streaming, no dedupe** — orders of magnitude cheaper on large analytical sets. Trino docs verbatim: *"If the argument `ALL` is specified all rows are included even if the rows are identical. If the argument `DISTINCT` is specified only unique rows are included in the combined result set. If neither is specified, the behavior defaults to `DISTINCT`."*

**Worked example + perf note:**

```sql
-- BARE UNION — full-result DISTINCT, equivalent to UNION ALL + DISTINCT (EXPENSIVE):
SELECT user_id FROM events_2026_q1
UNION                              -- = UNION DISTINCT (default) → silent global DISTINCT over all rows
SELECT user_id FROM events_2026_q2;

-- UNION ALL — streaming concatenation, cheap (DEFAULT for analytics):
SELECT user_id FROM events_2026_q1
UNION ALL
SELECT user_id FROM events_2026_q2;
```

**Default to `UNION ALL`.** Only use bare `UNION` when (a) you specifically need dedupe across the combined result AND (b) the inputs can produce overlapping rows. If the inputs are already disjoint (e.g., partitioned by date), bare `UNION` does a full-result sort/hash-aggregate for **zero benefit** — it's a silent perf killer.

**`INTERSECT` / `EXCEPT` always dedupe** by default (same rule: `DISTINCT` is the default when neither `ALL` nor `DISTINCT` is specified). Semantically: `INTERSECT` = semi-join (rows in both); `EXCEPT` = anti-join (rows in left but not right). See [§10 SemiJoin / NOT IN gotcha](#10-in-subqueries-vs-joins--let-trinos-optimizer-decide) for the join-form rewrites and the `NOT IN` + NULL trap — do not rewrite that section.

> **DO NOT WRITE.**
> 1. **Bare `UNION` "just to combine" two tables** when you don't need dedupe. The implicit global DISTINCT is a silent full-result sort/hash-aggregate — accidental perf killer on multi-billion-row analytics. Default to `UNION ALL`.
> 2. **"`UNION` preserves the order of the input queries"** — **FALSE.** Neither `UNION` nor `UNION ALL` guarantees row order. If you need order, wrap the union in an outer `ORDER BY`.
> 3. **"`UNION ALL` and then `DISTINCT` is slower than bare `UNION`"** — **FALSE.** They are equivalent operations; bare `UNION` IS `UNION ALL` + an implicit global DISTINCT. The planner produces the same shape.
> 4. **`UNION` to dedupe rows from a SINGLE table** — wrong tool. Use `SELECT DISTINCT` (single scan) instead of `SELECT ... UNION SELECT ...` (two scans + DISTINCT).

**Cross-references.** [§10](#10-in-subqueries-vs-joins--let-trinos-optimizer-decide) for the `INTERSECT` = semi-join and `EXCEPT` = anti-join rewrites, the `NOT IN` + NULL gotcha, and the SemiJoin canonical. [Trino 467 release notes — UNION ALL parallel write optimization](https://trino.io/docs/current/admin/properties-optimizer.html) note that the optimizer has special parallelization paths for `UNION ALL` writes that bare `UNION` does not get.

---

## 3.1G. Trino has NO `DISTINCT ON` — use `ROW_NUMBER() = 1` (or `max_by`) for one-row-per-group

### LEADING CANONICAL — Trino has NO `DISTINCT ON` — use `ROW_NUMBER() = 1` (or `max_by`) for one-row-per-group

> **READ THIS FIRST if your question contains any of these keywords:** `DISTINCT ON Trino`, `one row per group`, `latest row per key`, `Postgres DISTINCT ON equivalent`, `ROW_NUMBER 1 dedup`, `top-1 per partition`, `pick the most recent row per user`, `keep the newest row per group`, `latest order per customer`, `first event per session`, `dedup keeping the latest`. Verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) on 2026-06-06 (DISTINCT ON is NOT in the Trino SELECT grammar).

**The one-fact summary.** Postgres' `SELECT DISTINCT ON (k) ... FROM t ORDER BY k, ts DESC` (keep one row per `k`, picked by `ORDER BY`) is **NOT in Trino 467** — it raises a parse error: `mismatched input 'ON'`. Trino also has **NO `QUALIFY`** clause (see [§dialect anti-patterns table](#trino-467-sql-dialect-anti-patterns--do-not-carry-these-over-from-other-warehouses) above), so the Snowflake/BigQuery shortcut also fails. The canonical Trino rewrite is the **`ROW_NUMBER()` subquery** with an outer `WHERE rn = 1`.

```sql
-- Postgres:                                              -- Trino 467 (canonical):
-- SELECT DISTINCT ON (customer_id)                       SELECT customer_id, order_id, order_date, amount
--   customer_id, order_id, order_date, amount            FROM (
-- FROM orders                                              SELECT customer_id, order_id, order_date, amount,
-- ORDER BY customer_id, order_date DESC;                          ROW_NUMBER() OVER (
--                                                                   PARTITION BY customer_id
--                                                                   ORDER BY order_date DESC NULLS LAST
--                                                                 ) AS rn
--                                                          FROM iceberg.analytics.orders
--                                                        ) WHERE rn = 1;
```

**Top-N-per-group (not just top-1)?** Same pattern with `WHERE rn <= N`. **Single-column "latest value" pick?** Skip the subquery entirely and use `max_by(val, ts)` (cross-ref [§3.1D](#31d-arbitrary--any_value-pick-one-value-per-group-and-max_by--min_by-deterministic-representative-value-pick) — do not rewrite). The `max_by` form is cheaper when you only need ONE column from the picked row; the `ROW_NUMBER()` form is the right choice when you need ALL columns from the picked row.

**Tie-break determinism.** If the `ORDER BY` key can tie (e.g. two rows share the same `updated_at` / `event_time` / `session_timestamp`), `rn = 1` picks an **ARBITRARY** row among the tied rows — different runs of the same query can return different rows. Add a secondary deterministic tiebreaker on a unique column: `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY session_timestamp DESC, session_id DESC)` (or any monotonic unique key — `event_id`, `order_id`, etc.). The same rule applies to `max_by` — see the `max_by(status, (updated_at, event_id))` ROW-tuple tiebreaker note in [§3.1D](#31d-arbitrary--any_value-pick-one-value-per-group-and-max_by--min_by-deterministic-representative-value-pick).

**Honest fallbacks when there is NO unique column.** *(Keyword anchor — route here on: "I have NO unique column", "no unique column", "no column that's unique per row", "nothing unique to break ties", "table has no primary key", "no monotonic id", "no event_id / order_id / session_id", "tie-break without a unique key", "ROW_NUMBER tiebreaker without unique column".)* Sometimes the table genuinely has no second-column unique key to break ties on. **DO NOT** try `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY ts DESC, ROW_NUMBER() OVER (...))` — a nested window function inside another window function's `ORDER BY` is **REJECTED by the Trino 467 analyzer** (`StatementAnalyzer.analyzeWindowFunctions` raises an error; see [trinodb/trino PR #23929](https://github.com/trinodb/trino/pull/23929) and [Issue #24163](https://github.com/trinodb/trino/issues/24163)) AND it's semantically circular — the inner `ROW_NUMBER` adds no real distinguishing key, it just renumbers the same tied rows. Use one of these instead: **(a) Add EVERY remaining column to the ORDER BY as a deterministic-given-values tiebreaker** — `ORDER BY ts DESC, col_a, col_b, col_c` — deterministic across runs as long as no two rows are byte-identical (if they are, the rows are duplicates and no tiebreaker can distinguish them — they belong dedup'd). **(b) Add a SURROGATE sequence column at INGEST time** — a monotonic `_ingest_seq BIGINT` / generated id assigned by the Spark ingest job (e.g. via `monotonically_increasing_id()` or a UUID column written into the Iceberg table). This is the robust real-world fix: solve the missing-unique-key problem at the source. **(c) When you genuinely don't care WHICH tied row wins**, drop `ROW_NUMBER() = 1` entirely and use the deterministic-by-`ts` representative-value form from [§3.1D](#31d-arbitrary--any_value-pick-one-value-per-group-and-max_by--min_by-deterministic-representative-value-pick): `max_by(payload, ts)` (or `arbitrary(payload)` if you don't even care about latest-by-ts). `max_by` returns the `x` associated with the maximum `y`; `arbitrary` returns any non-null value.

> **DO NOT WRITE.** (1) **`SELECT DISTINCT ON (k) ...`** in Trino — parse error. Always rewrite to the `ROW_NUMBER()` subquery (or `max_by` for a single-column pick). (2) **`SELECT * FROM t QUALIFY ROW_NUMBER() OVER (PARTITION BY k ORDER BY ts DESC) = 1`** — Trino has NO `QUALIFY`; you MUST nest the window function in a subquery and filter `WHERE rn = 1` in the outer query (window functions are illegal in `WHERE` in every SQL dialect, including Trino). (3) **`SELECT * FROM t WHERE ROW_NUMBER() OVER (...) = 1`** — parse error (window functions are illegal in `WHERE` in every SQL dialect). (4) **`SELECT customer_id, MAX(order_date), ANY(amount), ANY(order_id) FROM orders GROUP BY customer_id`** as a shortcut — `ANY` is not Trino syntax (`arbitrary`/`any_value` exist but are NON-deterministic — you'd get `amount` and `order_id` from random rows, NOT from the max-date row). The deterministic forms are `max_by(amount, order_date)` and `max_by(order_id, order_date)`. (5) **The `NULLS-default` landmine on `ORDER BY ... DESC`** — always write explicit `NULLS FIRST` / `NULLS LAST` inside the window's `OVER (... ORDER BY ts DESC NULLS LAST)` (or `NULLS FIRST` to preserve Oracle behavior) — see [resource 27 § LEADING CANONICAL — Oracle vs Trino NULLS-default semantics](27-oracle-plsql-to-dbt-trino.md). (6) **Nested window function inside another window function's `ORDER BY`** as a "tiebreaker" — `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY ts DESC, ROW_NUMBER() OVER (...))` is **REJECTED by Trino 467's `StatementAnalyzer`** (see PR #23929 / Issue #24163) AND it's semantically circular. See the **Honest fallbacks** paragraph immediately above for the three correct alternatives (all-remaining-columns, ingest-time surrogate sequence, or `max_by(payload, ts)` / `arbitrary(payload)`).

**Cross-references.** [§3.1D — `arbitrary` / `any_value` / `max_by` / `min_by`](#31d-arbitrary--any_value-pick-one-value-per-group-and-max_by--min_by-deterministic-representative-value-pick) for the single-column representative-value pick. [§dialect anti-patterns table below](#trino-467-sql-dialect-anti-patterns--do-not-carry-these-over-from-other-warehouses) for the full cross-dialect `QUALIFY` / `LIMIT N BY` / `TOP N` / `DISTINCT ON` ban + the most-common rewrite pattern. [Resource 27 § 4.5C ROWID dedup](27-oracle-plsql-to-dbt-trino.md) for the in-place dedup pattern (CTAS+swap vs MERGE).

---

### DO NOT WRITE — `IGNORE NULLS` placement on window functions: AFTER the closing args paren, BEFORE `OVER` (iter572 PIN)

> **Keyword anchors (route here on any of these):** IGNORE NULLS placement, IGNORE NULLS inside parentheses parse error, where does IGNORE NULLS go, IGNORE NULLS after closing paren before OVER, LAST_VALUE IGNORE NULLS syntax, FIRST_VALUE IGNORE NULLS syntax, LAG IGNORE NULLS syntax, LEAD IGNORE NULLS syntax, null treatment clause Trino, RESPECT NULLS Trino, mismatched input 'IGNORE', mismatched input IGNORE Trino, null treatment outside args.

**The one-line rule.** On every Trino 467 window function that supports null-treatment (`LAST_VALUE`, `FIRST_VALUE`, `NTH_VALUE`, `LAG`, `LEAD`), the `IGNORE NULLS` / `RESPECT NULLS` keyword pair lives **AFTER the closing parenthesis of the function arguments and BEFORE the `OVER` clause** — *never* inside the function-args paren. The Trino 467 grammar (verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) + the `SqlBase.g4` grammar referenced in [trinodb/trino PR #1244](https://github.com/trinodb/trino/pull/1244)) literally reads `functionCall: name '(' args ')' nullTreatment? filter? over?` — the `nullTreatment` clause is an **optional clause OUTSIDE the args paren**, in the third position between `)` and the optional `OVER`. The Trino window-functions doc says verbatim: *"By default, null values are respected. If `IGNORE NULLS` is specified, all rows where `x` is null are excluded from the calculation."* and the syntax examples show `IGNORE NULLS` **after** the closing args paren.

**Grep-findable exact-wrong tokens — every one of these forms is a Trino 467 parse error (`mismatched input 'IGNORE'`):**

| WRONG (parse error — `IGNORE NULLS` inside args paren) | RIGHT (Trino 467 — `IGNORE NULLS` after `)`, before `OVER`) |
|---|---|
| `LAST_VALUE(col IGNORE NULLS) OVER (...)` &nbsp;❌ | `LAST_VALUE(col) IGNORE NULLS OVER (...)` &nbsp;✅ |
| `FIRST_VALUE(col IGNORE NULLS) OVER (...)` &nbsp;❌ | `FIRST_VALUE(col) IGNORE NULLS OVER (...)` &nbsp;✅ |
| `LAG(col IGNORE NULLS) OVER (...)` &nbsp;❌ | `LAG(col) IGNORE NULLS OVER (...)` &nbsp;✅ |
| `LAG(col, 1 IGNORE NULLS) OVER (...)` &nbsp;❌ | `LAG(col, 1) IGNORE NULLS OVER (...)` &nbsp;✅ |
| `LEAD(col IGNORE NULLS) OVER (...)` &nbsp;❌ | `LEAD(col) IGNORE NULLS OVER (...)` &nbsp;✅ |
| `NTH_VALUE(col, 2 IGNORE NULLS) OVER (...)` &nbsp;❌ | `NTH_VALUE(col, 2) IGNORE NULLS OVER (...)` &nbsp;✅ |

**Mnemonic.** Close the args paren, then `IGNORE NULLS`, then `OVER` — three tokens in that order, whitespace between each:

```
function_name(args)   IGNORE NULLS   OVER (PARTITION BY ... ORDER BY ... ROWS BETWEEN ...)
   ^^^^^^^^^^^^^^^^   ^^^^^^^^^^^^   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   close the args     null clause    window spec
```

**Worked correct end-to-end forward-fill (canonical — copy this):**

```sql
-- LAST_VALUE forward-fill (LOCF) — IGNORE NULLS placed OUTSIDE the closing args paren, BEFORE OVER:
SELECT device_id,
       ts,
       LAST_VALUE(status) IGNORE NULLS OVER (
         PARTITION BY device_id ORDER BY ts
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS last_known_status
FROM dense_grid;

-- LAG(col) IGNORE NULLS — previous NON-NULL value (skips NULL rows):
SELECT device_id,
       ts,
       LAG(status) IGNORE NULLS OVER (PARTITION BY device_id ORDER BY ts) AS prev_nonnull_status
FROM facts;
```

**Why this lives in the §3.1 dialect zone (between §3.1G window-function tie-break and §3.1H ORDER BY determinism).** Engineers carrying muscle memory from other engines (or just re-deriving the syntax from English — *"ignore nulls inside the function"*) reflexively type `LAST_VALUE(col IGNORE NULLS) OVER (...)`. The Trino 467 parse error is `mismatched input 'IGNORE'. Expecting: ')', ','` — opaque, easy to misdiagnose as a missing comma. Routing every `IGNORE NULLS`-shaped question here gives the immediate fix. **The full forward-fill recipe (date spine + LOCF + post-join window placement) lives at [resource 07 § COMBINED CANONICAL — composing the date-spine + forward-fill correctly](07-analytical-query-patterns.md) — same `IGNORE NULLS` placement rule applies there.**

**Cross-references.** [Resource 07 § LEADING CANONICAL — forward-fill / `LAST_VALUE ... IGNORE NULLS`](07-analytical-query-patterns.md) for the standalone LOCF recipe (look-BACK frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, `PARTITION BY entity_id` for multi-series fill, `COALESCE` wrapper is optional). [Resource 07 § COMBINED CANONICAL — date-spine + forward-fill composition](07-analytical-query-patterns.md) for the four-step recipe (spine via `sequence()` + UNNEST, per-bucket dedup via `max_by`, LEFT JOIN, then `LAST_VALUE(...) IGNORE NULLS` in the FINAL SELECT). [Trino 467 window functions doc](https://trino.io/docs/467/functions/window.html) for the official grammar.

---

### LEADING CANONICAL — `greatest()` / `least()` return NULL if ANY arg is NULL in Trino (Oracle + MySQL + BigQuery match; **PostgreSQL DIFFERS** — it ignores NULLs)

> **READ THIS FIRST if your question contains any of these keywords:** `greatest least NULL Trino`, `greatest returns NULL`, `least NULL argument`, `greatest vs Postgres`, `do all engines greatest least behave the same`, `ignore NULL greatest`, `COALESCE greatest`, `porting Postgres greatest to Trino`, `greatest cross-engine`, `least cross-engine`. Verified at [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html) + [postgresql.org/docs/current/functions-conditional.html](https://www.postgresql.org/docs/current/functions-conditional.html) on 2026-06-07.

**The one-fact summary — engines DISAGREE on NULL handling in `greatest`/`least`.** **Trino** (and **Oracle, MySQL, BigQuery**) — `greatest(...)` / `least(...)` return **NULL if ANY argument is NULL**. **PostgreSQL** — IGNORES NULL args, returning NULL **only if ALL args are NULL**. So `GREATEST(1, NULL, 5)` returns `5` in Postgres but **`NULL`** in Trino (and Oracle/MySQL/BigQuery). Trino's docs explicitly call out this contrast verbatim: *"Like most other functions in Trino, they return null if any argument is null. Note that in some other databases, such as PostgreSQL, they only return null if all arguments are null."* Postgres's docs say verbatim: *"NULL values in the argument list are ignored. The result will be NULL only if all the expressions evaluate to NULL."* So **"all SQL engines behave the same on greatest/least + NULL"** is **FALSE** — Postgres is the outlier.

**To get Postgres-like ignore-NULLs behavior in Trino** — wrap each arg in `COALESCE` with a sentinel floor (for `greatest`) or ceiling (for `least`):

```sql
-- Trino — Postgres-like "ignore NULLs" via COALESCE per arg:
SELECT greatest(coalesce(a, 0),     coalesce(b, 0),     coalesce(c, 0))     AS max_nonnull,   -- floor=0 for greatest
       least(   coalesce(a, 9e18),  coalesce(b, 9e18),  coalesce(c, 9e18))  AS min_nonnull    -- ceiling sentinel for least
FROM t;

-- Two-arg null-passthrough variant (use one side when the other is NULL):
SELECT CASE WHEN a IS NULL THEN b WHEN b IS NULL THEN a ELSE greatest(a, b) END AS max_either FROM t;
```

> **DO NOT WRITE.** (1) **"`greatest`/`least` ignore NULLs in Trino"** — FALSE; Trino returns NULL if ANY arg is NULL. (2) **"Postgres and Trino `greatest`/`least` behave identically on NULL"** — FALSE; Postgres ignores NULLs (returns NULL only if ALL args NULL); Trino returns NULL if ANY arg NULL. (3) **"All SQL engines treat `greatest`/`least` NULLs the same way"** — FALSE; engine-specific. **Trino, Oracle, MySQL, BigQuery** all return NULL if ANY arg is NULL; **PostgreSQL** is the outlier (ignores NULLs). (4) **"`COALESCE(greatest(a, b, c), 0)` reproduces Postgres semantics"** — FALSE; the outer `COALESCE` only fires when the WHOLE expression is NULL (all-NULL case), not when SOME args are NULL — `greatest(1, NULL, 5)` returns NULL in Trino regardless of outer COALESCE. You MUST wrap **each arg** in `COALESCE` (as shown above) to replicate Postgres ignore-NULLs behavior.

**Cross-references.** Full deep canonical with worked migration examples (Oracle vs Trino vs Postgres + the COALESCE-each-arg workaround + `MAX(col)`-aggregate vs `greatest(c1,c2,c3)`-scalar distinction): [resource 27 § 4.4D — `greatest`/`least` row-wise max/min + NULL-propagation differs from PostgreSQL/Oracle](27-oracle-plsql-to-dbt-trino.md). Related row-wise scalar-vs-aggregate cluster: `MAX(col)` is an aggregate DOWN ROWS (one value per group); `greatest(c1, c2, c3)` is scalar ACROSS COLUMNS in the same row — `SELECT MAX(a, b, c)` is a parse error.

---

### LEADING CANONICAL — Postgres `EXTRACT(EPOCH FROM ts)` → Trino `to_unixtime(ts)` (Trino's `EXTRACT` has **NO `EPOCH` field**)

> **READ THIS FIRST if your question contains any of these keywords:** `EXTRACT EPOCH Trino`, `timestamp to epoch seconds Trino`, `to_unixtime`, `Postgres EXTRACT EPOCH equivalent`, `convert timestamp to unix seconds`, `epoch from timestamp Trino`, `seconds since epoch Trino`, `porting Postgres EXTRACT(EPOCH) to Trino`. Verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) on 2026-06-07.

**The one-fact summary — Postgres's `EXTRACT(EPOCH FROM ts)` does NOT work in Trino; use `to_unixtime(ts)` instead.** PostgreSQL's `EXTRACT(EPOCH FROM ts)` returns seconds-since-epoch (a `double precision` including fractional seconds). **Trino's `EXTRACT` does NOT support an `EPOCH` field** — the only documented fields are `YEAR, QUARTER, MONTH, WEEK, DAY, DAY_OF_MONTH, DAY_OF_WEEK, DOW, DAY_OF_YEAR, DOY, YEAR_OF_WEEK, YOW, HOUR, MINUTE, SECOND, TIMEZONE_HOUR, TIMEZONE_MINUTE`. Writing `EXTRACT(EPOCH FROM ts)` against Trino raises a semantic/parse error. So **"`EXTRACT` works the same across Postgres and Trino"** is **FALSE** — the EPOCH field is a Postgres extension. The Trino-correct form is **`to_unixtime(timestamp) → double`** (verbatim docs signature) — returns epoch SECONDS as a DOUBLE (the fractional part preserves sub-second precision). Inverse: **`from_unixtime(seconds)`** returns `timestamp(3) with time zone`.

```sql
-- PostgreSQL (works in Postgres; FAILS in Trino):
SELECT EXTRACT(EPOCH FROM occurred_at) AS epoch_seconds FROM events;

-- Trino-correct equivalent:
SELECT to_unixtime(occurred_at)              AS epoch_seconds  FROM events;  -- DOUBLE seconds (with fractional)
SELECT CAST(to_unixtime(occurred_at) AS BIGINT) AS epoch_seconds_bigint FROM events;  -- whole seconds as BIGINT
SELECT CAST(to_unixtime(occurred_at) * 1000 AS BIGINT) AS epoch_millis FROM events;   -- epoch MILLISECONDS (cross-ref r13)
```

**"How long ago" / elapsed-time question — prefer `date_diff(unit, a, b)` over subtracting `to_unixtime`.** `date_diff('second', a, b)` returns a `BIGINT` integer directly and is more readable than `to_unixtime(b) - to_unixtime(a)` (which is DOUBLE seconds and forces you to divide for other units). Both are correct.

> **DO NOT WRITE.** (1) **"Trino supports `EXTRACT(EPOCH FROM ts)`"** — FALSE; Trino's `EXTRACT` has NO `EPOCH` field (only YEAR/QUARTER/MONTH/WEEK/DAY/DOW/DOY/HOUR/MINUTE/SECOND/TIMEZONE_*). The statement fails. (2) **"`to_unixtime` returns milliseconds"** — FALSE; `to_unixtime(timestamp) → double` returns **SECONDS** as a DOUBLE per docs. For milliseconds, **multiply by 1000** (`to_unixtime(ts) * 1000`). (3) **"`EXTRACT` works the same on Trino and Postgres"** — FALSE; the `EPOCH` field is a Postgres extension; Trino's standard `EXTRACT` field list omits it. (4) **"`unix_timestamp(ts)` is the Trino function"** — FALSE; `unix_timestamp` is the **Spark/Hive** name. Trino's function is literally **`to_unixtime`**.

**Cross-references.** Inverse direction (epoch → timestamp): [resource 13 §`from_unixtime` SECONDS vs MILLISECONDS — the year-52000 pitfall](13-postgres-to-iceberg-ingestion.md) (epoch-ms canonical with the year-56378 trap if you pass raw ms into `from_unixtime`). Now/current_timestamp + Iceberg timestamptz UTC normalization: [resource 07 §`now()` LEADING CANONICAL](07-analytical-query-patterns.md) and [resource 27 §4.2-NOW](27-oracle-plsql-to-dbt-trino.md). Full Postgres→Trino date/time porting table (covers `EPOCH`, `MICROSECOND`, `EXTRACT(epoch FROM ts)` patterns in CDC ingestion context): [resource 13 §Postgres date-function porting table](13-postgres-to-iceberg-ingestion.md).

---

## 3.1H. ORDER BY determinism in Trino — TOP-LEVEL is honored (with or without LIMIT); NESTED/redundant is dropped; ties need a tiebreaker

### LEADING CANONICAL — ORDER BY determinism in Trino — TOP-LEVEL is honored (with or without LIMIT); NESTED/redundant is dropped; ties need a tiebreaker

> **READ THIS FIRST if your question contains any of these keywords:** `Trino ORDER BY without LIMIT`, `ORDER BY ignored Trino`, `does Trino strip ORDER BY`, `stable sort Trino`, `deterministic order`, `ORDER BY in subquery not preserved`, `ORDER BY in CTE not preserved`, `ORDER BY in view dropped`, `ORDER BY tiebreaker`, `random order each run`, `TopN operator`, `why does my row order vary between runs`, `is my ORDER BY honored`. Verified at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) on 2026-06-07.

**The one-fact summary.** A **TOP-LEVEL** `SELECT ... ORDER BY x` (the OUTERMOST query — the one whose rows the client receives) **IS honored — Trino returns sorted output WITH OR WITHOUT a `LIMIT`**. `LIMIT` does **NOT** "make ORDER BY execute"; the top-level sort runs either way. `LIMIT` only lets the planner use the cheaper **TopN** operator (single-pass heap of size N) instead of a full sort. Per the [Trino SELECT docs](https://trino.io/docs/467/sql/select.html) verbatim: *"an ORDER BY clause only affects the order of rows for queries that immediately contain the clause... Trino follows that specification, and drops redundant usage of the clause to avoid negative performance impacts."* The drop applies to a **REDUNDANT** ORDER BY — one whose ordered output the enclosing operation does not preserve: ORDER BY in a SUBQUERY/CTE/VIEW, or in `INSERT ... SELECT ... ORDER BY`. To get ordered rows from an inner query: put the ORDER BY in the **OUTERMOST** query, OR use `ORDER BY ... LIMIT N` in the inner query (LIMIT forces a TopN whose bounded output survives — though the consumer may still reshuffle, so re-`ORDER BY` outside if you need ordered final output).

**TIES are a separate issue.** `ORDER BY x` with duplicate `x` values is non-deterministic **among the ties** (run-to-run variance within the peer group). For a deterministic TOTAL order, add a unique tiebreaker column: `ORDER BY x, id`.

**Worked contrast — three shapes, three behaviors:**

```sql
-- (1) TOP-LEVEL ORDER BY — HONORED, with or without LIMIT.
--     Trino returns rows in ts DESC order. No LIMIT needed for the sort to happen.
SELECT user_id, ts, event_name
FROM iceberg.analytics.events
WHERE event_date = DATE '2026-06-07'
ORDER BY ts DESC;                                  -- top-level sort: HONORED.

-- (2) NESTED ORDER BY in a subquery — may be DROPPED as redundant.
--     The outer SELECT does NOT preserve the inner ordering.
--     Wrong:
SELECT * FROM (
  SELECT user_id, ts, event_name
  FROM iceberg.analytics.events
  ORDER BY ts DESC                                 -- redundant: outer doesn't preserve.
) t;
--     Right: move ORDER BY to the OUTERMOST query.
SELECT user_id, ts, event_name
FROM (
  SELECT user_id, ts, event_name
  FROM iceberg.analytics.events
) t
ORDER BY ts DESC;                                  -- top-level: HONORED.

-- (3) TIES — non-deterministic ordering among rows that share the ORDER BY value.
--     Two rows with identical `ts` can appear in either order.
SELECT user_id, ts, event_id
FROM iceberg.analytics.events
ORDER BY ts DESC, event_id;                        -- unique tiebreaker → deterministic.
```

> **DO NOT WRITE.**
> 1. **"Trino strips/ignores a top-level `ORDER BY` without `LIMIT` / returns rows in random order"** — **FALSE.** A top-level ORDER BY is honored with or without LIMIT. Only a REDUNDANT (nested) ORDER BY is dropped.
> 2. **"You must add `LIMIT` to make `ORDER BY` execute"** — **FALSE.** The top-level sort runs either way. `LIMIT` only enables the cheaper TopN operator (heap of size N vs full sort).
> 3. **"An `ORDER BY` in a CTE / view / subquery / `INSERT ... SELECT` guarantees ordered output downstream"** — **FALSE.** Nested ORDER BY is redundant and may be dropped by the planner. Put the ORDER BY in the OUTERMOST query (or use `ORDER BY ... LIMIT N` inside to force a TopN, then re-`ORDER BY` outside).
> 4. **"`ORDER BY ts DESC` is deterministic when multiple rows share `ts`"** — **FALSE among the ties.** Add a unique tiebreaker: `ORDER BY ts DESC, event_id`.

**Why your row order varies between runs (decision rule):**
- **Inner ORDER BY only** → the planner dropped it. Move ORDER BY to the OUTERMOST query.
- **Top-level ORDER BY on a non-unique column** → ties are non-deterministic. Add a unique tiebreaker (`event_id`, a UUID, a serial).
- **Top-level ORDER BY on a unique column** → output IS deterministic. If you observe variance, you are looking at a different SQL shape than you think (e.g., the ORDER BY is in a CTE wrapped by an outer query). Run `EXPLAIN` to confirm.

**Cross-references.** [§5 Window-function tied-ORDER-BY peer semantics in resource 07](07-analytical-query-patterns.md#rows-vs-range-on-tied-order-by-values--pick-the-right-tool-avoid-interval-0-day) for the ROWS-vs-RANGE-on-tied-keys peer semantics inside `OVER (...)`. [Resource 22 §3.3A / §13.5](22-trino-federation-postgresql.md) for TopN-pushdown EXPLAIN signatures on federated tables (the absence of a separate `TopN[...]` operator above the TableScan IS the pushdown success signature; ORDER BY without LIMIT is a known TopN-pushdown failure shape because there is no `LIMIT` to push). [Resource 27 § LEADING CANONICAL — Oracle vs Trino NULLS-default semantics](27-oracle-plsql-to-dbt-trino.md) for the `NULLS FIRST` / `NULLS LAST` default that affects sort order on a column with NULLs.

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

- Missing `dynamicFilter` on a join — joins between fact and dim tables typically show dynamic filters. **Dynamic filtering is a RUNTIME mechanism that is ON BY DEFAULT (`enable-dynamic-filtering=true` / session `enable_dynamic_filtering=true`)** — it builds an IN-list (or min/max range) from the build side at execution time and pushes it into the probe-side scan to skip splits/files. **DF is NOT gated on `ANALYZE`/table stats**; it functions for both BROADCAST and PARTITIONED joins regardless of whether you've ever run `ANALYZE`. ANALYZE stats are RECOMMENDED because the CBO uses them to pick the smaller table as the build side and a BROADCAST distribution (which makes DF most selective and lowest-latency), but the DF mechanism itself runs without them. **If `dynamicFilter` is missing from `EXPLAIN`, check (in this order) — NOT just "run ANALYZE":** (1) **join type** — DF supports INNER and RIGHT joins (and semi-joins with `IN`); LEFT and FULL OUTER are NOT supported; (2) **join predicates** — must be `=`, `<`, `<=`, `>`, `>=`, or `IS NOT DISTINCT FROM` on the join key; (3) **join distribution** — confirm BROADCAST (`RemoteExchange[REPLICATE]`) vs PARTITIONED (`RemoteExchange[REPARTITION]`) on the probe side; both support DF, but a misclassified PARTITIONED-when-it-should-have-been-BROADCAST often points to missing stats (here ANALYZE helps the CBO pick BROADCAST, which makes DF most effective); (4) **connector pushdown** — the probe-side connector must support DF (Iceberg/Hive/Delta/Postgres/MySQL all do); (5) **wait-timeout** — DF was wired up in `EXPLAIN` but `dynamicFilterSplitsProcessed=0` at runtime means the wait-timeout fired (Iceberg default 1s, JDBC default 20s — see [resource 22 §5.4](22-trino-federation-postgresql.md)); (6) **stats** — running `ANALYZE iceberg.<schema>.<table>` (Trino syntax: bare `ANALYZE`, NO `TABLE` keyword — `ANALYZE TABLE ...` is Spark/Hive and fails in Trino) helps the CBO pick the right build side and distribution, indirectly improving DF effectiveness; this is a TUNING LEVER, not a PREREQUISITE. See [resource 22 §5](22-trino-federation-postgresql.md) for the full DF diagnostic decision tree, [resource 24 §4 leading canonical statement](24-trino-cbo-analyze.md) for ANALYZE syntax, and [trino.io/docs/current/admin/dynamic-filtering.html](https://trino.io/docs/current/admin/dynamic-filtering.html) for the official docs.

**For deeper inspection** use `EXPLAIN (TYPE DISTRIBUTED)` or `EXPLAIN ANALYZE` (runs the query and reports actual rows/time per stage).

**EXPLAIN variants — which one surfaces which signal (Trino 467, verified at [trino.io/docs/current/sql/explain.html](https://trino.io/docs/current/sql/explain.html) and [trino.io/docs/current/sql/explain-analyze.html](https://trino.io/docs/current/sql/explain-analyze.html)):**

| Variant | Runs the query? | What to read |
|---|---|---|
| `EXPLAIN` (default `TYPE DISTRIBUTED`) | NO | Logical/distributed plan: `TableScan` with `constraint on [...]` (predicate pushed) vs `ScanFilterProject` with `filterPredicate = ...` (filter in Trino memory). Estimates only. |
| `EXPLAIN (TYPE IO)` | NO | **JSON** with `inputTableColumnInfos` — the `constraints` and `estimate` (row count / size) the scan **will** read, per input table. Best for "did partition pruning happen at the scan boundary". |
| `EXPLAIN ANALYZE` | **YES** | **Actual** per-operator runtime stats. The line to read for "did the scan filter early / push the predicate down" is the `ScanFilterProject` operator's `Physical input: <X> rows (<Y> bytes)` + `Filtered: <Z>%`. Bigger `Filtered:` = more rows dropped at the scan. |
| `EXPLAIN ANALYZE VERBOSE` | YES | Same as above + low-level per-driver distributions (CPU, scheduled time, p50/p99). Trino-internals oriented. |

**`EXPLAIN ANALYZE` is the right tool for verifying optimizations actually worked.** Plain `EXPLAIN` shows the planner's *estimated* costs; `EXPLAIN ANALYZE` runs the query and reports **actual bytes read, actual row counts per stage, and real wall time**. When you rewrite `COUNT(DISTINCT)` to `approx_distinct`, or swap a raw scan for a rollup/sketch table, run both versions with `EXPLAIN ANALYZE` and compare the `Physical input` bytes — that's the ground-truth proof that you reduced I/O. Estimates can be wrong; actuals from `EXPLAIN ANALYZE` cannot.

**The EXACT per-operator field labels Trino 467 prints (memorize these — these are the strings you grep for in the output, verified at [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/467/sql/explain-analyze.html)):** **`CPU`** (operator CPU time), **`Scheduled`** (wall-clock scheduled time), **`Blocked`** (time blocked on input/output), **`Input`** (rows + data size received — printed as `Input: <N> rows (<X>B)`), **`Output`** (rows + data size produced), **`Estimates`** (planner-predicted rows/CPU/memory/network — compare these to the actuals!), plus the per-driver distribution fields **`Input avg.`** (mean input per driver) and **`Input std.dev.`** (standard deviation **as a percentage of mean — this is the DATA-SKEW indicator**: a high `std.dev.` % across drivers/workers means ONE worker is doing most of the work while the others sit idle). `EXPLAIN ANALYZE VERBOSE` additionally prints `CPU time distribution (s)`, `Input rows distribution`, `Scheduled time distribution (s)` with percentile fields `count`, `p01`, `p05`, `p50`, `p99`, `min`, `max`.

**5-row red-flag cheat-sheet — what to look for in `EXPLAIN ANALYZE` output:**

| Red flag in EXPLAIN ANALYZE | What it means | Fix |
|---|---|---|
| **`Input` physical bytes >> what your partition predicate should allow** | Predicate pushdown FAILED — you wrapped the partition column in a function (`date(event_date) = ...`) OR you have a type mismatch. Trino scanned everything and filtered in memory. | Use the bare partition column: `event_date = DATE '2026-06-01'`. See §6 below. |
| **`CorrelatedJoin` node in the plan** | Trino's `Decorrelate Subqueries` rule bailed out — the correlated subquery runs **once per outer row** (O(N×M)). | ANALYZE the inner table; if `CorrelatedJoin` persists, manually rewrite the correlated subquery as a JOIN or `SemiJoin`-friendly `IN`. See §10 below. |
| **`Input` rows >> `Output` rows** (e.g., `ScanFilterProject` reads 1B rows and emits 5M) | Filter-after-scan — the predicate did not push into the connector; Trino read everything and dropped 99.5% post-scan. | Same fix as row 1 (drop function wrappers, fix type, use partition column). Also check `filterPredicate = ...` vs `constraint on [...]` in plain EXPLAIN. |
| **High per-operator `Input std.dev.` % (e.g., 80%, 200%, "stddev across drivers" big)** — real Trino-docs examples: `Input avg.: 15.63 rows, Input std.dev.: 24.36%` healthy vs `Input std.dev.: 793.73%` extreme skew | **DATA SKEW.** One driver/worker is processing far more rows than the others — typical with a hot join key (e.g., one giant tenant). The skewed stage is the bottleneck. `EXPLAIN ANALYZE VERBOSE` adds the per-driver `Input rows distribution` percentiles (`p01`/`p50`/`p99`) — a wide `p99` vs `p50` gap confirms it. | **Salt** the hot key on the join (`ON a.key = b.key AND a.salt = b.salt` with random salt buckets), or break a skewed GROUP BY with the two-level (key, salt) → final SUM pattern. Also check if the build side was inverted (run `ANALYZE` on both join sides). **Worked salt-the-key example:** see [resource 18 § Step 5 — Check for partition / data skew](18-query-performance-regression.md#step-5-check-for-partition--data-skew--explain-analyze-input-stddev-one-worker-slow-one-stage-slow-uneven-worker-time-skewed-join-skewed-group-by-salt-the-key-leading-canonical-oncall-worked-example--read-this-first-when-one-stage--one-worker-is-dragging-the-query) (Fix 1 = canonical two-level GROUP BY with salt). |
| **Many `RemoteExchange[REPARTITION]` nodes for the same CTE** | Trino **INLINES** CTEs at planning time — a CTE referenced N times runs N times (and shuffles N times). | **Materialize** the CTE to a real Iceberg table, dbt model, or use `INSERT INTO <temp_table>` once. See §1b `WITH` / CTE semantics in resource 07. |

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

> **Trino GROUP BY rules (anchor — applies to every `GROUP BY` query):**
> 1. GROUP BY accepts **expressions or ordinal numbers ONLY** (per [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) verbatim).
> 2. **NO `AS alias` definition syntax inside GROUP BY** — `GROUP BY DATE_TRUNC('month', event_date) AS event_month` is a **parse error in every SQL dialect**. Alias definitions belong in the SELECT list.
> 3. Trino does **NOT support referencing a SELECT-list alias by name** in GROUP BY (issue [trinodb/trino #16533](https://github.com/trinodb/trino/issues/16533), still open). PostgreSQL/MySQL allow this; Trino does NOT. Repeat the expression or use an ordinal `GROUP BY 1, 2`.
> 4. A SELECT alias **may be used in the outer `ORDER BY`** (after projection) but **NOT in `GROUP BY` / `WHERE` / `HAVING`** (all evaluated before/during projection).
> 5. A window's inline `ORDER BY` inside `OVER (...)` also uses **pre-projection scope** — `ORDER BY DATE_TRUNC('month', event_date)`, not `ORDER BY event_month`.
>
> For the canonical bucketed-running-total worked example (`GROUP BY` + `SUM(COUNT(*)) OVER (...)`), see [resource 07 § Pattern A2 — Bucketed running total](07-analytical-query-patterns.md).

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
> | **Semi-join** | "Did this left row match ANY right row? TRUE/FALSE per left row — never duplicates the left row." This is the physical operator Trino wants `IN (SELECT ...)` and non-correlated `EXISTS` / `NOT EXISTS` to lower to. | `SemiJoin[k = k]` producing a boolean output symbol (`semijoinoutput:boolean`). |
> | **Anti-join** | "Return left rows that have NO match on the right." It's a semi-join with the output inverted. `NOT IN` and `NOT EXISTS` both compute this semantically. | `SemiJoin[k = k]` (same node) + a downstream `Filter[NOT semijoinoutput]`. **There is NO `FilterMode = ANTI` token in Trino EXPLAIN output** — anti semantics are expressed by the downstream `NOT`-filter, not by a flag on the SemiJoin node. |
> | **SemiJoinNode** | Trino's physical plan node implementing semi-join. Hash-build the small side, probe the big side once, output a boolean column (`semijoinoutput:boolean`) per probe row. Fast. For NOT IN / NOT EXISTS, a downstream `Filter[NOT semijoinoutput]` inverts the boolean. | `SemiJoin[...]` (output: `semijoinoutput:boolean`); anti adds `Filter[NOT semijoinoutput]`. |
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
> - **Anti-semi-join rendering in Trino EXPLAIN** = `SemiJoin[k = k]` producing a boolean output symbol `semijoinoutput:boolean`, followed by a downstream `Filter[NOT semijoinoutput]` node that keeps only the rows where the boolean is FALSE. **Trino EXPLAIN does NOT print a `FilterMode = ANTI` token** — the anti-semantics live in the downstream `NOT`-filter, not in a flag on the SemiJoin node. (Prior versions of this gloss used the `FilterMode = ANTI` shorthand; that was a documentation slip — the real plan-text token is `Filter[NOT semijoinoutput]`.)
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

`NOT EXISTS` checks row-by-row whether a matching row exists. It returns TRUE/FALSE, never UNKNOWN — so NULLs in `premium_users.user_id` are simply ignored (they don't match anything). Trino decorrelates **non-correlated** `NOT EXISTS` into an **anti-join** (a `SemiJoin[k = k]` node producing `semijoinoutput:boolean`, followed by a downstream `Filter[NOT semijoinoutput]`) internally; in that case, EXPLAIN looks identical to the `NOT IN` plan and performance is comparable. **Correlated** `NOT EXISTS` is a different story — see the dedicated callout below.

> **Anti-join — what the term means.** An **anti-join** returns rows from the left side that have **NO matching row on the right side**. It's the relational-algebra opposite of a regular (inner) JOIN, which returns rows that DO have a match. `NOT EXISTS (SELECT 1 FROM right WHERE right.key = left.key)` and `LEFT JOIN right ON right.key = left.key WHERE right.key IS NULL` both produce anti-join semantics. For **non-correlated** subqueries, Trino's optimizer rewrites both into a `SemiJoin[k = k]` node producing a boolean column (`semijoinoutput:boolean`), followed by a downstream `Filter[NOT semijoinoutput]` that keeps only the no-match rows. **Trino EXPLAIN does NOT emit a `FilterMode = ANTI` token** — the anti-semantics are expressed by the downstream `NOT`-filter on the boolean output, not by a flag on the SemiJoin node. NOT-IN and non-correlated NOT-EXISTS plans look identical and perform similarly. Unlike `NOT IN`, an anti-join is **NULL-safe** — NULL rows on the right side simply don't match anything, instead of poisoning the WHERE clause via three-valued logic. This is exactly why the recommended fix for the `NOT IN` + NULL zero-rows bug is to switch to `NOT EXISTS` (which decorrelates to an anti-join), not just to add an `IS NOT NULL` filter to the subquery.

> **CRITICAL — correlated `NOT EXISTS` is NOT always as fast as `NOT IN`. Read this before claiming "performance should be identical."**
>
> The common shorthand "`NOT IN` and `NOT EXISTS` decorrelate to the same anti-join so performance is identical" is **only true for the non-correlated case**. For correlated `NOT EXISTS`, Trino's current implementation can be **measurably slower** than the equivalent `NOT IN` — and this is inherent executor cost, NOT a planner regression.
>
> **The two cases — be precise about which one you're looking at:**
>
> | Subquery shape | Lowered to | Performance characteristic |
> |---|---|---|
> | **Non-correlated** `NOT IN (SELECT col FROM t)` (no reference to outer row) | `SemiJoin[k = k]` (producing `semijoinoutput:boolean`) + downstream `Filter[NOT semijoinoutput]` via the *Semi-Join (IN) Decorrelation* rule | Optimal anti-join. Hash-join, broadcast small side, probe big side, returns TRUE/FALSE per probe row; the `NOT`-filter keeps the FALSE (no-match) rows. |
> | **Non-correlated** `NOT EXISTS (SELECT 1 FROM t WHERE <constant>)` (no outer-row reference inside the WHERE) | Same `SemiJoin[k = k]` + `Filter[NOT semijoinoutput]` shape via the *Decorrelate Subqueries* rule | Comparable to NOT IN — both rules target the same physical operator. EXPLAIN plans look identical. |
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
> 2. **EXPLAIN both versions, compare physical operators.** `NOT IN` should show `SemiJoin[k = k]` (producing `semijoinoutput:boolean`) followed by `Filter[NOT semijoinoutput]`. Correlated `NOT EXISTS` will show `LeftJoin` + `Aggregate` (without a SemiJoin). If you see this asymmetry, you are hitting [trinodb/trino #21859](https://github.com/trinodb/trino/issues/21859) — the correctness premium of NOT EXISTS comes at an executor cost.
> 3. **Pick a workaround based on nullability:**
>    - **Right-side column is `NOT NULL` (schema-enforced)**: stick with `NOT IN` — `SemiJoin` is the optimal physical operator and you don't need NOT EXISTS's NULL safety. This is the fastest option.
>    - **Right-side column is nullable but you want NOT EXISTS performance**: **rewrite as a non-correlated anti-join** — `LEFT JOIN ... ON ... WHERE right.key IS NULL` combined with `SELECT DISTINCT` on the inner side (see Rewrite B below and the "Worked example" section further down). This decorrelates back to `SemiJoin[k = k]` + `Filter[NOT semijoinoutput]` and avoids the LeftJoin enumeration problem entirely.
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

**The exact same NOT EXISTS before/after pattern** — the manual rewrite changes the `WHERE p.user_id IS NOT NULL` to `WHERE p.user_id IS NULL` (the anti-join half: rows from `events` that did NOT match). EXPLAIN should produce the same `SemiJoin[k = k]` physical operator producing `semijoinoutput:boolean`, followed by a downstream `Filter[NOT semijoinoutput]` to keep the no-match rows. (Note: Trino EXPLAIN does NOT print a `FilterMode = ANTI` token — the anti semantics live in the downstream `NOT`-filter. The CorrelatedJoin → SemiJoin transformation is identical; only the post-join filter flips between `Filter[semijoinoutput]` and `Filter[NOT semijoinoutput]`.)

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

> **LEADING CO-CANONICAL — "count rows where a boolean / condition is true PER GROUP" → `count_if` LEADS (iter585 landing-point relocation).** *Keyword anchors AT § 11: count of X where boolean is true per group, how many flagged per region/customer/group, count true rows per group, per-region count of fraud/late/failed/damaged, count_if per group, conditional count by group, count where flag = true grouped, every group including zero-match.*
>
> When the question is "**how many orders are flagged as fraud per region**" / "**how many shipments were late per carrier**" / "**count of `is_X` true per group**", you have **THREE equivalent forms — prefer them in this rank order**:
>
> 1. **`count_if(bool)` — IDIOMATIC TRINO** (the lead). Verbatim from [Trino 467 aggregate-functions docs](https://trino.io/docs/467/functions/aggregate.html): *"`count_if(x) -> bigint` — Returns the number of `TRUE` input values. This function is equivalent to `count(CASE WHEN x THEN 1 END)`."* Pass a boolean column or any boolean expression directly. **Zero-group-safe**: with `GROUP BY region`, every region appears in the output — clean regions emit `0`, not "missing row."
> 2. **`COUNT(*) FILTER (WHERE bool)` — ANSI-STANDARD equivalent** (the `FILTER` form §11 already leads with above for the duplicate-subquery-collapse pattern). Verbatim from the same docs: *"The `FILTER` keyword can be used to remove rows from aggregation processing with a condition expressed using a `WHERE` clause. This is evaluated for each row before it is used in the aggregation and is supported for all aggregate functions."* **Zero-group-safe** — `FILTER` filters rows *within the aggregate*, not the rows that reach `GROUP BY`, so every group still appears with `0` when no rows match.
> 3. **`SUM(CASE WHEN bool THEN 1 ELSE 0 END)` — PORTABLE FALLBACK** (ANSI, works on every engine). Verbose but produces the same result and the same plan on Trino 467. **Zero-group-safe** — `CASE` returns `0` for non-matches, so every grouped row contributes (zero-match groups land at `SUM = 0`, not vanish).
>
> **ZERO-GROUP-SAFE — DO NOT WRITE for "per group count of flag = true":** do **NOT** push the boolean into the outer `WHERE` clause when the question asks "for **each** region / customer / carrier, how many were flagged true." That is:
>
> ```sql
> -- WRONG for "how many fraudulent orders per region" — DROPS zero-fraud regions
> SELECT region, COUNT(*) AS fraud_orders
> FROM orders
> WHERE is_fraud = true                 -- pre-aggregation filter throws away ALL clean rows
> GROUP BY region;                      -- a region with 0 fraud has no surviving rows → it
>                                       -- VANISHES from the result instead of showing fraud_orders = 0
> ```
>
> The pre-aggregation `WHERE is_fraud = true` filter eliminates every row that does **not** satisfy the boolean *before* `GROUP BY` sees it. A region with zero fraudulent orders therefore has zero surviving rows for the grouper to bucket — that region **silently disappears** from the result set instead of appearing with `fraud_orders = 0`. This is the single most common "for EACH group" reporting bug; it ships a partial result that looks right until someone notices a known-clean region missing.
>
> **Correct — count the boolean over the FULL table grouped by region**, so every region survives the grouper and zero-match groups emit `0`:
>
> ```sql
> -- RIGHT — count_if LEAD (idiomatic Trino), every region appears, clean regions show fraud_orders = 0
> SELECT region,
>        COUNT(*)             AS total_orders,
>        count_if(is_fraud)   AS fraud_orders          -- boolean column passed directly
> FROM orders
> GROUP BY region;
>
> -- RIGHT — COUNT(*) FILTER (WHERE ...) form (ANSI-standard equivalent), identical result + plan
> SELECT region,
>        COUNT(*)                          AS total_orders,
>        COUNT(*) FILTER (WHERE is_fraud)  AS fraud_orders
> FROM orders
> GROUP BY region;
>
> -- RIGHT — SUM(CASE WHEN ...) portable fallback, identical result + plan, verbose
> SELECT region,
>        COUNT(*)                                          AS total_orders,
>        SUM(CASE WHEN is_fraud THEN 1 ELSE 0 END)         AS fraud_orders
> FROM orders
> GROUP BY region;
> ```
>
> All three forms produce **identical row counts, identical column values, and identical query plans** on Trino 467. The `count_if(is_fraud)` form is the idiomatic Trino-native lead — reach for it first for any "count rows where condition is true per group / per region / per customer" question. Predicate form is also valid: `count_if(status = 'shipped' AND shipped_at > due_at)` — any boolean *expression* works, not just a stored boolean column. See [§ 3.1E LEADING CANONICAL](#31e-trino-if-vs-case-when-and-count_if--the-conditional-expression-family) for the single-row (non-grouped) form + the `if()` vs `CASE WHEN` family.

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

**If you need to reuse a result across multiple queries — save a query result as a new table / create a table from a SELECT / materialize a query into a table / persist a query output as a table (CREATE TABLE AS SELECT — CTAS).** Use Trino's `CREATE TABLE <target> AS SELECT ...` (CTAS) form — the team's "ad-hoc extract" pattern documented for this environment. The COMPLETE statement LEADS with the `CREATE TABLE ... AS` prefix; a bare `SELECT ... GROUP BY ...` is **not** CTAS — it only returns rows to the client. Copy the full form below:

```sql
-- Save the query result as a new Iceberg table (CTAS — CREATE TABLE AS SELECT).
-- The CREATE TABLE <fully.qualified.target> AS prefix is REQUIRED — without it,
-- the SELECT just returns rows and nothing is persisted.
-- DO NOT WRITE: `iceberg.catalog_name.schema_name.tbl` (4-segment placeholder). A Trino
-- table reference is EXACTLY 3-part: `catalog.schema.table` (here `iceberg.analytics.daily_revenue_summary`).
CREATE TABLE iceberg.analytics.daily_revenue_summary AS
SELECT
    event_date,
    region,
    SUM(amount)        AS revenue,
    COUNT(*)           AS order_count,
    COUNT(DISTINCT user_id) AS unique_buyers
FROM iceberg.analytics.orders
WHERE event_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
GROUP BY event_date, region;

-- Now query the small materialized table multiple times — cheaper than re-running the SELECT.
SELECT region, SUM(revenue) FROM iceberg.analytics.daily_revenue_summary GROUP BY region;
SELECT event_date, SUM(unique_buyers) FROM iceberg.analytics.daily_revenue_summary GROUP BY event_date;

-- Drop when done with the ad-hoc workflow.
DROP TABLE iceberg.analytics.daily_revenue_summary;
```

**Keyword anchors:** save query result as a table, create a table from a SELECT, CREATE TABLE AS SELECT, CTAS, materialize a query into a table, persist a query output as a table, save the output of a query, store query results.

**What CTAS carries — and what it does NOT.** CTAS carries the column **TYPES** inferred from the SELECT's result columns. It does **NOT** carry NOT NULL constraints, primary keys, partitioning of the source, or other constraints — the new table's columns are nullable unless you switch to the explicit `CREATE TABLE <name> (col TYPE NOT NULL, ...)` + separate `INSERT INTO ... SELECT` 2-step form. See [resource 09 CTAS-NOT-NULL-INFERENCE GUARDRAIL](09-lakehouse-schema-design.md) for the full worked guardrail and the verbatim trino.io citations — that GUARDRAIL is the authority; do **not** rewrite it inline here.

**Partitioning the CTAS target.** Add a `WITH (partitioning = ARRAY['day(event_date)'])` clause between the target name and `AS` to partition the materialized result — common for date-bucketed extracts:

```sql
CREATE TABLE iceberg.analytics.daily_revenue_summary
WITH (partitioning = ARRAY['day(event_date)'], format = 'PARQUET')
AS
SELECT event_date, region, SUM(amount) AS revenue
FROM iceberg.analytics.orders
WHERE event_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
GROUP BY event_date, region;
```

**On-prem `temp` schema convention.** The team's prod environment (see `prod_info.md`) documents `INSERT INTO <temp_table> AS SELECT ...` for ad-hoc result export — you can equally use `CREATE TABLE temp.my_extract AS SELECT ...` (CTAS into a `temp` schema) when the target doesn't yet exist, then `DROP TABLE temp.my_extract` when finished. Both forms produce Iceberg tables on MinIO that the engineer can download via the S3 protocol.

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
| **`STRING_AGG(col, sep ORDER BY ...)`** | PostgreSQL | **NOT under that name.** | `listagg(col, sep) WITHIN GROUP (ORDER BY ...)` is Trino's ANSI-standard form. **AGGREGATE-ONLY** — Trino `listagg` does **NOT support `OVER (...)` window frames** (per [trino.io/docs/current/functions/aggregate.html#listagg](https://trino.io/docs/current/functions/aggregate.html#listagg) verbatim: "The current implementation of listagg function does not support window frames"). Requires `GROUP BY` in the outer query, produces ONE row per group. For Oracle's windowed `LISTAGG(...) OVER (PARTITION BY k)` (value repeated on every row), use `array_join(array_agg(expr) OVER (PARTITION BY k), sep)` — see [resource 27 § 7A.2A — Oracle WINDOWED LISTAGG → Trino](27-oracle-plsql-to-dbt-trino.md). |
| **`ARRAY_AGG` with implicit ORDER BY** | various | **No implicit ORDER BY** — Trino's `array_agg` is unordered unless specified. | `array_agg(col ORDER BY ts)` — always specify ORDER BY when order matters. |
| **`MERGE` on non-Iceberg connectors without flag** | various | **Per-connector gate.** Iceberg MERGE is supported by default; MySQL/PostgreSQL MERGE requires connector-specific flags (see resource 22 section 2A). | Check the connector's MERGE support matrix before assuming MERGE works. |
| **Postgres `RETURNING` clause** on INSERT/UPDATE/DELETE | PostgreSQL | **NOT supported.** Parse error. | Run a follow-up SELECT or use the `Trino transaction count(...) - count(...)` row-count diagnostics. |
| **`ILIKE`** (case-insensitive LIKE) | PostgreSQL | **NOT supported in native Trino 467 SQL.** Parse error: `WHERE col ILIKE 'pat'` on a local Iceberg/Hive table fails with `mismatched input 'ilike'`. ILIKE is absent from [trino.io/docs/current/functions/comparison.html](https://trino.io/docs/current/functions/comparison.html), [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html), and [trino.io/docs/current/language/reserved.html](https://trino.io/docs/current/language/reserved.html). Feature request [trinodb/trino #2491](https://github.com/trinodb/trino/issues/2491) (titled "Add `ILIKE` function to support case-insensitive LIKE-like string matching") has been **OPEN since January 2020** — no PR merged. **Disambiguator**: ILIKE DOES appear in the **PostgreSQL CONNECTOR** context (resource 22 §3.3) as a predicate **pushed down to the remote PostgreSQL engine** (Postgres has ILIKE natively) — that is **federation/connector-pushdown behavior**, NOT native Trino SQL you can run on a local Iceberg table. Do not conflate. | **Case-insensitive LIKE / contains / starts-with on native Trino tables**: lower both sides — `WHERE LOWER(col) LIKE LOWER('pat%')` (or `WHERE LOWER(email) LIKE '%@gmail.com'` when the literal is already lowercase). **Case-insensitive equality**: `WHERE LOWER(col) = 'acme'`. **Case-insensitive regex**: `WHERE regexp_like(col, '(?i)pattern')` (the `(?i)` inline flag makes the Java regex case-insensitive). **Ingest-time optimization**: if the column is queried case-insensitively often, store a `lower(col)` generated/computed column at ingest and filter on it directly — avoids the per-row `LOWER()` and lets the predicate push down to Iceberg as `col_lower = 'acme'`. **DO NOT WRITE on local Trino tables**: `WHERE col ILIKE 'pat'` — parse error, ILIKE is not native Trino SQL (keyword anchors: case-insensitive LIKE Trino, ILIKE Trino, case-insensitive match, match regardless of case, LOWER LIKE, ILIKE not supported Trino, case-insensitive equals/contains/starts-with). |
| **`GROUP BY ALL`** (group by every non-aggregate) | Snowflake, Databricks | **SUPPORTED** in Trino's SELECT grammar (`GROUP BY [ ALL | DISTINCT ] ...`). | Free to use, but explicit `GROUP BY col1, col2` is more grep-able. |
| **`FETCH FIRST N ROWS ONLY`** (ANSI) | ANSI SQL, DB2, Oracle | **SUPPORTED** alongside `LIMIT N`. | Either is fine; `LIMIT N` is shorter. |
| **Window function in WHERE** (`WHERE ROW_NUMBER() OVER (...) = 1`) | none — never legal in standard SQL | **NOT supported in any SQL dialect, including Trino.** | Wrap in a subquery: `SELECT * FROM (SELECT *, ROW_NUMBER() OVER (...) AS rn FROM t) WHERE rn = 1;` — same pattern as the QUALIFY rewrite. |
| **Assuming `ORDER BY ts DESC` puts NULLs at the top** (Oracle's default) | Oracle | **SILENT-WRONG row ordering on Trino.** Per [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) verbatim: "The default null ordering is `NULLS LAST`, regardless of the ordering direction." Trino defaults `NULLS LAST` for BOTH `ASC` and `DESC` — Oracle defaults `NULLS LAST` for `ASC` and `NULLS FIRST` for `DESC`. Same SQL, different row order, no error message. | Always write `ORDER BY ts DESC NULLS FIRST` (preserve Oracle behavior) or `ORDER BY ts DESC NULLS LAST` (explicit Trino default). See [resource 27 § LEADING CANONICAL — Oracle vs Trino NULLS-default semantics in ORDER BY](27-oracle-plsql-to-dbt-trino.md). |

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
