# Iter 178 Q1 — Schema Evolution in Federated Postgres Views: Caching, Errors, and View Lifecycle

## Answer

Your experience — some dashboards failing with hard errors while others silently drop data — is exactly what happens with stale metadata caches in federated views. Two completely different failure modes are at play.

---

### How Trino's PostgreSQL Connector Caches Metadata

By default, **Trino's PostgreSQL connector does NOT cache schema metadata**. Every query that touches a Postgres table asks Postgres for a fresh column list. However, if your cluster has enabled `metadata.cache-ttl` in the catalog properties file, Trino caches the column list in memory for the TTL window:

```properties
# In etc/catalog/billing_pg.properties

# Default: 0s (caching disabled — every query gets fresh metadata)
metadata.cache-ttl=60s

# Also cache "table not found" responses for the same TTL
metadata.cache-missing=true
```

When `metadata.cache-ttl > 0`, Trino holds onto the column list for that duration. If someone renames or adds a column on the Postgres side, Trino won't know until the TTL expires or you manually flush.

**The cache is in-memory on the Trino coordinator** — not on disk. There are no "cache files" to delete; the cache lives in the JVM heap.

---

### Two Failure Modes: Silent vs Hard

**Silent data loss: `ADD COLUMN` + `SELECT *` view**

If your view uses `SELECT *`:
```sql
CREATE VIEW analytics.invoices_with_events AS
SELECT * FROM billing_pg.invoices
JOIN events_iceberg.usage_events USING (invoice_id);
```

When a new column `region` is added to `billing_pg.invoices`:
1. Trino's planner expands `SELECT *` using the **cached** column list (old 5 columns).
2. Trino sends `SELECT id, amount, created_at, status, currency FROM invoices` to Postgres.
3. Postgres returns those 5 columns. **No error. No warning.** The new `region` column is invisible.
4. Dashboards silently lose the new column — aggregates on `region` show 100% NULL.

No exception is raised because Postgres successfully returned the requested columns. Only the data is wrong.

**Hard errors: `RENAME COLUMN` or `DROP COLUMN`**

If your view explicitly references a now-renamed column:
```sql
CREATE VIEW v AS SELECT plan_type, COUNT(*) FROM app_pg.public.accounts GROUP BY plan_type;
```

After `ALTER TABLE accounts RENAME COLUMN plan_type TO plan_tier`:
1. Trino compiles against the cached schema, sees `plan_type` exists, sends that to Postgres.
2. Postgres returns: `ERROR: column "plan_type" does not exist`
3. Trino propagates this as a hard error — the dashboard fails completely on every refresh.

---

### Four-Step Runbook After a Schema Change

**Step 1: Check whether caching is enabled**

```bash
cat /etc/trino/catalog/billing_pg.properties | grep metadata.cache
```

If `metadata.cache-ttl` is absent or `0s`, the cache is not your problem — investigate something else. If it's > 0, proceed.

**Step 2: Flush the metadata cache immediately**

**CRITICAL**: The PostgreSQL connector's `flush_metadata_cache` procedure is **parameterless**. Named arguments `schema_name`/`table_name` work only on Hive and Delta Lake connectors — NOT on PostgreSQL. To scope the flush, use `USE` first:

```sql
-- Flush the entire catalog's cache
CALL billing_pg.system.flush_metadata_cache();

-- OR scope by schema with USE:
USE billing_pg.public;
CALL system.flush_metadata_cache();
```

Run this once. The flush is cluster-wide for that catalog. **No pod restart required.**

**Step 3: Find and update all affected views**

Views don't update themselves. Search for views referencing the old column:

```sql
SELECT table_schema, table_name, view_definition
FROM billing_pg.information_schema.views
WHERE view_definition LIKE '%plan_type%';  -- old column name

SELECT table_schema, table_name, view_definition
FROM analytics.information_schema.views
WHERE view_definition LIKE '%plan_type%';
```

Rewrite each view with the new column name using explicit column lists (never `SELECT *`):

```sql
CREATE OR REPLACE VIEW analytics.invoices_summary AS
SELECT
  i.id,
  i.amount,
  i.plan_tier,       -- renamed column
  i.currency,
  COUNT(*) AS event_count
FROM billing_pg.invoices i
JOIN events_iceberg.usage_events e USING (invoice_id)
GROUP BY i.id, i.amount, i.plan_tier, i.currency;
```

**Use `CREATE OR REPLACE VIEW`** — it's atomic (the view never briefly disappears) and preserves existing GRANTs on the view.

**Step 4: Verify the view works and check SECURITY mode**

Trino views have two SECURITY modes:

| Mode | Behavior | Best for |
|---|---|---|
| `SECURITY DEFINER` (default) | View body runs with view owner's grants. Callers only need SELECT on the view. | Tenant isolation — analysts can't access Postgres tables directly |
| `SECURITY INVOKER` | View body runs with calling user's grants. Callers need SELECT on base tables. | Trusted analysts who already have base-table grants |

**Critical leak with DEFINER + SELECT \***: every column added to the Postgres table becomes accessible to every analyst who can query the view — no code change needed. If Postgres gets a new `ssn` or `payment_token` column, it's immediately exposed.

**Defense**: always use an explicit column list in views.

---

### Best Practices for Schema Evolution in Federated Views

**1. Never use `SELECT *` in views**
```sql
-- WRONG — hides schema changes and exposes new sensitive columns
CREATE VIEW v AS SELECT * FROM app_pg.public.accounts;

-- RIGHT — explicit contract; schema changes are intentional
CREATE VIEW v AS SELECT id, name, account_tier FROM app_pg.public.accounts;
```

**2. Disable caching if Postgres schema evolves frequently**

If your team runs weekly Postgres migrations, set `metadata.cache-ttl=0s`. The metadata query overhead is cheap (~10 ms per query at planning time, not per row).

**3. Monitor for both failure modes separately**

- Hard errors (rename/drop): Alert on Trino query failures with JDBC error codes; Postgres slow logs show `column "..." does not exist`.
- Silent data loss (ADD COLUMN + SELECT *): NULL-rate alerts on downstream aggregates; periodically compare `information_schema.columns` between Postgres and what Trino sees.

**4. Codify view dependencies in version control**

Keep view definitions in a dbt project or SQL migration framework. When a Postgres schema change is planned, find all affected views before deploying the Postgres ALTER, and update them in the same PR. Test in staging before production.

**5. Deploy Postgres migrations and view updates together**

1. Find views referencing the old column (Step 3 above).
2. Update them alongside the Postgres migration.
3. Test in staging.
4. Deploy: run the Postgres ALTER, then immediately run `CALL system.flush_metadata_cache()` and `CREATE OR REPLACE VIEW` for each affected view.
