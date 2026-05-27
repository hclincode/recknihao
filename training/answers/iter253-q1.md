# Iter253 Q1 — Broadcast Join EXPLAIN Plan Structure

## Answer

Your coworker is exactly right. In a correct **broadcast join**, the large Iceberg events table should NOT have any `RemoteExchange` node above its table scan. Here is what to look for.

## The Key Rule

When you see `EXPLAIN (TYPE DISTRIBUTED)` output for a join, count the `RemoteExchange` nodes that mention `REPARTITION` or `REPLICATE`:

**Broadcast join (correct behavior for small dim × large fact):**
- **Exactly ONE** `RemoteExchange[REPLICATE, BROADCAST, []]` — appears ONLY above the small Postgres table scan
- **NO** `RemoteExchange[REPARTITION, ...]` above the large Iceberg events scan
- One additional `RemoteExchange[GATHER]` at the top for final result collection (unrelated to join distribution)

**Partitioned join (both sides shuffled):**
- **TWO** `RemoteExchange[REPARTITION, HASH, [<join_key>]]` nodes — one above the Iceberg scan AND one above the Postgres scan
- Plus the top-level `RemoteExchange[GATHER]`

## What the Exchanges Mean

**`RemoteExchange[REPLICATE, BROADCAST, []]` above the build side (Postgres):**
This is the broadcast marker. The empty `[]` (no join key) means the small table is sent in full to EVERY worker, regardless of key value. Every worker gets a copy to build the in-memory hash table.

**NO exchange above the probe side (Iceberg events) — this is critical:**
The large events table stays put. Each worker scans only its own local file splits directly from MinIO. The `[]` empty key list in REPLICATE confirms: the build goes everywhere because it is replicated, not partitioned. The probe never gets a RemoteExchange at all.

**`LocalExchange[HASH]` between build and join:**
This lives inside each worker's JVM (one worker only). It is NOT a network shuffle. Trino is just redistributing the broadcasted rows across local driver threads within that worker to build the hash table in parallel.

## A Complete Correct Broadcast Join EXPLAIN (Trino 467)

```
Fragment 0 [SINGLE]
    Output[...]
        Aggregate(FINAL)[tenant_name]
            RemoteExchange[GATHER]                                    -- result collection to coordinator
                Aggregate(PARTIAL)[tenant_name]
                    InnerJoin[e.tenant_id = t.id]                     -- hash join runs on every worker
                        TableScan[iceberg:analytics.events]           -- PROBE side: NO exchange above
                            dynamicFilters = {tenant_id = #df0}       -- DF from build prunes files
                        LocalExchange[HASH]                           -- local to this worker, not network
                            RemoteExchange[REPLICATE, BROADCAST, []]  -- BUILD side: sent to all workers
                                TableScan[app_pg:public.tenants]
```

**What to look for, line by line:**

| Plan node | Meaning |
|---|---|
| `RemoteExchange[REPLICATE, BROADCAST, []]` above the build (Postgres) scan | **The broadcast marker.** The `[]` empty key list confirms it is NOT hash-partitioned — it goes to all workers. |
| **NO `RemoteExchange[REPARTITION, ...]` above the probe** (Iceberg events) scan | **This is the entire point of broadcast mode.** Each worker reads its own local file splits directly. If you see `RemoteExchange[REPARTITION, HASH, ...]` above the probe scan, the join is NOT broadcast — it is PARTITIONED. |
| `dynamicFilters = {tenant_id = #df0}` on the probe TableScan | Dynamic filter arrived from the completed build side and is pruning probe-side files at the manifest level before they are read. |
| `LocalExchange[HASH]` between the broadcasted build and the join operator | Local to each worker (no network). Trino redistributes the broadcasted build rows across local driver threads to build the in-memory hash table in parallel. |
| `RemoteExchange[GATHER]` at the top | Coordinator collects partial aggregates from workers for the final GROUP BY. Normal and unrelated to join distribution. |

## Contrast: PARTITIONED Plan (Both Sides Have REPARTITION)

```
Fragment 0 [SINGLE]
    Output[...]
        Aggregate(FINAL)[tenant_name]
            RemoteExchange[GATHER]
                Aggregate(PARTIAL)[tenant_name]
                    InnerJoin[e.tenant_id = t.id]
                        RemoteExchange[REPARTITION, HASH, [tenant_id]]    -- PROBE shuffled by join key
                            TableScan[iceberg:analytics.events]
                                dynamicFilters = {tenant_id = #df0}
                        LocalExchange[HASH]
                            RemoteExchange[REPARTITION, HASH, [id]]       -- BUILD also shuffled by join key
                                TableScan[app_pg:public.tenants]
```

## Interpreting Your EXPLAIN Output

If you see `RemoteExchange[REPARTITION, HASH, [join_key]]` **above the Iceberg events scan**, the join is **NOT broadcast — it is partitioned**. Both the 2-billion-row events table AND the Postgres table are being shuffled across the network by the join key.

**The diagnostic rule:**
- **Broadcast** = exactly ONE `RemoteExchange[REPLICATE, BROADCAST, []]` (over the build), plus a top-level `GATHER`. The probe scan is bare.
- **Partitioned** = TWO `RemoteExchange[REPARTITION, HASH, [<key>]]` nodes (one per side), plus a top-level `GATHER`. Both sides shuffle.

## Why You Might Get PARTITIONED When You Expected BROADCAST

When you see `REPARTITION` above the probe, the usual culprits:

1. **Missing statistics** — The CBO (cost-based optimizer — the part of Trino's query planner that decides join order, build/probe sides, and broadcast vs partitioned distribution) cannot estimate the Postgres table size accurately without stats, so it defaults to PARTITIONED. Run native `ANALYZE` on the Postgres PRIMARY (not the read replica, which rejects ANALYZE as a hot standby), then flush Trino's metadata cache: `CALL app_pg.system.flush_metadata_cache()`. Then verify: `SHOW STATS FOR app_pg.public.tenants`.

2. **Table estimate exceeded the broadcast threshold** — Trino defaults to `join_max_broadcast_table_size = 100MB`. If the CBO estimates your Postgres table exceeds this, it partitions instead. With 800 rows this is unlikely, but verify with `SHOW STATS FOR`.

3. **Forced distribution** — Check `SET SESSION join_distribution_type` in your session or catalog properties. If set to `'PARTITIONED'`, override with `SET SESSION join_distribution_type = 'BROADCAST'` and re-run `EXPLAIN (TYPE DISTRIBUTED)`.

## What to Do Next

Run `EXPLAIN (TYPE DISTRIBUTED)` on your join query and scan the output:

1. Count `RemoteExchange[REPARTITION, ...]` nodes — if zero (apart from the final GATHER), you have broadcast
2. If there are two, investigate missing stats: `SHOW STATS FOR iceberg.analytics.events` and `SHOW STATS FOR app_pg.public.tenants`
3. Check `distinct_values_count` and `row_count` are populated — if NULL, stats are missing
