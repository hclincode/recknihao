# Iter 213 Q1 — Three-Source Federation: Iceberg + Postgres + MySQL Join Strategy

## Answer

## How Trino handles join strategy across three catalogs

Yes, Trino **is smart enough** to recognize that your 50K-row MySQL tenants table should be broadcast (sent to all workers), and it will preferentially make that the **build side** of the join. However, this depends on having statistics in place, and there are important nuances about how it handles three catalogs versus two.

### The key principle: Trino's cost-based optimizer (CBO) picks join order

Trino uses a **cost-based optimizer** that looks at estimated row counts on both sides of a join. For any join between tables, Trino tries to pick the **smaller side as the build side** (the side that gets hashed into memory) and the larger side as the **probe side** (the side that streams through the hash table). This is true whether you're joining two tables or three.

For your scenario (Iceberg with hundreds of millions of rows, Postgres catalog, MySQL with 50K rows), Trino will:

1. **Estimate the size of each table** after applying any WHERE predicates
2. **Pick the smallest result set as the build side** — that should be your MySQL tenants table
3. **Use broadcast distribution** if the build side stays under the `join_max_broadcast_table_size` threshold (default: **100MB**)

A 50K-row tenants table is almost certainly only a few MB, so broadcast is the expected choice. Trino will send a copy of the hash table to every worker, then stream the Iceberg events through it.

**Critical requirement:** For the CBO to make this smart decision, **you must run native `ANALYZE` on both the MySQL and Postgres catalogs** to populate their statistics. If Trino doesn't know how many rows Postgres will return after filtering, it may over-estimate and unexpectedly choose a partitioned (hash-repartitioned) join instead of broadcast, causing unnecessary network shuffles of your huge Iceberg table.

### Three catalogs does NOT break join planning

Adding a third catalog is fine — Trino's join planning works the same way. If you're joining events × users × tenants, Trino will:

- Plan the first join (e.g., events × tenants) and pick the smaller side as the build.
- Take that result and join it against the third table, again picking the smaller side as the build.

The optimizer enumerates possible join orders and picks the cheapest. With proper statistics on all three tables, it should still recognize that the tiny tenants table should be built first and broadcast early.

### Predicate pushdown still works across all three catalogs

Yes, **predicate pushdown is independent of how many catalogs are in the query**. Each catalog's connector handles its own predicates:

- **Postgres catalog**: `WHERE` clauses on Postgres tables get pushed down as SQL to the Postgres replica
- **MySQL catalog**: `WHERE` clauses on MySQL tables get pushed down as SQL to MySQL
- **Iceberg catalog**: `WHERE` clauses become partition pruning + Parquet file skipping via manifest metadata

**However, the join itself never pushes down across catalogs.** The join always executes on Trino workers. What *does* push down is **dynamic filtering** — a runtime optimization where Trino builds a small filter from the build-side join keys and pushes that filter to the probe-side scan.

### Dynamic filtering: the real performance lever

This is the critical piece for your three-catalog setup. Here's how it works:

1. Trino scans and builds the hash table from your 50K MySQL tenants table
2. It derives a **runtime predicate** — an `IN`-list of tenant IDs, or a min/max range
3. **That predicate pushes to the Iceberg scan** as additional pruning: `WHERE tenant_id IN (id1, id2, ..., id50000)`
4. Iceberg uses this to skip files and row groups that don't match any of those tenant IDs

Without dynamic filtering, Trino would scan all hundreds of millions of Iceberg rows. With it, Iceberg may prune down to only the rows actually belonging to those 50K tenants.

**To confirm dynamic filtering is working**, run `EXPLAIN (TYPE DISTRIBUTED)` on your query and look for `dynamicFilters = {...}` annotations on the Iceberg scan. Then run `EXPLAIN ANALYZE` to verify that `dynamicFilterSplitsProcessed > 0` on the probe-side scan — that's proof the filter actually pruned splits at runtime.

### What you need to do now

1. **Run native `ANALYZE` on your Postgres replica** (not through Trino):
   ```sql
   ANALYZE public.users;
   ```
   Then verify in Trino: `SHOW STATS FOR app_pg.public.users;` — you should see non-NULL `row_count` and `distinct_values_count` for join-key columns.

2. **Run native `ANALYZE` on your MySQL replica** (or ensure it has been run):
   ```sql
   ANALYZE TABLE tenants;
   ```
   Then verify: `SHOW STATS FOR mysql_catalog.schema.tenants;` in Trino.

3. **Run `ANALYZE` on the Iceberg side** (from Trino, targeting join-key columns):
   ```sql
   ANALYZE iceberg.schema.events WITH (columns = ARRAY['tenant_id', ...]);
   ```

4. **Test your join with `EXPLAIN (TYPE DISTRIBUTED)` and `EXPLAIN ANALYZE`.** Look for:
   - `join_distribution_type = BROADCAST` on the tenants join step (should be automatic if CBO has stats)
   - `dynamicFilters = {tenant_id IN ...}` or `dynamicFilters = {tenant_id BETWEEN ...}` on the Iceberg probe scan
   - `dynamicFilterSplitsProcessed > 0` in EXPLAIN ANALYZE output

If you see `PARTITIONED` instead of `BROADCAST` on a 50K-row table, the CBO is mis-estimating the size — check your statistics. If you see `dynamicFilters = {}` (empty), the dynamic filter generation gave up — likely because the build side is too large or you need `enable_large_dynamic_filters = true`. If `dynamicFilterSplitsProcessed = 0`, the Iceberg scan started before the build finished — raise `iceberg.dynamic_filtering_wait_timeout` from the default `1s` to `10s`–`30s`.
