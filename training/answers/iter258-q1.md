# Iter258 Q1 — TopN Pushdown for ORDER BY LIMIT on Postgres

## Answer

**No, Trino does NOT push ORDER BY ... LIMIT (topN) down to Postgres in OSS Trino.** When you run:

```sql
SELECT * FROM app_pg.public.events ORDER BY created_at DESC LIMIT 100
```

Trino **pulls all 50 million rows over the network** from Postgres, then sorts and limits them on Trino workers. Your concern is valid — this query silently becomes catastrophically slow.

### Why Trino Doesn't Push topN to Postgres

Trino's PostgreSQL connector pushes **predicates** (WHERE clauses) and **some aggregates**, but it has **no optimizer rule for topN pushdown** — sending `ORDER BY ... LIMIT` to Postgres as part of the JDBC query.

The resource documents what pushes to Postgres: equality/range predicates on numeric/date/UUID columns, equality on VARCHAR, IN-lists, IS NULL checks, and some aggregates. But there is **no mention of ORDER BY or LIMIT pushdown** — a conspicuous absence. The architectural reason: topN optimization requires the optimizer to recognize a specific query shape and decide it's safe to reorder operations, which is complex and not implemented for JDBC connectors in this way.

### What EXPLAIN Shows

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.events ORDER BY created_at DESC LIMIT 100;
```

You will see:

```
Limit [count=100]
  └─ TopN [topN=100, orderBy=[created_at DESC]]
    └─ TableScan [table=app_pg:public.events]
```

The `TopN` operator is a **Trino-side node**, not pushed into the TableScan's constraint. If topN were pushed to Postgres, you would see `ORDER BY ... LIMIT` **inside** the TableScan node — but you won't.

Compare to a pushed predicate:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.events WHERE created_at > TIMESTAMP '2026-05-01 00:00:00' LIMIT 100;
```

Here you see:

```
Limit [count=100]
  └─ TableScan [table=app_pg:public.events, constraint=(created_at > TIMESTAMP '2026-05-01 00:00:00')]
```

The **predicate is inside the TableScan's constraint** — it pushed down. The Limit is still Trino-side, but the predicate correctly pre-filters in Postgres.

### The Performance Implication: All 50M Rows Over JDBC

If Trino doesn't push ORDER BY LIMIT, here's what happens:

1. Postgres sends all 50 million rows over JDBC to Trino workers.
2. Trino workers buffer these rows in memory (or spill to disk) for sorting.
3. Trino sorts the 50M rows by `created_at DESC`.
4. Trino takes the first 100 rows.
5. The remaining 49,999,900 rows are discarded.

Your index on `created_at` in Postgres is **completely wasted** — Postgres never gets a `LIMIT 100` clause to tell it "stop after finding 100 rows." It returns everything.

### Practical Workaround 1: Use the system.query() Escape Hatch

Pass the ORDER BY LIMIT query **verbatim** to Postgres:

```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT * FROM events ORDER BY created_at DESC LIMIT 100'
  )
);
```

This sends the query string directly to Postgres via JDBC. Postgres uses its index on `created_at`, finds the 100 most recent rows, and returns only those 100 rows to Trino. Fast.

**Trade-off:** You lose Trino's ability to join the result to other data sources (Iceberg) within the same query. But you can wrap it in a CTE:

```sql
WITH recent_events AS (
  SELECT * FROM TABLE(
    app_pg.system.query(
      query => 'SELECT id, created_at, customer_id, event_type FROM events ORDER BY created_at DESC LIMIT 100'
    )
  )
)
SELECT re.id, re.event_type, COUNT(*) AS event_count
FROM recent_events re
JOIN iceberg.analytics.summary_by_event e ON re.event_type = e.event_type
GROUP BY re.id, re.event_type;
```

### Practical Workaround 2: Pre-materialize the Recent Events on Postgres

Create a small table on Postgres that a scheduled job keeps fresh:

```sql
-- On Postgres (scheduled job runs every minute)
TRUNCATE TABLE recent_events_100;
INSERT INTO recent_events_100
SELECT * FROM events ORDER BY created_at DESC LIMIT 100;
```

Then from Trino:
```sql
SELECT * FROM app_pg.public.recent_events_100;
-- Only 100 rows are fetched. Fast.
```

### How to Verify

**EXPLAIN**: Look for `TopN` as a Trino-side operator above `TableScan` with no `ORDER BY` inside the TableScan node.

**EXPLAIN ANALYZE**: Check the `TableScan` output row count. If it shows 50M rows and `TopN` reduces it to 100, you're fetching everything.

**pg_stat_activity** on the Postgres replica while the query runs:
```sql
SELECT query FROM pg_stat_activity
WHERE state = 'active' AND query LIKE '%events%';
```
If the query Postgres executes has no `ORDER BY` and no `LIMIT`, Trino is doing the ordering and fetching all rows.

### Summary

| Question | Answer |
|---|---|
| Does Trino push ORDER BY ... LIMIT to Postgres? | **No.** No topN pushdown in OSS Trino for JDBC connectors. |
| What does the plan show? | `TopN` is a Trino-side operator above `TableScan`. No ORDER BY in the TableScan constraint. |
| Performance impact? | All 50M rows fetched over JDBC, sorted in Trino. Your Postgres index is wasted. |
| Fix? | Use `system.query()` escape hatch to run ORDER BY LIMIT directly on Postgres, or pre-materialize a small recent-events table. |
