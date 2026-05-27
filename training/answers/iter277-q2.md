# Iter277 Q2 — Federate vs Ingest: 50M-Row Postgres Table at Scale

## Answer

At 50 million rows with high query frequency, you are well above the threshold to stop federating and ingest into Iceberg. Here is how to make that decision, execute the migration, and keep it fresh.

### 1. The Federate vs Ingest Decision

The decision is driven by observable production signals — not just row count:

| Signal | Action threshold |
|---|---|
| Postgres read-replica CPU | Sustained >70% attributable to Trino's JDBC queries |
| Query latency | Federated joins consistently >2s when dashboard SLO requires <500ms |
| Query frequency | Analytics joins against this table on every dashboard load |
| Freshness tolerance | Business can accept T-15min or T-1hour staleness |

Your situation checks the key boxes: 50M rows (well above "small dimension table" scale), high frequency joins on every analytics query, and Postgres facing both transactional writes and analytical read load simultaneously.

### 2. Why 50M Rows at High Frequency Warrants Ingestion

The JDBC connector runs as a single task — no parallelism, no splits. Trino's entire 20-worker cluster funnels reads through one JDBC connection to Postgres per query. At 50M rows, even a filtered scan returns millions of rows over that single connection. Your Postgres replica is doing analytical work (full scans, sort-merge joins) it wasn't designed for — work that would run in milliseconds on Iceberg running distributed across all workers.

Migrating to Iceberg removes the load entirely. Trino reads from object storage (MinIO/S3), not from Postgres. The join becomes a local parallel operation.

### 3. Initial Full Load into Iceberg

Use CTAS to snapshot the entire table:

```sql
CREATE TABLE iceberg.analytics.customers AS
SELECT
  account_id,
  plan_tier,
  region,
  signup_date,
  updated_at
FROM app_pg.public.customers;
```

This is a single federated read — it will put one last burst of load on Postgres, then you're done. At 50M rows, this takes a few minutes on a healthy cluster. The new Iceberg table is immediately queryable once CTAS commits.

If you need resume-from-failure guarantees (unstable cluster), use Spark with checkpointing instead of Trino CTAS.

### 4. Keeping It Fresh — Incremental MERGE INTO

For a customer metadata table (accounts change plan tier, region — UPDATEs are common), use MERGE INTO on a scheduled cadence:

```sql
MERGE INTO iceberg.analytics.customers AS t
USING (
  SELECT account_id, plan_tier, region, signup_date, updated_at
  FROM app_pg.public.customers
  WHERE updated_at > TIMESTAMP '2026-05-26 00:00:00'   -- from last run watermark
    AND updated_at <= TIMESTAMP '2026-05-27 00:00:00'  -- explicit upper bound
) AS s
ON t.account_id = s.account_id
WHEN MATCHED THEN UPDATE
  SET plan_tier = s.plan_tier, region = s.region, updated_at = s.updated_at
WHEN NOT MATCHED THEN INSERT (account_id, plan_tier, region, signup_date, updated_at)
  VALUES (s.account_id, s.plan_tier, s.region, s.signup_date, s.updated_at);
```

Key details:
- **Always use an explicit upper bound** — not `NOW()` inside the query. Let the scheduler compute window boundaries so retries are safe and idempotent.
- **MERGE handles both cases**: new customers (WHEN NOT MATCHED) and updated customers (WHEN MATCHED) in one atomic Iceberg commit.
- Track the watermark in an external metadata table or your scheduler (Airflow/dbt variable), so each run knows where the last one stopped.
- After heavy MERGE activity, run periodic compaction: `ALTER TABLE iceberg.analytics.customers EXECUTE optimize` to compact the positional delete files that accumulate.

### 5. What Changes After Ingestion

**Before (federated join):**
```sql
SELECT e.event_id, e.event_type, c.plan_tier, c.region
FROM iceberg.analytics.events e
JOIN app_pg.public.customers c ON e.account_id = c.account_id
WHERE e.event_date = DATE '2026-05-27';
```

**After (local join — no JDBC):**
```sql
SELECT e.event_id, e.event_type, c.plan_tier, c.region
FROM iceberg.analytics.events e
JOIN iceberg.analytics.customers c ON e.account_id = c.account_id
WHERE e.event_date = DATE '2026-05-27';
```

What changes:
- Zero JDBC connections from Trino to Postgres during analytics queries.
- `iceberg.analytics.customers` reads from MinIO/S3 in parallel across all Trino workers — no single-task bottleneck.
- Trino can predicate-prune and project-push into Iceberg the same way it does with your events table.
- Postgres replica is freed from analytical load — it only serves your application's transactional reads and writes.
- You gain Iceberg features: time travel (query yesterday's snapshot), snapshot history, compaction.

**Operational change:** Add the MERGE INTO job to your Airflow/dbt schedule. That job becomes your sole freshness responsibility — Trino no longer reaches into Postgres for analytics.

### 6. When You'd Still Federate at This Scale

- **Sub-minute freshness required**: If your SLO requires data <30 seconds stale and your MERGE runs every 5 minutes, federation may still be necessary. For a customer metadata table, this is rare.
- **Hybrid pattern**: Keep Iceberg for historical snapshots (updated hourly) and federate only the last 1 hour of changes via a UNION ALL view. For metadata tables, this is usually overkill.
- **One-off ad-hoc queries**: Exploratory queries from an analyst can still federate directly without setting up a MERGE pipeline.

### Your Action Plan

1. **CTAS** — snapshot the full 50M rows into `iceberg.analytics.customers` (one-time, last Postgres read burst).
2. **Update references** — change `app_pg.public.customers` to `iceberg.analytics.customers` in dashboards and views.
3. **Schedule MERGE INTO** — nightly or hourly refresh with watermark tracking.
4. **Plan compaction** — run `optimize` weekly (or daily for high-churn tables).
5. **Verify** — check `pg_stat_activity` on the Postgres replica to confirm Trino's user has no more active connections during analytics load.
