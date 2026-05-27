# Iter 174 Q2 — Dynamic Filtering with Federated Postgres: How It Works and How to Verify

## Answer

Yes — dynamic filtering works with Postgres federation in Trino. Here's how it works and how to verify it actually fired.

### (1) What Dynamic Filtering Does

Dynamic filtering is an optimization where Trino derives a filter from one side of a join and pushes it to the other side at runtime. In your scenario:

- Your **Iceberg lookup table** (few hundred rows) is the "build side" — Trino scans it first.
- Your **Postgres customer table** (2 million rows) is the "probe side" — Trino wants to scan it.

Instead of Trino blindly reading all 2 million rows from Postgres and then joining, dynamic filtering creates a list of the join-key values found in the Iceberg side and tells Postgres "only return rows where the join key matches these specific values." Postgres returns only the rows that can possibly join — not all 2 million.

### (2) Yes — It Works for Federated Postgres

This is the key fact: **Trino pushes dynamic filters to Postgres as SQL `WHERE` predicates over the JDBC connection.** The filter is executed server-side on Postgres, not in Trino memory.

The mechanics:
1. Trino scans the Iceberg lookup table (build side) and collects the join-key values.
2. Trino constructs an IN-list from those values.
3. Trino rewrites the Postgres query to include `WHERE join_key IN (val1, val2, ..., valN)`.
4. Postgres receives this modified query, uses its index on the join key, and returns only matching rows.

The join still executes on Trino workers, but the Postgres scan is filtered server-side — that's the win.

### (3) The Timeout: `dynamic_filtering_wait_timeout`

Trino can't wait forever for the build side to finish collecting values. The timeout controls how long Trino waits before starting the probe scan without the dynamic filter.

**For the PostgreSQL connector** (the probe side in your scenario): **default is 20 seconds**. If the Iceberg build side hasn't finished in 20 seconds, Trino starts the Postgres scan without the dynamic filter.

**For the Iceberg connector** (if roles were reversed): default is 1 second — much tighter.

If the timeout is hit, the Postgres scan runs as a full table scan (or with whatever local predicates Trino has, but not the IN-list). You lose the I/O savings — the IN-list filter applies after rows arrive at Trino workers, not before.

**Tune per session with the catalog prefix** (mandatory — bare form is invalid):
```sql
-- Replace 'app_pg' with your actual Postgres catalog name
SET SESSION app_pg.dynamic_filtering_wait_timeout = '30s';
```

`SET SESSION dynamic_filtering_wait_timeout = '30s'` (without catalog prefix) fails with "Session property does not exist." This is a per-catalog property, not a system property.

### (4) The IN-list Can Degrade to a Range

If your Iceberg lookup table has many thousands of distinct join-key values, Trino may convert the IN-list to a `BETWEEN` range to keep the filter small. A range still prunes, but less aggressively than an exact IN-list. You'll see `dynamicFilters = {id BETWEEN ... AND ...}` instead of `dynamicFilters = {id IN (...)}` in EXPLAIN output.

If the build side has millions of rows, Trino may not generate a dynamic filter at all by default. Enable larger filters:
```sql
SET SESSION enable_large_dynamic_filters = true;
```

### (5) How to Verify It Fired: EXPLAIN ANALYZE

**Step 1: Check whether dynamic filtering was planned** (no query execution):
```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT c.customer_id, c.name
FROM iceberg.lookups.small_lookup l
JOIN app_pg.public.customers c ON l.id = c.id;
```
Look for `dynamicFilters = {id = ...}` on the **Postgres scan node** (the probe side). If it's there, DF was planned.

**Step 2: Verify it fired at runtime** (actually runs the query):
```sql
EXPLAIN ANALYZE
SELECT c.customer_id, c.name
FROM iceberg.lookups.small_lookup l
JOIN app_pg.public.customers c ON l.id = c.id;
```

On the **Postgres `TableScan` node** (the probe side — the side RECEIVING the filter), look for:
```
dynamicFilterSplitsProcessed = <number>
```

- **`dynamicFilterSplitsProcessed > 0`**: dynamic filtering fired. Postgres received the IN-list and filtered server-side.
- **`dynamicFilterSplitsProcessed = 0`** but the plan showed `dynamicFilters`: DF was planned but didn't fire in time. The timeout was hit — consider raising `app_pg.dynamic_filtering_wait_timeout`.

**Critical**: `dynamicFilterSplitsProcessed` appears on the **probe side** (Postgres scan), NOT the build side (Iceberg scan). In your join (Iceberg build → Postgres probe), look for the metric on the Postgres node.

Also check `Input: N rows (size)` on the Postgres TableScan — if dynamic filtering worked, you should see a much lower row count than 2 million. Compare the filtered Input count against the Iceberg lookup's row count to confirm the filter was selective.

### Summary for Your Setup

For your 2 million–row Postgres customer table joining against a few-hundred-row Iceberg lookup:

1. **Dynamic filtering is enabled by default** — Trino derives the join-key IN-list and pushes it to Postgres.
2. **Verify with `EXPLAIN ANALYZE`** — look for `dynamicFilterSplitsProcessed > 0` on the Postgres TableScan.
3. **If it's zero but planned** — raise the timeout: `SET SESSION app_pg.dynamic_filtering_wait_timeout = '30s';`
4. **If `Input: N rows` is still 2 million** — check whether the IN-list grew too large and degraded to a range, or whether dynamic filtering was disabled by default for your build-side size.

This type of query (small lookup × large Postgres table) is exactly the use case dynamic filtering is designed for. With it working, your query should complete in seconds, not minutes.
