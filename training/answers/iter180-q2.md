# Iter 180 Q2 — Joining Two Postgres Catalogs in a Single Trino Query

## Answer

**Yes, your query works exactly as written.** You can join across two separate PostgreSQL catalogs in a single Trino statement. But "works" and "works well in production" are different questions — here are the gotchas.

---

### The Query Works — Here's the Correct Syntax

```sql
SELECT
  s.subscription_id,
  s.plan_type,
  u.email
FROM billing_pg.public.subscriptions s
JOIN app_pg.public.users u ON s.user_id = u.id
WHERE s.active = true;
```

Trino treats `billing_pg` and `app_pg` as separate catalogs, each with its own Postgres connection config. You can join across them freely in a single SQL statement — this is core Trino federation.

---

### Connection Model: Two Separate JDBC Connections

When Trino executes this query, it opens one JDBC connection per catalog:
- One connection to your billing Postgres replica (for `subscriptions`)
- One connection to your app Postgres replica (for `users`)

**The join itself executes on Trino workers, not inside either Postgres.** Each Postgres database only sees its own table scan — neither sees the join predicate.

Connections scale with concurrent queries × catalogs touched. 10 concurrent queries each joining two Postgres catalogs = 20 simultaneous JDBC connections. For non-partitioned tables, each table scan is one split → one connection.

---

### Critical Gotcha: OSS Trino 467 Has No Native Connection Pooling

**OSS Trino 467's PostgreSQL connector has NO built-in JDBC connection pooling.** Properties like `connection-pool.enabled` and `connection-pool.max-size` that appear in some documentation do not exist — they belong to Starburst Enterprise. Trino silently ignores them.

This means every JDBC connection is a raw socket held open for the full query duration. 10 concurrent cross-catalog joins = 20+ open sockets.

**The solution: PgBouncer in front of each Postgres replica** in transaction-pooling mode. Point your Trino catalog at PgBouncer instead of Postgres directly:

```properties
# etc/catalog/billing_pg.properties
connector.name=postgresql
connection-url=jdbc:postgresql://pgbouncer-billing.svc:6432/billing?prepareThreshold=0&defaultRowFetchSize=1000&socketTimeout=60
connection-user=${ENV:BILLING_PG_USER}
connection-password=${ENV:BILLING_PG_PASSWORD}
```

```properties
# etc/catalog/app_pg.properties
connector.name=postgresql
connection-url=jdbc:postgresql://pgbouncer-app.svc:6432/appdb?prepareThreshold=0&defaultRowFetchSize=1000&socketTimeout=60
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}
```

`prepareThreshold=0` is required for PgBouncer transaction-pooling mode — without it you'll get intermittent `prepared statement "S_1" does not exist` errors as prepared statements are routed to different backend connections.

---

### Memory: The Join Runs in Trino Worker Memory

Since the join crosses catalogs, Trino materializes the smaller side (build side) into a hash table in worker memory and streams the larger side (probe side) through it. For a join of a 5K-row users table with a 100M-row subscriptions table:
- The 5K users hash table is tiny — works fine
- If the build side is unexpectedly large (millions of rows), it spills to disk and the query slows 10–100×

Check your build-side table size and ensure `query.max-memory-per-node` is large enough to avoid spill.

---

### Predicates: Each Catalog Gets Its Own Filter, Join Stays in Trino

```sql
SELECT * FROM billing_pg.subscriptions s
JOIN app_pg.users u ON s.user_id = u.id
WHERE s.active = true        -- pushes to billing_pg
  AND u.status = 'active';   -- pushes to app_pg
```

Both `WHERE` clauses push down to their respective Postgres databases. The `JOIN ON s.user_id = u.id` stays in Trino — neither Postgres sees the join predicate.

**Dynamic filtering:** Trino can derive an IN-list of `user_id` values from the `users` scan and push it back to the `subscriptions` scan. If `users` is small and selective, this reduces the `subscriptions` scan dramatically. Check `dynamicFilterSplitsProcessed` in `EXPLAIN ANALYZE` to confirm it fired.

---

### Verify Pushdown with EXPLAIN

Before running in production, always verify your WHERE clauses are pushing down:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT s.subscription_id, u.email
FROM billing_pg.public.subscriptions s
JOIN app_pg.public.users u ON s.user_id = u.id
WHERE s.active = true AND u.status = 'active';
```

Look for `constraint on [active]` inside the `billing_pg` TableScan and `constraint on [status]` inside the `app_pg` TableScan. If you see `ScanFilterProject` above either TableScan, that filter is not pushing down — Trino is fetching all rows and filtering in-memory.

---

### Production Guardrails

1. **Read replicas only** — Never point Trino catalog at your OLTP primary. Each open JDBC connection holds a transaction slot and can block VACUUM.

2. **PgBouncer per replica** — Multiplex connections; set `default_pool_size = 50` per catalog.

3. **Postgres role connection limit** — `ALTER ROLE trino_reader CONNECTION LIMIT 50;` on each replica as defense-in-depth.

4. **Resource groups** — Set `hardConcurrencyLimit` in Trino resource groups to cap concurrent federation queries and prevent connection storms.

5. **Statement timeout on Postgres** — `ALTER ROLE trino_reader SET statement_timeout = 300000;` (5 min) to kill runaway queries on the replica.

---

### Summary

| Aspect | What Happens |
|---|---|
| Does the query work? | Yes — syntax is correct, runs normally |
| Connections | One JDBC connection per catalog per split (2 total for this query) |
| Pooling | OSS Trino 467 has no native pool — use PgBouncer in front of each replica |
| Join location | Trino workers, not Postgres — memory scales with build-side table size |
| WHERE predicates | Push to their respective catalogs independently |
| JOIN predicate | Stays in Trino; cannot be pushed to either Postgres |
| Dynamic filtering | Automatic; check `dynamicFilterSplitsProcessed` in EXPLAIN ANALYZE |
