# Iter 218 Q2 — Verifying Predicate Pushdown to PostgreSQL in Trino 467

## Answer

## What `constraint =` Means in EXPLAIN Output

When you see `constraint =` (or `constraint on [columns]`) in EXPLAIN output, this is **Trino's signal that predicate pushdown succeeded**. The predicate is embedded inside the `TableScan` node's constraint block, meaning that Postgres will execute your WHERE clause server-side, not Trino pulling all rows back to workers for in-memory filtering.

In real Trino 467 `EXPLAIN (TYPE DISTRIBUTED)` output, it appears on separate indented lines beneath the `TableScan` node, like this:

```
TableScan[table = app_pg:public.events, ...]
    Layout: [id:bigint:0, tenant_id:uuid:1, created_at:timestamp:2, ...]
    Estimates: {rows: ..., cpu: ..., memory: ..., network: ...}
    constraint on [tenant_id, created_at]
        tenant_id = 'your-uuid'
        created_at >= TIMESTAMP '2026-05-01 00:00:00'
```

This tells you Postgres receives a SQL query like `SELECT ... FROM events WHERE tenant_id = '...' AND created_at >= TIMESTAMP '...'` — the unfiltered table does **not** stream over JDBC.

---

## How to Definitively Verify Pushdown Happened

### 1. EXPLAIN (TYPE DISTRIBUTED) — Plan-Time Verification (Fastest, No Query Execution)

This is your first diagnostic step. Run:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.tenant_id = a.tenant_id
WHERE a.tenant_id = '11111111-2222-3333-4444-555555555555'
  AND a.created_at >= DATE '2026-05-01';
```

**Read the plan tree structure** for the Postgres `TableScan` node:

- **Pushdown SUCCEEDED**: The predicate appears **inside the `constraint on [columns]` block** underneath the `TableScan` node. **NO `ScanFilterProject` or `Filter` node sits ABOVE the `TableScan`.**

  ```
  TableScan[table = app_pg:public.accounts, ...]
      constraint on [tenant_id, created_at]
          tenant_id = '...'
          created_at >= DATE '2026-05-01'
  ```

- **Pushdown FAILED**: A **`ScanFilterProject` or standalone `Filter` node sits ABOVE the `TableScan`** with your WHERE clause inside it. This means Trino is pulling unfiltered rows from Postgres and filtering them in-memory on workers.

  ```
  ScanFilterProject[filterPredicate = (created_at >= DATE '2026-05-01')]
      TableScan[table = app_pg:public.accounts]
  ```

**The key signal is vertical position in the plan tree**: predicate **under** the TableScan = pushed; predicate **above** the TableScan in a Filter/ScanFilterProject node = NOT pushed.

### 2. EXPLAIN ANALYZE — Runtime Verification (Actually Runs the Query, Strongest Evidence)

This is **the definitive proof**. `EXPLAIN ANALYZE` executes your query and reports what actually happened:

```sql
EXPLAIN ANALYZE
SELECT * FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.tenant_id = a.tenant_id
WHERE a.tenant_id = '11111111-2222-3333-4444-555555555555'
  AND a.created_at >= DATE '2026-05-01';
```

**Look for these runtime fields on the Postgres `TableScan` node**:

1. **`Filtered: XX.XX%`** — The single most direct visual signal. This percentage shows how many rows Postgres filtered internally before returning them to Trino.
   - **Non-zero `Filtered:` = pushdown SUCCEEDED.** Postgres used its indexes and eliminated rows server-side.
   - **`Filtered: 0%` or absent = pushdown FAILED.** Postgres returned all scanned rows; Trino is filtering in-memory.

   Example indicating success:
   ```
   TableScan[table = app_pg:public.accounts, ...]
       Input: 52000 rows (4.51MB)
       Filtered: 97.25%
       constraint on [tenant_id, created_at]
           ...
   ```

2. **`Input: N rows (size)`** — Total rows Postgres returned to Trino. Compare this against your table's total row count. If `Input:` shows a row count close to your full table size and `Filtered:` is 0%, pushdown failed.

3. **CPU / Elapsed / Wall timing** — High time relative to the overall query suggests the Postgres scan is a bottleneck, which can indicate network-bound I/O from fetching too many rows.

### 3. Postgres Slow Query Log — Ground Truth

This is **the most authoritative verification** — what SQL did Postgres actually receive?

```bash
# Enable slow query logging temporarily (log everything):
psql -c "ALTER DATABASE appdb SET log_min_duration_statement = 0;"
```

Then run your Trino query and tail the Postgres logs:

```bash
tail -f /var/log/postgresql/postgresql.log | grep trino_reader
```

You will see the **verbatim SQL Postgres received**:

- **Pushdown succeeded**: `SELECT ... FROM accounts WHERE tenant_id = '...' AND created_at >= ...`
- **Pushdown failed**: `SELECT ... FROM accounts` (the entire WHERE clause is missing)

---

## Which Types of Predicates DO Push Down to PostgreSQL

As of Trino 467, these predicate types push down by default:

| Predicate Type | Example | Pushes Down? |
|---|---|---|
| Equality on numeric columns | `WHERE id = 12345` | YES |
| Range on numeric columns | `WHERE amount BETWEEN 100 AND 500` | YES |
| Equality on UUID columns | `WHERE tenant_id = 'a1b2c3d4-...'` | YES |
| Equality on temporal columns | `WHERE created_at = TIMESTAMP '2026-05-01 12:00:00'` | YES |
| Range on temporal columns | `WHERE created_at > TIMESTAMP '2026-05-01 00:00:00'` | YES |
| `DATE` comparisons | `WHERE order_date = DATE '2026-05-01'` | YES |
| `IN` lists on numeric/UUID | `WHERE id IN (1, 2, 3, ...)` | YES |
| `IS NULL` / `IS NOT NULL` | `WHERE deleted_at IS NULL` | YES |
| Equality on strings | `WHERE status = 'active'` | YES |

**Your specific WHERE clause:**
```sql
WHERE tenant_id = '...'                              -- UUID equality, PUSHES DOWN
  AND created_at >= TIMESTAMP '2026-05-01 00:00:00' -- timestamp range, PUSHES DOWN
