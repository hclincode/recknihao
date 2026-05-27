# Iter 206 Q1 — Dynamic Filtering + Postgres Partition Pruning in Cross-Catalog Joins

## Answer

### 1. How dynamic filtering works in cross-catalog joins

When Trino executes a join, it works in two phases:

**Phase 1: Build side produces a filter**
Trino scans the smaller side (the build side). As it collects rows, it extracts the join key values and derives a runtime predicate — typically an `IN`-list or `BETWEEN` range.

**Phase 2: Probe side receives the filter**
The derived predicate is pushed to the probe-side scan. For Postgres-connector scans, this predicate becomes part of the actual SQL Trino sends via JDBC. So Postgres receives the filter as a WHERE clause and can use it for server-side pruning.

---

### 2. How the dynamic filter arrives at Postgres via JDBC

When Postgres is the **probe side** (receiving the filter), the exact path:

1. Trino coordinator derives the DF predicate from the build side (e.g., 4 distinct months: `'2025-10', '2025-11', '2025-12', '2026-01'`).
2. Trino's JDBC connector encodes the predicate into SQL. Instead of:
   ```sql
   SELECT * FROM events
   ```
   Postgres receives:
   ```sql
   SELECT * FROM events WHERE event_month IN ('2025-10', '2025-11', '2025-12', '2026-01')
   ```
3. This SQL is sent over JDBC to the Postgres replica and executes there natively.

---

### 3. Does this trigger Postgres server-side partition pruning? YES.

**This is the key answer to your question:** If the dynamic filter predicate constrains the partition key, Postgres **absolutely prunes its child partitions server-side.**

- Your table is declaratively partitioned by `event_month`.
- Trino sends: `WHERE event_month IN ('2025-10', '2025-11', '2025-12', '2026-01')`
- Postgres's constraint exclusion planner evaluates each partition's bounds against the filter and **prunes all non-matching child partitions** — they never get scanned.
- Result: 4 partitions scanned instead of 12+. Rows from other months never leave Postgres.

This compounds two optimizations: Trino's dynamic filtering reduces what SQL reaches Postgres, and Postgres's partition pruning further reduces what gets scanned inside Postgres.

---

### 4. How to verify this with EXPLAIN ANALYZE

**Step 1: Check the Trino plan**

```sql
EXPLAIN ANALYZE
SELECT e.event_month, COUNT(*)
FROM iceberg.analytics.events e
JOIN app_pg.public.events p ON e.event_month = p.event_month
WHERE e.event_month BETWEEN '2025-10' AND '2026-01'
GROUP BY e.event_month;
```

Look for on the Postgres `events` TableScan:
- **`dynamicFilterSplitsProcessed` — non-zero** confirms the DF arrived in time
- **`constraint on [event_month]`** shows the pushed predicate includes the partition column
- **Small `Input:` row count** shows Postgres pruned older partitions

Example (good output):
```
TableScan[table = app_pg.public.events]
    dynamicFilterSplitsProcessed = 4
    Input: 4,200,000 rows
    constraint on [event_month]
        event_month IN ('2025-10', '2025-11', '2025-12', '2026-01')
```

**Step 2: Verify on the Postgres replica (most conclusive)**

While your Trino query is executing:
```sql
SELECT query, query_start, state
FROM pg_stat_activity
WHERE usename = 'trino_reader'
ORDER BY query_start DESC
LIMIT 5;
```

**Good output** (DF arrived, partition pruning fired):
```
query = SELECT ... FROM events WHERE event_month IN ('2025-10', '2025-11', '2025-12', '2026-01')
```

**Bad output** (DF did NOT arrive in time):
```
query = SELECT ... FROM events
-- (no WHERE clause)
```

If you see the full `IN` clause with exactly the months you expect, Postgres partition pruning is happening.

---

### 5. When the DF might NOT arrive in time — and how to fix it

Dynamic filtering is **asynchronous and time-bounded**. The probe scan doesn't always wait for the build side to finish.

**Default timeout for Postgres probe**: `20 seconds` (`dynamic_filtering_wait_timeout` for the JDBC connector).

**Symptoms of a timeout**: `dynamicFilterSplitsProcessed = 0` on the Postgres scan node in `EXPLAIN ANALYZE`, large `Input:` row count despite having a WHERE clause.

**Fix: raise the wait timeout**

```sql
-- For Postgres probe side:
SET SESSION app_pg.dynamic_filtering_wait_timeout = '30s';
```

Note: this requires the catalog prefix (`app_pg.`). Bare `SET SESSION dynamic_filtering_wait_timeout = '30s'` fails.

Or set cluster-wide in the catalog properties file:
```properties
# etc/catalog/app_pg.properties
postgresql.dynamic-filtering.wait-timeout=30s
```

**Secondary issue — IN-list degradation to BETWEEN**: If the build side produces >256 distinct values, the JDBC connector may compact the IN-list to a BETWEEN range before sending to Postgres. For your 4-month query this won't happen, but if you have queries with many values:

```sql
SET SESSION app_pg.domain_compaction_threshold = 1024;
```

---

### Bottom line: does adding more Postgres partitions help?

**Yes, but only if the DF arrives in time.**

- **With DF arriving**: more granular partitions (e.g., daily instead of monthly) means Postgres can prune more aggressively. This is a genuine win.
- **If DF times out**: adding partitions makes things worse — Postgres scans everything anyway and now has to evaluate constraint exclusion on more partition bounds.

**Recommendation**:
1. Verify `dynamicFilterSplitsProcessed > 0` on the Postgres scan in `EXPLAIN ANALYZE`.
2. If it's 0, fix the timeout first (`dynamic_filtering_wait_timeout = '30s'`).
3. Only then consider adding more granular Postgres partitions.
