# Iter259 Q2 — Aggregation Pushdown: Does Trino Send GROUP BY to Postgres?

## Answer

**Short answer: Trino CAN push GROUP BY down to Postgres — Postgres will do the grouping and counting itself, returning only a few rows (one per group). But this only happens under specific conditions.**

### The Big Performance Difference

When aggregation **does** push down:
- Postgres receives `SELECT plan_tier, COUNT(*) FROM accounts GROUP BY plan_tier`
- Postgres computes the groups server-side
- Postgres returns **a few rows** (one per plan tier) over the network
- Network traffic: tiny

When aggregation **does NOT** push down:
- Postgres receives `SELECT * FROM accounts` (no GROUP BY)
- Postgres returns **millions of rows** over JDBC
- Trino's workers buffer the entire table, then compute groups client-side
- Network traffic: potentially multiple gigabytes

### The Critical Rule: All WHERE Predicates Must Push

**Aggregation pushdown only succeeds when ALL of your WHERE predicates also push down to Postgres.**

This is the non-negotiable rule. Example:

```sql
SELECT plan_tier, COUNT(*) 
FROM postgres.public.accounts 
WHERE region = 'us-east-1'          -- pushdownable (equality on text)
  AND status = 'active'             -- pushdownable (equality on text)
GROUP BY plan_tier
```

Both predicates push → aggregate can push too.

Now add a non-pushdownable filter:

```sql
SELECT plan_tier, COUNT(*) 
FROM postgres.public.accounts 
WHERE region = 'us-east-1'                  -- pushdownable
  AND some_json_col ->> 'flag' = 'yes'      -- NOT pushdownable (complex expression)
GROUP BY plan_tier
```

Trino must apply the `some_json_col` filter locally after Postgres returns rows. Because Postgres doesn't know which rows will survive Trino's filter, it can't pre-compute the count. The aggregate stays on Trino workers. The instant a `Filter` node sits above the `TableScan` in the plan tree, the aggregate cannot ride along.

### How to Tell: EXPLAIN Shows the Truth

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT plan_tier, COUNT(*) FROM postgres.public.accounts GROUP BY plan_tier;
```

**Aggregation PUSHED (Postgres does the grouping):**
```
Fragment 0 [SINGLE]
    Output[plan_tier, _count]
    └─ TableScan[table = postgres:public.accounts, ...]
           Layout: [plan_tier, _count]
```

- The `Aggregate` node is **absent** from the plan tree
- The `TableScan` projects already-aggregated columns (`plan_tier`, `_count`)
- Postgres receives: `SELECT plan_tier, COUNT(*) FROM accounts GROUP BY plan_tier`
- Postgres sends back: **a few rows**

**Aggregation NOT pushed (Trino does the grouping):**
```
Fragment 0 [SINGLE]
    Output[plan_tier, count]
    └─ Aggregate[GROUP BY [plan_tier]]
         └─ TableScan[table = postgres:public.accounts]
                Layout: [id, plan_tier, region, status, ...]
```

- A separate `Aggregate` node sits **ABOVE** the `TableScan`
- The `TableScan` projects raw table columns, not aggregated ones
- Postgres receives: `SELECT id, plan_tier, region, status, ... FROM accounts`
- Postgres sends back: **all rows**

**The unifying rule**: if a separate operator above the TableScan does the work (Aggregate, TopN, Filter), that work happens on Trino workers and was NOT pushed. If the work has been absorbed into the TableScan's layout, it WAS pushed.

### Session Property: aggregation_pushdown_enabled

Aggregation pushdown is **on by default**. To test whether it's helping:

```sql
SET SESSION postgres.aggregation_pushdown_enabled = false;

EXPLAIN (TYPE DISTRIBUTED)
SELECT plan_tier, COUNT(*) FROM postgres.public.accounts GROUP BY plan_tier;
-- Now you'll see a separate Aggregate node above TableScan

RESET SESSION postgres.aggregation_pushdown_enabled;
```

The catalog-name prefix (`postgres.`) is mandatory for connector session properties.

### When Aggregation May NOT Push

1. **Non-pushdownable WHERE clauses** — any WHERE predicate that doesn't push (complex expressions, JSON extractions, function calls) blocks the entire aggregate
2. **HAVING clause** — `HAVING COUNT(*) > 100` may prevent pushdown depending on the expression
3. **Window functions** — if they coexist with GROUP BY, aggregate pushdown is typically disabled
4. **Complex aggregates** — `COUNT(DISTINCT region)` may not push; `COUNT`, `SUM`, `AVG`, `MIN`, `MAX` on simple columns generally do

### Verify with pg_stat_activity

While Trino runs your query, check on the Postgres replica:

```sql
SELECT query FROM pg_stat_activity 
WHERE query NOT LIKE '%pg_stat_activity%'
ORDER BY query_start DESC LIMIT 5;
```

- **Pushed**: `SELECT plan_tier, COUNT(*) FROM accounts GROUP BY plan_tier` — a few rows
- **Not pushed**: `SELECT id, plan_tier, region, status, ... FROM accounts` — all rows

### What To Do If Aggregation Is NOT Pushing

1. **Run EXPLAIN** — verify by checking for a separate `Aggregate` node above `TableScan`
2. **Audit WHERE clauses** — any non-pushdownable predicate blocks the aggregate. Pushdownable predicates: equality, IN-lists, IS NULL/NOT NULL on any type; range predicates on non-VARCHAR columns. Non-pushdownable: function calls, JSON extraction, VARCHAR range predicates (by default)
3. **Use system.query() escape hatch** if native pushdown won't fire:

```sql
SELECT * FROM TABLE(
  postgres.system.query(
    query => 'SELECT plan_tier, COUNT(*) FROM accounts GROUP BY plan_tier'
  )
)
```

This sends the full SQL to Postgres verbatim. Trade-off: you lose Trino's cross-catalog federation capabilities for this query.

### Summary

Your `SELECT plan_tier, COUNT(*) FROM postgres.public.accounts GROUP BY plan_tier` will push the aggregation to Postgres if all WHERE predicates (or none) also push. When it pushes, Postgres returns a few rows; when it doesn't, Postgres returns millions of rows. Always verify with `EXPLAIN (TYPE DISTRIBUTED)` — a separate `Aggregate` node above `TableScan` = not pushed. No `Aggregate` node (absorbed into `TableScan` layout) = pushed.
