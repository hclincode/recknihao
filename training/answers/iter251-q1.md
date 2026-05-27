# Iter251 Q1 — ANALYZE on Postgres Replica vs Primary

## Answer

You ran `ANALYZE` on the **primary Postgres server**, but Trino is reading statistics from the **read replica**. This is why `SHOW STATS FOR` shows stale data — it's reading from the replica's own `pg_stats`, which was never updated.

### Why ANALYZE on the primary doesn't help Trino

When you run `ANALYZE` on your Postgres primary, it writes statistics to the primary's `pg_statistic` system catalog. **Streaming replication does replicate `pg_statistic` rows to the replica via WAL**, but in your case this likely hasn't happened because:

1. **`autovacuum` is disabled on your read replica** (standard for replicas to reduce CPU load). The replica never automatically runs `ANALYZE`, so the replica's catalog is stale.
2. **Trino connects directly to the replica's `pg_stats` view.** When Trino's PostgreSQL connector builds a query plan, it executes queries against `pg_stats` **on the replica**, not the primary. Statistics it reads are whatever the replica's `pg_stats` exposes.

### The fix: run ANALYZE directly on the read replica

Connect to your read replica with `psql` and run `ANALYZE` there — not on the primary:

```bash
psql -h replica-host -U postgres -d appdb
```

```sql
-- On the read replica (not the primary):
ANALYZE public.customers;

-- Verify stats were collected on THIS replica:
SELECT attname, n_distinct, null_frac
FROM pg_stats
WHERE schemaname = 'public' AND tablename = 'customers'
LIMIT 10;
```

Expected: non-NULL values for `n_distinct` and `null_frac` on key columns.

### Metadata cache: flush if you have caching enabled

If your Trino PostgreSQL connector has `metadata.cache-ttl > 0s` configured, flush the cache:

```sql
-- From Trino:
CALL app_pg.system.flush_metadata_cache();
```

If `metadata.cache-ttl` is absent or `0s` (the default), caching is off — skip this step.

### Verify the stats are now visible to Trino

```sql
-- From Trino:
SHOW STATS FOR app_pg.public.customers;
```

The `distinct_values_count` and `nulls_fraction` columns should be populated with numbers, not NULL. If still NULL after ANALYZE:
- Re-run `ANALYZE` on the replica and verify with `SELECT * FROM pg_stats` there
- Run `CALL app_pg.system.flush_metadata_cache()` to clear any cached "no stats" entry

### Ongoing maintenance

Since `autovacuum` is likely disabled on your replica, schedule periodic ANALYZE runs:

```bash
# Example cron (daily at 2am):
0 2 * * * psql -h replica-host -U postgres -d appdb -c "ANALYZE;" >> /var/log/postgres-analyze.log 2>&1
```

**Key takeaway**: Trino reads Postgres statistics from the replica's `pg_stats`, not the primary's. Always run native `ANALYZE` **on the replica that Trino connects to**, then flush the metadata cache if caching is enabled.
