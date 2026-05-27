# Iter 189 Q2 — Trino Views Over Federated Postgres Tables

## Answer

## Yes, Trino views over Postgres-backed tables absolutely work. Here's what actually happens.

### 1. Creating views over Postgres tables works exactly as you'd expect

When you run:

```sql
CREATE VIEW my_dashboard_view AS
SELECT u.id, u.email, u.plan_type
FROM app_pg.public.users u
WHERE u.status = 'active';
```

Trino stores this view definition in its metastore (Hive Metastore). The view itself lives in **Trino's catalog** (e.g., in `analytics` or whatever your Trino catalog is), not in Postgres. Your dashboard code can then query it just like any other Trino table:

```sql
SELECT * FROM analytics.my_dashboard_view WHERE plan_type = 'enterprise';
```

This is a real, working pattern and it's widely used in production.

### 2. Predicate pushdown still applies—with important nuances

This is the critical part because your WHERE clauses don't necessarily behave the way you might expect.

**The short answer:** When someone queries your view with an additional WHERE clause, Trino **combines that filter with the view's original WHERE** and tries to push the combined predicate down to Postgres. For eligible predicates (equality on numeric columns, string equality, ranges on dates/timestamps, `IS NULL`, etc.), this works and Postgres filters server-side—only matching rows come back over JDBC.

**Example of what works (pushes down):**

```sql
-- View definition:
CREATE VIEW user_view AS
SELECT id, email, plan_type, created_at
FROM app_pg.public.users;

-- Dashboard queries the view:
SELECT * FROM user_view
WHERE plan_type = 'enterprise'  -- string equality pushes down
  AND created_at > TIMESTAMP '2026-05-01 00:00:00';  -- timestamp range pushes down
```

Both predicates push to Postgres as a combined `WHERE plan_type = 'enterprise' AND created_at > ...`. Postgres uses indexes and returns only matching rows.

**Example of what doesn't work (pulls full table to Trino):**

```sql
SELECT * FROM user_view
WHERE LOWER(email) = 'foo@example.com';  -- function call on column
```

The `LOWER()` function-on-column is **not on the pushdown list**. Trino fetches all rows from Postgres and applies `LOWER()` in-memory on Trino workers. For a million-row table, this is catastrophic.

**The table of what pushes down:**

| Predicate | Pushes down? | Example |
|---|---|---|
| Equality on any numeric column | YES | `WHERE id = 12345` |
| Range on numbers, dates, timestamps | YES | `WHERE created_at >= TIMESTAMP '2026-05-01'` |
| String equality | YES | `WHERE status = 'active'` |
| `IN` lists (numeric, UUID, string) | YES | `WHERE id IN (1, 2, 3)` |
| `IS NULL` / `IS NOT NULL` | YES | `WHERE deleted_at IS NULL` |
| String ranges (`LIKE`, `>`, `<` on VARCHAR) | NO by default | `WHERE email LIKE 'a%'` — needs `postgresql.experimental.enable-string-pushdown-with-collate=true` |
| Function calls on columns | NO | `WHERE LOWER(email) = 'foo'` — Trino filters in-memory |

**Verify pushdown actually happens** with:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM user_view WHERE plan_type = 'enterprise';
```

Look for `constraint on [columns]` under the `TableScan` node — if the predicate appears there, pushdown succeeded. If you see a `ScanFilterProject` or `Filter` node **above** the `TableScan`, pushdown failed and Trino is filtering in-memory.

### 3. Schema changes in Postgres are NOT automatically reflected in the view

This is the gotcha that catches most teams. When someone adds or drops a column in Postgres, **the Trino view does not magically know about it**. Here's why and how to handle it:

**The problem: frozen column schema**

When you create a Trino view, the view definition (SQL text) and the **resolved column list** are stored together in Trino's metastore at creation time. If your view uses `SELECT *`:

```sql
CREATE VIEW accounts_view AS SELECT * FROM app_pg.public.accounts;
```

Trino expands `SELECT *` to an explicit list of columns **at creation time** — say, `id, name, plan_type, created_at, status`. This list is **frozen**. If Postgres later runs `ALTER TABLE accounts ADD COLUMN region VARCHAR(64)`, the view still only knows about the original 5 columns. The `region` column is silently invisible to every query through the view.

**This is silent data loss**, not an error — the query succeeds, but the new column is missing from the result set.

**The fix: always use explicit column lists and re-deploy views after schema changes**

Step 1 — Flush the metadata cache so Trino sees the new Postgres schema:

```sql
CALL app_pg.system.flush_metadata_cache();
```

(Note: this is **parameterless** on PostgreSQL connector. Do not pass schema/table names — that syntax only works on Hive/Delta connectors.)

Step 2 — Find affected views by searching your Trino-native catalogs (not the Postgres catalog):

```sql
SELECT table_catalog, table_schema, table_name, view_definition
FROM analytics.information_schema.views
WHERE view_definition LIKE '%plan_type%'
   OR view_definition LIKE '%accounts%';
