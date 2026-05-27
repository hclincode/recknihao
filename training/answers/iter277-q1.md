# Iter277 Q1 — LIKE/ILIKE Pushdown: Conditional Behavior and Diagnostics

## Answer

Your team is correct that string filters (LIKE/ILIKE) have conditional pushdown behavior in Trino with PostgreSQL — but the real story is more nuanced than "never push."

### 1. Does LIKE/ILIKE Push to Postgres?

**For LIKE (any pattern shape):**
- **Anchored prefix patterns** (`LIKE 'global%'`) may push down on PostgreSQL for standard-collation columns — behavior is collation-dependent. Non-default collation on the Postgres column, ICU collation, or `COLLATE` clauses in the query can suppress it.
- **Unanchored patterns** (`LIKE '%global%'`) effectively do not push usefully — even if the predicate reaches Postgres, it still scans every row. Postgres returns the entire table over JDBC, and Trino filters locally.

**For ILIKE (case-insensitive):**
- ILIKE does NOT push by default with Trino 467. It requires both:
  1. The session/catalog property `enable_string_pushdown_with_collate` enabled
  2. The Postgres column's collation to be compatible (standard C/en_US.UTF-8 typically works; custom or ICU collations may not)
- With the default `false`, ILIKE runs as in-memory filtering on Trino workers after JDBC fetch.

**The bottom line for your use case:** Unanchored patterns (`%global%`, `%corp%`) are the worst case — Postgres cannot use an index for these regardless of pushdown, so Trino pulls the full table either way. The pushdown optimization helps more for anchored patterns.

### 2. Enabling String Pushdown

**Session level (test first, no restart needed):**
```sql
SET SESSION app_pg.enable_string_pushdown_with_collate = true;
```

**Catalog level (persistent, requires coordinator restart):**
In `etc/catalog/app_pg.properties`:
```properties
postgresql.experimental.enable-string-pushdown-with-collate=true
```

**Correctness warning:** This flag emits a `COLLATE "C"` clause on pushed predicates. For standard C/POSIX-locale databases, this is correct. On ICU-collated columns (Postgres 12+ with ICU), the pushed predicate may match a different set of rows than Trino's in-memory evaluation — silent wrong results. Test on a non-production replica first.

### 3. Verifying with EXPLAIN

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.companies
WHERE name ILIKE '%global%';
```

**Pushdown FAILED** (what you likely see now):
```
ScanFilterProject[filterPredicate = (name ILIKE '%global%')]
    TableScan[table = app_pg:public.companies, ...]
```
A `ScanFilterProject` or `Filter` node sits **above** the `TableScan` — Trino fetches rows first, then filters locally.

**Pushdown SUCCEEDED:**
The `ScanFilterProject` node **disappears** from the plan tree. The `TableScan` becomes the topmost data-producing node. The exact textual format of the pushed constraint inside the TableScan varies by Trino version and connector — the official Trino docs only commit to "the `ScanFilterProject` disappears" as the success signal, not any specific format of the constraint block.

For runtime confirmation:
```sql
SET SESSION app_pg.enable_string_pushdown_with_collate = true;
EXPLAIN ANALYZE
SELECT * FROM app_pg.public.companies WHERE name ILIKE '%global%';
```
If `Input >> Output` row counts on the TableScan, the filter ran locally — pushdown failed.

### 4. The Success Signal

The canonical signal is: **the `ScanFilterProject` node disappears from the plan tree**. Do not rely on a specific textual format of the constraint inside TableScan — that format varies. The ground truth is the Postgres slow-query log: enable `log_min_duration_statement=0` temporarily and verify whether Postgres received a `WHERE name ILIKE ...` clause or a bare `SELECT ... FROM companies`.

### 5. Practical Recommendations for Your Search Bar

**Option 1 — Denormalized lowercase column with index (production-recommended):**
```sql
-- On Postgres (one-time setup):
ALTER TABLE companies ADD COLUMN name_lower TEXT GENERATED ALWAYS AS (lower(name)) STORED;
CREATE INDEX idx_companies_name_lower ON companies(name_lower);
```
Then query via Trino:
```sql
SELECT * FROM app_pg.public.companies
WHERE name_lower LIKE '%global%';
```
Equality and LIKE on a regular indexed column push cleanly — no experimental flags, no collation concerns.

**Option 2 — Pair the string filter with a selective date/ID predicate:**
```sql
SELECT * FROM app_pg.public.companies
WHERE created_at >= DATE '2026-05-01'   -- this pushes; reduces JDBC pull
  AND name LIKE '%global%';              -- Trino filters in-memory on smaller result
```
Postgres applies the date filter server-side, returning fewer rows over JDBC.

**Option 3 — Enable the flag and test:**
```sql
SET SESSION app_pg.enable_string_pushdown_with_collate = true;
EXPLAIN (TYPE DISTRIBUTED)
SELECT id, name FROM app_pg.public.companies WHERE name ILIKE '%global%';
```
If the `ScanFilterProject` disappears, the flag works. But for unanchored patterns, Postgres still scans all rows — the flag helps reduce network transfer but won't make the scan fast.

**Option 4 — Ingest companies table to Iceberg:**
If this search runs frequently on a large table, snapshot the companies table nightly into Iceberg. Trino can parallelize the scan across all workers and apply the filter without JDBC bottlenecks.

**Core rule:** Never assume LIKE/ILIKE pushes or doesn't — always verify with `EXPLAIN` after enabling the flag. Behavior is conditional on the session property, column collation, and pattern shape.
