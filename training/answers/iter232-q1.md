# Iter 232 Q1 — Iceberg + MySQL Join Gets Faster (Responder Answer)

## Answer

Your coworker is right — Trino does something smart automatically. The explanation involves two distinct layers of query optimization.

### What Trino Actually Does: Broadcast Joins (Planning-Time Optimization)

When Trino sees a query like yours — a huge fact table (200M events in Iceberg) joined to a small dimension (50K customer rows in MySQL) — it uses a **cost-based optimizer (CBO)** at query planning time to decide how to execute the join.

**Normal join (without optimization):**
- Both tables get shuffled across all workers by join key
- Each worker builds a hash table for its slice of the dimension
- High network and memory coordination cost

**Broadcast join (what Trino picks with good stats):**
- The small MySQL table (50K rows) is sent in full to every worker
- Each worker receives the complete dimension once (small, fixed memory cost)
- Each worker streams its local fact partition past the full dimension hash table
- No inter-worker coordination during the join itself

This is a **planning decision** — it happens at query compile time, before any data moves.

### What Might Explain the "Second Run Feels Faster" Effect

1. **Metadata caching**: Trino's coordinator caches Iceberg manifest metadata. On the second query with a slightly different filter, if the filter uses the same partition column, Trino may reuse partition pruning decisions.

2. **Dynamic filtering** (a runtime feature): this is where Trino uses statistics from the small table's scan to filter the large table's scan *during execution*, not just at plan time. The resources don't have explicit coverage of how to configure or verify this feature. I'd recommend checking trino.io/docs for "dynamic filtering" to confirm whether it's enabled by default and what properties control it.

### What You Should Do to Ensure Broadcast Joins Are Happening

**Step 1: Populate statistics on both tables**

The CBO only picks broadcast joins confidently when it knows the dimension is small:

```sql
-- On your Iceberg events table
ANALYZE iceberg.analytics.events
  WITH (columns = ARRAY['customer_id']);
```

For MySQL, run native `ANALYZE` on the MySQL replica — Trino reads row counts and NDV from MySQL's `INFORMATION_SCHEMA.STATISTICS`.

**Step 2: Set join distribution to AUTOMATIC**

```sql
SET SESSION join_distribution_type = 'AUTOMATIC';
```

**Step 3: Verify with EXPLAIN**

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ...
FROM iceberg.analytics.events e
JOIN mysql_catalog.app.customer_accounts c ON e.customer_id = c.customer_id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY;
```

Look for `Join[BROADCAST]` in the output. If you see `Join[PARTITIONED]`, the CBO didn't have stats — re-run ANALYZE and check `SHOW STATS FOR iceberg.analytics.events`.

**Resources relevant to your situation:**
- `/Users/hclin/github/recknihao/resources/23-trino-cbo-analyze.md` — CBO, NDV stats, and broadcast join selection
- `/Users/hclin/github/recknihao/resources/18-query-performance-regression.md` — `join_distribution_type` modes
- `/Users/hclin/github/recknihao/resources/22-trino-federation-postgresql.md` — federation details for MySQL connector
