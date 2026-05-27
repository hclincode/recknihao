# Iter251 Q2 — join_distribution_type Session Override for Broadcast Join

## Answer

Yes, you can force Trino to use a broadcast join with a session-level configuration. This is both **supported and practical for production use** when conditions are right — but it requires understanding when it's safe and when it's risky.

### How to force broadcast join

```sql
SET SESSION join_distribution_type = 'BROADCAST';
```

Then run your federated query:

```sql
SET SESSION join_distribution_type = 'BROADCAST';

SELECT e.event_id, e.occurred_at, a.tier_name
FROM iceberg.analytics.events e          -- ~800M rows (probe side)
JOIN app_pg.public.account_tiers a        -- ~200 rows (build side)
  ON e.account_id = a.account_id
WHERE e.occurred_at >= CURRENT_DATE - INTERVAL '30' DAY;
```

### What broadcast vs partitioned join means

**Broadcast join**:
1. Trino scans all 200 rows from Postgres (the build side)
2. Copies the entire result to **every worker** in the cluster as a hash table in memory
3. Each worker streams its local slice of the 800M events (probe side) through the in-memory hash — no network shuffle on the large side

**Partitioned join** (what you're getting now):
1. Both sides are re-hashed by join key across all workers — expensive network shuffle
2. Each worker builds a hash table on its partition of the small side, then probes with its partition of the large side
3. Full shuffle of both the 800M events AND the 200 account_tiers rows

For a 200-row dimension table, broadcast is dramatically faster: tiny table ships once to all workers, huge table never moves off its local worker.

### Why Trino picked partitioned despite accurate stats

Since `SHOW STATS FOR` already shows accurate stats, likely causes:

1. **CBO join reordering not enabled**:
   ```sql
   SHOW SESSION LIKE 'join_reordering_strategy';
   -- Should show 'AUTOMATIC', not 'NONE'
   SET SESSION join_reordering_strategy = 'AUTOMATIC';
   ```

2. **Table exceeds broadcast memory threshold**:
   ```sql
   SHOW SESSION LIKE 'join_max_broadcast_table_size';
   -- Default ~100MB; 200 rows will never hit this
   ```

3. **Stale stats on the Postgres side** — even if you ran ANALYZE, check it was on the replica (not primary) and the metadata cache was flushed.

### Verify the plan changed

```sql
SET SESSION join_distribution_type = 'BROADCAST';

EXPLAIN (TYPE DISTRIBUTED)
SELECT ...;
```

Look for `Join[BROADCAST]` in the output. If it still shows `Join[PARTITIONED]`, Trino fell back because the small side exceeds `join_max_broadcast_table_size`.

### Is it safe in production?

| Situation | Safe? |
|---|---|
| Small dimension table you know fits in memory (<500MB) | **Yes** — use it |
| Fact-to-dimension join, stats confirm dimension is small | **Yes** — faster and safer than partitioned |
| Table size near `join_max_broadcast_table_size` | **Risky** — test under full concurrent load first |
| Large-to-large join, neither side is truly small | **No** — broadcasting a multi-GB table OOMs workers |

**The actual risk**: broadcasting a larger-than-expected table to every worker can OOM your cluster. Unlike partitioned join (each worker holds only its partition), broadcast puts the full build side on every worker.

**Mitigation**: run `EXPLAIN ANALYZE` (executes the query) with BROADCAST set and check "Spilled Data Size" — if zero, broadcast is safe under your memory budget.

### How to reset

```sql
RESET SESSION join_distribution_type;
-- Or:
SET SESSION join_distribution_type = 'AUTOMATIC';
```

The `SET` applies only to your current session — it does not affect other users or persist across sessions.

### Recommended steps for your situation

1. Confirm stats are fresh on the Postgres **replica** (not primary): `ANALYZE public.account_tiers;` (run via psql on the replica)
2. Check: `SHOW SESSION LIKE 'join_reordering_strategy';` — should be `AUTOMATIC`
3. Run `EXPLAIN (TYPE DISTRIBUTED)` without SET to see current plan
4. Add `SET SESSION join_distribution_type = 'BROADCAST';` and re-run EXPLAIN — look for `Join[BROADCAST]`
5. For production: pair with resource-group limits to cap per-query memory; test under real concurrent load before deploying permanently

This override is a legitimate production tool, not just a debugging trick — as long as you've verified the dimension table is genuinely small.
