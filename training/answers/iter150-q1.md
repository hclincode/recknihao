# Iter 150 Q1 — Trino PreparedStatement and Plan Caching

## Answer

Trino does **not** cache query plans between executions. Every time you call `PreparedStatement.executeQuery()`, Trino re-plans from scratch. That includes all 200 requests per minute you're running. There is no server-side plan cache in Trino, unlike Postgres or Oracle.

### What happens on the wire with PreparedStatement

When you use JDBC `PreparedStatement` with Trino 467:
1. The JDBC driver sends a SQL `PREPARE` statement to define the parameterized query.
2. Then it sends `EXECUTE` with your bound parameters.
3. **Trino parses the prepared statement, re-optimizes the query plan, and executes it — every single time.**

The bind parameters (`?` placeholders) are not used to avoid re-planning. They are used only to prevent SQL injection. The query planner runs fresh with each execution.

For your workload of 200 identical queries per minute with different parameters:
- Request 1: plan + execute = X ms
- Request 2: plan + execute = X ms
- Request 200: plan + execute = X ms

You are paying the planning cost 200 times. `PreparedStatement` does not help with this.

### What PreparedStatement actually gives you

1. **SQL injection safety** — parameters are properly typed and escaped. Never string-concatenate tenant IDs into SQL.
2. **Small parse-time win** — the SQL text itself is parsed once per connection, not per execution. This is minor compared to planning cost.
3. **Cleaner code** — type-safe parameter binding instead of string templating.

Use `PreparedStatement` because it is the right practice for security and code quality — not because it will reduce planning latency.

### Postgres vs Trino: the key difference

| Behavior | Postgres | Trino |
|---|---|---|
| Parse SQL text | Once per PREPARE | Once per PREPARE (per connection) |
| Optimize query plan | Once per PREPARE (plan cached) | **Every EXECUTE (no plan cache)** |
| Bind parameters | At EXECUTE time | At EXECUTE time |
| SQL injection safe | Yes | Yes |
| Plan reuse across requests | Yes | **No** |

### How to actually reduce planning latency

Since Trino does not cache plans, the lever is elsewhere:

**Option 1: Materialize the hot path**

If your 200 requests/minute are all running variants of the same join-heavy query, push the expensive computation upstream into a pre-aggregated Iceberg table (a dbt model or a scheduled Spark job). Query the materialized result instead. This moves expensive planning and execution offline, and your API just reads from a pre-built table.

**Option 2: Simplify the query and use explicit partition filters**

Use `EXPLAIN` to see where planning time is spent. If the coordinator is doing expensive dynamic filter pushdown or partition elimination, add explicit partition filter columns to your WHERE clause to reduce the planner's search space.

**Option 3: Measure before optimizing**

If planning takes 20 ms per query and execution takes 300 ms, planning is 6% of total latency — not worth optimizing. Run `EXPLAIN ANALYZE` on a live query to see actual planning time vs. execution time split. If planning is under 10% of total latency, focus on execution instead.

### Should you bother with PreparedStatement?

Yes — always use `PreparedStatement` instead of string-concatenating SQL. The reasons are:
1. SQL injection prevention (security requirement, not optional)
2. The JDBC driver in Trino 467 automatically uses `EXECUTE IMMEDIATE` (available since Trino 425) which collapses the PREPARE + EXECUTE round-trips into a single HTTP call, reducing network overhead slightly.

Just do not expect it to cache query plans. It does not, by design.

### Summary

| Question | Answer |
|---|---|
| Does Trino cache plans between EXECUTE calls? | **No** — re-plans every time |
| What does PreparedStatement give you in Trino? | SQL injection safety, parse efficiency, cleaner code |
| How to reduce planning cost on 200 req/min? | Materialize the hot path upstream; simplify the query |
| Should you use PreparedStatement? | Yes — for injection safety, not for plan reuse |
