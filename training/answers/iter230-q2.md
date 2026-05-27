# Iter 230 Q2 — WHERE Clause Not Pushing Down to MySQL (Predicate Pushdown Failure)

## Answer

Your issue is almost certainly caused by **predicate pushdown failure on the MySQL side**. Here's the diagnostic process and the most likely root causes:

### How Predicate Pushdown Should Work

In your Trino query joining Iceberg events to MySQL:
```sql
SELECT ...
FROM iceberg.analytics.events e
JOIN mysql_catalog.schema.table m ON e.id = m.id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY
```

Trino should:
1. Push the date filter `event_date >= ...` down to Iceberg (via partition pruning + file skipping)
2. Push any filters on the MySQL side down to MySQL as a WHERE clause
3. Apply dynamic filtering: after the smaller join side completes, Trino derives an IN-list or range predicate from join keys and pushes it to the larger side

When this breaks and MySQL scans the full table, it's almost always one of these causes:

---

### Primary Cause: VARCHAR/String Column Predicates on MySQL

**The MySQL connector does NOT push down text-column predicates.** This is the #1 "why is my MySQL query so slow?" issue.

| Predicate Type | Pushes to MySQL? | Workaround |
|---|---|---|
| Numeric equality/range (`WHERE id > 100`) | YES | - |
| Date/timestamp range (`WHERE created_at >= '2026-05-01'`) | YES | - |
| `VARCHAR` equality (`WHERE status = 'active'`) | **NO** | Pair with a pushing date/numeric filter |
| `LIKE` pattern | **NO** | Pair with a pushing filter |
| `IN` list on VARCHAR | **NO** | Use numeric/date IN instead |
| `IS NULL` on VARCHAR column | **NO** | Add a numeric/date co-predicate |

**If your WHERE clause on the MySQL table uses any text column, that filter does NOT push down** — Trino pulls the entire table over JDBC and filters in worker memory. This is why your MySQL replica scans millions of rows.

---

### How to Diagnose

Run this on your slow query:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT e.*, m.*
FROM iceberg.analytics.events e
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY
JOIN mysql_catalog.schema.table m ON e.id = m.id;
```

**Look at the plan tree for the MySQL `TableScan` node:**

- **If the predicate is INSIDE the `constraint` field of `TableScan`**: pushdown succeeded. MySQL received the filter.
- **If there is a `ScanFilterProject` or `Filter` node ABOVE the `TableScan`**: pushdown FAILED. Trino is filtering in worker memory after pulling rows from MySQL.

---

### Fix: Pair Non-Pushing Filters with Pushing Filters

The workaround is to add a **numeric or date predicate that DOES push down**, so MySQL ships fewer rows:

**BAD** (pulls full table):
```sql
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY
  AND m.status = 'active'  -- VARCHAR: does NOT push
```

**GOOD** (MySQL only returns recent rows, Trino filters status in memory):
```sql
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY
  AND m.updated_at >= CURRENT_DATE - INTERVAL '7' DAY  -- pushes to MySQL (date range)
  AND m.status = 'active'                              -- filtered in Trino memory on smaller set
```

If MySQL has no date column, use an indexed numeric column:

```sql
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY
  AND m.id >= 1000000  -- pushes to MySQL (numeric range)
  AND m.status = 'active'
```

---

### Other Possible Causes

1. **VARCHAR join key + dynamic filtering**: If you're joining on a VARCHAR column, the IN-list that Trino's dynamic-filtering machinery derives **will NOT push to MySQL** either (because of collation-correctness concerns — MySQL's default collation is case-insensitive while Trino's is bytewise). Effect: Trino pulls all rows from MySQL. Solution: add a numeric/date co-predicate to the MySQL table.

2. **No explicit WHERE clause on MySQL**: If your WHERE is only on the Iceberg side and the join is an INNER JOIN, Trino still scans the MySQL table without filters. Add a known-pushing predicate on the MySQL table.

3. **Large IN-list compaction**: If dynamic filtering generates a huge IN-list (>1000 entries by default), Trino compacts it to `BETWEEN min AND max`, which returns extra rows. Verify with `EXPLAIN (TYPE DISTRIBUTED)`.

---

### Specific Diagnostic Queries

**From Trino, inspect what gets pushed:**
```sql
-- Step 1: See the plan
EXPLAIN (TYPE DISTRIBUTED)
SELECT ... FROM iceberg... JOIN mysql_catalog... WHERE ...;

-- Step 2: Run EXPLAIN ANALYZE to see actual I/O
EXPLAIN ANALYZE
SELECT ... FROM iceberg... JOIN mysql_catalog... WHERE ...;
-- Look at physical_input_bytes — if it's huge, a full table scan happened
```

**On your MySQL replica, check the slow query log** to see what SQL Trino is actually sending:
```sql
-- MySQL slow query log shows the actual SQL Trino submitted
-- If you see no WHERE clause in the MySQL slow log, pushdown failed
```

**Check if the MySQL table has indexes** on the columns you're filtering:
```sql
-- From MySQL directly (not through Trino)
SHOW INDEX FROM schema.table;
```

---

### Summary

**Your filter likely IS being applied on the Iceberg side.** The MySQL side is scanning the full table because:

1. Your WHERE clause on the MySQL table uses a `VARCHAR`/text column, which never pushes down on the MySQL connector, OR
2. You're joining on a VARCHAR key and dynamic filtering can't push the IN-list, OR
3. You have no explicit filter on the MySQL table at all

**Immediate fix:** Add a **numeric or date-range predicate** to your MySQL WHERE clause. This will cause MySQL to ship fewer rows back, making Trino's in-memory filtering on the text column feasible.
