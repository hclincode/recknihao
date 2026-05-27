# Iter239 Q2 — ANALYZE TABLE on Iceberg for Cross-Catalog Joins

## How to run ANALYZE on Iceberg and its effect on cross-catalog joins

### 1. The exact SQL command

In Trino (not Spark or Hive), the syntax is **`ANALYZE schema.table`** with **NO `TABLE` keyword**:

```sql
-- Analyze all columns:
ANALYZE iceberg.analytics.user_events;

-- More common: analyze only the join-key and filter columns (much faster):
ANALYZE iceberg.analytics.user_events 
  WITH (columns = ARRAY['account_id', 'user_id', 'event_type']);
```

**Critical syntax note:** `ANALYZE TABLE iceberg.analytics.user_events` will fail with a parser error. The Trino Iceberg connector does NOT support the `partitions` property (that's Hive-only) — the **only property for Iceberg is `columns`**.

### 2. What ANALYZE collects and stores

When you run `ANALYZE` on an Iceberg table, Trino:

1. **Walks the table and counts distinct values (NDV)** for each specified column — this is a real scan of the data.
2. **Creates approximate "sketches"** (tiny data structures called Theta or HLL sketches, typically 4–8 KB per column) that let the cost-based optimizer (CBO) answer "how many distinct values are in this column?" in O(1) time without re-scanning.
3. **Writes a Puffin file** — a small binary metadata file (typically hundreds of KB to a few MB) that stores these sketches alongside the table's metadata in MinIO. Filenames look like:
   ```
   s3://lakehouse/warehouse/analytics/user_events/metadata/
       00012-a1b2c3d4-...-snap-1234567890123456789.stats
   ```

Verify what was collected:
```sql
SHOW STATS FOR iceberg.analytics.user_events;
```

Expected output:
```
 column_name | data_size | distinct_values_count | nulls_fraction | row_count
-------------+-----------+-----------------------+----------------+-----------
 account_id  |   8.0E6   |       2.5E2           |     0.0        |   5.0E8
 user_id     |   8.0E6   |       1.45E5          |     0.0        |   5.0E8
```

If `distinct_values_count` is **NULL**, ANALYZE was either not run or ran for different columns.

### 3. Does it help cross-catalog joins (Iceberg × PostgreSQL)?

**Yes, genuinely — and meaningfully.** But here's the nuance: **cross-catalog joins always execute on Trino workers**, not in Postgres. There is no "cross-catalog join pushdown" feature. However, `ANALYZE` helps in a different way.

For a join like:
```sql
SELECT *
FROM iceberg.analytics.user_events e
JOIN pg_catalog.public.accounts a ON e.account_id = a.id
```

Trino must decide:
- **Which side is the "build"** (small, hashed in memory) and which is the "probe" (streamed)?
- **Broadcast or partitioned join?** (broadcast sends the build side to every worker; partitioned shuffles both sides by join key)

Without `ANALYZE`, the CBO guesses. It might assume both sides are equal size, pick the wrong build side, and either OOM the cluster (tried to broadcast a huge Iceberg table) or pick an unnecessarily expensive shuffle (should have been broadcast). With accurate stats, typical observed speedups are **2× to 10×** for small Postgres dimension × large Iceberg fact patterns.

With `ANALYZE` on the Iceberg side **AND native ANALYZE on the PostgreSQL side**, Trino's CBO knows:
- The Postgres `accounts` table has 250 distinct values → broadcast it.
- The Iceberg `user_events` table has 500M rows → use it as probe.
- Pick the cheapest strategy based on actual cardinality.

### 4. How the CBO uses NDV to choose join strategies

The CBO runs **cost estimation** at query planning time:

1. **Estimates post-filter cardinality** for each side. If your query has `WHERE event_type = 'click'` and NDV tells the CBO there are 5 distinct event types with roughly uniform distribution, it estimates `~20% of rows` pass the filter.

2. **Picks the build side** — whichever has fewer estimated rows after filters. This minimizes hash-table memory.

3. **Decides broadcast vs partitioned:**
   - Broadcast if estimated build side ≤ `join_max_broadcast_table_size` (default 100MB). All workers get a copy of the small side; each processes its slice of the probe side.
   - Partitioned if larger — shuffle both sides by join key, each worker joins its slice locally.

4. **Reserves memory** — operators allocate memory based on cardinality estimates. Wrong estimate → memory spill or OOM.

**Without ANALYZE (no NDV):** The CBO defaults to assuming ~10–50% selectivity and treats both sides as roughly equal. This is catastrophically wrong for lopsided joins (huge fact × tiny dimension).

**With ANALYZE:** Each operator's `EXPLAIN` output shows concrete `Estimates: {rows: N}` instead of question marks. Join order is typically reordered to join selective tables first.

### 5. Limitations and caveats

**Postgres side still needs native ANALYZE:**
Your coworker's advice is incomplete. For the CBO to see accurate statistics on **both** sides of the cross-catalog join, you must:

```sql
-- On the PostgreSQL replica (via psql, NOT via Trino):
ANALYZE public.accounts;
```

Then verify in Trino:
```sql
SHOW STATS FOR pg_catalog.public.accounts;
```

Expected: `distinct_values_count` and `nulls_fraction` are populated. If they're NULL, the CBO is still guessing for the Postgres side.

**Stats must be kept fresh:**
ANALYZE results don't auto-update. After large bulk ingests to the Iceberg table, re-run ANALYZE (typical cadence: weekly, or after any backfill). Stale stats can mislead the CBO — it trusts the numbers and will commit to a plan based on stale cardinality.

**One-time footgun when switching from full-table to column-specific ANALYZE:**
If you previously ran `ANALYZE iceberg.analytics.user_events;` (all columns), then later try to run a column-targeted refresh:
```sql
ANALYZE iceberg.analytics.user_events 
  WITH (columns = ARRAY['account_id', 'user_id']);
```

The old Puffin file persists and may shadow your refresh. **You MUST first drop the old stats:**
```sql
ALTER TABLE iceberg.analytics.user_events EXECUTE drop_extended_stats;
ANALYZE iceberg.analytics.user_events 
  WITH (columns = ARRAY['account_id', 'user_id']);
```

**ANALYZE fixes join planning, not data scanning:**
If your query is slow because Trino is reading millions of unfiltered Iceberg rows, ANALYZE won't fix that — partition pruning and file skipping reduce data scanned. ANALYZE only optimizes **how** the join is executed once both sides are scanned.

**Cross-catalog join pushdown does not exist:**
Even with perfect stats on both sides, the join itself always runs on Trino workers — Postgres doesn't see the Iceberg table and vice versa. But with stats, Trino makes the right decisions about build/probe assignment and broadcast/partitioned choice.

---

**Practical next step:** Run `SHOW STATS FOR iceberg.analytics.user_events` and `SHOW STATS FOR pg_catalog.public.accounts`. If either shows NULL for `distinct_values_count` on your join keys, run the relevant ANALYZE (Trino-side for Iceberg, native psql for PostgreSQL). Then re-run your join query and inspect `EXPLAIN` to confirm the build/probe side and broadcast/partitioned choice make sense.
