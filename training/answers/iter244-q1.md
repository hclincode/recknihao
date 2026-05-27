# Iter244 Q1 — Federation Observability: system.runtime.queries + EXPLAIN ANALYZE

## Real-time query monitoring in Trino + Iceberg + PostgreSQL federation

You're asking three related questions: (1) how to see queries in real time, (2) how to identify where time is spent, and (3) how to tell if Trino is pushing filters to PostgreSQL or doing full table scans. The answers use different Trino tools at different layers.

### Part 1: Seeing running and queued queries in real time

Yes, Trino has a live equivalent to `pg_stat_activity`. The **Trino Web UI** at `http://trino-coordinator:8080/ui/queries` shows you every running, queued, and recently completed query with their states, durations, and which worker they're running on. This is the fastest way to spot slow queries right now.

For **programmatic real-time monitoring**, query two built-in system tables:

```sql
-- What's running RIGHT NOW?
SELECT
  query_id,
  "user",                              -- note: must be DOUBLE-QUOTED
  source,
  query,
  state,                               -- 'RUNNING', 'QUEUED', 'FINISHED', 'FAILED'
  date_diff('second', started, current_timestamp) AS running_sec,
  queued_time_ms
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY started DESC;
```

The `state` column tells you whether a query is actively executing (`RUNNING`) or sitting in the queue waiting for a worker slot (`QUEUED`). **Long `queued_time_ms` means your Trino cluster is saturated** — your workers don't have capacity yet, so new queries wait. This is different from slow-query problems; it's a concurrency bottleneck.

**Critical caveat:** `system.runtime.queries` is ephemeral — it lives only in the running coordinator's memory. When the coordinator restarts, this table is wiped. The default retention is ~100 queries or 15 minutes, whichever comes first. For anything longer than a few hours of real-time inspection, you need to set up an **event listener** to persist `QueryCompletedEvent` records to durable storage (Kafka, HTTP endpoint, or MySQL). See the `resources/18-query-performance-regression.md` file for the exact event-listener configuration.

### Part 2: Finding where queries spend time (I/O vs. compute)

Run `EXPLAIN ANALYZE` on your slow query — **actually run it**, not just `EXPLAIN`:

```sql
EXPLAIN ANALYZE
SELECT ...
FROM iceberg.analytics.my_table i
JOIN app_pg.public.users p ON i.user_id = p.id
WHERE i.event_date >= CURRENT_DATE - INTERVAL '7' DAY;
```

This executes the query and emits a query plan with actual runtime metrics. Look for these fields in the output:

| Field | What it means | Interpretation |
|---|---|---|
| `CPU:` | Actual CPU time spent computing | If `CPU` ≈ `Scheduled`, the query is compute-bound (joins, aggregations are the bottleneck) |
| `Scheduled:` | Total wall-clock time the operator ran | Use this to compare operators. |
| `Blocked: Input` | Time waiting on upstream data (storage, network) | High value = the operator is I/O-bound, waiting on data from MinIO or PostgreSQL |
| `Physical Input:` (bytes) | Actual bytes read from storage (for Iceberg) | The right metric for "did partition pruning work?" |

**Quick rule:** If `Scheduled:` is 5–10x larger than `CPU:`, the query is **I/O-bound** — most of its time is waiting on storage, not computing. If they're close, it's **compute-bound**.

### Part 3: Checking if Trino is pushing filters to PostgreSQL

This is the critical part for your federation question. Trino **does push some predicates to PostgreSQL**, but **not all of them**. Specifically:

**What DOES push down to Postgres** (Trino sends these as WHERE clauses):
- Equality filters: `WHERE user_id = 'abc-123'` ✓
- IN-list filters: `WHERE status IN ('active', 'inactive')` ✓
- NULL checks: `WHERE deleted_at IS NULL` ✓
- Dynamic filters from joins: when joining a small table to Postgres, the join keys automatically push down ✓

**What does NOT push down by default:**
- VARCHAR range filters: `WHERE username BETWEEN 'A' AND 'M'` ✗ (Trino scans the whole table, applies the filter locally)
- Boolean expressions with OR/AND across columns ✗ (depends on complexity)

To confirm what's actually being pushed, use `EXPLAIN ANALYZE VERBOSE`:

```sql
EXPLAIN ANALYZE VERBOSE
SELECT p.id, p.email, COUNT(*) AS event_count
FROM iceberg.analytics.events i
JOIN app_pg.public.users p ON i.user_id = p.id
WHERE p.plan = 'enterprise'
  AND i.event_date >= CURRENT_DATE - INTERVAL '90' DAY;
```

Look for a section labeled something like `TableScan [connectorId=app_pg...]` — it will show whether the PostgreSQL-side filter appeared in the pushed-down predicate. If you see `p.plan = 'enterprise'` mentioned in the Postgres connector section, it pushed. If you only see `i.event_date >= ...` in the Iceberg section but NOT the `p.plan` filter, then Trino scanned every row from `users`, fetched them to the cluster, and filtered them locally (expensive).

### Practical debugging workflow

When your federation query is slow:

1. **Check `system.runtime.queries` first.** Is the query `QUEUED`? Then your cluster is overloaded, not your Postgres. Scale or stagger queries.

2. **Run `EXPLAIN ANALYZE` on the slow query.** Look at `Physical Input:` for Iceberg scans. If it's much larger than expected, partition pruning broke (see resources on query performance regression).

3. **Run `EXPLAIN ANALYZE VERBOSE` and check the Postgres connector section.** If your WHERE clause on Postgres columns didn't push down, you found the problem — add an `ANALYZE` on the Postgres side to get table statistics to Trino's query planner, or rewrite the query to use pushdown-friendly predicates (equality > range for VARCHAR).

4. **For the full picture**, use `system.runtime.tasks` to break down CPU and I/O per worker:

```sql
SELECT
  t.node_id,
  t.stage_id,
  SUM(t.physical_input_bytes) / 1e9 AS input_gb,
  SUM(t.split_cpu_time_ms) / 1000.0 AS cpu_sec
FROM system.runtime.tasks t
WHERE t.query_id = '<query_id_from_step_1>'
GROUP BY t.node_id, t.stage_id
ORDER BY input_gb DESC;
```

This breaks down which stages (scan vs join vs aggregate) consumed the most data, and which workers did the most work.

**One last note:** The production setup uses OPA for authorization, so queries on system tables like `system.runtime.queries` may be restricted depending on your OPA policies. If you can't access these tables, ask your platform team for an admin service account that has unrestricted access to system views.
