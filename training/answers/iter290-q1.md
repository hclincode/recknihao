# Iter290 Q1 — DATE()/CAST() vs date_trunc: Which Forms Break Iceberg Partition Pruning?

## Short answer

`DATE(event_at)` and `CAST(event_at AS DATE)` are safe in Trino 467 — the optimizer unwraps them. `date_trunc('day', event_at)` is truly non-invertible and breaks pruning. For production queries, use explicit TIMESTAMP range predicates regardless — they're guaranteed to work without depending on optimizer rules.

## DATE(x) and CAST(x AS DATE) — Trino 467 can handle these

In Trino, `DATE(x)` is an alias for `CAST(x AS DATE)`. Trino 467 includes the `UnwrapCastInComparison` optimizer rule that rewrites these predicates into equivalent range comparisons against the raw timestamp column:

```sql
-- This:
WHERE DATE(event_at) = DATE '2026-05-01'
-- Gets internally rewritten to something like:
WHERE event_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND event_at < TIMESTAMP '2026-05-02 00:00:00'
```

After this rewrite, partition pruning works correctly — Iceberg sees a direct comparison against the `event_at` column and skips all partitions outside the date range. The Trino team's own blog post ("Just the right time date predicates with Iceberg", trino.io/blog/2023/04/11/date-predicates.html) confirms this behavior.

**Edge case — `timestamp with time zone` columns**: The unwrap optimization has known limitations with timezone-normalized types. If `event_at` is `timestamp with time zone` rather than `timestamp`, verify with EXPLAIN before assuming pruning works.

## date_trunc('day', event_at) — this breaks pruning

`date_trunc` is different: it is **not invertible**. Many input timestamps map to the same truncated value, so there is no range on the raw column that precisely represents `date_trunc('day', event_at) = DATE '2026-05-01'`. Trino cannot unwrap this and falls back to scanning all files, then filtering in memory.

```sql
-- BAD: date_trunc is non-invertible — full table scan
WHERE date_trunc('day', event_at) = DATE '2026-05-01'

-- GOOD: explicit range on the raw column — partition-pruned to one day
WHERE event_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND event_at <  TIMESTAMP '2026-05-02 00:00:00'
```

## Functions that definitely break pruning

| Bad pattern | Why it breaks | Fix |
|---|---|---|
| `date_trunc('day', event_at) = ...` | Non-invertible | Explicit TIMESTAMP range |
| `year(event_at) = 2026` | Non-monotonic for ranges | `event_at >= TIMESTAMP '2026-01-01 00:00:00' AND event_at < TIMESTAMP '2027-01-01 00:00:00'` |
| `month(event_at) = 5` | Non-monotonic | TIMESTAMP range for the month |
| `LOWER(email) = 'x@y.com'` | Non-invertible | Store lowercase at ingest |
| `SUBSTR(col, 1, 2) = 'US'` | Non-invertible | `WHERE col LIKE 'US%'` |

## Functions Trino 467 can unwrap (but still write the explicit form for production)

- `DATE(col)` = `CAST(col AS DATE)` with standard comparison operators
- Simple arithmetic casts on numeric types

Even though these work, the TIMESTAMP range form is recommended for production because it's explicit and doesn't depend on optimizer rules that could change between Trino versions.

## The defensive production pattern

```sql
-- Recommended for any production query — always prunes, no version dependency
WHERE event_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND event_at <  TIMESTAMP '2026-05-02 00:00:00'
```

For ad-hoc analysis, `DATE(event_at) = DATE '2026-05-01'` works in Trino 467. For dashboards and scheduled queries, convert to the range form.

## Verify with EXPLAIN

```sql
EXPLAIN
SELECT COUNT(*) FROM events
WHERE event_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND event_at <  TIMESTAMP '2026-05-02 00:00:00';
```

Look for `constraint on [event_at]` in the `TableScan` line — that means partition pruning is active. If the predicate shows up inside `ScanFilterProject` instead, pruning failed.
