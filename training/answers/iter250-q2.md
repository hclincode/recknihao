# Iter250 Q2 — ANALYZE TABLE for CBO Join Ordering

## Answer

Your coworker is correct that Trino has a cost-based optimizer (CBO) — but it's only as good as the statistics it has. In your case, Trino is likely guessing about table sizes because **the PostgreSQL side is missing the statistics the CBO needs** to make the right call.

### What ANALYZE does on Iceberg vs PostgreSQL

**On Iceberg tables** (run from Trino):
```sql
ANALYZE iceberg.analytics.events;
```
Writes a Puffin file with NDV (number of distinct values) estimates next to the table metadata in MinIO. The CBO uses these to estimate join cardinality.

**On PostgreSQL tables** (federated source):
- PostgreSQL's `ANALYZE` runs **on the Postgres replica itself**, not through Trino
- Trino's PostgreSQL connector automatically reads NDV and null fraction from Postgres's `pg_stats` table during query planning
- **`ANALYZE app_pg.public.customer_accounts` in Trino will fail** — Trino's ANALYZE command does NOT work on the PostgreSQL connector

### How the CBO uses statistics for join ordering

Without NDV stats, the CBO falls back to heuristic defaults and may:
1. Misestimate the build-side size and pick the wrong table to hash
2. Choose a shuffle (repartition) join when a broadcast join would be far cheaper

With good statistics, the CBO correctly identifies:
- Postgres table = 8,000 rows → **build side** (hashed into memory)
- Iceberg table = 400M rows → **probe side** (streamed past the hash table)

**The build/probe rule**: smaller table = build side. Dynamic filtering flows FROM the build side (Postgres) INTO the probe side (Iceberg), allowing Iceberg to skip entire Parquet files that can't match any join key.

### Step-by-step fix

**Step 1: Run ANALYZE on the Postgres read replica** (with psql, not through Trino)

```sql
ANALYZE public.customer_accounts;
```

On an 8K-row table, this completes in milliseconds.

**Step 2: Verify Postgres has statistics**

```sql
SELECT attname, n_distinct, null_frac
FROM pg_stats
WHERE schemaname = 'public' AND tablename = 'customer_accounts';
```

`n_distinct` should be populated (not null/negative placeholder) for your join columns.

**Step 3: Optionally flush Trino's metadata cache**

If your catalog has `metadata.cache-ttl > 0s` configured:
```sql
CALL app_pg.system.flush_metadata_cache();
```
If cache is at the default of 0s (disabled), skip this step.

**Step 4: Verify Trino sees the statistics**

```sql
SHOW STATS FOR app_pg.public.customer_accounts;
```

`distinct_values_count` should be populated for your join columns. If it shows NULL, the Postgres ANALYZE hasn't been read yet (or cache needs flushing).

**Step 5: Verify the join order changed**

```sql
EXPLAIN (TYPE LOGICAL)
SELECT COUNT(*)
FROM iceberg.analytics.fact_usage_events e
JOIN app_pg.public.customer_accounts a ON e.customer_id = a.id
WHERE a.plan = 'enterprise';
```

Look for:
- **`rows: ~8000`** on the Postgres side and **`rows: ~400000000`** on Iceberg (not `rows: ?` which means "guessing")
- **`Join[BROADCAST]`** — with good stats Trino broadcasts the small Postgres table to every worker
- **`dynamicFilters`** annotation on the Iceberg scan — confirms the filter is flowing from Postgres to Iceberg

### Maintenance cadence

Run `ANALYZE` on the Postgres replica:
- After major data ingests or schema changes
- Weekly as routine maintenance (if `autovacuum` is disabled on the replica, you must run it manually)

After ANALYZE, the next Trino federation query picks up fresh stats automatically. The CBO will plan joins correctly, and dynamic filtering from the small Postgres build side will prune the large Iceberg scan — typically a 2x–10x speedup for this join pattern.
