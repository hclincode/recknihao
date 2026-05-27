# Iter 176 Q2 — Writing Back to Postgres Through Trino (INSERT/UPDATE Gotchas)

## Answer

**Short answer:** Yes, your exact query will technically work — but **you should not do it on a live OLTP database**, and there are sharp limitations you need to understand before trying it in production.

---

### What Actually Works

The Trino PostgreSQL connector supports `INSERT`, `UPDATE`, `DELETE`, `CREATE TABLE`, and `DROP TABLE`. So a query like this:

```sql
UPDATE billing_pg.public.orders
SET status = 'processed'
WHERE id IN (SELECT id FROM iceberg.analytics.results)
```

**will parse and execute without syntax errors.** The connector translates it to a JDBC call, sends it to Postgres, and if everything is configured correctly, your Postgres table gets updated.

---

### The Critical Gotcha: UPDATE Only Works with Constants

**Trino 467's PostgreSQL connector only supports UPDATE with constant assignments.** You cannot reference the column being updated, another column, or any expression on the right-hand side of `SET`.

**These WORK** (constant literals only):
```sql
UPDATE billing_pg.public.orders SET status = 'inactive' WHERE id = 42;
UPDATE billing_pg.public.orders SET score = 0.95 WHERE id = 42;
```

**These FAIL** (expressions, self-references, or functions):
```sql
-- FAILS: self-reference
UPDATE billing_pg.public.orders SET event_count = event_count + 1 WHERE id = 42;

-- FAILS: another column reference
UPDATE billing_pg.public.orders SET display_name = full_name WHERE id = 42;

-- FAILS: function call
UPDATE billing_pg.public.orders SET email = LOWER(email) WHERE id = 42;
```

Your example (`SET status = 'processed'`) IS a constant assignment, so it **will work** at the connector level.

---

### Your OPA Policy Probably Blocks This Already

**This is the gotcha that will likely stop you before the technical limitations do.**

Your production stack uses OPA for authorization. The conventional policy is:

- `iceberg.*` catalog: read-write to ETL roles
- `app_pg.*` / `billing_pg.*` catalogs: **read-only to ALL roles** (including admins)

OPA can deny all DML operations (`INSERT` / `UPDATE` / `DELETE`) against the `billing_pg` catalog at the policy layer, even if the connector technically supports them. The write is rejected **before it ever reaches Postgres**, with:

```
Access Denied: action UPDATE not allowed on catalog billing_pg
```

**Check your cluster's OPA policy before attempting any write.** If the policy blocks DML, go talk to your platform team — the policy exists on purpose.

---

### Other Limitations

**DELETE also requires pushdownable predicates.** Simple predicates on indexed columns work:

```sql
DELETE FROM billing_pg.public.orders
WHERE created_at < TIMESTAMP '2026-05-01 00:00:00'
```

Cross-catalog subquery predicates may fail depending on pushdown rules. Before attempting any DELETE, run the equivalent SELECT first to verify row count:

```sql
SELECT COUNT(*) FROM billing_pg.public.orders
WHERE id IN (SELECT id FROM iceberg.analytics.results)
```

If the SELECT works and returns the expected count, the DELETE should succeed.

---

### Why You Shouldn't Write Back (Even If You Can)

The federation connector is intended for **read traffic only**. Writing from Trino bypasses:

1. **Application validation logic** — your app may have constraints (e.g., status can only transition `pending → processed`, not `submitted → processed` directly).
2. **Audit trails and triggers** — Postgres triggers, stored procedures, and application-level audit logging won't fire.
3. **Connection pooling** — you're using Trino's shared read connection to Postgres, not the application's own authenticated write pool.

**The right pattern:** If your SaaS app identifies records needing status updates, have **the application itself issue the UPDATE** through its normal write path. Let Trino stay in the analytics layer.

---

### The One Acceptable Write Pattern: CTAS to Iceberg

The write pattern that IS commonly used through Trino is **CREATE TABLE AS SELECT** to materialize Postgres data into Iceberg for repeated analytical use:

```sql
CREATE TABLE iceberg.analytics.orders_snapshot
WITH (
    partitioning = ARRAY['bucket(tenant_id, 16)'],
    format = 'PARQUET'
) AS
SELECT id, tenant_id, status, created_at
FROM billing_pg.public.orders
WHERE status = 'processed';
```

This reads from Postgres (with predicate pushdown) and writes into Iceberg on MinIO — the analytics layer, not the operational database. Generally acceptable because it's a one-shot materialization, not an ongoing write pattern.

**Caveat:** For very large tables (8M+ rows), avoid CTAS from Trino — use a dedicated Spark job with checkpointing and idempotent commit semantics. If CTAS fails halfway, you start over from scratch and leave orphan files on MinIO.

---

### Checklist Before Trying This in Production

1. **Check your OPA policy.** Verify that DML operations are NOT blocked on `billing_pg.*`. If they are, stop here.

2. **Verify the WHERE predicate pushes down.** Run the equivalent SELECT first to confirm it works and returns the row count you expect.

3. **Confirm UPDATE only uses constant assignments.** If you need `SET column = expression`, run it through Postgres directly instead.

4. **Confirm you're not hitting a read replica.** Your federation catalog should point at a read replica — that replica typically doesn't accept writes. Make sure you're pointed at the primary if write-back is actually needed.

5. **Test on a non-production table first.** Create a test table in Postgres, run the UPDATE through Trino, verify the results.

6. **Monitor Postgres connection usage.** Each write still consumes a JDBC connection. Monitor for "too many connections" errors, especially if you run multiple concurrent write queries through Trino.
