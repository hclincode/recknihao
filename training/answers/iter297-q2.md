# Answer to Q2: Joining Live Postgres Customer Table Against Analytics Data

## Short answer

Yes, Trino can query Postgres directly in the same SQL statement as your Iceberg event data. It is practical and fast enough for production dashboards — but only if you follow three critical rules: query your Postgres **read replica** (never the primary), ensure at least one side of the join is filtered small, and let dynamic filtering do its work (it's on by default). Skip any of these and the query will be slow or cause an outage.

## The mechanism: Trino's PostgreSQL connector

Trino has a built-in PostgreSQL connector that makes your Postgres tables appear inside Trino alongside your Iceberg tables. Once configured, you write a single SQL statement:

```sql
SELECT
  e.event_id,
  e.event_type,
  e.occurred_at,
  c.plan_tier,
  c.region
FROM iceberg.analytics.events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
WHERE e.occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
  AND c.plan_tier = 'enterprise';
```

Trino executes this by:
1. Scanning the Iceberg event table with your date filter → Iceberg partition pruning skips files outside the range on MinIO.
2. Scanning the Postgres customers table with your `plan_tier` filter → pushed down to Postgres as a SQL WHERE clause.
3. Joining the results on Trino workers.

The customer table is read **live from Postgres every time**. Plan upgrades appear immediately — no more 24-hour-old CSV.

## Why it's fast enough (three mechanisms)

### 1. Predicate pushdown
Your `WHERE c.plan_tier = 'enterprise'` filter does not cause Trino to pull the entire customers table. Trino rewrites it into a SQL WHERE clause and sends it to Postgres. Postgres applies the filter server-side and returns only matching rows.

### 2. Dynamic filtering
After reading the Iceberg events, Trino derives the set of customer IDs that actually appeared in those events. It pushes that list back to the Postgres scan as `WHERE id IN (...)`. This prevents Postgres from returning rows for customers with no events in your date range. Dynamic filtering is on by default and is the key lever that makes cross-catalog joins fast.

### 3. Join on Trino workers
The join itself runs on Trino, not in Postgres. Both sides ship their filtered rows to Trino for a hash join in memory. Because both sides are already filtered small (partition pruning on Iceberg + predicate pushdown + dynamic filtering on Postgres), the join is efficient.

## Critical rule 1: Read replica only, never the primary

This is non-negotiable. Trino 467 has no JDBC connection pooling — each Postgres table scan opens exactly one JDBC connection that stays open for the entire query duration. With 20 concurrent dashboard queries each joining the customers table, you get 20 simultaneous connections on your Postgres primary. A slow scan can hold a connection long enough to bloat tables, starve your replication pipeline, or saturate connection slots and block your application's own queries.

**Solution:** Configure the connector to point at a dedicated read replica. Isolate Trino traffic from your OLTP workload entirely.

## Critical rule 2: Filter at least one side small

**Fast (do this):**
```sql
-- Recent 1-day window + active enterprise customers only
FROM iceberg.analytics.events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
WHERE e.occurred_at >= CURRENT_DATE - INTERVAL '1' DAY
  AND c.plan_tier = 'enterprise' AND c.status = 'active'
```
- Iceberg side: ~10M events after partition pruning
- Postgres side: ~500 customers after filter
- Result: fast join

**Slow (avoid):**
```sql
-- No filters
FROM iceberg.analytics.events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
```
- Iceberg side: full 500M-row scan
- Postgres side: all 10M customers
- Result: 10+ minutes, Postgres replica under stress

The rule: at least one side of the join must reduce to tens of thousands of rows or fewer.

## How to set it up

Create `etc/catalog/app_pg.properties` on your Trino coordinator and workers:

```properties
connector.name=postgresql

# Point at your READ REPLICA — never the primary
connection-url=jdbc:postgresql://postgres-replica.internal:5432/appdb
connection-user=${ENV:POSTGRES_USER}
connection-password=${ENV:POSTGRES_PASSWORD}
```

Restart Trino. Verify the connector works:

```sql
SHOW CATALOGS;
SELECT * FROM app_pg.public.customers LIMIT 1;
```

Then write your dashboard query as above — it will work immediately.

## Caching the join for high-frequency dashboards

If this join runs 100+ times per day, consider materializing it hourly into an Iceberg table to reduce Postgres load:

```sql
-- Run hourly via Spark or dbt
INSERT INTO iceberg.analytics.events_with_customer
SELECT e.*, c.plan_tier, c.region
FROM iceberg.analytics.events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
WHERE e.occurred_at >= CURRENT_TIMESTAMP - INTERVAL '1' HOUR;
```

Then dashboards query the Iceberg table (fast, zero Postgres load, 1-hour freshness). Use live federation when you need current-second accuracy; use the materialized table for dashboard throughput.

## Things to watch

1. **Connection saturation**: monitor Postgres connection count. Use Trino resource groups to cap concurrent dashboard queries.
2. **Replica lag**: if the replica falls behind, dashboards see stale customers. Monitor WAL lag and set `statement_timeout` on the replica to kill runaway Trino queries.
3. **Forgetting the filter**: if a query runs `SELECT * FROM app_pg.public.customers` with no WHERE clause, Trino pulls all rows over the network every time. Always include at least one selective filter on the Postgres side.

## Bottom line

Trino's PostgreSQL connector replaces your nightly CSV dump with a live connection. Follow three rules: read replica only, filter at least one side small, let dynamic filtering run. Do those three things and a typical "recent events joined to current customers" query runs in seconds.
