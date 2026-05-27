# Iter 164 Q2 — Debugging a Slow Iceberg-Postgres Join

## Answer

For your specific case — small Postgres lookup (5K rows) joined to huge Iceberg events table (billions) — the problem is almost certainly one of three things. Here's how to diagnose each.

## What to look for in EXPLAIN ANALYZE

When you run `EXPLAIN ANALYZE` in the Trino UI, focus on these fields:

1. **`dynamicFilterSplitsProcessed`** — critically important for federated joins. A **non-zero value** on the Iceberg side's `ScanFilterProject` node confirms that dynamic filtering fired and pruned Iceberg splits at runtime. If this is `0` while your plan showed `dynamicFilters = {...}`, the filter was planned but didn't fire in time.
2. **`Physical Input:`** — the actual bytes Trino read from the Iceberg/Postgres side. If this is much higher than expected, a filter didn't push down.
3. **`Blocked: Input`** — time spent waiting on the upstream scan. High values here signal slow Postgres replica responses.

## The root cause (almost always one of these three)

### 1. Dynamic filtering didn't kick in (most common)

If the Postgres side is slow returning its 5,000 rows, Trino may have launched the Iceberg scan without waiting for the dynamic filter. This is the most common culprit: the default timeout in Trino 467 is only **2 seconds**. If your Postgres replica takes longer than that to return 5K rows, the probe side starts without a filter.

**Fix:** Increase the dynamic filtering wait timeout per-session:

```sql
SET SESSION dynamic_filtering_wait_timeout = '15s';
```

Then re-run your join. This gives the Postgres scan more time to finish before Trino launches the Iceberg probe, so the small IN-list actually pushes to Iceberg for file pruning. If `dynamicFilterSplitsProcessed` jumps from 0 to a large number, that was your problem.

### 2. Predicate pushdown to Postgres didn't happen

Use `EXPLAIN (TYPE DISTRIBUTED)` first to see the plan without running:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ...
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.account_id = a.id
...
```

Look at the `ScanFilterProject` node for the Postgres side. If you see a separate `Filter` node **above** the scan (rather than predicates embedded inside the `ScanFilterProject`), a filter didn't push down. Common causes:

- **String range predicates** (`LIKE`, `>`, `<` on VARCHAR) don't push down by default. Workaround: `postgresql.experimental.enable-string-pushdown-with-collate=true` in your Postgres catalog config, but test on a non-prod replica first.
- **Function calls** on the filter column (`LOWER(email)`, `DATE(created_at)`) block pushdown.

### 3. Postgres connection saturation

With 20 Trino workers and no native connection pooling in OSS Trino 467, the Postgres replica can get hammered. Check `system.runtime.queries` on Trino:

```sql
SELECT query_id, user, started, state
FROM system.runtime.queries
WHERE query LIKE '%accounts%'
ORDER BY started DESC
LIMIT 10;
```

If many queries are in `QUEUED` state, check on the Postgres replica:

```sql
SELECT count(*) FROM pg_stat_activity WHERE usename = 'trino_reader';
```

If that count is near `max_connections` or the role's `CONNECTION LIMIT`, Trino is starving for slots.

## Tools beyond the Trino UI

### On the Postgres side

1. **`pg_stat_activity` during the query:**
   ```sql
   SELECT pid, query_start, state, query
   FROM pg_stat_activity
   WHERE usename = 'trino_reader'
   ORDER BY query_start;
   ```
   Shows the actual SQL Postgres received (confirms predicate pushdown) and how long each query has been running.

2. **Slow query log** (temporary debugging):
   ```sql
   ALTER SYSTEM SET log_min_duration_statement = 0;  -- log everything
   SELECT pg_reload_conf();
   -- run your Trino query
   -- check logs: tail /var/log/postgresql/postgresql.log
   -- disable again
   ALTER SYSTEM SET log_min_duration_statement = -1;
   ```
   If Postgres received a bare `SELECT * FROM accounts` (no WHERE), pushdown failed.

3. **Check replica health:**
   ```sql
   SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;
   ```
   High lag means the replica is stale and may be returning stale data or performing slowly.

## Checklist: what to do right now

1. **Run `EXPLAIN ANALYZE` and check `dynamicFilterSplitsProcessed`** on the Iceberg side.
   - If it's `0`: increase `dynamic_filtering_wait_timeout` to `15s`.
   - If it's non-zero: dynamic filtering worked; the slow join is something else (Postgres replica health or file count on Iceberg side).

2. **Run `EXPLAIN (TYPE DISTRIBUTED)` and look for separate `Filter` nodes above scans** — those indicate pushdown didn't happen.

3. **Check `pg_stat_activity` during the query** — see what SQL Trino sent and if the Postgres connection count is hitting limits.

4. **If the Postgres side's `Blocked: Input` is very high**, check Postgres replica health (replication lag, query load).

If the issue is persistent connection pressure and you don't already have PgBouncer in front of Postgres, that's the next thing to add — Trino's OSS PostgreSQL connector has no built-in connection pooling, so PgBouncer + a role-level `CONNECTION LIMIT` on `trino_reader` is the standard production setup.