```

Both predicates will push down to Postgres, reducing network I/O significantly.

---

## Which Types of Predicates Do NOT Push Down (And Why)

There are three separate categories — each has a different reason and a different fix.

### 1. String Range Predicates (LIKE, >, <, BETWEEN on VARCHAR/CHAR)

| Example | Why it doesn't push | Workaround |
|---|---|---|
| `WHERE email LIKE 'a%'` or `WHERE name > 'M'` | **Collation differences** between Postgres and Trino could silently return wrong rows. Pushing them without collation handling is unsafe. | Enable experimental flag: `postgresql.experimental.enable-string-pushdown-with-collate=true` in `etc/catalog/app_pg.properties`. **Test on non-prod first.** |

`ILIKE` (case-insensitive) is not documented as pushdown-supported in OSS Trino 467. Safer alternative: add a `lower(email)` generated column on the Postgres side with an index, then `WHERE lower_email = 'foo'` pushes cleanly.

### 2. Function Calls on the Column (LOWER, SUBSTRING, CAST, etc.)

| Example | Why it doesn't push | Workaround |
|---|---|---|
| `WHERE LOWER(email) = 'foo@bar'` | Trino cannot translate arbitrary function-based predicates to JDBC SQL. | Add a stored/generated column on Postgres side (`lower_email` as `LOWER(email)`), index it, then push equality on that column. |

**Silent failure mode — the CAST trap:** `WHERE CAST(id AS VARCHAR) = '12345'` causes Trino to pull the entire table and apply the cast + filter in-memory. The query returns correct results but is catastrophically slow on large tables. Fix: use correctly-typed literals: `WHERE id = 12345` (no cast, no quotes).

### 3. ILIKE (Case-Insensitive Pattern Matching)

Not documented as supported in OSS Trino 467. Behavior is undefined and may change across versions. Always verify with EXPLAIN before relying on it, and re-verify after Trino upgrades.

---

## What to Do When a Predicate Won't Push Down

**Option 1: Rewrite the predicate to use supported forms**
```sql
-- DON'T: LIKE on string column (does not push)
WHERE email LIKE 'customer%';

-- DO: equality on a denormalized column (pushes cleanly)
WHERE email_prefix = 'customer';  -- after adding generated column in Postgres
```

**Option 2: Push down a more selective predicate to narrow scope first**
```sql
-- Let the date filter push down first (1/365 of the table), then apply LIKE in-memory on the small result
WHERE event_date = DATE '2026-05-01'   -- pushes down (selective, indexed)
  AND email LIKE 'alice%';             -- filtered in Trino on the ~5K matching rows
```

**Option 3: Enable experimental string range pushdown (carefully)**
```sql
-- Per-session test (no restart needed):
SET SESSION app_pg.enable_string_pushdown_with_collate = true;
EXPLAIN (TYPE DISTRIBUTED) SELECT ... WHERE name > 'M';  -- verify it pushed
```

**Option 4: Ingest the Postgres table into Iceberg (long-term)**
```sql
-- Run as a scheduled Spark/dbt job
CREATE OR REPLACE TABLE iceberg.analytics.accounts AS
SELECT * FROM app_pg.public.accounts;
```
Then join against Iceberg where all complex predicates work natively with columnar scan + partition pruning.

---

## Your Specific Use Case

Your WHERE clause is **ideal for pushdown**:
```sql
WHERE tenant_id = '...'                              -- UUID equality ✓
  AND created_at >= TIMESTAMP '2026-05-01 00:00:00' -- timestamp range ✓
```

To confirm on your exact query:
1. Run `EXPLAIN (TYPE DISTRIBUTED)` and confirm `constraint on [tenant_id, created_at]` appears under the Postgres TableScan.
2. Run `EXPLAIN ANALYZE` and confirm `Filtered:` shows a non-zero percentage and `Input:` shows a small result set.
3. (Optional) Tail the Postgres slow log and confirm the WHERE clause appears verbatim.

If all three check out, Postgres is applying your predicates with indexes, and Trino is receiving only matching rows over JDBC.
