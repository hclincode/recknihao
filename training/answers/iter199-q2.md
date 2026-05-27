# Iter 199 Q2 — Federation CBO: ANALYZE TABLE and PostgreSQL Statistics

## Answer

**No, `ANALYZE TABLE` does not work on PostgreSQL-connector tables, and you must not rely on it for federated join optimization.**

Here's the key distinction: Trino's `ANALYZE` command only works on connectors that own their own data files (Iceberg, Hive, Delta Lake). For JDBC connectors like PostgreSQL, **the source database owns the statistics layer**, not Trino. When you try `ANALYZE app_pg.public.accounts;` in Trino on your Postgres table, it fails with an error like "Catalog 'app_pg' does not support analyze."

But **this does NOT mean Postgres tables have no statistics for the CBO.** It means you populate those statistics in the right place: in PostgreSQL itself.

---

### How federated query planning really works with PostgreSQL

The Trino CBO (cost-based optimizer) can and does use statistics from PostgreSQL — it retrieves them automatically. Here's the pipeline:

1. **PostgreSQL collects statistics** when you run native `ANALYZE` in psql (or when `autovacuum_analyze` runs). The statistics live in PostgreSQL's `pg_stats` catalog view.
2. **The Trino PostgreSQL connector retrieves these stats on demand** during query planning by querying `pg_stats` over JDBC. It pulls the total row count, per-column distinct value counts (NDV), and null fractions.
3. **The Trino CBO uses these numbers** to estimate which side of your join should be the build side (broadcast vs. partitioned), and whether broadcasting the 200k-row Postgres table makes sense.

Verify this with `SHOW STATS FOR app_pg.public.accounts;` — if `distinct_values_count` is populated for your join keys, the CBO sees real statistics, not guesses.

---

### What happens without statistics

**Without stats, the CBO falls back to heuristics and makes bad choices.** When the Postgres table has never been analyzed (or `autovacuum` is disabled), `distinct_values_count` is NULL in `SHOW STATS`. The CBO then defaults to assuming each table is roughly the same size and picks a `PARTITIONED` join (a full shuffle of both sides across the cluster), when it should be broadcasting the small Postgres dimension table to every worker.

This is exactly the behavior you're seeing: the planner is making conservative (expensive) choices because it doesn't have enough information to estimate build-side size accurately.

---

### How to fix bad join plans without rewriting queries

**First, populate statistics on the Postgres side** (this is the real fix):

```sql
-- Run this in psql connected to your Postgres replica (NOT through Trino):
ANALYZE public.accounts;

-- Verify stats are now in PostgreSQL's catalog:
SELECT attname, n_distinct, null_frac
FROM pg_stats
WHERE schemaname = 'public' AND tablename = 'accounts';
```

If `metadata.cache-ttl` is set in your Trino PostgreSQL catalog config, flush it so Trino picks up the fresh stats:

```sql
-- Run in Trino (only needed if metadata caching is enabled):
CALL app_pg.system.flush_metadata_cache();
```

Then verify the CBO now sees the stats:

```sql
SHOW STATS FOR app_pg.public.accounts;
```

The join-key columns should now show concrete `distinct_values_count` instead of NULL.

**Second, run ANALYZE on your Iceberg side too.** You control Iceberg statistics with Trino's `ANALYZE` command:

```sql
ANALYZE iceberg.analytics.events WITH (columns = ARRAY['account_id']);
ANALYZE iceberg.analytics.events WITH (columns = ARRAY['created_at']);
```

With stats on both sides, the CBO can size each table, estimate post-filter cardinality accurately, and pick the right join distribution.

---

### If you still see bad plans after populating stats

You have two session-property levers without rewriting queries:

**Force broadcast join** (if the Postgres table is actually small after filtering):

```sql
SET SESSION join_distribution_type = 'BROADCAST';
-- Then run your federated query
```

This tells Trino to send the entire Postgres result set to every worker, avoiding a network shuffle of your huge Iceberg table.

**Force partitioned join** (for large × large joins):

```sql
SET SESSION join_distribution_type = 'PARTITIONED';
```

The default is `AUTOMATIC`, which is what you want long-term — it uses the CBO's cost estimates. But if the CBO's estimates are still wrong even after you've populated stats, these overrides are your escape hatch.

---

### Most likely root causes for your current situation

- **Your Postgres replica has never been analyzed.** Check if `autovacuum_analyze` is disabled. Run native `ANALYZE public.accounts;` in psql and flush Trino's metadata cache.
- **Trino's metadata cache is stale.** If `metadata.cache-ttl > 0` in your catalog config and you ran `ANALYZE` recently, call `CALL app_pg.system.flush_metadata_cache();`.
- **Your Iceberg events table has no CBO statistics.** Run `ANALYZE iceberg.analytics.events WITH (columns = ARRAY['account_id']);` so the CBO can size the event-side of the join.

---

### Summary

| Question | Answer |
|---|---|
| Does `ANALYZE TABLE` work on Postgres connector tables? | NO — fails with "does not support analyze" |
| Where do Postgres table statistics come from? | Postgres `pg_stats` — populated by native `ANALYZE` or autovacuum |
| Does Trino CBO use Postgres statistics? | YES — reads from `pg_stats` via JDBC during planning |
| How to verify the CBO has good stats? | `SHOW STATS FOR app_pg.public.accounts;` — look for non-NULL `distinct_values_count` |
| Session-level override for bad plans? | `SET SESSION join_distribution_type = 'BROADCAST'` or `'PARTITIONED'` |

Populate both sides' statistics on a weekly cadence (or after large data ingests), and the planner will make sound decisions without hints or query rewrites.
