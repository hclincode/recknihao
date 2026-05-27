# Iter 182 Q2 — Why More Trino Workers Don't Speed Up Postgres Federation Queries

## Answer

You're hitting one of the most counterintuitive differences between how Trino handles JDBC federation and how it handles Iceberg. It has everything to do with how **splits** work at the connector level.

---

### The single-split architecture: why your Postgres connector can't use extra workers

When Trino scans a **non-partitioned Postgres table**, the PostgreSQL connector creates **exactly ONE split for the entire table**. One split means one worker task, one JDBC connection, and one thread reading rows over the network. That's the complete parallelism budget — regardless of how many workers you have.

Compare this to Iceberg: Trino creates **one split per Parquet file**. A 10GB Iceberg table stored as 80 Parquet files becomes 80 splits, distributed across all workers in parallel. When you added three workers, Iceberg benefited immediately because those workers each grabbed splits and read in parallel. Postgres gets zero benefit because there is still only one split, assigned to one worker — the other workers sit idle for that scan.

---

### Why JDBC cannot parallelize the way Iceberg does

Iceberg's splits correspond to physical files on object storage. JDBC connectors have no such natural boundary — a Postgres table is logically one thing. Creating multiple splits would require dividing rows based on a column value range (e.g., `id BETWEEN 0 AND 1000000` on worker 1, `id BETWEEN 1000001 AND 2000000` on worker 2).

**This is possible, but OSS Trino 467 does not implement it.** The `partition-column` and `partition-count` properties that enable parallel JDBC reads exist only in **Starburst Enterprise** (the commercial fork). The GitHub issue requesting this feature for OSS Trino (issue #389) has been open since 2019 and remains unimplemented. Running `SET SESSION billing_pg.partition_column = 'id'` in OSS Trino 467 produces "Unknown session property" — the property simply does not exist.

---

### The fundamental insight: federation is a network/single-connection bottleneck

Your pure Iceberg queries got faster because **parallelism was the constraint** — more workers spread the work. Your federation queries stayed the same because **the constraint is a single JDBC connection** — one worker reading from Postgres at network throughput.

A 10M-row scan at 100K rows/second takes ~100 seconds on a single thread. Adding idle workers doesn't open new pipes; you still have the same one JDBC connection. The bottleneck is not CPU or memory — it's the sequential read over one database connection.

---

### What actually helps Postgres federation performance

Since adding workers is off the table, here's what does move the needle:

**1. Predicate pushdown** — the most impactful lever. If your WHERE clauses push to Postgres, the database filters rows before they stream over JDBC. A selective pushed-down predicate can reduce data volume by orders of magnitude. Verify with EXPLAIN:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM billing_pg.public.subscriptions s
JOIN app_pg.public.users u ON s.user_id = u.id
WHERE s.status = 'active';
```

Look for `constraint on [status]` inside the TableScan node. If you see a `ScanFilterProject` above the TableScan, that filter is running in Trino memory — Postgres returned all rows and Trino filtered them.

**2. Indexes on the Postgres replica** — predicate pushdown only helps if Postgres can use an index to satisfy it. `WHERE status = 'active'` pushes down, but if the replica lacks an index on `status`, Postgres still does a full sequential scan. Ensure your replica has the same relevant indexes as the primary.

**3. `domain-compaction-threshold`** — controls when dynamic filtering switches from a precise IN-list to a coarser BETWEEN range. If your join produces more than 256 distinct join-key values (the default), Trino compacts `WHERE tenant_id IN (101, 102, ..., 500)` to `WHERE tenant_id BETWEEN 101 AND 500`. Raise it to preserve more precise filtering:

```sql
SET SESSION billing_pg.domain_compaction_threshold = 1024;
```

No coordinator restart required — this takes effect immediately for the current session.

**4. `defaultRowFetchSize` in the JDBC URL** — increases rows fetched per round-trip, reducing round-trip overhead on large scans:

```properties
# etc/catalog/billing_pg.properties
connection-url=jdbc:postgresql://pgbouncer-billing.svc:6432/billing?prepareThreshold=0&defaultRowFetchSize=1000&socketTimeout=60
```

Trino defaults to fetching rows one at a time from JDBC. `defaultRowFetchSize=1000` fetches 1000 rows per round-trip, which alone can improve throughput noticeably for large scans.

**5. PgBouncer** — not about making one query faster, but enabling more concurrent federation queries without exhausting Postgres connection slots. Essential for production but doesn't help a single query's wall time.

---

### When the right answer is to stop federating and replicate

If your `billing_pg` queries don't have selective WHERE clauses — or the table is large enough that even a fast sequential read takes minutes — the real fix is to replicate the table to Iceberg.

Once in Iceberg, the table becomes hundreds of Parquet files. Your new workers DO help: each worker reads different files in parallel, and scan time drops proportionally with worker count. This is the architectural difference that makes federation suitable for small/selective lookups but unsuitable for large analytical scans.

Rough threshold: if a federation query consistently exceeds 2 seconds p95 after tuning predicate pushdown and indexes, or if the table is >10M rows and growing, replicate it.

---

### Summary

| Lever | Helps federation? | Why |
|---|---|---|
| **More Trino workers** | No | PostgreSQL connector = 1 split = 1 worker, regardless of cluster size |
| **Predicate pushdown** | Yes | Postgres returns fewer rows over the JDBC pipe |
| **Indexes on Postgres replica** | Yes | Enables efficient server-side filtering |
| **domain-compaction-threshold** | Yes | Keeps dynamic filter IN-list precise, not collapsed to BETWEEN |
| **defaultRowFetchSize=1000** | Yes | Reduces round-trip overhead on large scans |
| **PgBouncer** | Indirectly | Enables more concurrent queries without connection exhaustion |
| **partition-column / partition-count** | N/A | **Starburst Enterprise only** — not in OSS Trino 467 |
| **Replicate to Iceberg** | Yes (different approach) | Converts one-split-JDBC to many-split-Parquet; workers now help |
