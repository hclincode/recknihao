# Iter 228 Q2 — Trino query.max-execution-time and Resource Groups

## Answer

Your queries are being killed by Trino's built-in query execution timeouts. The good news is you can override them per query, and there are mechanisms to prevent any single query from choking the whole cluster.

### Where the timeout comes from

Trino has two cluster-level query timeouts configured in the coordinator's `etc/config.properties`:

- **`query.max-execution-time`** — caps the time your query *actually spends computing* on the workers. Does NOT include time waiting in a resource-group queue.
- **`query.max-run-time`** — caps the total time from when you submit the query until it finishes or fails. This includes analysis, planning, queue wait, and compute time combined.

The default for both is 100 days (basically unlimited), but your cluster almost certainly has them tightened to something like 10–15 minutes, which is why you're hitting timeouts around 10 minutes.

### How to override per query (safely)

You can raise the limit for a specific query using a SQL `SET SESSION` command. Run this *before* your slow query:

```sql
SET SESSION query_max_execution_time = '30m';
SET SESSION query_max_run_time = '45m';
```

Then run your query. These settings only apply to that session (your connection), so other users' dashboards and queries are unaffected.

**Important**: these are system-level session properties — use the bare form above, not `SET SESSION catalog.query_max_execution_time` (catalog-scoped form won't work for these).

### How to prevent runaway queries from hurting others

You're right to worry about one slow report starving the cluster. The answer is **resource groups** — a Trino feature that creates per-user or per-workload query queues, each with limits on CPU, memory, and concurrent queries.

For example, you can configure resource groups so that heavy analytics users can run at most 2 concurrent queries, each using at most 15% of cluster memory. Once that limit is hit, new queries from that user queue up instead of eating cluster resources. Meanwhile, dashboard queries from other users run in a separate resource group with different limits.

This is configured in `etc/resource-groups.json` on the coordinator. The mechanism matches JWT principals (the usernames from your JWT tokens) to specific groups with caps.

**Warning**: resource groups require a separate `etc/resource-groups.properties` file on the coordinator pointing at the JSON file. If this file is missing, the JSON sits inert and no limits apply, even though the config looks correct.

### The full picture: many timeout layers

Your 10-minute cutoff is just one layer. Between your dashboard and your MySQL/Iceberg data, there are 7 different timeout layers (outer to inner):
1. Trino client abandonment timeout (`query.client-timeout`, default 5 minutes)
2. Trino query execution caps (`query.max-execution-time`, `query.max-run-time`)
3. Resource group `cpuLimit` / `softCpuLimit`
4. Dynamic filter wait timeout (per-catalog; does NOT kill the query, only stops waiting for filter)
5. Database server timeout (`max_execution_time` on MySQL, `statement_timeout` on PostgreSQL)
6. JDBC socket/connect timeout (`socketTimeout`, `connectTimeout`)
7. Database connection idle timeouts (`wait_timeout`, `net_read_timeout`)

Each has its own knob and error message. Check the Trino Web UI query details page for the exact error string (e.g., "Query exceeded maximum time limit of X") to identify which layer fired.

**In production, all layers should be stacked so the innermost (database-side) timeout fires first.** This way the database cancels the work cleanly, the connection survives, and Trino's upper layers never have to forcefully kill anything.
