# Iter276 Q1 — ILIKE Pushdown to Postgres: Conditional, Not Categorical

## Answer

Your intuition is correct — the slowdown is likely because `ILIKE` is not pushing down to Postgres by default. Here's how ILIKE pushdown actually works in Trino, how to verify it, and how to fix it.

### 1. Does Trino Push ILIKE to Postgres?

**No, not by default — but it CAN, conditionally.**

ILIKE pushdown to the PostgreSQL connector was added via Trino PR #11045 and is available in Trino 467, but it does not activate automatically. Whether your `ILIKE` predicate reaches Postgres depends on two conditions:

1. **A session or catalog property must be explicitly enabled** — with the default `false`, Trino pulls rows over JDBC and evaluates the case-insensitive match in-memory on Trino workers after the fetch.

2. **The Postgres column's collation must be compatible** — columns using standard collations like `C`, `POSIX`, or `en_US.UTF-8` typically allow pushdown. Columns with custom ICU or locale-aware collations may suppress it even with the flag enabled.

Without both conditions met, Trino does the filter locally — pulling your full table or a large subset, then filtering post-fetch.

### 2. Configuration: How to Enable ILIKE Pushdown

**Option A: Test per-query (no restart needed)**
```sql
SET SESSION app_pg.enable_string_pushdown_with_collate = true;

SELECT * FROM app_pg.public.accounts WHERE name ILIKE '%corp%';
```

**Option B: Enable cluster-wide (requires coordinator restart)**

In `etc/catalog/app_pg.properties`:
```properties
postgresql.experimental.enable-string-pushdown-with-collate=true
```

Test the session-level option first before restarting the coordinator.

### 3. Verifying with EXPLAIN

**Pushdown FAILED (what you likely see now):**
```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.accounts WHERE name ILIKE '%corp%';
```
```
ScanFilterProject[filterPredicate=(name ILIKE '%corp%')]
  └─ TableScan[table=app_pg:public.accounts]
```
The predicate sits in a `ScanFilterProject` node **above** the scan — Trino fetches rows first, then filters locally.

**Pushdown SUCCEEDED (what you want):**
```
TableScan[table=app_pg:public.accounts, constraint=(name ILIKE '%corp%'), ...]
```
The predicate disappears from the plan tree and becomes embedded in the scan's `constraint` field. Postgres receives and applies the filter server-side.

**EXPLAIN ANALYZE for runtime confirmation:**
```sql
SET SESSION app_pg.enable_string_pushdown_with_collate = true;
EXPLAIN ANALYZE
SELECT * FROM app_pg.public.accounts WHERE name ILIKE '%corp%';
```
If pushdown worked, `Input` and `Output` row counts on the TableScan should be approximately equal. If `Input >> Output`, Trino filtered locally — pushdown failed.

### 4. Plan Shape Summary

| Scenario | EXPLAIN shape | What happens at runtime |
|---|---|---|
| ILIKE does NOT push (default) | `ScanFilterProject` above `TableScan` | Trino issues `SELECT *` to Postgres, pulls all rows, filters in Trino worker memory |
| ILIKE DOES push | `TableScan` with `constraint=(name ILIKE '...')` | Postgres applies filter server-side; only matching rows return over JDBC |

### 5. Practical Advice for Your Search Bar

**Short term — test the flag:**
```sql
SET SESSION app_pg.enable_string_pushdown_with_collate = true;

EXPLAIN (TYPE DISTRIBUTED)
SELECT id, name FROM app_pg.public.accounts WHERE name ILIKE '%corp%';
```
If the predicate moves into the `TableScan` constraint, the flag worked.

**If the flag doesn't help** (incompatible column collation):

Option 1 — Denormalized lower column with index (production-recommended):
```sql
-- In Postgres (one-time setup):
ALTER TABLE accounts ADD COLUMN name_lower TEXT GENERATED ALWAYS AS (lower(name)) STORED;
CREATE INDEX idx_accounts_name_lower ON accounts(name_lower);
```
Then query via Trino:
```sql
SELECT * FROM app_pg.public.accounts WHERE name_lower LIKE '%corp%';
```
Equality and LIKE comparisons on a regular indexed column always push — no flags, no collation concerns.

Option 2 — system.query() passthrough (escape hatch):
```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, name FROM accounts WHERE name ILIKE ''%corp%'''
  )
);
```
This works but bypasses Trino's optimizer — use it only when standard approaches fail.

**The core rule**: Never assume ILIKE pushes or doesn't push — always verify with `EXPLAIN` after enabling the flag. Behavior is conditional on session property + column collation.
