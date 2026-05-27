# Iter 207 Q1 — Postgres Views in Trino: Queryability and Predicate Pushdown

## Answer

Yes, Trino sees Postgres views exactly the same as regular tables — and predicate pushdown works through them too, with one important gotcha for aggregated views.

### 1. Trino sees Postgres views as queryable relations

When you configure the Postgres connector in Trino, it maps to Postgres's `information_schema.tables` which includes both BASE TABLE and VIEW rows. So `v_tenant_usage_summary` appears in `SHOW TABLES` from `app_pg.public` and you can query it directly:

```sql
SELECT * FROM app_pg.public.v_tenant_usage_summary
WHERE tenant_id = 'abc123';
```

This works. Trino does not know (or care) that the underlying object is a view — it just sends SQL to Postgres over JDBC and gets rows back.

---

### 2. Predicate pushdown DOES work through views

When you add `WHERE tenant_id = 'abc123'`, Trino's JDBC connector pushes that predicate down to Postgres. The actual SQL that lands on your read replica looks like:

```sql
SELECT tenant_id, total_usage, ...
FROM public.v_tenant_usage_summary
WHERE tenant_id = 'abc123'
```

Postgres then expands the view definition and executes the resulting query — the `WHERE tenant_id = 'abc123'` is applied server-side. You are NOT streaming the entire view result set to Trino workers and filtering there.

**Key mechanism**: Trino pushes the predicate to the JDBC layer. The JDBC layer wraps the Postgres view name in a SQL statement with the WHERE clause. Postgres's planner sees the filter during view expansion and can push it into the joins inside the view if the optimizer determines it's beneficial. This is Postgres-side optimization, not Trino-side.

---

### 3. The gotcha — aggregated view filtering

Your `v_tenant_usage_summary` view sounds like it has aggregation (usage summary usually implies `GROUP BY` + aggregate functions like `SUM`, `COUNT`). Here's where pushdown behavior splits:

**Filtering on GROUP BY columns (like `tenant_id`) — PUSHES DOWN:**

```sql
SELECT * FROM app_pg.public.v_tenant_usage_summary
WHERE tenant_id = 'abc123';
-- Postgres receives: SELECT ... FROM v_tenant_usage_summary WHERE tenant_id = 'abc123'
-- This is fine — tenant_id is a GROUP BY key, Postgres can filter early
```

**Filtering on computed aggregates — does NOT push down:**

```sql
SELECT * FROM app_pg.public.v_tenant_usage_summary
WHERE total_api_calls > 10000;
-- total_api_calls is a SUM() in the view definition
-- Postgres receives: SELECT ... FROM v_tenant_usage_summary WHERE total_api_calls > 10000
-- But wait — this is HAVING semantics. Postgres MUST compute the aggregate first,
-- then apply the HAVING-equivalent filter. All tenant rows are computed before filtering.
```

In this second case, Trino still pushes the predicate syntactically, but Postgres has to do the aggregation first. The rows leaving Postgres are reduced (only tenants with >10k calls come back), but the work inside Postgres is still "aggregate everything, then filter." Trino is not streaming excess rows in this case — but Postgres is doing more compute than a native query with an indexed lookup would.

**Bottom line**: `WHERE tenant_id = 'abc123'` on your `v_tenant_usage_summary` view is the good case — `tenant_id` is likely a GROUP BY column, so Postgres can use an index on `tenant_id` in the underlying tables and filter before aggregation.

---

### 4. Verifying pushdown through views

**Step 1: Check the Trino plan**

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.v_tenant_usage_summary
WHERE tenant_id = 'abc123';
```

Look for the `TableScan` node to show a `constraint on` block:

```
TableScan[table = app_pg:public.v_tenant_usage_summary]
    constraint on [tenant_id]
        tenant_id = 'abc123'
```

If you see a `ScanFilterProject` node ABOVE the `TableScan`, pushdown failed and Trino is filtering locally.

**Step 2: Confirm with Postgres slow-query log (ground truth)**

```sql
-- On Postgres replica:
ALTER SYSTEM SET log_min_duration_statement = 0;
SELECT pg_reload_conf();
```

Run the Trino query, then check the log:

```bash
tail -20 /var/log/postgresql/postgresql.log | grep "statement:"
```

**Pushdown confirmed** — you see the WHERE clause in the logged statement:
```
statement: SELECT tenant_id, total_usage FROM public.v_tenant_usage_summary WHERE tenant_id = 'abc123'
```

**Pushdown failed** — bare SELECT with no WHERE:
```
statement: SELECT tenant_id, total_usage FROM public.v_tenant_usage_summary
```

Disable logging after testing:
```sql
ALTER SYSTEM SET log_min_duration_statement = -1;
SELECT pg_reload_conf();
```

---

### 5. One bypass pattern to avoid: system.query()

Trino has a `system.query()` table function that lets you pass raw SQL to the connector:

```sql
-- DO NOT use this pattern:
SELECT * FROM TABLE(app_pg.system.query(query => '
  SELECT * FROM public.v_tenant_usage_summary WHERE tenant_id = ''abc123''
'));
```

This bypasses Trino's connector metadata layer entirely — which also means OPA row-filter and column-masking policies are **NOT invoked** for this query. If you have OPA-based tenant isolation, `system.query()` is a security hole. Use the standard `SELECT * FROM app_pg.public.v_tenant_usage_summary WHERE ...` syntax instead.

---

### Summary

| Scenario | Pushdown behavior |
|---|---|
| `WHERE tenant_id = 'abc123'` (GROUP BY column) | Pushes down — Postgres filters and aggregates only matching tenant |
| `WHERE total_api_calls > 10000` (aggregate result) | Syntactically pushed, but Postgres must aggregate first |
| `system.query()` bypass | Full pushdown of raw SQL, but OPA policies bypassed |

For your `v_tenant_usage_summary` view with `WHERE tenant_id = 'abc123'` — yes, this works correctly and pushes down. You won't stream the whole view. Verify with the Postgres slow-query log to confirm.
