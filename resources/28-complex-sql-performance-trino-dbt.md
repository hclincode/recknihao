# Improving Complex SQL Performance on Trino with dbt

> Your dbt models — many of them just-migrated from Oracle PL/SQL ([resource 27](27-oracle-plsql-to-dbt-trino.md)) — run, but slowly. Some take 20 minutes to process what Oracle did in 2. This guide is the practical performance-tuning playbook for complex SQL on Trino 467 + Iceberg 1.5.2 driven by dbt, organized around the patterns that go wrong most often when SQL is translated from a row-engine to a parallel query engine.
>
> **Production stack assumed**: Trino 467 OSS, Iceberg 1.5.2 with Hive Metastore, MinIO via S3, on-prem Kubernetes, dbt-trino adapter.

---

## TL;DR (read these 8 sentences first)

1. **A migrated SQL query that "works" is not the same as a fast SQL query.** Naive Oracle->Trino translations almost always reproduce three Trino-hostile patterns: correlated subqueries in the SELECT list, deep CTE chains that re-evaluate, and function-wrapped partition-column predicates that defeat partition pruning.
2. **Trino CTEs are INLINED, not materialized.** `WITH x AS (SELECT ...) SELECT * FROM x JOIN x ON ...` evaluates `x` TWICE. There is NO optimization fence, NO caching of the CTE result. To materialize once, write a dbt intermediate model (`materialized='table'` or `'incremental'`) and `ref()` it.
3. **Trino has NO query result cache** (OSS Trino 467). Re-running the exact same SQL re-executes from scratch. The "cache" your dashboard appears to have is the underlying Iceberg storage table (already-aggregated rollups) — that's what dbt incremental models, materialized views ([resource 25](25-trino-materialized-views-iceberg.md)), and dashboard-side caching give you.
4. **Predicate pushdown to Iceberg is the single biggest performance lever**, and the single easiest one to accidentally break — by wrapping the partition column in a function (`WHERE date_trunc('day', event_ts) = ...`), by casting it (`WHERE CAST(event_date AS varchar) = ...`), or by comparing it across types. Keep partition columns naked on one side of the predicate.
5. **Correlated subqueries are the migration-shaped slowness champion.** Trino tries to decorrelate them into joins; when it succeeds, the EXPLAIN shows `SemiJoin` / `Join` / `Project`. When decorrelation fails, EXPLAIN shows `CorrelatedJoin` — an O(N×M) nested-loop in worker memory. **Always EXPLAIN your migrated queries and search for `CorrelatedJoin`.**
6. **Joins**: tiny dim + huge fact -> BROADCAST (default for builds under ~100MB); large + large -> PARTITIONED; cross-source -> rely on **dynamic filtering** (Trino sends build-side keys to probe side at runtime). Run `ANALYZE TABLE` so the optimizer has stats to pick correctly ([resource 24](24-trino-cbo-analyze.md)).
7. **dbt-specific levers**: choose `materialized='incremental'` to skip recomputing unchanged rows; partition the dbt-built Iceberg table with `properties={'partitioning': "ARRAY[...]"}`; cluster files with `sorted_by` + run `ALTER TABLE ... EXECUTE optimize` ([resource 17](17-iceberg-table-maintenance.md)).
8. **EXPLAIN ANALYZE is the source of truth**, not folklore. `physicalInputDataSize` tells you how many bytes were read from MinIO; `CorrelatedJoin` vs `SemiJoin` tells you whether decorrelation fired; `dynamicFilterSplitsProcessed` tells you whether dynamic filtering worked; partition-prune constraint on `TableScan` tells you whether you scanned the whole table or one partition.

---

## Common myths about complex SQL performance on Trino + dbt — read FIRST

