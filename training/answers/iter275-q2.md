# Iter275 Q2 — Trino Web UI for Federated Query Debugging

## Answer

Yes, the Trino Web UI at `http://<coordinator-host>:8080/ui` does show useful information for federated queries — but it has real limitations for your specific question about whether Postgres is being over-scanned. Here's what it shows and when to use EXPLAIN instead.

### What the Web UI Shows

**Queries page**: Lists all active and recently completed queries with status, elapsed time, and the user who ran them. Click any query to open the detail view.

**Query detail — Overview tab**: Shows overall elapsed time, CPU time, memory used, and whether the query succeeded or failed. Useful for spotting which queries are slow.

**Query detail — Stages tab**: This is the most useful view for your question. Each stage shows:
- **Input Rows** — total rows read into that stage from its source
- **Output Rows** — total rows produced by that stage after filtering/joining
- **Wall time** — clock time including I/O wait (high wall time for a Postgres scan stage means the network or Postgres was slow)
- **CPU time** — actual processing time (high CPU relative to wall time means Trino is doing heavy filtering locally)

For a Postgres+Iceberg join, you'll typically see two source stages: one that scans Postgres over JDBC and one that scans Iceberg files. The Postgres stage's **Input Rows** tells you how many rows Trino fetched from Postgres over JDBC.

**What to look for**: If the Postgres stage shows `Input Rows: 5,000,000` and the join only produces 312 output rows, that's a red flag — Trino fetched 5 million rows over JDBC and then filtered most of them away locally. That points to a missing or failed predicate pushdown.

### The Critical Limitation

The Web UI shows **how many rows Postgres returned**, but it does **not** show whether Postgres applied your WHERE clause server-side or returned the full table unfiltered. You can see "Input: 5M rows" but not whether that's the filtered result or the full-table dump.

To answer that question definitively, you need EXPLAIN.

### The Authoritative Diagnostic: EXPLAIN and EXPLAIN ANALYZE

**Plain EXPLAIN** (no re-execution — free):
```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT o.id, o.status, e.event_type
FROM app_pg.public.orders o
JOIN iceberg.analytics.events e ON o.id = e.order_id
WHERE o.status = 'paid'
  AND e.occurred_at >= TIMESTAMP '2026-05-01 00:00:00';
```

Look for the Postgres TableScan in the plan output:

```
-- Pushdown SUCCEEDED: predicate inside the TableScan
TableScan[table = app_pg:public.orders, ...]
    constraint on [status]
        status = 'paid'

-- Pushdown FAILED: predicate in a node ABOVE the TableScan
ScanFilterProject[filterPredicate = (status = 'paid')]
    TableScan[table = app_pg:public.orders, ...]
```

If you see `ScanFilterProject` above the `TableScan`, Trino is pulling all rows over JDBC and filtering locally. That's the cause of your slowness.

**EXPLAIN ANALYZE** (re-executes the query — gives runtime row counts):
```sql
EXPLAIN ANALYZE
SELECT o.id, o.status, e.event_type
FROM app_pg.public.orders o
JOIN iceberg.analytics.events e ON o.id = e.order_id
WHERE o.status = 'paid'
  AND e.occurred_at >= TIMESTAMP '2026-05-01 00:00:00';
```

This gives you `Input: N rows` and `Output: M rows` on each operator. If the `TableScan` for Postgres shows `Input: 5,000,000 rows (450MB)` and the `ScanFilterProject` above it shows `Output: 312 rows`, you have the proof: Trino fetched 5M rows and filtered locally.

### Combining Both Tools

| What you need to know | Use |
|---|---|
| Which query is slow? | **Web UI** — Queries page with elapsed time |
| How many rows came from Postgres? | **Web UI** — Stages → Input Rows for the JDBC stage |
| Did Postgres apply my WHERE clause? | **EXPLAIN** — check for `constraint on [col]` inside TableScan |
| Exact row counts per operator at runtime | **EXPLAIN ANALYZE** — `Input:` and `Output:` per node |
| Absolute ground truth (what SQL Postgres received) | Postgres slow-query log (`log_min_duration_statement=0`) |

### Practical Workflow for Your Situation

1. **Web UI**: Open the query, go to Stages tab. Note the Input Rows for the Postgres source stage. If it's close to the full table size, suspect a pushdown failure.

2. **Plain EXPLAIN**: Run without re-executing. Look for `ScanFilterProject` above the Postgres `TableScan`. If present, your WHERE clause on the Postgres side is not pushing down.

3. **EXPLAIN ANALYZE**: Re-execute the query (use on queries that complete in < 30s) to get exact runtime row counts confirming what the plan predicted.

4. **Fix**: If pushdown is failing, check the predicate type — equality and numeric ranges push; ILIKE and function calls may or may not push depending on config. Remove implicit casts (`CAST(col AS VARCHAR) = '...'` blocks pushdown — use the direct comparison instead).

The Web UI gives you a quick visual signal; EXPLAIN gives you the definitive diagnosis.
