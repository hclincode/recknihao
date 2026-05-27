# Iter291 Q1 — Which Date/Time Functions Break Iceberg Partition Pruning in Trino 467?

## Quick reference

For a table with `event_at TIMESTAMP(6)` partitioned by `day(event_at)`:

| Pattern | Safe? | Reason |
|---|---|---|
| `event_at >= TIMESTAMP '...' AND event_at < TIMESTAMP '...'` | ✅ Always | Raw column, day-aligned literals — guaranteed |
| `CAST(event_at AS DATE) = DATE '2026-05-01'` / `DATE(event_at)` | ✅ In Trino 467 | `UnwrapCastInComparison` optimizer rule (PR #13567) rewrites to timestamp range |
| `date_trunc('day', event_at) = DATE '2026-05-01'` | ✅ In Trino 467 | `UnwrapDateTruncInComparison` optimizer rule (PR #14011) rewrites to timestamp range |
| `year(event_at) = 2026` | ❌ Full scan | Non-monotonic — no unwrap rule |
| `month(event_at) = 5` | ❌ Full scan | Non-monotonic (May recurs yearly) — no unwrap rule |
| `day_of_week(event_at) = 1` | ❌ Full scan | Non-monotonic, scattered — no unwrap rule |
| `hour(event_at) = 9` | ❌ Full scan | Non-monotonic within each day — no unwrap rule |
| `event_at + INTERVAL '7' DAY >= TIMESTAMP '...'` | ❌ Full scan | Complex arithmetic — Trino can't invert |

---

## How the optimizer rules work

The "some functions are fine, some aren't" distinction comes down to whether Trino has a specific optimizer rewrite rule for that function.

**Category 1 — Trino has a rewrite rule:**

`CAST(event_at AS DATE) = DATE '2026-05-01'` gets internally rewritten to:
```sql
WHERE event_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND event_at <  TIMESTAMP '2026-05-02 00:00:00'
```

`date_trunc('day', event_at) = DATE '2026-05-01'` gets rewritten the same way.

After the rewrite, partition pruning fires normally against the raw `event_at` column. Trino's own blog post ("Just the right time date predicates with Iceberg", trino.io/blog/2023/04/11/date-predicates.html) confirms both patterns.

**Caveats for Category 1**:
- Version-dependent — these rules exist in Trino 467; future versions may change behavior
- `unwrap_casts` session property = false disables the rules
- Edge case: `TIMESTAMP WITH TIME ZONE` columns have known limitations with the unwrap
- Complex nested predicates may escape the rule

**Category 2 — No rewrite rule exists:**

`year(event_at) = 2026` cannot be expressed as a single TIMESTAMP range (year is non-monotonic — it resets every January). Trino has no rule to invert this. Result: full table scan.

Same for `month()`, `day_of_week()`, `hour()` — all non-monotonic, all cause full scans.

---

## The fixes for non-monotonic functions

```sql
-- Instead of: year(event_at) = 2026
WHERE event_at >= TIMESTAMP '2026-01-01 00:00:00'
  AND event_at <  TIMESTAMP '2027-01-01 00:00:00'

-- Instead of: month(event_at) = 5
WHERE event_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND event_at <  TIMESTAMP '2026-06-01 00:00:00'

-- Instead of: day_of_week(event_at) = 1 (Mondays only)
-- Precompute a `day_of_week` column at ingest; filter that + partition column
WHERE event_at >= TIMESTAMP '2026-05-01 00:00:00'  -- partition pruning
  AND day_of_week = 1                                -- row-level filter
```

---

## Production recommendation

Always write production queries with raw TIMESTAMP range predicates aligned to day boundaries:

```sql
-- BEST: guaranteed on any Trino version, no optimizer dependency
WHERE event_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND event_at <  TIMESTAMP '2026-06-01 00:00:00'
```

For ad-hoc analysis, `CAST(event_at AS DATE)` and `date_trunc('day', event_at)` work in Trino 467 — just verify with EXPLAIN. For dashboards and scheduled queries, use the explicit form.

---

## Verifying with EXPLAIN

```sql
EXPLAIN
SELECT COUNT(*) FROM iceberg.analytics.events
WHERE event_at >= TIMESTAMP '2026-05-01 00:00:00'
  AND event_at <  TIMESTAMP '2026-06-01 00:00:00';
```

- **Good**: `TableScan[..., constraint on [event_at]]` — partition pruning active
- **Bad**: `ScanFilterProject` with predicate inside `filterPredicate = ...` — full scan, filter in memory

For measuring actual bytes: use `EXPLAIN ANALYZE` on a 1-day sample, check `Physical Input: X GB`, then extrapolate to your full date range.
