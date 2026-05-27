# Iter252 Q2 — EXPLAIN Distribution Labels for Broadcast Join

## Answer

Yes, `Distribution: REPLICATED` is exactly what you're looking for — it confirms the broadcast join was applied.

### Understanding REPLICATED vs PARTITIONED

**`Distribution: REPLICATED` means broadcast join:**
- The small lookup table (your Postgres table) is **read once and copied to every worker**
- Every Trino worker gets a complete copy in local memory
- The large table (your Iceberg table) is scanned normally on each worker — no network shuffle of the large side
- In EXPLAIN output: `RemoteExchange[REPLICATE, BROADCAST, []]` appears above the scan of your Postgres lookup table

**`Distribution: PARTITIONED` means hash-shuffle join:**
- **Both tables** are shuffled across workers by the join key
- Both sides travel over the network — expensive for large tables
- In EXPLAIN output: `RemoteExchange[REPARTITION, HASH, [join_key_columns]]` on both sides

### How to read the EXPLAIN output

Look for the `RemoteExchange` node above each side of the join:

```
RemoteExchange[REPARTITION, HASH, [user_id]]     -- Iceberg events: no shuffle in broadcast mode
    TableScan[iceberg.analytics.events]
InnerJoin on user_id
RemoteExchange[REPLICATE, BROADCAST, []]          -- Postgres lookup: replicated to all workers
    TableScan[app_pg:public.lookup_table]
```

This pattern (REPLICATE on the small Postgres side, no repartition on the Iceberg side) confirms broadcast join is active.

### Confirming it took effect

After `SET SESSION join_distribution_type = 'BROADCAST'` and re-running `EXPLAIN (TYPE DISTRIBUTED)`, look for:
- `REPLICATE` on the Exchange above your Postgres lookup table → broadcast was applied ✓
- `REPARTITION` on the Exchange above your Iceberg table → PARTITIONED mode instead (broadcast fell back)

If you expected REPLICATED but got REPARTITION:
1. The Postgres table exceeded `join_max_broadcast_table_size` (default: ~100 MB) — add a more selective WHERE filter
2. Table statistics are missing — run `ANALYZE` on the Postgres PRIMARY and check `SHOW STATS FOR`
3. Override: `SET SESSION join_max_broadcast_table_size = '500MB'` if workers have enough heap

### RemoteExchange label breakdown

`RemoteExchange[REPLICATE, BROADCAST, []]`:
- `REPLICATE` = copy-to-all-workers distribution strategy
- `BROADCAST` = keyword name for this strategy
- `[]` = no specific columns; all rows go to all workers

`RemoteExchange[REPARTITION, HASH, [user_id]]`:
- `REPARTITION` = hash-shuffle strategy
- `HASH, [user_id]` = shuffle by the `user_id` join column
