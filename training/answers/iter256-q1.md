# Iter256 Q1 — Dynamic Filtering in Federated Postgres-Iceberg Joins

## Answer

Yes, Trino absolutely does what you're observing — it's called **dynamic filtering**, and it's the critical optimization that makes cross-catalog joins between huge tables survivable.

### What Dynamic Filtering Does

When you join a small PostgreSQL dimension table to a huge Iceberg events table, Trino performs these steps at **runtime**:

1. **Reads the small PostgreSQL table first** — the 50,000 customer rows get loaded into an in-memory hash table.
2. **Collects the actual join keys** — Trino extracts all the customer IDs from that hash table (say, 5,000 unique IDs after your WHERE filter).
3. **Derives an IN-list filter** — Trino creates `WHERE customer_id IN (uuid1, uuid2, ..., uuid5000)` from those actual values.
4. **Pushes that IN-list into the Iceberg scan** — before Iceberg starts reading files, it receives this filter and uses it to skip Parquet files whose min/max statistics don't overlap the IN-list. Only files with matching customer IDs are opened.
5. **Result**: instead of reading 500 million Iceberg events, you read ~5 million — a 100× I/O reduction.

This is why your first case (small Postgres table joined to huge Iceberg table with a WHERE clause on customer ID) comes back in seconds — the dynamic filter is doing the heavy lifting on the Iceberg side.

### Why the "Flipped" Case Doesn't Get This Benefit

The critical rule: **dynamic filtering always flows from the SMALLER table to the LARGER table, not backwards.**

When you reverse the join (join the huge Postgres table to the small Iceberg table), the cost-based optimizer (CBO) picks the small Iceberg table as the "build side" (the side that gets hashed into memory first). Now the dynamic filter is derived from Iceberg's 2,000 rows and pushed INTO Postgres. But if the original column wasn't used in a WHERE clause, Postgres has no reason to use an index, so it performs a sequential scan of all 80 million rows anyway — the IN-list doesn't help much because the underlying scan strategy is already the bottleneck.

More importantly: **the direction of the dynamic filter depends entirely on which table is smaller after filtering.** If you remove the WHERE clause that made the first side selective, the CBO's decision can flip, and the whole benefit disappears.

### Seeing Dynamic Filtering in the Plan and UI

#### 1. **EXPLAIN (TYPE DISTRIBUTED) — plan-time view**

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ...
FROM iceberg.analytics.events e
JOIN app_pg.public.customers c ON e.customer_id = c.id
WHERE c.plan_tier = 'enterprise';
```

Look at the **Iceberg TableScan node** (the probe side — the larger table receiving the filter). You'll see an annotation like:

```
TableScan[table = iceberg:analytics.events,
          constraint = (occurred_at >= TIMESTAMP '2026-05-25 00:00:00'),
          dynamicFilters = {df_customer_id_0 = <...>}]
```

The presence of `dynamicFilters = {...}` proves the optimizer **planned** for dynamic filtering to fire.

#### 2. **EXPLAIN ANALYZE — runtime proof**

This actually runs the query. Look for this metric on the **Iceberg TableScan**:

```
dynamicFilterSplitsProcessed = 185
```

A **non-zero value** confirms dynamic filtering actually pruned Iceberg file splits during execution. If the plan showed `dynamicFilters = {...}` but `dynamicFilterSplitsProcessed = 0`, the build side timed out waiting to deliver its filter.

Also compare the `Input:` row count to the `Output:` row count on that TableScan. A dramatic reduction (e.g., Input: 50M rows → Output: 200K rows) signals that the dynamic filter was applied at the source.

#### 3. **Trino UI — easiest for post-mortem analysis**

After the query runs, navigate to `/ui/query.html?<query_id>`. Under the query's operator stats, look for the "Dynamic filters" panel. It shows how many dynamic filters were generated, how many input rows each filter pruned on each scan, and timing information.

### Seeing the Actual IN-List on the PostgreSQL Side

To see what filter Trino actually sent to Postgres, while the Trino query is running, execute this on your Postgres replica:

```sql
-- On the Postgres replica, while the Trino query is running:
SELECT query FROM pg_stat_activity 
WHERE state = 'active' 
AND query LIKE '%customer_id%';
```

You'll see the actual SQL Trino issued to Postgres. If dynamic filtering worked, it will contain an explicit `WHERE customer_id IN (...)` clause with the actual values. If the filter was too large, you might see `WHERE customer_id BETWEEN ... AND ...` instead.

### The `domain_compaction_threshold` Gotcha

If the dynamic filter's IN-list grows too large (more than **256 distinct values** by default), Trino **silently collapses it** into a `BETWEEN min AND max` range filter:

```
Build side produces:         Compaction occurs:          Probe side receives:
WHERE id IN (...300 IDs...)  --> (if > 256)          --> WHERE id BETWEEN 142 AND 8915
```

This has two consequences:

1. **For Iceberg probes**: a BETWEEN range still helps with file-level pruning, but per-row selectivity inside those files drops (you're reading rows you didn't ask for if your IDs are sparse across the range).

2. **For PostgreSQL probes with VARCHAR join keys**: VARCHAR BETWEEN does NOT push down to Postgres by default (due to collation concerns). So the IN-list would have pushed fine, but the compacted BETWEEN doesn't, and the Postgres scan runs unfiltered. You pay massive network cost for nothing.

#### Fix: raise `domain_compaction_threshold`

**Per-query (temporary):**
```sql
SET SESSION app_pg.domain_compaction_threshold = 1024;
-- Now run your join; IN-lists up to 1024 distinct values stay precise
```

**Cluster-wide (permanent):**
```properties
# etc/catalog/app_pg.properties
domain-compaction-threshold=1024
```

Sweet spot for multi-tenant SaaS cohort queries is usually **1024** (4× the default).

### Why Filter-On-Join-Key Works and Others Don't

- **With WHERE on the join key**: the Postgres side reads only ~5,000 filtered rows. The CBO sees 5K << 500M, so Postgres becomes the build side. Dynamic filtering flows from Postgres to Iceberg. The Iceberg probe receives a tight IN-list and skips 99% of the files.

- **Without WHERE on the join key**: the Postgres side reads all 50,000 rows, the resulting dynamic filter is too large to be effective, or flows in the wrong direction (from large to small, which is pointless).

This is why query plan verification with `EXPLAIN ANALYZE` is essential before declaring a federated join "production-ready." The difference between a 2-second query and a 5-minute query is often just whether dynamic filtering fired on the right side.