These are the absolutes most often stated incorrectly when an engineer with Postgres / Oracle / Snowflake muscle memory tries to performance-tune a dbt model on Trino 467. Each TRUTH below has been verified against the [Trino docs](https://trino.io/docs/current/), [dbt-trino docs](https://docs.getdbt.com/reference/resource-configs/trino-configs), and the cited GitHub discussions. **Lead with the TRUTH; state the nuance.**

| MYTH (commonly said wrong) | TRUTH (correct framing) | Authoritative pointer |
|---|---|---|
| "Trino CTEs are materialized — defining `WITH x AS (SELECT expensive_thing)` and referencing `x` twice computes `x` once." | **FALSE on Trino 467 — CTEs are INLINED, NOT materialized.** Trino's optimizer textually substitutes the CTE SELECT wherever the name is referenced. Referencing the same CTE 3 times runs the expensive_thing 3 times. There is no optimization fence and no result reuse. **DO NOT WRITE `WITH heavy AS (...) SELECT ... FROM heavy a JOIN heavy b ON ...` expecting heavy to run once — it runs twice.** Materialize once with a dbt intermediate model (`materialized='table'`) or, for the single-query case, save the result to a temp Iceberg table via `CREATE TABLE ... AS SELECT` first. See [trinodb/trino discussion #28090](https://github.com/trinodb/trino/discussions/28090) and [issue #28085](https://github.com/trinodb/trino/issues/28085). | [Trino SELECT - WITH](https://trino.io/docs/current/sql/select.html#with-clause) — *"the SQL for the WITH clause will be inlined anywhere the named relation is used"*. |
| "More CTEs = faster — breaking a query into 10 CTEs lets the optimizer plan each one separately." | **FALSE — CTE count is performance-neutral or NEGATIVE.** Each CTE is inlined into the query tree; the optimizer plans the whole tree as one. 10 CTEs and one giant subquery produce the same physical plan. CTEs are a READABILITY tool, not a performance tool. If a CTE is referenced multiple times, MORE CTEs can be WORSE (each reference inlines and re-evaluates). The performance lever is *materialization*, not *naming the subquery*. | Same as above. |
| "OSS Trino 467 caches query results — re-running the same SQL is fast." | **FALSE — OSS Trino 467 has NO query result cache.** Re-executing the same query re-reads from Iceberg/MinIO from scratch. See [trinodb/trino #20854](https://github.com/trinodb/trino/issues/20854) (open feature request). What DOES exist: (a) Iceberg connector metadata cache (table/snapshot metadata, reduces planning latency, NOT data cache), (b) the OS page cache on MinIO nodes (incidental), (c) commercial forks (Starburst) which add result caching. The standard mitigation in this stack is to MATERIALIZE the result: dbt incremental models, Trino materialized views ([resource 25](25-trino-materialized-views-iceberg.md)), or dashboard-side cache (Redis). **DO NOT advise an engineer to "just re-run the query, Trino will cache it." It won't.** | [trinodb/trino #20854](https://github.com/trinodb/trino/issues/20854) |
| "Adding more Trino workers always speeds up a slow query." | **FALSE — only true when the query is CPU-bound or scan-bound AND parallelizable.** Adding workers does NOT help when: (a) the bottleneck is a non-distributable operator (single-stage final aggregation; `CorrelatedJoin` nested-loop; ordered global sort), (b) the bottleneck is a SOURCE that can't be scanned in parallel (MySQL via JDBC = 1 split, regardless of workers — see [resource 22](22-trino-federation-postgresql.md)), (c) the bottleneck is the coordinator's planning time, (d) data is skewed so one worker holds 90% of the rows. **Always EXPLAIN ANALYZE first to find the bottleneck — don't reflexively scale out.** | [Trino tuning](https://trino.io/docs/current/admin/tuning.html) |
| "`QUALIFY ROW_NUMBER() OVER (...) = 1` is faster than the equivalent subquery + WHERE rn = 1." | **FALSE on Trino 467 — QUALIFY is a PARSE ERROR.** QUALIFY is a Snowflake/BigQuery/Databricks/Teradata extension, not in the SQL standard, NOT in Trino. The canonical Trino rewrite is `SELECT * FROM (SELECT *, row_number() OVER (PARTITION BY ... ORDER BY ...) AS rn FROM t) WHERE rn = 1`. There is no faster shape; that IS the canonical pattern. **DO NOT WRITE `QUALIFY ...` in a dbt model targeting Trino — it will fail to compile.** | [resource 23](23-sql-best-practices-olap.md) |
| "`rewrite_data_files` is the Trino procedure to compact Iceberg files." | **FALSE — `rewrite_data_files` is the SPARK procedure (`CALL iceberg.system.rewrite_data_files(...)`). On Trino 467 the equivalent is `ALTER TABLE ... EXECUTE optimize`, which honors the table's `sorted_by` property if set.** Pasting Spark `CALL` syntax into a Trino query yields `Procedure not registered`. See [resource 17 § Trino EXECUTE vs Spark CALL disambiguation](17-iceberg-table-maintenance.md). | [Trino Iceberg connector](https://trino.io/docs/current/connector/iceberg.html); [Iceberg Spark procedures](https://iceberg.apache.org/docs/latest/spark-procedures/) |
| "Wrapping a partition column in `date_trunc()` is fine — Iceberg understands the function." | **FALSE on Trino 467 — `WHERE date_trunc('day', event_ts) = DATE '2026-05-30'` does NOT prune partitions** even if the table is partitioned by `day(event_ts)`. The function on the LEFT side of the predicate prevents Trino from translating the predicate into a partition constraint, so the connector scans every partition. **The fix:** rewrite to `WHERE event_ts >= TIMESTAMP '2026-05-30 00:00:00' AND event_ts < TIMESTAMP '2026-05-31 00:00:00'` — Iceberg's hidden partitioning + transform-aware constraint solver will then prune. Verify with `EXPLAIN` and look at the `constraint=` annotation on the `TableScan`. | [resource 10](10-lakehouse-partitioning.md), [resource 23 § Always include the partition column in WHERE](23-sql-best-practices-olap.md) |
| "Correlated subqueries are fine — Trino's optimizer handles them." | **PARTIALLY TRUE — and partially DANGEROUS.** Trino's optimizer ATTEMPTS to decorrelate correlated subqueries via the `TransformCorrelatedJoinToJoin` rule (and related rules for LIMIT, TopN, scalar subqueries). When decorrelation SUCCEEDS, the EXPLAIN shows the rewritten Join/SemiJoin and the query is fast. When decorrelation FAILS (common shapes: aggregates inside the correlated subquery referencing outer cols, correlated WHERE with non-equality conditions, complex outer-references), the EXPLAIN shows a `CorrelatedJoin` operator — a nested-loop executed in worker memory, O(N×M). **The fix is to manually rewrite as a window function or explicit JOIN — don't rely on the optimizer to always win.** Always EXPLAIN and search for `CorrelatedJoin`. | [Trino - Decorrelate subqueries (episode 7)](https://trino.io/episodes/7.html) |
| "BROADCAST joins are always faster than PARTITIONED joins." | **FALSE — only when the BUILD side fits in worker memory.** BROADCAST replicates the build to every worker (fast for small builds, OOM for large). PARTITIONED hash-shuffles BOTH sides by join key (extra shuffle, scales to TB-scale joins). The optimizer picks based on `join-max-broadcast-table-size` (100MB default) when stats are available. **If you have a 5GB dim table joining 500GB fact, BROADCAST will OOM — let Trino pick PARTITIONED.** Run `ANALYZE TABLE` so the optimizer can choose; see [resource 24](24-trino-cbo-analyze.md). | [resource 22 § BROADCAST vs PARTITIONED](22-trino-federation-postgresql.md) |
| "Dynamic filtering doesn't apply to my query — it's only for federated joins." | **FALSE — dynamic filtering is for INNER and RIGHT joins regardless of source.** When you join Iceberg fact x Iceberg dim, build-side keys are still sent to the probe scan at runtime to prune the probe Parquet row-groups. EXPLAIN ANALYZE VERBOSE shows `dynamicFilterSplitsProcessed` and pruned-row counts. Caveat: dynamic filtering does NOT apply to LEFT or FULL OUTER joins. | [Trino - Dynamic filtering](https://trino.io/docs/current/admin/dynamic-filtering.html) |
| "If a CTE is referenced N times in one query, I can force Trino to materialize it with a session property." | **FALSE on Trino 467 — there is no `WITH ... MATERIALIZED` syntax and no session flag to force CTE materialization.** Postgres 12+ has `WITH x AS MATERIALIZED (...)`; Trino has not implemented it (open since 2018, see [trinodb/trino issue #10](https://github.com/prestosql/presto/issues/10) and [#5878](https://github.com/prestosql/presto/issues/5878)). **DO NOT WRITE `WITH x AS MATERIALIZED (...)` in Trino — parse error.** The only way to materialize once on Trino 467 is to write the intermediate to a real (or temp) table — typically a dbt intermediate model with `materialized='table'`. | [trinodb/trino issues #10, #5878, #28090](https://github.com/trinodb/trino/discussions/28090) |

> **Why these specific myths matter.** Each is a load-bearing assumption that, if held, leads engineers to either (a) skip the actual fix (build more CTEs instead of materializing; add workers when the bottleneck is `CorrelatedJoin`; assume Trino caches the result) or (b) confidently break a working query (paste Spark `CALL` into Trino, paste QUALIFY into a dbt model, wrap partition columns in `date_trunc`). **The correct discipline: when about to claim "Trino does / doesn't / will / won't do X" about performance, run `EXPLAIN` or `EXPLAIN ANALYZE` and verify the plan shape.**

---

## 1. The performance-tuning workflow on Trino + dbt

Before changing any SQL, do these four things in order. Steps 1-2 are mandatory; skip them and you'll guess wrong.

### Step 1: Capture the EXPLAIN plan

```sql
EXPLAIN (FORMAT TEXT)
SELECT ...your slow query...;
```

Look for:

- **`TableScan` constraint** — is the partition column listed? If so, partition pruning is firing. If the `TableScan` has no constraint on the partition column, you scanned the whole table.
- **`CorrelatedJoin`** — decorrelation failed. This is almost always the #1 problem in a migrated Oracle query.
- **`Filter`** between `TableScan` and the upper plan — the filter did NOT push down. Predicate may be function-wrapped or type-mismatched.
- **`Aggregate` followed by `Exchange[REPARTITION]`** — your GROUP BY is shuffling all data. Often unavoidable for high-cardinality groups, but sometimes a sign of skew.
- **`Join` distribution** — `REPLICATED` = broadcast (small build), `REPARTITION` = partitioned (both sides shuffle).

### Step 2: Run EXPLAIN ANALYZE on a representative slice

```sql
EXPLAIN ANALYZE
SELECT ...your slow query with a small WHERE filter so it actually finishes...;
```

This adds runtime metrics to each operator. Look for:

- **`physicalInputDataSize: X.X GB`** on `TableScan` — how many bytes were actually read from MinIO. If you expected MB and got GB, partition pruning failed.
- **`Time: X.Xs (Y rows)`** per operator — where is time being spent.
- **`dynamicFilterSplitsProcessed: N`** — verifies dynamic filtering fired on a join.
- **`Output rows: N`** vs **`Input rows: N`** — selectivity at each operator. A `Filter` that reduces 1B rows to 1M rows is doing useful work; a `Filter` that reduces 1B to 999.9M is not.

### Step 3: Identify the bottleneck operator

The slow operator(s) will jump out from the EXPLAIN ANALYZE timings. Map it to the section below:

| Bottleneck shape | Section |
|---|---|
| `CorrelatedJoin` operator visible in plan | § 2 |
| `TableScan` reads all partitions despite WHERE on partition col | § 4.2 |
| Same expensive CTE referenced N times | § 3 |
| `Filter` sitting between `Aggregate` and `TableScan` | § 4.2 |
| `Join` with very large `RemoteExchange[REPLICATE]` (broadcast OOM risk) | § 5 |
| Long sequential scan when the underlying table is huge | § 6 (dbt materialization) |
| Query reruns are also slow | § 7 (materialization + dashboards) |

### Step 4: Make ONE change, re-EXPLAIN, measure

Resist the urge to make 5 changes at once. After each change, re-EXPLAIN, then EXPLAIN ANALYZE on the slice. The bottleneck should move (good) or vanish (better). If it stays in the same place, the change didn't help — revert it before trying the next.

---

## 2. Correlated subqueries — the migration slowness champion

Correlated subqueries are the SQL shape that most often slows a migrated Oracle query to a crawl on Trino. They look harmless in source, and they sometimes work fine (decorrelation succeeded), and sometimes catastrophically (decorrelation failed). Both shapes are common; you can't tell which by reading the SQL.

### 2.1 The pattern that causes the problem

```sql
-- "For each order, get the customer's most recent order amount before this one"
-- (A typical Oracle-shaped per-row lookup.)
SELECT
  o.order_id,
  o.customer_id,
  o.amount,
  (SELECT MAX(o2.amount)
     FROM orders o2
    WHERE o2.customer_id = o.customer_id
      AND o2.order_ts < o.order_ts) AS prev_max_amount
FROM orders o;
```

The inner SELECT references `o.customer_id` and `o.order_ts` from the outer query — that's the correlation. Conceptually, Oracle's row-engine ran this once per outer row. Trino tries to decorrelate it; depending on shape, it may or may not succeed.

### 2.2 EXPLAIN: did decorrelation work?

```sql
EXPLAIN
SELECT o.order_id, ..., (SELECT MAX(o2.amount) FROM orders o2 WHERE ...) FROM orders o;
```

**Success case** — the plan shows a `Join` or `SemiJoin` (decorrelation rewrote the correlation to a join):

```
... Project[...]
      Join[INNER][customer_id = customer_id, order_ts > order_ts]
        TableScan[orders]
        Aggregate[GROUP BY customer_id, ... MAX(amount)]
          TableScan[orders]
```

**Failure case** — the plan shows `CorrelatedJoin`:

```
... Project[...]
      CorrelatedJoin[...]
        TableScan[orders]
        Aggregate[MAX(amount)]
          Filter[customer_id = $0 AND order_ts < $1]
            TableScan[orders]
```

The `CorrelatedJoin` operator is the smoking gun: a nested-loop in worker memory, O(N x M) execution, no parallelism inside.

### 2.3 The manual rewrite — use a window function

The same logic expressed without correlation, as a window function:

```sql
SELECT
  order_id,
  customer_id,
  amount,
  MAX(amount) OVER (
    PARTITION BY customer_id
    ORDER BY order_ts
    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
  ) AS prev_max_amount
FROM orders;
```

One pass over the table, hash-partitioned by `customer_id`, sorted within each partition by `order_ts`, MAX accumulated incrementally. This is consistently 10x-100x faster than the correlated-subquery version when the latter fails to decorrelate.

### 2.4 Common correlated patterns and their canonical Trino rewrites

| Correlated pattern | Trino-friendly rewrite |
|---|---|
| `SELECT (SELECT MAX(b.x) FROM b WHERE b.id = a.id) FROM a` (scalar subquery in SELECT) | `SELECT ... FROM a LEFT JOIN (SELECT id, MAX(x) AS max_x FROM b GROUP BY id) b_agg ON b_agg.id = a.id` |
| `SELECT ... FROM a WHERE EXISTS (SELECT 1 FROM b WHERE b.id = a.id)` | `SELECT a.* FROM a WHERE a.id IN (SELECT id FROM b)` (Trino converts to SemiJoin) OR explicit `JOIN ... DISTINCT` |
| `SELECT ... FROM a WHERE NOT EXISTS (SELECT 1 FROM b WHERE b.id = a.id)` | `SELECT a.* FROM a LEFT JOIN b ON b.id = a.id WHERE b.id IS NULL` (anti-join) |
| `SELECT (SELECT COUNT(*) FROM b WHERE b.cid = a.cid) FROM a` | `SELECT a.*, b_cnt.cnt FROM a LEFT JOIN (SELECT cid, COUNT(*) AS cnt FROM b GROUP BY cid) b_cnt ON b_cnt.cid = a.cid` |
| Per-row "running total" via correlated `(SELECT SUM(x) FROM t t2 WHERE t2.dt <= t.dt)` | `SELECT ..., SUM(x) OVER (ORDER BY dt ROWS UNBOUNDED PRECEDING) FROM t` (window function) |
| "Most recent N per group" via `WHERE n_rows_with_later_date < N` correlated count | `SELECT * FROM (SELECT *, row_number() OVER (PARTITION BY g ORDER BY dt DESC) rn FROM t) WHERE rn <= N` |

---

## 3. CTEs are inlined — materialize once with dbt

This is the second most common migration slowness pattern, and the one most experienced Postgres / Snowflake engineers get wrong because in those engines CTEs were either materialized by default (older Postgres) or by hint (modern Postgres). **In Trino 467, CTEs are inlined and re-evaluated.**

### 3.1 The pattern that causes the problem

```sql
-- BAD: heavy_cte is computed TWICE
WITH heavy_cte AS (
  SELECT customer_id, SUM(amount) AS total
  FROM orders
  WHERE order_date >= DATE '2026-05-01'
  GROUP BY customer_id  -- expensive: shuffles 100GB of orders
)
SELECT
  big_spenders.customer_id,
  big_spenders.total,
  small_spenders.total AS small_total
FROM heavy_cte AS big_spenders
JOIN heavy_cte AS small_spenders ON big_spenders.total > small_spenders.total * 10;
```

The CTE `heavy_cte` is referenced under two aliases in the JOIN. Trino INLINES BOTH references — it runs the GROUP BY twice, shuffles the 100GB orders table twice, etc.

### 3.2 The dbt-shaped fix — materialize the intermediate

Move `heavy_cte` to its own dbt model with `materialized='table'`:

```jinja
-- models/intermediate/int_customer_totals.sql
{{ config(
    materialized='table',
    properties={
      'format': 'PARQUET',
      'partitioning': "ARRAY['order_month']",
      'sorted_by': "ARRAY['customer_id']",
      'format_version': 2
    }
) }}

SELECT
  customer_id,
  date_trunc('month', order_date) AS order_month,
  SUM(amount) AS total
FROM {{ ref('stg_orders') }}
WHERE order_date >= DATE '2026-05-01'
GROUP BY customer_id, date_trunc('month', order_date)
```

Then your downstream model references it twice:

```sql
-- models/marts/big_vs_small_spenders.sql
SELECT
  big.customer_id,
  big.total,
  small.total AS small_total
FROM {{ ref('int_customer_totals') }} AS big
JOIN {{ ref('int_customer_totals') }} AS small
  ON big.total > small.total * 10;
```

Now the expensive aggregation runs ONCE during `dbt run` (when `int_customer_totals` builds), and the downstream join reads the already-materialized table.

### 3.3 When to use `ephemeral` vs `table` for the intermediate

| Intermediate referenced... | Choose |
|---|---|
| **1 time only**, lightweight | `ephemeral` (it gets inlined as a CTE — same as writing the CTE directly, but reusable) |
| **2-3 times** within a single downstream model | `table` (materialize once, read N times — the CTE-inlining problem above) |
| **Reused across multiple downstream models** | `table` or `incremental` (the cost is amortized across all consumers) |
| **Across multiple dbt runs and the cost is bounded** | `incremental` with `merge` strategy |

### 3.4 The "deep CTE chain" anti-pattern

```sql
-- A "readable" deep CTE chain that's actually slow:
WITH a AS (SELECT ... FROM source),
     b AS (SELECT ... FROM a WHERE ...),
     c AS (SELECT ... FROM b JOIN ... ON ...),
     d AS (SELECT ... FROM c GROUP BY ...),
     e AS (SELECT ... FROM d JOIN c ON ...)  -- c is referenced TWICE (in d and e), so c is inlined twice
SELECT * FROM e;
```

`c` is referenced both directly by `e` AND indirectly through `d` (which `e` joins). Trino inlines `c`'s SELECT in both places. If `c` is an expensive join, you pay for it twice. **The fix:** identify the CTEs referenced 2+ times in the dependency graph, promote each to its own dbt model with `materialized='table'` (or `ephemeral` if it's only referenced once after the split).

---

## 4. Predicate pushdown — the partition-prune predicate shape

Trino's Iceberg connector can push partition predicates into the metadata layer, skipping entire partitions without reading their data files. This is the single biggest performance lever on a partitioned Iceberg table. It's also the easiest one to accidentally defeat.

### 4.1 What works (predicate pushes, partitions prune)

```sql
-- ALL of these prune partitions on a table partitioned by day(event_ts):
WHERE event_ts >= TIMESTAMP '2026-05-30 00:00:00'
  AND event_ts <  TIMESTAMP '2026-05-31 00:00:00'

WHERE event_ts BETWEEN TIMESTAMP '2026-05-30 00:00:00'
                   AND TIMESTAMP '2026-05-30 23:59:59'

WHERE event_date = DATE '2026-05-30'    -- if partitioned by event_date

WHERE tenant_id = 42                    -- if partitioned by tenant_id

WHERE tenant_id IN (42, 43, 44)         -- IN-list partition prune
```

### 4.2 What breaks pushdown (and how to fix it)

| Broken shape | Why it breaks | Fix |
|---|---|---|
| `WHERE date_trunc('day', event_ts) = DATE '2026-05-30'` | Function on partition column prevents Trino from translating to a partition constraint. | `WHERE event_ts >= TIMESTAMP '2026-05-30 00:00:00' AND event_ts < TIMESTAMP '2026-05-31 00:00:00'` |
| `WHERE CAST(event_date AS varchar) = '2026-05-30'` | Cast wraps the column. | `WHERE event_date = DATE '2026-05-30'` |
| `WHERE event_date + INTERVAL '1' DAY = DATE '2026-05-31'` | Arithmetic on partition col. | `WHERE event_date = DATE '2026-05-30'` |
| `WHERE LOWER(tenant_id) = 'tenant_42'` | Function wraps the partition col. | If `tenant_id` is already lowercase in storage, drop `LOWER`; otherwise reconsider partitioning. |
| `WHERE event_date >= '2026-05-30'` (string compared to date) | Type mismatch — Trino does NOT push when types don't match. | Use `DATE '2026-05-30'` literal. |
| `WHERE event_date >= ?` (parameter, query against a view that hides partition col) | Sometimes parameters defeat pushdown — verify with EXPLAIN. | Inline the literal where possible. |
| `WHERE event_date >= CURRENT_DATE - INTERVAL '7' DAY` | Verify in EXPLAIN — modern Trino versions evaluate this at plan time and push, but some shapes don't. | If it doesn't push, compute the literal in dbt Jinja: `{% set sd = run_started_at.strftime('%Y-%m-%d') %}` and inline. |

### 4.3 How to verify in EXPLAIN

```sql
EXPLAIN
SELECT COUNT(*) FROM iceberg.analytics.events
WHERE event_date = DATE '2026-05-30';
```

Look for the `TableScan` line. If pushdown worked:

```
TableScan[iceberg.analytics.events, constraint=event_date = DATE '2026-05-30']
```

The `constraint=...` annotation on the TableScan is the success signature. If you instead see:

```
Filter[event_date = DATE '2026-05-30']
  TableScan[iceberg.analytics.events]
```

— a separate `Filter` node sits between the projection and the scan — pushdown did NOT fire. The full table is being scanned and filtered in worker memory.

---

## 5. Join distribution — broadcast, partitioned, dynamic filtering

When you join two tables on Trino, the engine picks one of two distribution strategies:

- **BROADCAST** (`RemoteExchange[REPLICATE]`): build side (smaller) is replicated to every worker. Fast for small builds. OOMs for big builds.
- **PARTITIONED** (`RemoteExchange[REPARTITION]`): both sides hash-shuffled by join key. Scales to huge tables. Adds a network shuffle.

The optimizer picks based on the table's stats. **If you've never run `ANALYZE TABLE iceberg.analytics.events` on the joined tables, the optimizer's pick is unreliable** — see [resource 24 — CBO / ANALYZE](24-trino-cbo-analyze.md).

### 5.1 The single-query session overrides (when you need to force it)

```sql
-- Force BROADCAST (use only when you KNOW the build side is small):
SET SESSION join_distribution_type = 'BROADCAST';

-- Force PARTITIONED (use when stats are missing or wrong and BROADCAST OOMs):
SET SESSION join_distribution_type = 'PARTITIONED';

-- Default (let optimizer pick based on stats):
SET SESSION join_distribution_type = 'AUTOMATIC';
```

These are session-scoped, so set them at the start of a Trino client session or set per-dbt-run via the dbt profile / `pre_hook`. For the per-model case, dbt-trino allows `pre_hook` in the config:

```jinja
{{ config(
    materialized='table',
    pre_hook="SET SESSION join_distribution_type = 'PARTITIONED'"
) }}
```

### 5.2 Dynamic filtering — the runtime probe-prune

Dynamic filtering is the runtime feature that makes "small dim x huge fact" joins fast even without partitioning by the join key. At runtime, Trino collects the build-side join key values into a filter (an IN-list or min/max range), sends it to the probe-side scan, and the probe side prunes Parquet row-groups using the filter BEFORE reading them.

Verify it fired:

```sql
EXPLAIN ANALYZE VERBOSE
SELECT f.*, d.tenant_name
FROM iceberg.analytics.events f
JOIN iceberg.analytics.tenants d ON f.tenant_id = d.id
WHERE d.region = 'us-west';
```

Look in the TableScan for `events`:

```
dynamicFilterSplitsProcessed: 200 (was 5000 unfiltered)
```

That means dynamic filtering pruned 4800 of 5000 splits at runtime.

Supported shapes (verified against [Trino dynamic filtering docs](https://trino.io/docs/current/admin/dynamic-filtering.html)):

- **INNER and RIGHT joins** — supported.
- **LEFT and FULL OUTER joins** — NOT supported.
- **Equality and inequality predicates** (`=`, `<`, `<=`, `>`, `>=`, `IS NOT DISTINCT FROM`) — supported.

---

## 6. dbt-specific levers — materialization choice, partitioning, sorting

When the query you're tuning is a dbt model (not an ad-hoc), the right fix is often at the dbt-config layer, not the SQL layer.

### 6.1 Choose `materialized='incremental'` to skip unchanged work

If your model rebuilds a full fact table from yesterday's source — but only 0.1% of the rows changed — switching from `table` to `incremental` with `merge` strategy can cut the run time from hours to minutes. See [resource 27 § 6](27-oracle-plsql-to-dbt-trino.md) for the canonical worked example.

### 6.2 Partition the dbt-built Iceberg table

```jinja
{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='event_id',
    properties={
      'format': 'PARQUET',
      'partitioning': "ARRAY['day(event_ts)']",  -- Iceberg partition transform
      'sorted_by': "ARRAY['tenant_id']",
      'format_version': 2
    }
) }}
```

Partition by the column that dominates your downstream WHERE clauses. See [resource 10 — partitioning](10-lakehouse-partitioning.md) for the full transform options (`day(...)`, `month(...)`, `bucket(N, col)`, `truncate(N, col)`, identity).

### 6.3 Cluster files with `sorted_by` + run `optimize`

The `sorted_by` property tells Iceberg writers to sort rows within each file by the specified columns. This dramatically improves Parquet's data skipping for range predicates on the sort key — because each file's min/max statistics for the sort col have a much narrower range.

To enforce ordering across existing files (e.g., after many small incremental writes), run:

```sql
-- Trino 467: bin-packs and re-sorts to honor the table's sorted_by property
ALTER TABLE iceberg.analytics.events EXECUTE optimize;
```

NOT `CALL iceberg.system.rewrite_data_files(...)` — that's the Spark syntax. See [resource 17 § Trino EXECUTE vs Spark CALL](17-iceberg-table-maintenance.md).

### 6.4 ANALYZE TABLE for join planning

```sql
ANALYZE TABLE iceberg.analytics.events;
ANALYZE TABLE iceberg.analytics.tenants;
```

Run after a `dbt run` that significantly changes data (e.g., post full refresh, post big incremental). The Trino optimizer uses these stats to pick join distribution, join order, and dynamic-filter thresholds. See [resource 24](24-trino-cbo-analyze.md).

---

## 7. Re-runs of the same query are also slow — the result-caching gap

If your dashboard fires the same SQL every time a user clicks "refresh" and each click takes 30s, you need to know: **Trino does NOT cache query results.** Every run re-reads from MinIO and re-aggregates.

Your three options on this stack:

1. **dbt incremental model + scheduled `dbt run`** — the dashboard reads the already-aggregated table. Freshness = the cron cadence (5 min, 1 hour, daily). This is the standard pattern. See [resource 27 § 5-6](27-oracle-plsql-to-dbt-trino.md).
2. **Trino materialized view (Iceberg only)** — `CREATE MATERIALIZED VIEW` + scheduled `REFRESH MATERIALIZED VIEW`. Reads hit the Iceberg storage table. Manual refresh; no auto-refresh. See [resource 25](25-trino-materialized-views-iceberg.md).
3. **Application-side cache (Redis / in-memory)** — your SaaS app caches the query result keyed by user/tenant/date. Sub-second freshness for repeated reads; you manage the invalidation.

Pick based on freshness SLO: minutes -> dbt incremental; minutes-to-hours -> Trino MV; sub-second -> Redis.

---

## 8. Worked example — a slow migrated query, optimized step by step

This is the canonical "translated-from-Oracle and slow" query shape, walked through three fixes with before/after EXPLAIN signatures.

### 8.1 The slow query (the migrated form — typical day-one output)

```sql
SELECT *
FROM events e
WHERE date_trunc('day', e.event_ts) >= CURRENT_DATE - INTERVAL '7' DAY
  AND EXISTS (
    SELECT 1
    FROM customers c
    WHERE c.id = e.customer_id
      AND c.tier = 'PREMIUM'
  );
```

Three problems wrapped in one query:

1. `SELECT *` — opens every column of a 50-column wide table.
2. `date_trunc('day', e.event_ts)` — function-wrapped partition column, no partition prune.
3. Correlated `EXISTS` on `customers` — may or may not decorrelate.

### 8.2 EXPLAIN before any fix

```
Project[*]
  CorrelatedJoin[c.id = e.customer_id, c.tier = 'PREMIUM']      <-- DECORRELATION FAILED (nested loop)
    Filter[date_trunc('day', event_ts) >= DATE '2026-05-23']    <-- FILTER NOT PUSHED
      TableScan[iceberg.analytics.events]                       <-- FULL TABLE SCAN, all 50 cols, all partitions
    Aggregate[...]
      Filter[tier = 'PREMIUM']
        TableScan[iceberg.analytics.customers]
```

EXPLAIN ANALYZE on a slice reports `physicalInputDataSize: 800 GB`. Wall clock: ~22 min.

### 8.3 Fix 1 — narrow projection

```sql
SELECT e.event_id, e.event_ts, e.customer_id, e.event_type, e.amount
FROM events e
WHERE date_trunc('day', e.event_ts) >= CURRENT_DATE - INTERVAL '7' DAY
  AND EXISTS (SELECT 1 FROM customers c WHERE c.id = e.customer_id AND c.tier = 'PREMIUM');
```

EXPLAIN: still `CorrelatedJoin`, still `Filter` not pushed, but `TableScan` now reads only 5 columns. `physicalInputDataSize: 80 GB` (-90%). Wall clock: ~7 min.

### 8.4 Fix 2 — partition-prune-friendly predicate

```sql
SELECT e.event_id, e.event_ts, e.customer_id, e.event_type, e.amount
FROM events e
WHERE e.event_ts >= CURRENT_TIMESTAMP - INTERVAL '7' DAY
  AND EXISTS (SELECT 1 FROM customers c WHERE c.id = e.customer_id AND c.tier = 'PREMIUM');
```

EXPLAIN: `TableScan` now has `constraint=event_ts >= TIMESTAMP '...'`, only 7 partitions scanned. `physicalInputDataSize: 1.2 GB` (-98.5%). Wall clock: ~90s. `CorrelatedJoin` still present.

### 8.5 Fix 3 — rewrite EXISTS as a JOIN (force decorrelation)

```sql
SELECT e.event_id, e.event_ts, e.customer_id, e.event_type, e.amount
FROM events e
JOIN (SELECT DISTINCT id FROM customers WHERE tier = 'PREMIUM') c
  ON c.id = e.customer_id
WHERE e.event_ts >= CURRENT_TIMESTAMP - INTERVAL '7' DAY;
```

(Or, equivalently, `WHERE e.customer_id IN (SELECT id FROM customers WHERE tier = 'PREMIUM')` which Trino converts to a `SemiJoin`.)

EXPLAIN: `Join[INNER]` (or `SemiJoin`) with `RemoteExchange[REPLICATE]` for the small premium-customers build side. Dynamic filtering fires on the `events` scan. `physicalInputDataSize: 1.2 GB` for events; `physicalInputDataSize: 5 MB` for customers (build side, broadcast). Wall clock: ~12s. **180x speedup over the original.**

### 8.6 Summary of the three fixes

| Fix | EXPLAIN signature change | Wall clock | Cumulative speedup |
|---|---|---|---|
| Original | `CorrelatedJoin`, full Filter+TableScan, 50-col scan | 22 min | 1x |
| Fix 1: narrow projection | 5-col scan | 7 min | 3x |
| Fix 2: naked partition predicate | `constraint=` on TableScan, 7-partition scan | 90s | 15x |
| Fix 3: EXISTS -> JOIN | `Join` (broadcast) + dynamic filter on probe | 12s | **110x** |

The first two fixes are essentially free (no architecture change). The third was the only one that required understanding what `CorrelatedJoin` means and rewriting it.

---

## 9. The full performance-tuning checklist for a slow dbt model

When a migrated dbt model is slow, run through this in order:

1. **`EXPLAIN <the model SQL>` — look for `CorrelatedJoin`.** Rewrite to JOIN / window function. (Section 2.)
2. **`EXPLAIN ANALYZE` on a slice — check `physicalInputDataSize` on the TableScan.** If huge, partition pruning failed. Naked the partition col in WHERE. (Section 4.)
3. **Find expensive CTEs referenced multiple times.** Promote to `materialized='table'` dbt models. (Section 3.)
4. **Replace `SELECT *` with the columns you actually use.** (Section 8.1.)
5. **`ANALYZE TABLE` on the inputs.** Lets the optimizer pick join distribution correctly. ([Resource 24](24-trino-cbo-analyze.md).)
6. **Switch from `materialized='table'` to `materialized='incremental'`** if the delta is small. (Section 6.1; [resource 27 § 5](27-oracle-plsql-to-dbt-trino.md).)
7. **Add `partitioning` and `sorted_by` in dbt config** to match dominant WHERE filters. (Section 6.2-6.3, [resource 10](10-lakehouse-partitioning.md).)
8. **Schedule `ALTER TABLE ... EXECUTE optimize` on the dbt-built table** to consolidate small files from incremental runs. (Section 6.3, [resource 17](17-iceberg-table-maintenance.md).)
9. **For repeated dashboard queries**, add either a Trino materialized view ([resource 25](25-trino-materialized-views-iceberg.md)) or an app-side cache. (Section 7.)
10. **Replace exact `COUNT(DISTINCT)` with `approx_distinct()`** in non-billing contexts — typical 10-50x speedup. ([Resource 23 § 3](23-sql-best-practices-olap.md).)

---

## 10. Cross-references

- **Migrating Oracle PL/SQL to dbt + Trino:** [resource 27](27-oracle-plsql-to-dbt-trino.md) — the procedural -> declarative mindset, the Oracle->Trino SQL dialect translation table, the worked nightly-rollup example.
- **SQL best practices on Trino:** [resource 23](23-sql-best-practices-olap.md) — partition filter, approximate functions, SELECT * avoidance, QUALIFY anti-pattern.
- **Trino CBO / ANALYZE / Puffin stats:** [resource 24](24-trino-cbo-analyze.md) — running ANALYZE for join-distribution correctness.
- **Iceberg partitioning:** [resource 10](10-lakehouse-partitioning.md) — partition transforms, hidden partitioning, partition column choice.
- **Iceberg maintenance:** [resource 17](17-iceberg-table-maintenance.md) — `ALTER TABLE ... EXECUTE optimize`, sorted_by, the Trino EXECUTE vs Spark CALL disambiguation matrix.
- **Trino materialized views on Iceberg:** [resource 25](25-trino-materialized-views-iceberg.md) — dashboard-rollup caching pattern.
- **Federation pushdown reference card:** [resource 22](22-trino-federation-postgresql.md) — predicate / projection / aggregate / TopN pushdown signatures.
- **Query regression triage workflow:** [resource 18](18-query-performance-regression.md) — oncall debugging pattern for "it was fast yesterday."

---

## 11. Reference URLs verified for this resource

- Trino SELECT (WITH clause inlining): https://trino.io/docs/current/sql/select.html
- Trino dynamic filtering: https://trino.io/docs/current/admin/dynamic-filtering.html
- Trino cost-based optimizations: https://trino.io/docs/current/optimizer/cost-based-optimizations.html
- Trino EXPLAIN: https://trino.io/docs/current/sql/explain.html
- Trino EXPLAIN ANALYZE: https://trino.io/docs/current/sql/explain-analyze.html
- Trino Iceberg connector (EXECUTE optimize, sorted_by, properties): https://trino.io/docs/current/connector/iceberg.html
- Trino tuning: https://trino.io/docs/current/admin/tuning.html
- dbt-trino configurations: https://docs.getdbt.com/reference/resource-configs/trino-configs
- dbt incremental strategies: https://docs.getdbt.com/docs/build/incremental-strategy
- Iceberg Spark procedures (for the rewrite_data_files disambiguation): https://iceberg.apache.org/docs/latest/spark-procedures/
- Trino CTE materialization discussion: https://github.com/trinodb/trino/discussions/28090
- Trino query result cache request: https://github.com/trinodb/trino/issues/20854
