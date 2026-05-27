# Iter 196 Q1 — Dynamic Filtering Deep Dive for Cross-Catalog Joins

## Answer

## What Dynamic Filtering Is and How It Works

**Dynamic filtering** (DF) is a runtime optimization that Trino applies automatically to joins. When Trino builds a hash table from one side of a join, it inspects the actual join-key values it collected and derives a compact filter — either an `IN`-list of specific values or a min/max range — then **pushes that filter to the other side's scan while it's still reading data**. This dramatically reduces how many rows need to be read from the probe side.

In your case: Trino filters the Postgres accounts to a specific set of account IDs, builds a hash table from those rows, then derives an IN-list of those account IDs and pushes it to the Iceberg scan before it reads the events table. Without dynamic filtering, Iceberg would scan every row in the partition.

### Direction: Which Side Benefits

**Dynamic filtering flows from the build side to the probe side.**

For your query pattern:
- **Build side** (smaller): Postgres accounts after filtering
- **Probe side** (larger): Iceberg events table
- **The filter flows FROM Postgres TO Iceberg**

The Iceberg side gets the filter and uses it for partition pruning and file skipping. The Postgres side does NOT receive the filter — it produces the filter. Always look for DF evidence on the **probe side** (Iceberg in your case).

---

## Checking EXPLAIN Output for Dynamic Filtering

### 1. `EXPLAIN (TYPE DISTRIBUTED)` — Plan-time check (doesn't run the query)

Look for a `dynamicFilters = {...}` annotation on the **probe-side scan node** (the Iceberg events scan):

```
TableScan[table = iceberg:analytics.events]
    dynamicFilters = {account_id = #df_accounts_id_0}
    constraint on [event_date]
        event_date >= DATE '2026-05-01'
```

The presence of `dynamicFilters = {...}` proves Trino **wired up** dynamic filtering at plan time. This does NOT guarantee it fired at runtime (the build side could have been slow), but it shows the optimizer intended to use it.

If you don't see `dynamicFilters` on the Iceberg scan, DF was not planned. Common reasons: the Postgres side is not selective enough (build side too large), or the CBO picked the wrong build/probe sides.

### 2. `EXPLAIN ANALYZE` — Runtime verification (actually runs the query, strongest proof)

Look for `dynamicFilterSplitsProcessed` on the **Iceberg TableScan node**:

```
TableScan[table = iceberg:analytics.events]
    Input: 5200000 rows (450MB)
    dynamicFilterSplitsProcessed = 127
    Filtered: 45.5%
    CPU: 2.34s
```

- **`dynamicFilterSplitsProcessed = 127`**: Iceberg skipped 127 splits (files) thanks to the dynamic filter. A non-zero value confirms DF actually pruned data at runtime. ✅
- **`dynamicFilterSplitsProcessed = 0`** while the plan showed `dynamicFilters`: DF was planned but didn't fire in time — usually the wait-timeout was hit.

**Critical mistake to avoid**: Do NOT look for `dynamicFilterSplitsProcessed` on the Postgres scan — it will be zero there. Always look on the probe side (Iceberg).

### 3. Trino Web UI — Post-execution

Visit `http://trino-coordinator:8080/ui/query.html?<query_id>`. The "Dynamic filters" section under operator stats shows how many DFs were generated and how many rows each one filtered.

---

## Configuration

**Good news: Dynamic filtering is enabled by default in Trino 467.** No configuration switch needed.

### Wait-Timeout — How long Trino waits for the build side

When the join starts, Trino must eventually start scanning the probe side. If the Postgres build side is slow, Trino waits up to `dynamic-filtering.wait-timeout` before launching the probe scan without the filter.

```properties
# In etc/catalog/iceberg.properties (for Iceberg as probe — your case):
iceberg.dynamic-filtering.wait-timeout=1s    # default is 1s

# In etc/catalog/app_pg.properties (for Postgres as probe — rarer):
postgresql.dynamic-filtering.wait-timeout=20s   # default is 20s
```

If you see `dynamicFilterSplitsProcessed = 0` in EXPLAIN ANALYZE even though the plan showed `dynamicFilters`, the build side (Postgres query) took longer than the wait-timeout. Fix: raise it via session property without restarting:

```sql
SET SESSION iceberg.dynamic_filtering_wait_timeout = '15s';
-- Then run your query
```

### Compaction Threshold — When IN-lists become range filters

If the dynamic filter IN-list exceeds the compaction threshold (default 256 on Postgres), the connector compacts it to a `BETWEEN` range. This is weaker pruning but still helpful.

```properties
# In etc/catalog/app_pg.properties:
domain-compaction-threshold=1024
```

Or per-query:
```sql
SET SESSION app_pg.domain_compaction_threshold = 1024;
```

### Enabling Large Dynamic Filters

For larger build sides:
```sql
SET SESSION enable_large_dynamic_filters = true;
```

---

## Cross-Catalog vs Same-Catalog Joins

**Same-catalog joins** (both tables in `app_pg`, or both in Iceberg): Dynamic filtering works normally.

**Cross-catalog joins** (Postgres + Iceberg, like yours):
- The join itself **always executes on Trino workers** — there is no cross-catalog join pushdown.
- Each side's **predicates** still push down independently (Postgres WHERE clause → SQL; Iceberg filters → partition/file pruning).
- **Dynamic filtering still works** — Trino derives the filter from the Postgres build side and pushes it to the Iceberg probe side.

The key insight: cross-catalog join pushdown doesn't exist (join runs on Trino), but dynamic filtering does. Without DF you'd scan all Iceberg events; with it, you scan only the files matching the account IDs Postgres returned.

---

## Troubleshooting Checklist

1. **`EXPLAIN (TYPE DISTRIBUTED)`** — look for `dynamicFilters = {account_id = ...}` on Iceberg scan. Missing = DF not planned.
2. **Verify Postgres predicate pushes down** — the WHERE clause filtering accounts should appear in `constraint on [...]` inside the Postgres `TableScan`.
3. **`EXPLAIN ANALYZE`** — check `dynamicFilterSplitsProcessed > 0` on Iceberg scan. Zero despite plan showing DF = raise wait-timeout.
4. **Build-side selectivity** — if Postgres returns 50M of 60M accounts, the build side is too large and DF degrades. Add a more selective WHERE on Postgres.
5. **Force broadcast join** for dimension-to-fact joins:
   ```sql
   SET SESSION join_distribution_type = 'BROADCAST';
   ```
