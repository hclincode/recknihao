# Iter 195 Q2 — EXPLAIN for Federation Query Planning

## Answer

## What EXPLAIN Actually Shows You

`EXPLAIN (TYPE DISTRIBUTED)` is the command you want — it shows the query plan **without executing** the query (so no resource cost). It reveals whether your WHERE clause filters are being pushed down to Postgres or pulled back to Trino for local filtering.

Run this on your query:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ...
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.account_id = a.id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY
  AND a.status = 'active'
  AND a.plan_type = 'enterprise';
```

### The Critical Signal: Where the Predicate Appears in the Plan Tree

**One simple rule: if Postgres is handling a filter, it disappears from the plan tree.**

**Pushdown SUCCEEDED** — the predicate is embedded inside the `TableScan` constraint:

```
TableScan[table = app_pg:public.accounts, ...]
    Layout: [id, status, plan_type, ...]
    constraint on [status, plan_type]
        status = 'active'
        plan_type = 'enterprise'
```

No separate `Filter` or `ScanFilterProject` node sits ABOVE this `TableScan`. The predicates are nested inside the `constraint on` block — Postgres received `WHERE status = 'active' AND plan_type = 'enterprise'` and applied them server-side.

**Pushdown FAILED** — a `ScanFilterProject` or `Filter` node sits ABOVE the `TableScan`:

```
ScanFilterProject[filterPredicate = (status = 'active' AND plan_type = 'enterprise')]
    TableScan[table = app_pg:public.accounts, ...]
        Layout: [id, status, plan_type, ...]
        # NO constraint block here
```

This is the red flag. The `TableScan` has no constraints — Postgres returned **the entire accounts table unfiltered**, and Trino workers are filtering rows **in-memory after fetching them over JDBC**. On a table with millions of rows, this causes a full table scan across the network.

### Three Quick Checks

1. **Does a `constraint on [columns]` block appear under the Postgres `TableScan` node?** Yes = pushdown succeeded.
2. **Is there a `ScanFilterProject` or `Filter` node sitting ABOVE the `TableScan`?** Yes = pushdown failed.
3. **Read the indentation.** In the success case, the constraint is *inside* the TableScan (more indented). In the failure case, the Filter is at the *same or higher* indentation level, sitting above it.

### What Doesn't Push Down (and Why)

**These predicates do NOT push down to Postgres by default:**
- `WHERE email LIKE 'user%'` — string LIKE/ILIKE (collation unsafe)
- `WHERE name > 'M'` — string ranges
- `WHERE LOWER(email) = 'foo'` — function-wrapped columns
- `WHERE CAST(id AS VARCHAR) = '12345'` — cast is a function; pulls entire table silently

**These DO push down:**
- `WHERE id = 12345` (numeric equality)
- `WHERE status = 'active'` (string equality, no CAST)
- `WHERE created_at > TIMESTAMP '2026-05-01 00:00:00'` (temporal range)
- `WHERE user_id IN (1, 2, 3)` (IN lists)
- `WHERE deleted_at IS NULL` (NULL checks)

### Using EXPLAIN ANALYZE for Real Proof

`EXPLAIN ANALYZE` executes the query and shows actual row counts — **be warned: it executes in full**:

```sql
EXPLAIN ANALYZE
SELECT ...
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.account_id = a.id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY
  AND a.status = 'active';
```

Look for the **`Filtered:` line** on the Postgres TableScan node:

**Pushdown succeeded:**
```
TableScan[table = app_pg:public.accounts, ...]
    Input: 52000 rows (4.51MB)
    Filtered: 97.25%
    constraint on [status]
        status = 'active'
```

`Filtered: 97.25%` means Postgres filtered out 97% of rows internally before returning them.

**Pushdown failed:**
```
TableScan[table = app_pg:public.accounts, ...]
    Input: 5200000 rows (450MB)
    Filtered: 0%
```

`Input:` close to full table size + `Filtered: 0%` = Trino fetched everything and filtered locally.

### Concrete Example for Your Case

A healthy plan for your Iceberg+Postgres join looks like:

```
Fragment 1 [SOURCE]
    TableScan[table = app_pg:public.accounts, ...]
        Layout: [id, status, plan_type]
        constraint on [status, plan_type]
            status = 'active'
            plan_type = 'enterprise'
        # Postgres applies both filters server-side

Fragment 2 [SOURCE]
    TableScan[table = iceberg:analytics.events, ...]
        Layout: [event_id, event_date, account_id]
        constraint on [event_date]
            event_date >= DATE '2026-05-19'
        dynamicFilters = {account_id = #df_accounts_id_0}
        # Iceberg partition-prunes by date AND gets a dynamic filter
        # from the Postgres join results
```

The `dynamicFilters` line on the Iceberg scan is a bonus signal — Trino derived a filter from the Postgres side's smaller result set and pushed it to Iceberg as an additional optimization.

If you see **no constraint blocks** on the Postgres side and **no dynamicFilters on the Iceberg side**, your query is scanning everything in both tables — that's the problem to fix.
