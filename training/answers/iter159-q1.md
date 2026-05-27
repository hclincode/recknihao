# Iter 159 Q1 — Trino Federation: Predicate Pushdown and Production Postgres Risk

## Answer

## How Trino actually handles your Postgres join

No, Trino does not pull all 8 million rows from Postgres into memory before joining. Here's what really happens, and why your concern about production impact is legitimate.

### The Join Execution Model

When Trino executes a cross-database join (Postgres to Iceberg), it works like this:

1. Each table's WHERE clause is evaluated independently on its home system first. For your Postgres table, if you have a predicate like `WHERE customer_id = 123`, Trino **pushes that down** to Postgres — meaning Postgres applies the filter and returns only matching rows, not the entire 8 million.
2. Both filtered result sets come back to Trino's workers.
3. Trino's workers build a hash table from the smaller side and probe through the larger one.

**The key word:** "predicate pushdown." This is what makes federation not terrible. Only rows that match your WHERE clause in Postgres are transmitted over the network.

### Your Production Postgres Risk is Real

Yes, you should worry about hammering production. Here are the actual risks:

- **Connection pool starvation**: If Trino has 20 workers and each maintains a pool of 10 Postgres connections, that's 200 simultaneous connections to your Postgres replica. If your app also connects to Postgres, you're competing for slots.
- **Long transactions**: A slow analytical join can hold open a transaction on your replica for minutes, blocking routine maintenance (VACUUM) and causing table bloat.
- **Replica contention**: Even on a replica, analytical queries consuming CPU and I/O can slow down your app's read traffic if they share the same replica.

### The One Non-Negotiable Rule

**Always point Trino at a read replica, never your OLTP primary.** If you're currently testing against your primary, stop immediately.

For the replica, add a `statement_timeout` (e.g., 5 minutes) so a runaway query doesn't run forever:

```sql
statement_timeout = '5min'
```

### How to Actually Prevent Problems

Size your Postgres connection pool explicitly in Trino's catalog configuration. With 20 Trino workers and `postgresql.connection-pool-max-size=10`, you're using up to 200 Postgres connections. If your replica is configured with `max_connections=300`, you're burning 2/3 of available slots just for Trino — and that's okay only if you've reserved it.

For your 8M × 500M join specifically: it can work **only if** you have a WHERE clause that makes Postgres return a small subset (thousands, not millions). If both sides are unconstrained, federation won't help — you need to ingest the Postgres data into Iceberg first.

### Verify Predicate Pushdown Before You Deploy

Run `EXPLAIN (TYPE DISTRIBUTED)` on your exact query. Look for a `TableScan` node showing predicates pushed down to Postgres. If you see a separate `FilterNode` above the scan, that predicate didn't push — Trino is filtering rows in-memory after pulling them from Postgres, which defeats the purpose.

You can also enable slow-query logging on the Postgres replica temporarily (`log_min_duration_statement=0`) and look at the actual SQL Trino sends. If Postgres receives a bare `SELECT col1, col2, ... FROM customers`, pushdown didn't happen.
