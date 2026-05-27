# Iter274 Q1 — Reading Trino EXPLAIN to Detect Filter Pushdown vs Local Filtering

## Answer

When reading a Trino EXPLAIN plan to figure out whether your WHERE clause is being pushed down to Postgres or filtered locally on Trino workers, the answer is in the **vertical position of the filter in the plan tree, not in keywords**. This is the difference between scanning 312 rows over JDBC vs pulling 4.2 million rows and filtering them in memory.

### The Core Rule: Position Tells You Everything

**Pushdown SUCCEEDED**: The filter disappears from the visible plan tree because Postgres handles it server-side. You see only a `TableScan` node with the predicate embedded in a `constraint on [col]` block indented beneath it. There is **no separate `Filter` or `ScanFilterProject` node above the TableScan**.

**Pushdown FAILED**: A `ScanFilterProject` or `Filter` node sits **above the TableScan** in the tree. The predicate is inside that upper node, not in the TableScan's constraint. Trino workers are filtering in memory after pulling rows from Postgres over JDBC.

### What the Plan Output Looks Like

**Pushdown success** — predicate inside `TableScan`:

```
TableScan[table = app_pg:public.orders, ...]
    Layout: [id:bigint, status:varchar, order_date:date, amount:decimal]
    constraint on [status, order_date]
        status = 'active'
        order_date >= DATE '2026-05-01'
```

The `constraint on` block is indented beneath the TableScan. No separate filter node above it. Postgres received and applied these conditions. This is the fast path.

**Pushdown failure** — predicate in `ScanFilterProject` above `TableScan`:

```
ScanFilterProject[filterPredicate = (status = 'active')]
    Input: 5200000 rows
    Output: 200000 rows
  TableScan[table = app_pg:public.orders, ...]
      Input: 5200000 rows (450MB)
      Output: 5200000 rows
```

The ScanFilterProject sits above the TableScan. The TableScan has no `constraint on` block — it's bare. Postgres returned all 5.2 million rows unfiltered, and Trino workers applied `status = 'active'` in memory.

### What Input/Output Row Counts Tell You

These numbers confirm what the plan structure already implies:

**Pushdown succeeded** — Input at TableScan is already filtered:
```
TableScan[table = app_pg:public.orders, ...]
    Input: 52000 rows (4.51MB)   ← only 52K of 1.9M total rows
    Output: 52000 rows           ← Input ≈ Output: no local filtering
    constraint on [status, order_date]
        status = 'active'
        order_date >= DATE '2026-05-01'
```
The table has 1.9M rows but only 52K arrived — Postgres filtered them server-side.

**Pushdown failed** — Input at TableScan is full table size:
```
ScanFilterProject[filter = (status = 'active')]
    Input: 5200000 rows     ← receives all rows from TableScan
    Output: 200000 rows     ← Trino filters to 200K locally
  TableScan[table = app_pg:public.orders, ...]
      Input: 5200000 rows (450MB)  ← full table pulled over JDBC
      Output: 5200000 rows
```
All 5.2M rows shipped over JDBC; Trino filtered to 200K. You paid the cost of a full-table JDBC scan.

### Three Filter Locations and What They Mean

| Plan shape | Meaning | What Postgres received |
|---|---|---|
| `constraint on [col]` inside `TableScan`, no Filter above | Pushdown SUCCEEDED | `SELECT ... WHERE <predicate>` |
| `ScanFilterProject[filterPredicate=...]` above bare `TableScan` | Pushdown FAILED | `SELECT ...` (unfiltered) |
| Standalone `Filter[predicate]` above `TableScan` | Pushdown FAILED | `SELECT ...` (unfiltered) |

### What Pushes vs What Doesn't

**Pushes down to Postgres by default:**
- Equality: `WHERE id = 12345`, `WHERE status = 'active'`
- Numeric/date ranges: `WHERE amount BETWEEN 100 AND 500`, `WHERE created_at > TIMESTAMP '2026-05-01'`
- IN-lists: `WHERE status IN ('active', 'pending')`
- NULL checks: `WHERE deleted_at IS NULL`

**Does NOT push down:**
- Case-insensitive LIKE: `WHERE email ILIKE 'a%'` — not supported by Trino's PostgreSQL connector
- String ranges on VARCHAR: `WHERE name BETWEEN 'a' AND 'm'` — collation concerns
- Function calls on columns: `WHERE LOWER(email) = 'foo@example.com'`

When you see a `ScanFilterProject` with an ILIKE or function call, that's **expected behavior** — those predicates never push to Postgres in OSS Trino 467.

### A Real Diagnostic Example

Query:
```sql
SELECT id, order_date, status, amount
FROM app_pg.public.orders
WHERE order_date = DATE '2026-05-01'
  AND status = 'active'
  AND customer_email ILIKE 'a%';
```

EXPLAIN output:
```
ScanFilterProject[filterPredicate = (customer_email ILIKE 'a%')]
  TableScan[table = app_pg:public.orders, ...]
      constraint on [order_date, status]
          order_date = DATE '2026-05-01'
          status = 'active'
```

What's happening: `order_date` and `status` pushed to Postgres (they're in the `constraint on` block). `customer_email ILIKE 'a%'` did not push (it's in the `ScanFilterProject` above). Postgres returned rows matching the date and status; Trino then applied the ILIKE locally.

This is partially good (two predicates pushed) and unavoidable (ILIKE never pushes in OSS Trino 467).

### Definitive Confirmation: EXPLAIN ANALYZE

Run `EXPLAIN ANALYZE` to get runtime row counts (warning: this executes the query):

- **Input much smaller than table size at TableScan, Input ≈ Output** → pushdown succeeded at runtime
- **Input ≈ full table size at TableScan, ScanFilterProject above reducing it** → pushdown failed

For absolute ground truth, temporarily enable Postgres slow-query logging:
```bash
# On the Postgres replica:
log_min_duration_statement = 0
```
Tail the log while your Trino query runs. If Postgres received a WHERE clause, pushdown happened. If Postgres received a bare SELECT, it didn't.

### Diagnostic Checklist

1. **Check plan structure**: Is your predicate in a `constraint on` block under TableScan (pushed), or in a `ScanFilterProject` above TableScan (not pushed)?
2. **Check predicate type**: Equality, numeric range, IN-list → should push. ILIKE, function calls, string ranges → expected not to push.
3. **Verify with EXPLAIN ANALYZE**: Compare `Input:` row count at TableScan to full table size.
4. **Ground truth**: Postgres slow-query log shows the actual SQL Postgres received.

The key insight: **use the tree structure of the EXPLAIN output, not keyword searches, to diagnose pushdown behavior**.
