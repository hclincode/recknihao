# Iter240 Q2 — Iceberg Time-Travel + PostgreSQL Cross-Catalog Join

## The Trino Syntax for Iceberg Time-Travel

You're on the right track. Trino 467 supports two forms of time-travel queries on Iceberg tables:

```sql
-- Option 1: Query as of a specific timestamp
SELECT user_id, account_name, event_count
FROM iceberg.analytics.user_events
FOR TIMESTAMP AS OF TIMESTAMP '2026-02-27 00:00:00 UTC'
WHERE tenant_id = 'customer-123'
GROUP BY user_id, account_name;

-- Option 2: Query a specific snapshot ID (more precise for audits)
SELECT user_id, account_name, event_count
FROM iceberg.analytics.user_events
FOR VERSION AS OF 4823511203987654321
WHERE tenant_id = 'customer-123'
GROUP BY user_id, account_name;
```

**Important:** `FOR TIMESTAMP AS OF T` resolves to the latest snapshot with `committed_at <= T`, not necessarily a snapshot committed at exactly T. For audit-grade precision (which is what you need here), always pin the exact snapshot ID instead — find it by querying the `$snapshots` metadata table.

## What Happens with the Cross-Catalog Join

When you write a query like this:

```sql
SELECT 
  e.user_id, 
  a.account_name,
  SUM(e.event_count) as total_events
FROM iceberg.analytics.user_events FOR VERSION AS OF 4823511203987654321 AS e
JOIN app_pg.public.accounts AS a
  ON e.user_id = a.user_id
WHERE e.tenant_id = 'customer-123'
GROUP BY e.user_id, a.account_name;
```

Here's the actual execution flow on your stack (Trino 467 + Iceberg 1.5.2 + PostgreSQL connector):

**1. Predicate pushdown DOES work on the Iceberg side**
The `WHERE e.tenant_id = 'customer-123'` filter is a partition column. Trino pushes this down to the Iceberg connector, which uses manifest file pruning and row-group statistics to skip entire Parquet files. Time-travel does not change this — the snapshot you query is still subject to the same pruning logic.

**2. Predicate pushdown ALSO works on the Postgres side**
Trino pushes any direct filters on the Postgres table down to Postgres via JDBC. The `accounts` table gets queried with whatever predicates Trino can express in SQL (equality, ranges, IN-lists from join keys).

**3. The join itself executes on Trino workers — no cross-catalog pushdown**
This is critical: **Postgres does NOT see the Iceberg table, and Iceberg does NOT see the Postgres table.** The join happens entirely on Trino. The two catalogs only exchange data through dynamic filtering (explained below).

**4. Dynamic filtering (runtime join pruning) DOES work across catalogs**
After Trino finishes the join's build side (whichever table it reads first), it derives a runtime predicate from the join keys and pushes it to the probe side's scan. Concretely:
- If Postgres `accounts` is the build side, Trino extracts the list of `user_id` values and generates an `IN (user_id_1, user_id_2, ...)` predicate pushed back to the Iceberg scan.
- If Iceberg is the build side, Trino extracts the matching `user_id` values and pushes them to the Postgres scan.

This dynamic filtering still works perfectly with time-travel — the snapshot you're querying responds to dynamic filters just like the current snapshot would.

## The Real Caveats

**1. Time-travel resolves BEFORE the join**
The `FOR VERSION AS OF` clause is resolved during planning — the specific snapshot ID is locked in before any join execution. You are not dynamically switching snapshots mid-join. This is correct and expected.

**2. VARCHAR pushdown limitation on Postgres**
There's an asymmetry in Trino's federated pushdown: numeric and timestamp predicates push down to Postgres, but **VARCHAR equality filters do not always push reliably**. If your join key is a VARCHAR `user_id`, the dynamic filtering from the Iceberg side may not push the VARCHAR IN-list as aggressively as you'd hope. Numeric or timestamp keys work better. For audit-grade joins where you control the schema, consider using a numeric user ID as the join key or verify with `EXPLAIN ANALYZE VERBOSE` that the pushdown is working.

**3. Verify pushdown with EXPLAIN ANALYZE**
After you write the query, run it with `EXPLAIN ANALYZE VERBOSE` and look for:
- **Iceberg side**: `Files:` count should be small if partition filters applied. If it's thousands of files, the filter is not being pushed.
- **Postgres side**: Check the actual SQL JDBC sent to Postgres by querying `pg_stat_activity` on your read replica during query execution. You should see a WHERE clause in the Postgres query, not a full table scan followed by filtering on Trino.

**4. Use the read replica only**
Your `accounts` table should come from a **read replica**, never the OLTP primary. Even a single analytical join can cause replica lag or connection saturation on the primary.

## Practical Steps for Your Audit Report

1. Find the exact snapshot ID for "three months ago":
   ```sql
   SELECT snapshot_id, committed_at
   FROM iceberg.analytics."user_events$snapshots"
   WHERE committed_at <= TIMESTAMP '2025-02-27 23:59:59 UTC'
   ORDER BY committed_at DESC
   LIMIT 1;
   ```

2. Write the audit query pinning that snapshot ID:
   ```sql
   SELECT 
     e.user_id,
     a.account_name,
     COUNT(*) as event_count,
     MIN(e.occurred_at) as earliest_event,
     MAX(e.occurred_at) as latest_event
   FROM iceberg.analytics.user_events FOR VERSION AS OF <snapshot_id> AS e
   JOIN app_pg.public.accounts AS a ON e.user_id = a.user_id
   WHERE e.tenant_id = 'customer-123'
   GROUP BY e.user_id, a.account_name
   ORDER BY event_count DESC;
   ```

3. Verify pushdown is working:
   ```sql
   EXPLAIN ANALYZE VERBOSE
   -- (same query as above)
   ```
   Look at the Iceberg `Files:` count and check Postgres `pg_stat_activity` for the actual JDBC SQL.

The combination of time-travel + federated join works as expected — predicates push down on both sides, and dynamic filtering still optimizes the probe-side scan. Your bottleneck will almost certainly be network I/O from Postgres or the number of Parquet files needing to be opened, not the join mechanism itself.
