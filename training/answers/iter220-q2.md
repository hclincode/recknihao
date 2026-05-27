# Iter 220 Q2 — Verifying OPA Row Filters on a Federated Postgres Table

## Answer

You're asking exactly the right questions. A misconfigured row-filter policy that silently returns an empty filter will expose all data without any error — so verification is critical. Here's how the whole mechanism works and how to confirm it's operating correctly.

### How OPA Row Filters Work Mechanically

When you set `opa.policy.row-filters-uri` on your `app_pg` connector, here's the exact flow:

1. **At query analysis time** (before any Postgres connection is made), Trino calls OPA with a `GetRowFilters` operation for each table your query touches.
2. OPA evaluates your policy and returns a WHERE expression — e.g., `tenant_id = 'acme'`.
3. Trino **injects that expression as a predicate into the SQL query** before pushing it to Postgres.
4. The modified query (`SELECT ... FROM users WHERE tenant_id = 'acme' AND <other predicates>`) is sent to Postgres.
5. Postgres applies the row filter server-side and returns only matching rows.

**Critical**: the filter is injected at query-rewriting time, before Postgres sees it. You are **NOT** fetching all rows and filtering in Trino memory. If the policy is working, Postgres gets a WHERE clause and applies it — the data never leaves Postgres.

### What a GetRowFilters Decision Log Entry Looks Like

Enable OPA's decision log (`decision_logs.console: true` in OPA config). A query against your `users` table will emit a `GetRowFilters` entry:

**Operation name to look for:**
```
input.action.operation = "GetRowFilters"
```

**Input shape (what Trino sends OPA):**
```json
{
  "action": {
    "operation": "GetRowFilters",
    "resource": {
      "table": {
        "catalogName": "app_pg",
        "schemaName": "public",
        "tableName": "users"
      }
    }
  },
  "context": {
    "identity": {
      "user": "alice@example.com",
      "groups": ["tenant:acme", "analytics_readers"]
    },
    "queryId": "20260526_142315_00042_xyz"
  }
}
```

**Result shape (what OPA returns):**
- **Filter applied**: `"result": [{"expression": "tenant_id = 'acme'"}]` — this WHERE clause will be injected.
- **No filter**: `"result": []` — empty array means no row-level restriction for this table and user. If you expected a filter here, your Rego policy has a bug or the user's group didn't match.

For a two-table federated join (Iceberg events + Postgres users), expect **two** `GetRowFilters` entries — one per table. Grep by `input.context.queryId` to find all entries for a single query.

### Three-Step Verification

**Step 1: OPA decision log — confirm the filter was evaluated and returned a WHERE expression**

Query your OPA decision log by `queryId` (shown in Trino's Web UI for any query). Filter to `GetRowFilters` operations:

```
input.context.queryId = "20260526_142315_00042_xyz"
input.action.operation = "GetRowFilters"
```

You should see `result: [{"expression": "tenant_id = 'acme'"}]`. If you see `result: []`, the filter was not injected — check your Rego rule and the user's group membership.

**Step 2: Postgres log — confirm the WHERE clause reached Postgres**

While the query is running:
```sql
SELECT pid, usename, query, state 
FROM pg_stat_activity 
WHERE usename = 'trino_reader' AND state = 'active';
```

The `query` column should show the injected filter:
```sql
SELECT ... FROM users WHERE tenant_id = 'acme' [AND other predicates]
```

If it shows `SELECT ... FROM users` with no WHERE clause, the OPA filter was returned but failed to push down to Postgres — see below.

For post-mortem analysis, enable slow query logging on the Postgres replica:
```sql
ALTER SYSTEM SET log_min_duration_statement = 100;
SELECT pg_reload_conf();
```

**Step 3: EXPLAIN ANALYZE — confirm pushdown vs in-memory filtering**

```sql
EXPLAIN ANALYZE 
SELECT user_id, email FROM app_pg.public.users LIMIT 100;
```

Look at the Postgres `TableScan` node:

- **Working correctly**: the row filter appears in the `constraint` block inside the `TableScan`. The `Filtered:` field will show a high percentage (Postgres applied it server-side).
  ```
  TableScan[table=app_pg:public.users]
      constraint on [tenant_id]
          tenant_id = 'acme'
  ```

- **Filter in Trino memory** (bad): a `ScanFilterProject` or `Filter` node sits ABOVE the `TableScan` with the tenant filter there instead.
  ```
  Filter[filterPredicate = (tenant_id = 'acme')]
      TableScan[table=app_pg:public.users]   ← no constraint, full table scan
  ```

### Diagnosis Table

| OPA result | Postgres receives | Conclusion |
|---|---|---|
| `[{"expression": "tenant_id = 'acme'"}]` | `WHERE tenant_id = 'acme'` in query | **Correct — filter pushed to Postgres server-side** |
| `[{"expression": "tenant_id = 'acme'"}]` | Unfiltered `SELECT * FROM users` | **Filter injected but didn't push — data leaks at Postgres boundary** |
| `[]` | N/A | **No filter returned — policy bug, data visible to wrong user** |

### What a Misconfigured Policy Looks Like

Signs of a broken policy:
- Decision log shows `result: []` for a user who should see filtered data.
- `EXPLAIN ANALYZE` shows the filter in a `Filter` node above the `TableScan` (Trino memory) rather than in the `TableScan` constraint.
- A tenant running `SELECT DISTINCT tenant_id FROM app_pg.public.users` returns more than one tenant ID.

Signs of a working policy:
- Decision log shows `result: [{"expression": "tenant_id = 'acme'"}]`.
- Postgres log shows `WHERE tenant_id = 'acme'` in the query.
- `EXPLAIN ANALYZE` shows the filter in the `TableScan` constraint with a high `Filtered:` percentage.
- `SELECT DISTINCT tenant_id FROM app_pg.public.users` returns exactly one tenant ID (the caller's own).

### Key Points

1. **OPA fires at analysis time, before any worker reads data.** The decision log entry exists regardless of whether the query succeeds — you can definitively audit "was a filter applied?" without ambiguity.

2. **`row-filters-uri` is separate from `opa.policy.uri`** and must be configured explicitly in `etc/config.properties`.

3. **Ship OPA decision logs to a durable sink** (OpenSearch, Loki) — stdout is lost when the OPA pod restarts and you lose your forensics trail.

4. **The row filter participates in Postgres predicate pushdown.** A simple expression like `tenant_id = 'acme'` pushes to Postgres (it's an equality on a UUID/text column that Trino can encode). A complex expression or function call might not push — always verify with `EXPLAIN ANALYZE`.

5. **One query emits one `GetRowFilters` entry per table.** A three-table cross-catalog join produces three `GetRowFilters` calls. Use `queryId` as the join key when reading decision logs.
