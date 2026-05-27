# Iter269 Q1 — Copying Postgres Data into Iceberg with Trino: Incremental Loads and Partitioning

## Answer

Yes, `INSERT INTO iceberg_table SELECT * FROM postgres_table` works via Trino federation. But the real challenge is incremental loads and keeping the Iceberg table fast. Let me walk through the full picture.

### Basic Cross-Source INSERT

This works out of the box:

```sql
INSERT INTO iceberg.analytics.events
SELECT * FROM app_pg.public.events;
```

Trino reads from Postgres via the PostgreSQL connector and writes to Iceberg in one statement. Good for one-time bulk loads or small dimension tables.

### Why CTAS Is Wrong for Incremental Use

`CREATE TABLE AS SELECT` creates a **new table** every time — replacing the old one. You lose query history, snapshots, and partition structure. Use CTAS only for one-off initial loads or tables where a full nightly replace is acceptable. For fact tables, use INSERT with incremental filtering instead.

### Incremental Loads: The Watermark Pattern

Pull only rows changed since the last run:

```sql
-- Nightly incremental load: only rows updated since last run
INSERT INTO iceberg.analytics.events
SELECT *
FROM app_pg.public.events
WHERE updated_at > TIMESTAMP '2026-05-25 14:32:00';  -- last watermark
```

Store the watermark (last processed `updated_at`) in a config file or MinIO, and update it after each successful run.

**Safe idempotent variant** — overwrite the current day's partition rather than append (so re-runs don't duplicate):

```sql
-- Overwrite only today's partition — idempotent on re-run
INSERT INTO iceberg.analytics.events
SELECT *
FROM app_pg.public.events
WHERE date(updated_at) = CURRENT_DATE;
```

With Iceberg's `overwrite` mode, if the job fails and re-runs, it replaces the same partition with the same rows — no duplicates.

**Critical prerequisite**: index the watermark column in Postgres, or each incremental load causes a full table scan:

```sql
CREATE INDEX CONCURRENTLY idx_events_updated_at ON events (updated_at);
```

### Iceberg Table Design for Incremental Loads

Partition by date and tenant to keep nightly loads confined to a small number of partitions:

```sql
CREATE TABLE iceberg.analytics.events (
  event_id    VARCHAR,
  tenant_id   VARCHAR,
  occurred_at TIMESTAMP(6) WITH TIME ZONE,
  event_type  VARCHAR,
  payload     VARCHAR
)
WITH (
  partitioning = ARRAY['day(occurred_at)', 'tenant_id'],
  format = 'PARQUET'
);
```

Why this layout:
- **Daily partitions**: each nightly batch lands in exactly one date partition. Queries filtering by date range prune to only the days they need.
- **Tenant sub-partitions**: per-tenant dashboards prune to one tenant's files.
- **Iceberg hidden partitioning**: you write `WHERE occurred_at >= TIMESTAMP '2026-05-01'` — not `WHERE day = '2026-05-01'`. Iceberg maps your column filter to the right partition files automatically.

### The Small-Files Problem and Compaction

Nightly batch jobs create one Parquet file per partition per batch. After a month with 80 tenants: 80 × 30 = 2,400 small files. Trino pays overhead per file, making date-range queries slow.

**Fix: run `OPTIMIZE` after ingestion:**

```sql
ALTER TABLE iceberg.analytics.events
EXECUTE optimize(file_size_threshold => '256MB');
```

This merges small files within each partition into ~256 MB Parquet files. Run it nightly after ingestion finishes:

- 2 AM: ingestion job inserts new rows
- 4 AM: compaction with OPTIMIZE
- Weekly: expire old snapshots to free storage

```sql
-- Weekly snapshot cleanup (retain 30 days of history)
ALTER TABLE iceberg.analytics.events
EXECUTE expire_snapshots(retention_threshold => '30d');
```

### Iceberg Snapshots: Atomic and Time-Travel Friendly

Every INSERT creates a new snapshot — a point-in-time version of the table. This gives you:

1. **Atomicity**: readers see either the old snapshot or the new one, never a partial write.
2. **Time travel**: query historical state for audits:
   ```sql
   SELECT * FROM iceberg.analytics.events
   FOR TIMESTAMP AS OF TIMESTAMP '2026-05-24 00:00:00';
   ```
3. **Rollback**: if a bad ingestion run happened, roll back to the previous snapshot without rewriting data.

### Key Gotchas

1. **Late-arriving rows**: if rows arrive with an `occurred_at` from 3 days ago, `overwritePartitions` will wipe that old day's data. Use `MERGE INTO` for late-arriving row handling.

2. **Don't compact during ingestion**: run compaction AFTER the ingestion job finishes to avoid write conflicts.

3. **Trino vs Spark for scheduled writes**: Trino's `INSERT INTO` works for testing and one-off loads. For production nightly jobs, Spark integrates better with schedulers (Airflow, Kubernetes CronJobs) and has more mature write reliability.

### Summary

| Task | Tool | Timing |
|---|---|---|
| Initial bulk load | Trino `INSERT INTO ... SELECT` | One-time |
| Nightly incremental | Trino or Spark with `WHERE updated_at > watermark` | 2 AM |
| Compaction | `ALTER TABLE ... EXECUTE optimize` | 4 AM (after ingestion) |
| Snapshot expiry | `ALTER TABLE ... EXECUTE expire_snapshots` | Weekly |
