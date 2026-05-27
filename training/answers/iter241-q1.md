# Iter241 Q1 — PostgreSQL Predicate Pushdown: Which Filters Run on the DB?

## Your Question Answered: Pushdown Behavior for Trino → PostgreSQL Filters

Your DBA is asking a smart question, and the answer is good news for most of your filters — **they are pushing down to PostgreSQL**. But the devil is in the operator details, so let me walk through your specific cases.

### The Bottom Line Up Front

1. **VARCHAR equality and IN** (`status = 'active'`, `status IN ('active', 'trial')`) — **YES, push down to PostgreSQL unconditionally.** PostgreSQL applies these server-side.
2. **Timestamp/date range filters** (`created_at > '2025-01-01'`) — **YES, push down to PostgreSQL unconditionally.** These are treated like numeric range filters in Trino.
3. **LIKE with leading wildcard** (`LIKE 'act%'`) — **MAYBE pushes down.** Anchored-prefix LIKE (the kind you described) may push to PostgreSQL for standard-collation columns, but the behavior is collation-dependent. Always verify with EXPLAIN.

---

### Case 1: VARCHAR Equality and IN — These Push Down

When you write:
```sql
WHERE status = 'active'
OR status IN ('active', 'trial')
```

Trino translates this into a JDBC SQL WHERE clause that PostgreSQL receives server-side:
```sql
SELECT * FROM your_table WHERE status = 'active'
```

**Trino sends the filter to PostgreSQL; PostgreSQL's query planner uses any index on `status` and returns only matching rows.** Trino never sees the unfiltered rows. This is unconditional pushdown — no flags, no exceptions.

The same applies to `!=` and `IS NULL`/`IS NOT NULL` on VARCHAR — all of these push.

---

### Case 2: Timestamp Range Filter — This Pushes Down

```sql
WHERE created_at > '2025-01-01'
```

This is treated like a numeric range filter by Trino. It **unconditionally pushes down to PostgreSQL.** PostgreSQL receives:
```sql
SELECT * FROM your_table WHERE created_at > '2025-01-01'
```

PostgreSQL uses its index on `created_at` and returns only rows matching the range. Again: Trino never fetches unfiltered rows.

All timestamp and date operators push: `>`, `<`, `>=`, `<=`, `BETWEEN`. No experimental flags needed.

---

### Case 3: Anchored LIKE (`LIKE 'act%'`) — Verify with EXPLAIN

This is more subtle:
```sql
WHERE status LIKE 'act%'
```

An **anchored** LIKE pattern (prefix pattern with no leading wildcard) **may** push down to PostgreSQL for standard-collation columns. But "may" is the operative word — the behavior is **collation-dependent**. A query with `LIKE 'act%'` might push on one PostgreSQL instance and fail to push on another, depending on the column's collation (C/POSIX vs. ICU).

The safe approach: **always verify with EXPLAIN** before relying on it.

**Leading-wildcard LIKE** (e.g., `LIKE '%act'` or `LIKE '%act%'`) is a different and worse story — **it does not push down** by default. Trino pulls rows to its workers and applies the filter in-memory, which on large tables is catastrophic (full table scan over the network).

---

### How to Verify Pushdown: Use EXPLAIN

Never assume pushdown is happening — verify it. Run this in Trino:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM your_postgres_catalog.public.your_table
WHERE status = 'active'
  AND created_at > '2025-01-01'
  AND status LIKE 'act%';
```

**Read the output for the PostgreSQL `TableScan` node.** Two critical signals:

1. **Pushdown succeeded**: You'll see a block labeled `constraint on [columns]` directly under the `TableScan`, listing the predicates PostgreSQL is handling:
```
TableScan[table = app_pg:public.your_table, ...]
    Layout: [status:varchar, created_at:timestamp, ...]
    constraint on [status, created_at]
        status = 'active'
        created_at > '2025-01-01'
        status LIKE 'act%'
```
   No `Filter` or `ScanFilterProject` node sits above the TableScan. This means PostgreSQL handles all three filters server-side.

2. **Pushdown failed**: You'll see a `ScanFilterProject` or `Filter` node **above** the `TableScan`:
```
ScanFilterProject[filterPredicate = (status LIKE 'act%')]
    TableScan[table = app_pg:public.your_table, ...]
        Layout: [status:varchar, created_at:timestamp, ...]
```
   This means Trino is applying the `LIKE` filter in-memory after fetching rows from PostgreSQL — the bad case.

---

### The Real Ground Truth: Check PostgreSQL's Slow Log

If EXPLAIN output is ambiguous, enable PostgreSQL slow-query logging on your read replica (temporarily):
```sql
ALTER SYSTEM SET log_min_duration_statement = 0;
SELECT pg_reload_conf();
```

Then run your Trino query and check PostgreSQL's logs. The actual SQL PostgreSQL received is the definitive answer:
- **Pushed predicates appear in the WHERE clause** of the logged SQL.
- **Non-pushed predicates are missing** — you'll see a bare `SELECT ... FROM your_table` without the WHERE.

---

### Putting It Together: What Your Query Actually Does

If your Trino query is:
```sql
SELECT * FROM app_pg.public.users
WHERE status = 'active'
  AND created_at > '2025-01-01';
```

What happens:
1. **Equality on `status`** → PostgreSQL receives `WHERE status = 'active'`
2. **Range on `created_at`** → PostgreSQL receives `WHERE created_at > '2025-01-01'`
3. PostgreSQL uses its indexes on `status` and `created_at`, returns only matching rows.
4. Trino never pulls unfiltered data.

If you add a LIKE filter:
```sql
WHERE status LIKE 'act%' AND created_at > '2025-01-01'
```

**Verify with EXPLAIN first.** If LIKE pushdown fails (collation mismatch, ICU collation, etc.), you'll see a `ScanFilterProject` above the PostgreSQL `TableScan`, and Trino will pull the entire table over JDBC and filter locally — slow on large tables.

---

### Key Takeaway for Your DBA Conversation

Tell your DBA:
- **VARCHAR equality, IN, and IS NULL** — unconditionally push. No exceptions.
- **Date and timestamp range filters** — unconditionally push. No exceptions.
- **LIKE 'prefix%'** — maybe pushes; collation-dependent. Always verify with `EXPLAIN (TYPE DISTRIBUTED)`.
- **Leading-wildcard LIKE '%text%'** — does NOT push down by default; Trino applies it in-memory.
- **The verify step is fast and free** — run EXPLAIN, read the `constraint on` block under the TableScan. If it's there, predicates are pushed. If a `Filter` node sits above, they're not.
