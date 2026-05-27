# Answer to Q2: Full-Refresh vs Incremental vs CDC Decision Tree for Postgres-to-Iceberg (Iter 335)

## Three patterns exist, and you choose based on table size and freshness needs

**Pattern A — Full Refresh**: Read the entire Postgres table and overwrite everything in Iceberg each night
- **When to use**: Small dimension tables under ~10 million rows
- **Pros**: Simplest. No state to track.
- **Cons**: Heavy load on Postgres. Briefly empties the Iceberg table during the rebuild (readers may see errors). Never use on shared tables where other jobs append to them.

**Pattern B — Incremental**: Read only rows that changed since the last run, append to Iceberg
- **When to use**: Tables over 10 million rows where you need same-day freshness
- **Pros**: Minimal Postgres load. Much faster per-run.
- **Cons**: Requires tracking state (a "watermark" timestamp). Needs an `updated_at` column on every source row that your application maintains on every INSERT and UPDATE.

**Pattern C — CDC (Change Data Capture)**: Stream Postgres write-ahead log changes via Debezium into Kafka, then into Iceberg
- **When to use**: Only if you need sub-minute freshness OR need to capture hard DELETEs
- **Trade-off**: ~3x more infrastructure (Debezium, Kafka, streaming jobs). Much more operational complexity. **Only start here if patterns A/B don't meet your requirements.**

## The decision for your two table types

**Heavy-write tables (constant updates):**
- Use **Pattern B (Incremental)**
- Add an `updated_at` timestamp column to those tables if missing
- Configure a trigger in Postgres so even buggy services can't accidentally skip the timestamp:
  ```sql
  CREATE TRIGGER events_touch_updated_at
  BEFORE INSERT OR UPDATE ON events
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
  ```
- Index the `updated_at` column in Postgres — unindexed watermark columns cause full-table scans on every nightly run
- Write using `overwritePartitions()` with a fixed batch window (e.g., "yesterday's date"), not append-based, because `append()` is not safe if the job restarts (it re-inserts rows)

**Large, rarely-changing tables (tens of millions of rows):**
- Use **Pattern A (Full Refresh)** if they're under ~10M rows
- Use **Pattern B (Incremental)** if they're larger — even if change rate is low, a nightly full-table scan of a 50M-row table is expensive
- For full refresh on frequently-read tables, use the **staging table + view swap** pattern: load into a temporary table, validate row counts, atomically swap a view from the old table to the new. This eliminates the brief "table not found" window that would otherwise disrupt dashboards.

## Critical gotchas

1. **Watermark column choice is load-bearing**: Use `updated_at`, not `created_at`, unless the table is append-only (rows never updated). Using `created_at` on tables that get UPDATEs causes rows to silently drift forever.

2. **Late-arriving rows**: If you're filtering by `updated_at` but Iceberg is partitioned by `occurred_at` (the event's actual time, not the update time), using `overwritePartitions()` can silently delete thousands of legitimate rows. Use MERGE INTO instead.

3. **Index on your watermark column**: Forgetting to index `updated_at` in Postgres turns a 4-minute nightly job into a 4-hour full-table scan. Always run this preflight before deploying:
   ```sql
   SELECT indexname FROM pg_indexes WHERE tablename='your_table' AND indexdef LIKE '%updated_at%';
   ```

4. **Load on your Postgres primary**: For the very largest bootstrap (initial load), consider reading from a Postgres read replica. This requires setting `hot_standby_feedback = on` on the replica to avoid mysterious "canceling statement due to conflict with recovery" errors during long scans.

## What NOT to do

- Don't dump the entire table every night unless it's truly small (under ~10M rows).
- Don't use `append()` for production — use `overwritePartitions()` with a fixed batch date instead to stay idempotent.
- Don't skip `updated_at` indexing or you'll discover the missing index when Postgres starts melting at 2 AM.

## Start here

1. Heavy-write tables → Pattern B with `updated_at` watermark + `overwritePartitions()` per day
2. Large, slow-change tables → Pattern B with `updated_at` watermark (if over 10M rows) OR Pattern A with staging table + view swap (if under 10M rows)

Only move to Debezium (Pattern C) if analysts need analytics fresher than once per hour, which is rare.

**Resources cited:** `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