```

(Important: search `analytics.information_schema.views`, NOT `app_pg.information_schema.views` — the latter is Postgres's own views, not Trino views.)

Step 3 — Rewrite the view with an explicit column list and `CREATE OR REPLACE VIEW`:

```sql
CREATE OR REPLACE VIEW analytics.accounts_view AS
SELECT
  id,
  name,
  plan_type,
  region,  -- now explicitly listed
  created_at,
  status
FROM app_pg.public.accounts;
```

This rewrites the view definition AND the frozen column schema atomically in Trino's metastore. Existing GRANTs are preserved.

Step 4 — Choose a SECURITY mode deliberately:

```sql
CREATE OR REPLACE VIEW analytics.accounts_view
SECURITY INVOKER  -- or SECURITY DEFINER (default)
AS
SELECT ...
```

- **`SECURITY DEFINER` (default)**: the view executes with the view owner's Postgres access grants. A new column added to `accounts` automatically becomes visible to all view users. Risk: sensitive new columns (`ssn`, `payment_token`) leak silently.
- **`SECURITY INVOKER`**: the view executes with the querying user's own Postgres grants. Safer for sensitive tables; requires analysts to have direct base-table access.

### 4. Operational runbook for schema drift

When a Postgres schema change breaks Trino queries (or is about to):

1. **Check your metadata cache TTL** in the Postgres catalog properties. If `metadata.cache-ttl=0s`, caching is off and this section doesn't apply. If it's `60s` or higher, proceed.

2. **Flush the cache immediately:**
   ```sql
   CALL app_pg.system.flush_metadata_cache();
   ```
   No pod restart needed; this is cluster-wide. The next query sees the new Postgres schema.

3. **Find all affected Trino views** (search your Trino-native catalogs, not the Postgres catalog).

4. **Re-deploy views with explicit column lists** using `CREATE OR REPLACE VIEW`. This is the only way to update a view's frozen column schema.

5. **Coordinate with dashboard/dbt owners.** Flushing the cache doesn't fix their saved queries or dbt models — those still reference the old column names.

6. **Monitor for two failure modes:**
   - **Hard error (RENAME or DROP COLUMN with explicit reference):** Trino queries fail immediately with `PSQLException: column "..." does not exist`. Error-rate alerts catch this.
   - **Silent data loss (ADD COLUMN + `SELECT *` view):** No error, but the new column is missing from view results. This requires cardinality anomaly detection or schema-drift CI checks to catch.

### In your production environment

Your on-prem Kubernetes setup with Trino 467 and Hive Metastore has a few specific considerations:

- **Authentication:** Your JWT-based auth flows through to Postgres via the Trino connector. The Postgres connector reads from a Postgres read replica (never the OLTP primary — federation queries can hold long transactions).
- **Connection pooling:** OSS Trino 467 has **no native connection pooling** for the Postgres connector. Use PgBouncer in front of Postgres or set a role-level `CONNECTION LIMIT` on the `trino_reader` role.
- **Metadata caching:** You probably have `metadata.cache-ttl=60s` or similar set to reduce repeated catalog queries. That means schema-change flushes are mandatory (step 2 above) — without them, views serve stale schema for up to 60 seconds.

The views-over-Postgres pattern is solid for read-only dashboards. The keys are: (1) always use explicit column lists, (2) flush the metadata cache immediately after Postgres DDL, and (3) re-deploy views to update their frozen column schema. Do that and your dashboard code stays stable.
