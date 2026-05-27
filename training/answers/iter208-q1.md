# Iter 208 Q1 — Broadcast vs Partitioned Join Selection Across Catalogs

## Answer

Your instinct about the "broadcast" strategy is correct. As your `tenants` table grows from a few thousand rows to 300K, Trino's query planner will indeed change how it distributes the join work across workers — and understanding that threshold and what happens when you cross it is exactly what separates "we got lucky" from "we planned ahead."

### What broadcast join actually means

In a **broadcast join**, the smaller table (your `tenants` table) is sent in full to every Trino worker. Each worker then has a complete hash table of all tenant data in memory, so when it streams through the large Iceberg events table, every row can be joined without any network shuffling. It's fast because there's no expensive network shuffle — the tradeoff is memory: every worker must hold the entire tenants table in RAM.

In a **partitioned (hash) join**, by contrast, both tables are reorganized across workers based on the join key (`tenant_id` in your case). All rows with the same `tenant_id` are sent to the same worker, that worker builds a hash table of its slice of the tenants table, and joins against its slice of events. This requires a large network shuffle of both tables, but the memory cost per worker is lower because each worker only holds its partition of tenants.

---

### How Trino decides: the threshold and the CBO

Trino's **cost-based optimizer (CBO)** makes the decision. The session property that controls this is:

```sql
SET SESSION join_distribution_type = 'AUTOMATIC';  -- default
```

`AUTOMATIC` mode (the default) means: estimate the size of each side using statistics, then pick broadcast if the smaller side fits comfortably in worker memory, otherwise pick partitioned.

**The threshold is NOT a fixed row count.** Instead, Trino uses **statistics** to estimate the size of your tenants table:
- It multiplies the row count by the average row width (estimated from column statistics).
- It compares that estimated byte size to a configurable memory budget (essentially the per-query memory limit on each worker).
- If estimated size < available memory budget, broadcast is safe. If not, partitioned is safer.

On Trino 467, the key property is `query.max-memory-per-node` (defaults to ~20% of worker JVM heap). Broadcast happens when the CBO's estimate fits within that budget.

**For 300K rows of tenant data**: if each row is ~200 bytes (a realistic tenant record with id, name, plan, region, etc.), that's roughly 60 MB. On a worker with a multi-GB per-node memory budget, 60 MB is trivial, so broadcast should still win. But as you approach a few million rows, or if your tenant records are wider, the CBO will switch to partitioned.

---

### The critical catch: statistics

Here's the real gotcha. The CBO's decision is only as good as its statistics. If Trino has **no statistics** about your tenants table, it falls back to heuristics and often guesses wrong — it may pick partitioned even when broadcast would be dramatically faster, because the optimizer doesn't know the table is actually small.

Since your tenants table lives in **Postgres** (via Trino's JDBC connector), you must run native Postgres `ANALYZE` to populate statistics:

```sql
-- On your Postgres replica (not in Trino):
ANALYZE public.tenants;
```

After that, Trino can see the statistics by querying `pg_stats`. You can verify it worked in Trino:

```sql
SHOW STATS FOR app_pg.public.tenants;
```

If `distinct_values_count` and row count columns are populated, you're good. If they're NULL, stats are missing and the CBO is flying blind.

---

### What happens when it grows past the threshold

There is **no sudden failure or crash**. Instead:

1. **Query execution shifts from broadcast to partitioned automatically.** When the CBO's size estimate exceeds the memory budget, the next time the query is planned, Trino will choose `PARTITIONED` instead of `BROADCAST`.

2. **The query gets slower, and memory pressure is reorganized.** Broadcast avoids the expensive shuffle; partitioned requires shuffling both tables across the network. For a large fact table joined to a medium-sized dimension, that shuffle can easily add 5–30 seconds to the query. You'll see more network activity and more inter-worker I/O in the Trino UI.

3. **Worker memory pressure changes shape.** Under broadcast, each worker holds the full tenants table (60 MB × all workers = manageable). Under partitioned, each worker holds its slice of tenants, but must hold a larger temporary hash table to manage the shuffle. The per-worker peak memory may stay similar, but the distributed memory layout is different.

4. **Concurrent query capacity may drop slightly.** Partitioned joins often compete more for network bandwidth and disk I/O (spill-to-disk if memory is tight), which can reduce how many queries the cluster can run concurrently.

---

### How to verify which join type was chosen

Use `EXPLAIN ANALYZE` to see what happened:

```sql
EXPLAIN ANALYZE
SELECT e.event_type, t.name, COUNT(*) AS event_count
FROM iceberg.analytics.events e
JOIN app_pg.public.tenants t ON e.tenant_id = t.id
WHERE e.occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY e.event_type, t.name;
```

In the output, look for the Join operator line. It will show either:
- `Join[BROADCAST]` — broadcast join, good
- `Join[PARTITIONED]` — hash-partitioned join, expected when the build side is large

The build side is the one Trino loads into memory first; it's usually the smaller table (your tenants table). You can confirm from which side appears under the join hash builder vs the probe side in the plan.

---

### How to tune if needed

If your tenants table has grown and Trino switched to partitioned, you have three levers:

**1. Force broadcast manually (session-scoped, safest):**

```sql
SET SESSION join_distribution_type = 'BROADCAST';

SELECT e.event_type, t.name, COUNT(*) AS event_count
FROM iceberg.analytics.events e
JOIN app_pg.public.tenants t ON e.tenant_id = t.id
WHERE e.occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY e.event_type, t.name;

RESET SESSION join_distribution_type;  -- revert to automatic for next query
```

This is reversible and costs nothing. If the tenants table is truly too large, the query may hit an OOM error. But for 300K rows, it should work fine.

**2. Ensure the Postgres side is filtered aggressively before the join:**

```sql
SELECT e.event_type, t.name, COUNT(*) AS event_count
FROM iceberg.analytics.events e
JOIN app_pg.public.tenants t ON e.tenant_id = t.id
WHERE e.occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
  AND t.plan = 'enterprise'  -- Filter on Postgres side before the join
GROUP BY e.event_type, t.name;
```

Trino pushes the `t.plan = 'enterprise'` filter to Postgres, so the tenants table is pre-filtered to just the enterprise customers before the join. If that reduces tenants from 300K to 5K, broadcast becomes more likely even if it was picked partitioned before.

**3. Run ANALYZE on the Iceberg events table:**

```sql
-- In Trino:
ANALYZE iceberg.analytics.events
  WITH (columns = ARRAY['tenant_id', 'occurred_at']);
```

With good statistics on both sides, `AUTOMATIC` mode usually picks the right join strategy without manual override.

---

### The production signal to watch

As your tenants table grows, monitor for:
- **Query latency increasing** on cross-catalog join queries
- **Network bytes shuffled** (visible under `Output:` on Exchange nodes in EXPLAIN ANALYZE) going from near-zero to large numbers
- **Concurrent query capacity dropping** — more queries queued, waiting for cluster capacity

If you hit any of those, run a quick `EXPLAIN ANALYZE` to confirm the join changed to partitioned, then apply one of the tuning levers above. The safest immediate fix is `SET SESSION join_distribution_type = 'BROADCAST'` for that query, paired with running `ANALYZE` on both sides to give the CBO better information going forward.

At 300K rows today, you should still be safely in the broadcast zone. But as your SaaS grows and that table hits a few million rows, watching this threshold becomes part of your regular performance-tuning routine.
