# Iter289 Q2 — approx_distinct() vs COUNT(DISTINCT) + Reading Trino EXPLAIN

## Answer

Yes, `approx_distinct()` is real and is the right call for your query. The tradeoff is ~2% error for a 10–50x speedup. I'll also explain how to read Trino's EXPLAIN output — it's very different from Postgres but tells you more.

---

## Part 1: approx_distinct() — the faster COUNT DISTINCT

### Why COUNT(DISTINCT) is slow on 300M rows

When you run `COUNT(DISTINCT user_id)`, Trino must find every unique `user_id` globally. This requires shuffling all 300M rows across workers via a network exchange (a "RemoteExchange" in the query plan), then deduplicating and counting. This network shuffle is the bottleneck — it's expensive in both CPU and I/O.

### The fast alternative

```sql
-- Your current slow query (90+ seconds)
SELECT tenant_id, week,
       COUNT(DISTINCT user_id) AS dau
FROM events
WHERE event_date >= DATE '2026-05-20'
GROUP BY tenant_id, week;

-- Fast version (2–5 seconds, ~2% error)
SELECT tenant_id, week,
       approx_distinct(user_id) AS dau
FROM events
WHERE event_date >= DATE '2026-05-20'
GROUP BY tenant_id, week;
```

`approx_distinct()` uses a HyperLogLog sketch — a compact probabilistic algorithm that counts distinct values in a single pass without shuffling data globally. Instead of moving 300M rows across the network, each worker builds a tiny sketch (kilobytes), and Trino merges the sketches — almost no network traffic.

### The accuracy tradeoff in concrete terms

| True count | approx_distinct() result | Error |
|---|---|---|
| 100,000 users | ~98,000–102,000 | ±2,000 rows |
| 1,000,000 users | ~980,000–1,020,000 | ±20,000 rows |
| 50,000,000 users | ~49M–51M | ±1M rows |

The default standard error is about 2.3%. If that's not precise enough, you can tighten it:

```sql
-- 1% error (slower, more memory — usually not needed)
approx_distinct(user_id, 0.01)
```

### When to use approximate vs exact

| Use case | Use |
|---|---|
| Dashboards, trend reports, analytics UI | `approx_distinct()` |
| Weekly/monthly DAU/WAU/MAU reports | `approx_distinct()` |
| Billing — counting MAU for a subscription tier | `COUNT(DISTINCT ...)` |
| Compliance or audit reports | `COUNT(DISTINCT ...)` |
| Exploratory / ad-hoc analysis | `approx_distinct()` |

**Rule of thumb:** If 2% error could trigger a policy change, financial adjustment, or legal obligation, use exact. For everything user-visible on a dashboard, `approx_distinct()` is indistinguishable from exact.

---

## Part 2: Reading Trino EXPLAIN

Trino's EXPLAIN looks nothing like Postgres's — it's distributed, byte-focused, and shows actual execution costs when you ask for them.

### The three forms of EXPLAIN

```sql
-- 1. Bare EXPLAIN — shows plan, does NOT execute the query
EXPLAIN
SELECT tenant_id, approx_distinct(user_id) FROM events ...;

-- 2. EXPLAIN (TYPE DISTRIBUTED) — shows fragment/exchange layout, no execution
EXPLAIN (TYPE DISTRIBUTED)
SELECT tenant_id, approx_distinct(user_id) FROM events ...;

-- 3. EXPLAIN ANALYZE — executes the query and reports actual stats (EXPENSIVE!)
EXPLAIN ANALYZE
SELECT tenant_id, approx_distinct(user_id) FROM events ...;
```

**Use bare EXPLAIN before running a heavy query.** It's sub-second and tells you if the plan looks right. `EXPLAIN ANALYZE` costs the same as running the query — only use it when actively debugging.

### What to look for in the output

**1. Is the partition filter being pushed down?**

```
-- GOOD: partition pruning active
TableScan[table = iceberg:analytics.events, constraint on [event_date]]

-- BAD: filter not pushed, full table scan
ScanFilterProject[table = iceberg:analytics.events]
    Filter: (event_date >= DATE '2026-05-20')
```

`constraint on [event_date]` means Iceberg received the predicate and will skip files at scan time. If you see the filter in `ScanFilterProject` instead, your WHERE clause isn't pruning — check if you're wrapping the column in a function (see Q1).

**2. Physical Input bytes**

```
Physical Input: 2.10GB
```

This is the actual bytes Trino will read from MinIO. For a 5-day window of events, 2–5 GB is reasonable. If it says 50 GB for a 5-day filter, your partition filter isn't working.

**3. RemoteExchange row estimates**

```
RemoteExchange[GATHER]
    Estimates: {rows: 50000000, ...}
```

A RemoteExchange with 50M rows flowing through it is the COUNT(DISTINCT) shuffle. After switching to `approx_distinct()`, this number will collapse to thousands (sketch size), not millions — that's the speedup.

### A pre-run checklist using bare EXPLAIN

Before firing your query:

1. Does `TableScan` show `constraint on [event_date]`? If not, your filter isn't working.
2. Is `Physical Input` reasonable for your filter range? A few GB per week is fine; tens of GB is a red flag.
3. For aggregations: does `RemoteExchange` show a huge row estimate? If so, consider `approx_distinct()`.

### CPU vs Scheduled timing (from EXPLAIN ANALYZE)

When you do run `EXPLAIN ANALYZE`:

```
CPU: 8.12s, Scheduled: 40.05s, Blocked: 29.80s
```

- **CPU**: actual compute time
- **Scheduled**: wall time workers were busy with this operator
- **Blocked**: time spent waiting for I/O or network (Scheduled − CPU)

If Scheduled >> CPU (large Blocked), you're I/O-bound — the bottleneck is reading data from MinIO, not compute. Fix: add partition filters to reduce Physical Input.

---

## Summary for your specific query

```sql
-- Run this first to verify the plan looks right
EXPLAIN
SELECT tenant_id, week,
       approx_distinct(user_id) AS dau
FROM events
WHERE event_date >= DATE '2026-05-20'
GROUP BY tenant_id, week;
```

Check:
- `constraint on [event_date]` present → pruning working
- `Physical Input` is a few GB, not tens of GB
- `RemoteExchange` row estimate is small (sketch, not all distinct user_ids)

If those look good, run it. Expect 90 seconds → 2–5 seconds, with ~2% error — negligible for dashboards and trend reports.
