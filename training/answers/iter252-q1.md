# Iter252 Q1 — ANALYZE on Primary, Trino Stats Propagation Path

## Answer

You've encountered a three-step problem: your Postgres primary has fresh statistics, but Trino is still serving stale ones. Here's the path from `ANALYZE` on the primary to "Trino sees new stats," plus the diagnostic checklist.

## The Path: Primary → WAL → Replica → Trino Metadata Cache → CBO

**Step 1: ANALYZE on the primary** — you did this correctly. When you run `ANALYZE customers` on the primary, Postgres writes statistics to `pg_statistic`, a regular heap table.

**Step 2: WAL replication to the read replica** — `pg_statistic` IS replicated via WAL. When the primary writes new statistics, those writes flow through WAL to the standby automatically. After WAL catches up, the replica's `pg_stats` contains the new statistics.

**Step 3: Trino reads `pg_stats` from the replica** — but two caching layers can hide fresh stats:
1. **Trino's metadata cache** (`metadata.cache-ttl` in catalog properties) — if > 0, stats are cached locally for that duration
2. **Already-cached query plans** won't change until replanned

## Step-by-Step Diagnostic

### 1. Verify stats arrived on the read replica

Run this **on the read replica** (SELECT works fine on a hot standby):

```sql
SELECT attname, n_distinct, null_frac
FROM pg_stats
WHERE schemaname = 'public' AND tablename = 'customers'
ORDER BY attname;
```

- `n_distinct` and `null_frac` populated → stats are on the replica; break is in Trino's cache
- NULL/missing → stats haven't replicated yet → check replication lag

### 2. Check replication lag (if stats haven't arrived yet)

```sql
-- On the read replica:
SELECT now() - pg_last_xact_replay_timestamp() AS replay_lag_seconds;
```

Lag should be seconds, not minutes. If lagging, your DBA needs to investigate — check `pg_stat_replication` on the primary.

### 3. Flush Trino's metadata cache

Check `etc/catalog/app_pg.properties` on the coordinator for:
```properties
metadata.cache-ttl=60s
```

If > 0s, flush immediately:
```sql
-- In Trino:
CALL app_pg.system.flush_metadata_cache();
```

Then verify:
```sql
SHOW STATS FOR app_pg.public.customers;
```

`distinct_values_count` and `nulls_fraction` should now be populated. If still NULL after flush, go back to step 1.

### 4. Verify the CBO sees fresh stats

```sql
EXPLAIN SELECT * FROM iceberg.analytics.events e
  JOIN app_pg.public.customers c ON e.customer_id = c.id
  WHERE e.occurred_at >= DATE '2026-05-01';
```

Look at the `Estimates:` lines for the Postgres scan — the row count should match `SHOW STATS FOR` output.

## When to Increase `statistics_target`

If `SHOW STATS FOR` shows populated but imprecise NDV estimates for high-cardinality columns, raise `statistics_target` on the primary:

```sql
-- On the PRIMARY:
ALTER TABLE public.customers ALTER COLUMN customer_id SET STATISTICS 300;
ANALYZE public.customers;
-- Stats replicate to replica via WAL; flush Trino cache if needed
```

Default is 100; raising to 300 gives the CBO better histograms for skewed distributions.

## TL;DR — Four Checks in Order

1. Stats fresh on replica? `SELECT n_distinct FROM pg_stats WHERE ...` on the replica
2. Trino cache stale? Check `metadata.cache-ttl`, then `CALL app_pg.system.flush_metadata_cache()`
3. `SHOW STATS FOR` shows fresh values after flush?
4. `EXPLAIN` shows updated row estimates?

The safe production pattern: `ANALYZE` on the primary weekly (or after bulk loads), `metadata.cache-ttl=60s` to reduce replica query load, and flush manually after urgent ANALYZE runs.
