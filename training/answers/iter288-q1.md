# Iter288 Q1 — Broadcast Join for Iceberg × Postgres Lookup Table

## Answer

Yes, Trino supports broadcast joins and can do them automatically. The join being slow means either the cost-based optimizer (CBO) is not broadcasting the Postgres side, or dynamic filtering isn't helping reduce the Iceberg scan.

## How broadcast join works in Trino

Trino's CBO evaluates estimated table sizes and decides whether to broadcast the smaller side to all workers (faster, no shuffle) or partition both sides (default partitioned hash join). A 50K-row Postgres lookup table should be a strong candidate for broadcasting.

**Session property to see the current mode:**
```sql
SHOW SESSION LIKE 'join_distribution_type';
```

The default is `AUTOMATIC` — CBO decides per-join. The other options:
- `BROADCAST` — force broadcast of the build side to every worker
- `PARTITIONED` — force shuffle of both sides (slower for small lookups)

## Does Trino know about Postgres statistics?

Only if `ANALYZE` has been run on the Postgres side. Trino's PostgreSQL connector reads row counts and NDV (distinct value counts) from Postgres's `pg_stats` view, which is populated by running native `ANALYZE` on the Postgres primary:

```sql
-- Run on the Postgres PRIMARY (replicas are read-only)
ANALYZE public.customers;
```

After replication flows to the replica, verify Trino sees the stats:
```sql
SHOW STATS FOR app_pg.public.customers;
```

`distinct_values_count` populated for the join-key column = CBO has what it needs. If it shows `NULL`, stats are missing and the CBO will use defaults — likely choosing partitioned join instead of broadcast.

## Diagnosing the plan

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT e.event_id, c.plan_tier, c.region
FROM iceberg.analytics.usage_events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY;
```

- **`Exchange[type = REPLICATE]`** on the Postgres side → broadcast is happening
- **`Exchange[type = REPARTITION]`** on both sides → partitioned join; Postgres side is being shuffled

## Forcing broadcast if CBO gets it wrong

```sql
SET SESSION join_distribution_type = 'BROADCAST';

SELECT e.event_id, c.plan_tier, c.region
FROM iceberg.analytics.usage_events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY;

RESET SESSION join_distribution_type;
```

Expected result: 4-5 minutes → seconds to ~30 seconds.

## Why the CBO might not broadcast automatically

1. **Missing Postgres stats** — `SHOW STATS FOR` shows `NULL`; fix with native `ANALYZE` on primary
2. **Broadcast table size limit** — default `join-max-broadcast-table-size=100MB`; if the 50K rows estimated as wider than 100MB, CBO falls back to partitioned join (rare for a typical lookup table)
3. **No statistics from JDBC** — Trino can only read stats Postgres has already computed; columns not included in recent ANALYZE have NULL stats

After running `ANALYZE` on Postgres, flush Trino's metadata cache:
```sql
CALL app_pg.system.flush_metadata_cache();
```

Then re-run `SHOW STATS FOR` and the join query — the CBO should now broadcast automatically.
