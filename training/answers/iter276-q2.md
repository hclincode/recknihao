# Iter276 Q2 — system.query() Passthrough for Native Postgres Functions

## Answer

Yes — `system.query()` is exactly the tool for this. It lets you send Postgres-specific SQL (including your `similarity()` function from pg_trgm) directly to Postgres as a verbatim string, get back the result set, and then join that result to your Iceberg data in Trino.

### 1. The system.query() Passthrough — Exact Syntax

The PostgreSQL connector exposes a table function under `<catalog>.system.query()`:

```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => '<your Postgres SQL here>'
  )
);
```

The SQL inside the string is sent verbatim to Postgres via JDBC. Trino does not parse or rewrite it — Postgres sees exactly what you wrote, executes it, and returns the result set. This is why `similarity()` (or any other Postgres extension function) works: Trino never tries to understand it.

### 2. Wrapping the Postgres-Specific SQL

```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, customer_name, similarity(customer_name, ''Acme Inc'') AS match_score FROM public.customers WHERE similarity(customer_name, ''Acme Inc'') > 0.3'
  )
);
```

**Critical escaping rule**: Single quotes inside the SQL string must be **doubled** (`''`). The string `'Acme Inc'` becomes `''Acme Inc''` inside the `query =>` argument. This is Trino's string escaping convention — the doubled quotes tell Trino the single quote is part of the inner string, not the string delimiter.

### 3. Joining the Result to Iceberg Data

You cannot join inside the `system.query()` call — it runs entirely on Postgres and returns an opaque result set. But you can wrap it as a derived table and join it outside:

```sql
SELECT
    customers.id,
    customers.customer_name,
    customers.match_score,
    events.event_id,
    events.event_type,
    events.occurred_at
FROM (
    SELECT * FROM TABLE(
      app_pg.system.query(
        query => 'SELECT id, customer_name, similarity(customer_name, ''Acme'') AS match_score FROM public.customers WHERE similarity(customer_name, ''Acme'') > 0.5 ORDER BY match_score DESC LIMIT 100'
      )
    )
) AS pg_matches
INNER JOIN iceberg.analytics.events AS events
  ON pg_matches.id = events.customer_id
 AND events.event_timestamp >= CURRENT_DATE - INTERVAL '30' DAY;
```

What happens at runtime:
1. Postgres runs the `similarity()` function server-side, filters to matches > 0.5, returns the top 100 customers.
2. Trino receives those 100 rows as the `pg_matches` derived table.
3. Trino joins `pg_matches` to the Iceberg `events` table with the timestamp filter pushed into Iceberg as a partition prune.

### 4. Limitations

**No predicate pushdown on the outer query**: Trino treats the `system.query()` result as an opaque source. A `WHERE` clause outside the derived table will pull all rows from Postgres first, then filter on Trino workers. Always push your filters INSIDE the `query` string where Postgres can evaluate them server-side.

**No join pushdown to Postgres**: The join between `pg_matches` and Iceberg runs on Trino workers. Postgres cannot read Iceberg files, so this is unavoidable for cross-catalog joins.

**Single-quote escaping**: Use `''` (doubled) for all string literals inside `query =>`. This is the most common error when using `system.query()`.

**EXPLAIN shows a `TableFunctionProcessor` node, not the Postgres plan**: To debug the inner Postgres SQL, run it directly against a Postgres replica with `EXPLAIN ANALYZE`.

**No column statistics**: Trino has no row count or NDV estimates for the `system.query()` result, so the join order may be suboptimal. Use `LIMIT` inside the query string to bound the result size when possible.

### 5. Complete Example

```sql
-- Fuzzy-match customers by name (Postgres side), join to recent events (Iceberg side)
SELECT
    customers.id,
    customers.customer_name,
    customers.match_score,
    events.event_type,
    events.event_timestamp
FROM (
    SELECT * FROM TABLE(
      app_pg.system.query(
        query => 'SELECT id, customer_name, similarity(customer_name, ''Acme'') AS match_score '
              || 'FROM public.customers '
              || 'WHERE similarity(customer_name, ''Acme'') > 0.5 '
              || 'ORDER BY match_score DESC LIMIT 200'
      )
    )
) AS customers
LEFT JOIN iceberg.analytics.customer_events AS events
  ON customers.id = events.customer_id
 AND events.event_timestamp >= CURRENT_DATE - INTERVAL '30' DAY;
```

The `similarity()` function runs entirely inside Postgres — Trino only joins the result. This is the correct pattern whenever you need a Postgres-specific function in a cross-catalog query.
