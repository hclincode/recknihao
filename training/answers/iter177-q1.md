# Iter 177 Q1 — Cross-Catalog Join: Is Trino Pulling the Whole Postgres Table?

## Answer

**The short answer: Trino is not pulling the entire Postgres table into memory as-is — but cross-catalog joins always execute on Trino workers, not inside Postgres. Both sides optimize their scans independently, and dynamic filtering bridges them so Postgres learns which rows Iceberg actually needs.**

---

### What's Actually Happening in Your Query

When you join `billing_pg` (Postgres) against `events_iceberg` (Iceberg):

1. **Each side of the join gets its filters pushed down independently.**
   - **Postgres side**: The `WHERE c.plan = 'enterprise'` predicate pushes down to Postgres if it's pushable. Postgres uses its index and returns only matching rows — say, 50,000 customers instead of 5 million.
   - **Iceberg side**: Trino's Iceberg connector prunes partitions based on `WHERE e.event_date >= '2026-05-01'`. Entire date partitions are eliminated at planning time. Iceberg also uses file-level min/max statistics to skip unopened data files.

2. **The JOIN itself runs on Trino workers, NOT in either Postgres or Iceberg.**
   > Cross-catalog joins always execute on Trino workers. Neither Postgres nor Iceberg sees the join. Each connector returns its filtered result set, and Trino's workers perform the hash join on the rows that arrived over the network.

You cannot "push the whole join down" to Postgres. The instant the join crosses catalogs, it becomes Trino's responsibility.

---

### The Slow Path: Why You Feel Like "the Entire Table" Is Moving

If your query has no selective predicate on the Postgres side:

```sql
SELECT ...
FROM billing_pg.public.customers c
JOIN events_iceberg.analytics.events e ON c.id = e.customer_id
WHERE e.event_date >= '2026-05-01'  -- only Iceberg has a filter
```

1. Trino issues `SELECT * FROM customers` to Postgres (no filter to push down).
2. **All 5 million customer rows stream over the JDBC connection** to a single Trino worker — the Postgres connector uses a single split, so one worker reads all rows sequentially.
3. Trino builds a hash table from 5M rows in that worker's memory.
4. Dynamic filtering should push an IN-list of customer IDs back to Postgres, but if the Iceberg result set is huge, the IN-list becomes too large to be useful, or the dynamic filter times out.

**Result:** you feel like the entire Postgres table was pulled, because it actually was.

---

### How to Tell What's Actually Happening: EXPLAIN and EXPLAIN ANALYZE

**Step 1: Check the plan with `EXPLAIN (TYPE DISTRIBUTED)`**

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT c.id, c.plan, COUNT(*) AS event_count
FROM billing_pg.public.customers c
JOIN events_iceberg.analytics.events e ON c.id = e.customer_id
WHERE c.plan = 'enterprise'
  AND e.event_date >= '2026-05-01'
GROUP BY c.id, c.plan;
```

Look for these signals on the Postgres side:

**Pushdown working:**
```
TableScan[table = billing_pg:public.customers, ...]
    constraint on [plan]
        plan = 'enterprise'
```

**Pushdown NOT working:**
```
ScanFilterProject[filterPredicate = (plan = 'enterprise')]
    TableScan[table = billing_pg:public.customers]
```

If you see `ScanFilterProject` above `TableScan`, the filter is being applied in Trino workers after all rows arrive from Postgres.

Also look for dynamic filtering annotations:
```
TableScan[table = events_iceberg:analytics.events, ...]
    dynamicFilters = IN(customer_id_from_postgres_side)
```
This means Trino will derive a set of customer IDs from Postgres and use that to prune Iceberg files before scanning them.

**Step 2: Run `EXPLAIN ANALYZE` to see what actually happened at runtime**

```sql
EXPLAIN ANALYZE
SELECT c.id, c.plan, COUNT(*) AS event_count
FROM billing_pg.public.customers c
JOIN events_iceberg.analytics.events e ON c.id = e.customer_id
WHERE c.plan = 'enterprise'
  AND e.event_date >= '2026-05-01'
