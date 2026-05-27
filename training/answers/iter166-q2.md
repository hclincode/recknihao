# Iter 166 Q2 — Cross-Catalog CTAS: Postgres to Iceberg

## Answer

Yes, Trino can do exactly this in a single statement. You can use either `CREATE TABLE AS SELECT` (CTAS) or `INSERT INTO ... SELECT` to take query results spanning both the Postgres and Iceberg catalogs and materialize them as a new Iceberg table.

## The pattern

Here's what it looks like:

```sql
-- Create a new Iceberg table from a cross-catalog query
CREATE TABLE iceberg.analytics.user_activity_summary AS
SELECT 
    u.id,
    u.email,
    COUNT(e.event_id) AS event_count,
    MAX(e.event_time) AS latest_event
FROM app_pg.public.users u
JOIN iceberg.analytics.events e ON e.user_id = u.id
WHERE u.status = 'active'
  AND e.event_time > TIMESTAMP '2026-05-01 00:00:00'
GROUP BY u.id, u.email;
```

Or, if the table already exists and you just want to append results:

```sql
INSERT INTO iceberg.analytics.user_activity_summary
SELECT 
    u.id,
    u.email,
    COUNT(e.event_id) AS event_count,
    MAX(e.event_time) AS latest_event
FROM app_pg.public.users u
JOIN iceberg.analytics.events e ON e.user_id = u.id
WHERE u.status = 'active'
  AND e.event_time > TIMESTAMP '2026-05-01 00:00:00'
GROUP BY u.id, u.email;
```

## How it works

Trino handles the entire operation — reads from Postgres via the PostgreSQL connector, reads from Iceberg via the Iceberg connector, performs the joins and aggregations on Trino workers, and **writes the results directly to MinIO as a new Iceberg table**. It's all one statement; no application-side re-ingestion step is needed.

The result is immediately queryable from Trino without any additional setup.

## Important caveats

**1. HMS is required at commit time.** Both `CREATE TABLE AS SELECT` and `INSERT INTO ... SELECT` need Hive Metastore to register the new table (or update the existing one) at the end of the operation. If HMS is down, the SELECT part of the query completes, but the write commit fails.

**2. Make sure the Postgres side has a selective WHERE clause.** The same cross-catalog join performance rules apply here as for any federated query. If your Postgres tables are large, you need a selective filter on the Postgres side so dynamic filtering can work effectively. Without it, you'll pull unnecessarily large result sets over the network from Postgres and the query will be slow.

**3. Choose your table design carefully.** Decide:
   - **Partitioning**: if this is a fact table you'll query repeatedly, partition it by something like `day(created_at)` or `tenant_id` so future queries benefit from partition pruning.
   - **File size**: Trino will write the results as Parquet files; you can run compaction later with maintenance operations if needed.

**4. Schedule it or run ad-hoc as needed.** Since this is a single statement, you can:
   - Run it ad-hoc from your Trino CLI or DBeaver whenever you need a fresh materialization.
   - Wrap it in an Airflow DAG or Kubernetes CronJob and schedule it nightly / hourly to keep the results fresh.

## Compared to your current approach

Right now you're running the query and getting results back to the dashboard. With this pattern, you run it once, save the results as an Iceberg table, and then every subsequent dashboard query hits the cheap columnar Iceberg table instead of recomputing the join every time. For repeated dashboard queries, this is a significant win — you pay the Postgres + Iceberg join cost once at write time, not on every dashboard refresh.
