# Iter271 Q1 — Diagnosing Predicate Pushdown Failures in Trino-PostgreSQL Federated Queries

## Answer

The best way to determine if Trino is pushing your WHERE conditions down to Postgres is to examine the **structure of the `EXPLAIN` output** and then verify with runtime metrics from `EXPLAIN ANALYZE`. The signal lives in the **vertical position of predicates in the plan tree**, not in any keyword.

### The Core Problem

When you write:

```sql
SELECT * 
FROM app_pg.public.users 
WHERE tenant_id = 'abc123' 
  AND created_at > now() - interval '30' day
```

Trino can either:

1. **Push the WHERE down to Postgres** — Postgres applies the indexed filter server-side and returns only matching rows over JDBC (fast, what you want)
2. **Fetch the whole table locally** — Trino pulls all rows over JDBC, then filters them in-memory on Trino workers (catastrophic for large tables)

### The Diagnostic Workflow: Three Steps

#### Step 1: Run Plain EXPLAIN to Check Plan Structure

```sql
EXPLAIN (TYPE DISTRIBUTED) 
SELECT * 
FROM app_pg.public.users 
WHERE tenant_id = 'abc123' 
  AND created_at > now() - interval '30' day;
```

**What pushdown SUCCESS looks like:**

```
TableScan[table = app_pg:public.users, ...]
    Layout: [id, tenant_id, email, created_at, ...]
    constraint on [tenant_id, created_at]
        tenant_id = 'abc123'
        created_at > (current_timestamp - interval '30' day)
```

The predicates are **inside** the `TableScan` node under the `constraint on [...]` block. There is **no** `ScanFilterProject` or `Filter` node above it. This is the canonical signal of pushdown success.

**What pushdown FAILURE looks like:**

```
ScanFilterProject[filterPredicate=(tenant_id = 'abc123')]
    Input: 5000000 rows
    Output: 150000 rows
  TableScan[table = app_pg:public.users, ...]
      constraint on [created_at]
          created_at > (current_timestamp - interval '30' day)
```

The `tenant_id` predicate is **above** the `TableScan` in a `ScanFilterProject` node — Trino is applying it in-memory after fetching rows. Only `created_at` pushed to Postgres.

**The Rule**: If you see a `ScanFilterProject` or `Filter` node above the `TableScan` carrying a predicate, that predicate is **not pushing down**.

#### Step 2: Run EXPLAIN ANALYZE to Verify at Runtime

```sql
EXPLAIN ANALYZE 
SELECT * 
FROM app_pg.public.users 
WHERE tenant_id = 'abc123' 
  AND created_at > now() - interval '30' day;
```

Look at the `Input:` row count at the `TableScan` node:

- **`Input: 52000 rows`** — if your table has 8M rows but Trino only read 52K, pushdown succeeded at runtime
- **`Input: 5200000 rows`** — if Input equals your full table size, pushdown failed and Trino fetched everything

**Concrete example of failed pushdown in EXPLAIN ANALYZE:**

```
ScanFilterProject[filter = (tenant_id = 'abc123')]
    Input: 5200000 rows
    Output: 200000 rows
  TableScan[table = app_pg:public.users, ...]
      Input: 5200000 rows (450MB)
      Output: 5200000 rows
      constraint on [created_at]
          created_at > (...)
```

Postgres fetched 5.2 million rows (450MB) because `tenant_id` did not push down. Trino filtered locally in `ScanFilterProject`, keeping only 200K rows.

#### Step 3: Verify on the Postgres Side (Ground Truth)

Enable Postgres's slow log temporarily:

```bash
# Add to postgresql.conf temporarily:
log_min_duration_statement = 0

# Tail while your Trino query runs:
tail -f /var/log/postgresql/postgresql.log | grep "SELECT"
```

**If pushdown worked**, Postgres received:
```sql
SELECT ... FROM users WHERE tenant_id = 'abc123' AND created_at > ...
```

**If pushdown failed**, Postgres received:
```sql
SELECT ... FROM users
```

The SQL Postgres receives is the absolute ground truth.

### Why Your tenant_id Predicate Might Not Be Pushing

| Predicate | Pushes Down? | Notes |
|---|---|---|
| `tenant_id = 'abc123'` (equality) | **YES** | Pushes unconditionally on VARCHAR/text |
| `tenant_id IN ('a', 'b', ...)` (IN-list) | **YES** | Even 100+ values push fine |
| `tenant_id > 'abc'` (range) | **NO** | Ranges on strings do NOT push (collation concerns) |
| `tenant_id LIKE 'abc%'` (prefix LIKE) | **MAYBE** | Depends on collation; behavior is conservative |
| `CAST(tenant_id AS VARCHAR) = 'abc123'` | **NO** | Any implicit cast breaks pushdown |

If `tenant_id = 'abc123'` is still not pushing with a VARCHAR column, check for implicit casts in your WHERE clause. The most common cause is:

```sql
-- BAD: cast blocks pushdown
WHERE CAST(tenant_id AS VARCHAR) = 'abc123'

-- GOOD: direct comparison
WHERE tenant_id = 'abc123'
```

Also verify there are no session property overrides:

```sql
SHOW SESSION LIKE 'app_pg.%';
```

### Complete Diagnostic Checklist

1. Run `EXPLAIN (TYPE DISTRIBUTED)` — look for `ScanFilterProject` **above** `TableScan`:
   - Present → predicate is NOT pushing down; investigate why
   - Absent → predicate inside `constraint on [...]` → pushdown succeeded

2. Run `EXPLAIN ANALYZE` — compare `Input:` row count at TableScan to full table size:
   - Much smaller than table → pushdown worked at runtime
   - Equal to full table → pushdown failed

3. Tail Postgres slow log briefly — look at actual SQL Postgres received:
   - WHERE clause present → pushdown happened
   - Bare SELECT with no WHERE → pushdown failed

4. If equality on VARCHAR is failing → check for implicit casts in the WHERE clause

### Why This Matters

In your on-premises stack (Trino 467 + Postgres + Iceberg + MinIO), predicate pushdown is the difference between queries finishing in seconds and running for minutes. Your Postgres indexes on `tenant_id` and `created_at` are sub-second even on large tables — but only if Trino sends the WHERE clause to Postgres instead of fetching all rows. Once filtered rows arrive (tens of thousands instead of millions), the cross-catalog join with your Iceberg events table is fast.

Pushdown failure is the most common cause of unexpectedly slow federation queries in production.