GROUP BY c.id, c.plan;
```

Key fields to read:

On the **Postgres TableScan** node:
- `Input: N rows` — how many rows Postgres actually returned. If this is 5M, the filter didn't push down. If it's 50K, pushdown worked.
- `Filtered: X%` — non-zero means Postgres filtered rows server-side. Absent or 0% with a large `Input:` count means Postgres returned unfiltered data.

On the **Iceberg TableScan** node:
- `Physical Input: X GB` — actual bytes read from MinIO. If you're querying one day and this is 500 GB, partition pruning is broken.
- `dynamicFilterSplitsProcessed = N` — if non-zero, dynamic filtering actively pruned Iceberg files at runtime. If zero but the plan showed `dynamicFilters`, the filter was planned but didn't fire in time (timeout).

---

### Three Critical Optimization Concepts

**1. Predicate Pushdown — your first line of defense**

What pushes down from Trino to Postgres by default:
- Equality on any type: `WHERE plan = 'enterprise'`
- IN-lists: `WHERE customer_id IN (1, 2, 3)`
- Ranges on numeric/timestamp: `WHERE created_at > '2026-05-01'`
- `IS NULL` / `IS NOT NULL`

What does NOT push down:
- `LIKE` patterns: `WHERE email LIKE 'a%'` stays in Trino. Workaround: add a denormalized column on Postgres and push down equality on that.
- Function calls: `WHERE LOWER(email) = 'foo'` doesn't push. Add a generated column instead.

**2. Dynamic Filtering — lets Iceberg help Postgres prune**

Trino's dynamic filtering works like this:
1. Trino starts scanning the Iceberg side to find distinct customer IDs matching the date filter.
2. Once a threshold of distinct values is collected, Trino derives a predicate — either an IN-list or a min/max range.
3. Trino **pushes this predicate back to Postgres** before the full scan, so Postgres only returns the customers whose IDs appeared in the Iceberg result.

Key coordinator properties:
```properties
# Time to wait for dynamic filters to be collected before proceeding:
dynamic-filtering.wait-timeout=2s

# Threshold before dynamic filter fires (broadcast join variant):
dynamic-filtering.small-broadcast.max-distinct-values=1000
```

If you see `dynamicFilterSplitsProcessed = 0` in `EXPLAIN ANALYZE` despite a plan that shows `dynamicFilters`, increase `dynamic-filtering.wait-timeout` to give the Iceberg side more time.

**3. Broadcast vs Partitioned Join — controls memory and network cost**

For a fact table (500M Iceberg events) × dimension table (10M Postgres customers) join, you can hint:

```sql
SET SESSION join_distribution_type = 'BROADCAST';
```

**What it does:** The smaller side (customers, after filtering) is broadcast to every Trino worker as a complete hash table. Each worker joins its local slice of the 500M events against the full customer hash table, without shuffling events across the network.

The alternative (`PARTITIONED`) shuffles **both sides** across the cluster by join key — 500M rows of events get re-hashed and sent around, which is expensive.

**The catch:** if the smaller side is too large (several GB), `BROADCAST` will OOM your workers. Let the cost-based optimizer pick: run `ANALYZE` on your tables to populate column statistics, set `join_reordering_strategy = AUTOMATIC`, and Trino will choose based on actual row counts.

---

### Actionable Diagnostics Checklist

1. **Run `EXPLAIN (TYPE DISTRIBUTED)`** — look for `constraint on [plan]` on the Postgres scan (absent = filter not pushing down). Look for `dynamicFilters` on the Iceberg scan.
2. **Run `EXPLAIN ANALYZE`** — check `Input:` rows on Postgres side (should be filtered, not full table). Check `dynamicFilterSplitsProcessed` on Iceberg side (should be > 0 if DF is working). Check `Physical Input:` bytes on Iceberg side (should match your date partition, not the whole table).
3. **Check your Postgres catalog properties** — is `defaultRowFetchSize=1000` set? Are you pointing at a read replica through PgBouncer?
4. **Check for non-pushable predicates** — if your WHERE clause on the Postgres side uses LIKE or function calls, they won't push. Add denormalized columns on Postgres to enable equality pushdown.

You are NOT stuck shuffling all data. Both connectors can optimize their scans independently, and dynamic filtering bridges them. Start with `EXPLAIN ANALYZE` — it will tell you exactly which layer needs fixing.
