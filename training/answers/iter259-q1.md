# Iter259 Q1 — TopN Pushdown: Does Trino Use the Postgres Index for ORDER BY LIMIT?

## Answer

**Short answer: Yes, Trino pushes `ORDER BY ... LIMIT N` to Postgres for simple queries. Your index on `created_at` WILL be used. You can verify this with EXPLAIN, and confirm via pg_stat_activity on Postgres.**

### Trino DOES Push Top-N Queries to Postgres

When you run:
```sql
SELECT * FROM postgres.public.users ORDER BY created_at DESC LIMIT 100
```

Trino's optimizer recognizes this as a **Top-N pushdown** pattern. It ships `ORDER BY ... LIMIT 100` directly to Postgres via the JDBC driver. Postgres traverses the B-tree index on `created_at` backward, reads 100 entries, and returns exactly 100 rows. **Trino does not pull all 8 million rows into memory and sort them.** This is officially supported in the PostgreSQL connector — it's listed alongside join and aggregate pushdown in the official pushdown documentation.

### How to Verify — The EXPLAIN Signature

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM postgres.public.users ORDER BY created_at DESC LIMIT 100;
```

**If pushdown SUCCEEDED**, you'll see:

```
Fragment 0 [SINGLE]
    Output[id, email, created_at]
    └─ TableScan[table = postgres:public.users, sortOrder=[created_at DESC NULLS LAST], limit=100]
           Layout: [id, email, created_at]
```

Key signals:
- `sortOrder=[created_at DESC NULLS LAST]` annotation is **INSIDE** the `TableScan` node
- `limit=100` annotation is also **INSIDE** the `TableScan` node
- There is **NO separate `TopN` operator** above the `TableScan`

When you see this, Postgres received `SELECT ... FROM users ORDER BY created_at DESC LIMIT 100` and used your index.

**If pushdown FAILED**, you'll see:

```
Fragment 0 [SINGLE]
    Output[id, email, created_at]
    └─ TopN[topN = 100, orderBy = [created_at DESC NULLS LAST]]
           └─ TableScan[table = postgres:public.users]
                  Layout: [id, email, created_at]
```

Key signals:
- A **separate `TopN[...]` operator** sits **above** the `TableScan` as its own node
- The `TableScan` has **NO `sortOrder=` or `limit=`** annotations

In this case, Postgres received just `SELECT ... FROM users` (no ORDER BY, no LIMIT). All 8 million rows came back to Trino over JDBC, Trino workers buffered and sorted them, then kept the top 100. Multiple gigabytes of JDBC traffic — very slow.

### The Ground Truth: pg_stat_activity on Postgres

While your Trino query is running, connect to your Postgres read replica:

```sql
SELECT pid, usename, query, state 
FROM pg_stat_activity 
WHERE usename = 'trino_reader' AND state = 'active';
```

The `query` column shows the exact SQL the JDBC driver sent:
- `SELECT ... FROM users ORDER BY created_at DESC LIMIT 100` → pushdown succeeded, Postgres is using the index
- `SELECT ... FROM users` (no ORDER BY, no LIMIT) → pushdown failed, all 8M rows are en route to Trino

This is the **definitive check** — the SQL Postgres actually parsed is unambiguous.

### When Top-N Pushdown May NOT Fire

1. **Top-N inside a JOIN** — if the query joins users to another table, the optimizer may not push the Top-N past the join boundary.

2. **Top-N over a GROUP BY** — `ORDER BY COUNT(*) DESC LIMIT 10` over an aggregation. The aggregate may push separately, but the Top-N over the aggregated result may stay on Trino.

3. **Sort on a function or expression** — `ORDER BY LOWER(email) DESC LIMIT 100` or `ORDER BY (created_at + interval '1 day')`. Arbitrary expressions don't push. **Workaround**: store the derived value in a generated column on Postgres.

4. **OFFSET after LIMIT** — `LIMIT 100 OFFSET 1000` is more limited. **Better pattern**: use keyset pagination (`WHERE created_at < :last_seen ORDER BY created_at DESC LIMIT 100`) — both the predicate and Top-N push cleanly using the same index.

5. **ORDER BY without LIMIT** — standalone `ORDER BY created_at DESC` without a LIMIT is a full sort, not a Top-N. Not pushed.

### Session Property to Toggle Pushdown

Top-N pushdown is **on by default**. To test whether it's helping:

```sql
-- Disable for testing only:
SET SESSION postgres.topn_pushdown_enabled = false;

-- Re-run EXPLAIN — you should now see a separate TopN node
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM postgres.public.users ORDER BY created_at DESC LIMIT 100;
```

Note: catalog-name prefix (`postgres.`) is mandatory for connector session properties.

### Fallback: system.query() Escape Hatch

If EXPLAIN shows a separate `TopN` operator (pushdown failed, e.g., due to a join) and the table is large, use the system.query() passthrough to send raw SQL directly to Postgres:

```sql
SELECT * FROM TABLE(
  postgres.system.query(
    query => 'SELECT id, email, created_at FROM users ORDER BY created_at DESC LIMIT 100'
  )
);
```

Postgres runs the full query server-side and Trino relays the 100-row result.

### Quick Debugging Checklist

1. **Index exists?** On Postgres: `SELECT * FROM pg_indexes WHERE tablename = 'users' AND indexdef LIKE '%created_at%'`
2. **Run EXPLAIN** — look for `sortOrder=... limit=100` INSIDE the TableScan node, not above it as a separate `TopN` operator
3. **Check pg_stat_activity** — confirm Postgres sees `ORDER BY ... LIMIT` clause
4. **If pushdown failed**: verify the query is simple (no joins, no aggregations, no function-based sorts, no OFFSET)
5. **Compare performance**: toggle `topn_pushdown_enabled = false`, re-run, compare wall-clock time

Your 100-row query against an 8M-row table will use the `created_at` index and return in sub-second latency if the pattern pushes.
