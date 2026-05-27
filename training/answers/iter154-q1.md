# Iter 154 Q1 — Trino Join OOM: BROADCAST hint and join distribution type

## Answer

## Why Your Join Is Hitting Memory Limits

Your intuition is partly right — Trino should handle this. But the issue is in **how** Trino distributes the join work by default, not whether it can handle the data volumes themselves.

### What's Actually Happening in Memory

By default, Trino uses a `PARTITIONED` join strategy. Here's what that means:

1. **Both tables get hashed and shuffled**: Trino hashes both the 500M events table and the 50K accounts table on the join key.
2. **Data gets distributed across workers**: All rows with the same join key get sent to the same worker so the join can happen locally.
3. **Every worker builds a partial hash table**: Even though the accounts table is tiny, *each worker* receives its portion of the accounts data and builds a hash table for it. Because data gets scattered across all workers during the shuffle, the memory cost multiplies.

This works fine for large-to-large joins where you want to parallelize. But for fact-to-tiny-dimension joins like yours, it's wasteful: every worker gets a piece of a 50K row table and has to dedicate memory to building a hash table, even though 50K rows could fit in a single worker's RAM.

### The Solution: `BROADCAST` Join Distribution

Tell Trino to use `BROADCAST` instead. This tells the query planner: "Send the **entire** accounts table to every worker. Then each worker streams its local slice of the 500M events through the join against the full accounts table in memory."

**The memory math:**
- **PARTITIONED (default)**: Peak memory per worker = hash table for ~(500M rows / number of workers) + hash table for ~(50K rows / number of workers) = large + small = still large
- **BROADCAST**: Peak memory per worker = hash table for 50K rows (full accounts table) + streaming the events slice = small + bounded = much smaller

**Try this first:**

```sql
SET SESSION join_distribution_type = 'BROADCAST';

SELECT 
  a.account_name,
  COUNT(e.event_id) AS event_count
FROM iceberg.analytics.events e
JOIN iceberg.analytics.accounts a ON e.account_id = a.account_id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY a.account_name;
```

If the query completes, you've fixed it. The `SET SESSION` command applies to your current session only and is reversible.

### When BROADCAST Is Safe

BROADCAST is safe when the smaller side fits comfortably in your per-worker memory budget. Trino's default is `query.max-memory-per-node = 4GB` (check your config). Here's the rule of thumb from the resources:

**If the hash table for the smaller side (roughly 50K rows) fits in less than half of `query.max-memory-per-node`, BROADCAST is safe and usually faster.**

A 50K-row accounts table is typically a few hundred MB at most — easily safe on a 4 GB per-node limit. Broadcast it.

### If It Still Fails: Three Additional Levers

If `BROADCAST` doesn't solve it, try these in order:

**1. Add partition filters** to your WHERE clause
```sql
WHERE e.event_date >= CURRENT_DATE - INTERVAL '90' DAY
  AND a.account_status = 'active'  -- reduces 50K to maybe 30K active accounts
```

**2. Pre-filter before the join** — restructure as a CTE
```sql
WITH active_accounts AS (
  SELECT account_id, account_name
  FROM iceberg.analytics.accounts
  WHERE account_status = 'active'
)
SELECT a.account_name, COUNT(e.event_id)
FROM iceberg.analytics.events e
JOIN active_accounts a ON e.account_id = a.account_id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY a.account_name;
```

**3. Enable spill-to-disk** — a cluster-level safety valve (last resort)

This requires a coordinator/workers restart and is in the config file at `/etc/trino/config.properties` on every worker:
```properties
spill-enabled=true
spiller-spill-path=/var/trino/spill
spill-compression-codec=LZ4
max-spill-per-node=200GB
query-max-spill-per-node=50GB
```

Spill lets workers write intermediate state to disk instead of OOM-killing, but queries run much slower — use only as a last resort for queries you can't restructure.

### Query Plan Inspection

To see what's happening, run:

```sql
EXPLAIN ANALYZE
SELECT a.account_name, COUNT(e.event_id)
FROM iceberg.analytics.events e
JOIN iceberg.analytics.accounts a ON e.account_id = a.account_id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY a.account_name;
```

Look for `Scheduled:` and `CPU:` fields on the join operator. If `Scheduled:` is much larger than `CPU:`, you're I/O-bound (waiting on network shuffle). If they're close, you're compute-bound and `BROADCAST` won't help as much — you need to filter or restructure instead.
