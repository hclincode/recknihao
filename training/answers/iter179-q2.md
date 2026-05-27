# Iter 179 Q2 — Postgres Declarative Partitioning and Trino: Splits, Pruning, and Parallelism

## Answer

**Short answer:** Trino sees your `events` parent table as one flat entity — it has no awareness of the child partitions. Postgres still prunes partitions server-side (you get the I/O reduction), but you get no parallelism across Trino workers from the Postgres-side partitioning.

---

### What Trino Sees: One Split, One JDBC Connection

Trino's PostgreSQL connector uses a **JDBC single-split model** for non-partitioned (to Trino) table scans. When you query `app_pg.public.events`:

1. Trino creates **one split** for the entire `events` parent table.
2. One Trino worker task picks up that split.
3. One JDBC connection is opened to Postgres.
4. That one worker reads all rows sequentially over the network.

**Adding more Trino workers does not help.** Even with a 50-worker cluster, only one worker is doing the JDBC read. The other 49 are idle for this table scan.

This is fundamentally different from Iceberg, where Trino creates one split per Parquet file and reads them all in parallel:

| Scenario | Splits Created | Trino Parallelism |
|---|---|---|
| Postgres `events` (any partitioning) | 1 | Single-threaded JDBC read |
| Iceberg `events` with 100 Parquet files | 100 | 100 parallel worker reads |

---

### Postgres-Side Pruning Still Works (But Invisibly)

Here's the good news: Postgres **does** prune child partitions at the server level. If you query:

```sql
SELECT * FROM app_pg.public.events
WHERE event_date >= '2025-02-01' AND event_date < '2025-03-01';
```

Postgres's planner identifies which child partitions match that range and only scans `events_2025_02`. The rows returned to Trino are only the matching month's data. This reduces the data volume flowing over the JDBC connection — a real improvement over a full-table scan.

**But this pruning is invisible to Trino.** Trino still opened one JDBC connection to the parent table and read sequentially. It just happened to read fewer rows because Postgres did the work internally. You see this in `EXPLAIN ANALYZE` as a low `Input:` row count compared to the full table size.

---

### How to Get Parallelism: The `partition-column` Property

If you need true parallel reads across Trino workers, the PostgreSQL connector has a `partition-column` property that artificially splits the table into N parallel range scans:

**Catalog-level (in `etc/catalog/app_pg.properties`):**
```properties
partition-column=event_id
partition-count=10
```

**Per-session (requires catalog prefix):**
```sql
SET SESSION app_pg.partition_column = 'event_id';
SET SESSION app_pg.partition_count = 10;
```

With `partition-count=10`, Trino creates 10 splits. Each split opens its own JDBC connection and reads a range (e.g., `WHERE event_id BETWEEN 0 AND 999999`). Ten workers read in parallel — 10× the throughput.

**Requirements and tradeoffs:**
- `partition-column` must be a **numeric, UUID, or date-typed** column with reasonably uniform distribution.
- 10 splits = 10 simultaneous JDBC connections to Postgres. Manage connection pressure with **PgBouncer** (`pool_mode = transaction`, `default_pool_size` capping real backend connections) and `ALTER ROLE trino_reader CONNECTION LIMIT` on Postgres.
- Each partition range scan uses its own query plan in Postgres — more load on the Postgres planner.
- Skewed partition-column distribution (e.g., all recent event_ids clustered in last 10%) produces uneven splits where one worker does 90% of the work.

---

### What Postgres Partitioning Does NOT Give You Through Trino

- **No automatic Trino parallelism.** Postgres child partitions do not translate to Trino splits.
- **No split-level pruning in Trino.** Trino doesn't know which child partitions hold relevant data — that's Postgres's job.
- **No protection against large scans without a predicate.** `SELECT * FROM events` with no WHERE clause: Postgres reads all children, Trino gets the full result as one slow sequential stream.

---

### When to Use Postgres Partitioning vs Migrate to Iceberg

**Keep Postgres partitioning for:**
- OLTP maintenance benefits: smaller VACUUM scope, faster partition drops, index sizes per child
- Selective queries with date range filters (Postgres prunes server-side; Trino benefits from reduced data volume)
- Low-frequency federation where query latency is acceptable

**Migrate the table to Iceberg if:**
- You run frequent unselective scans (full-table aggregations, no time filter)
- You need true parallel reads for throughput at scale
- Iceberg's hidden partitioning and file-level statistics match your query patterns better
- You want Trino to control pruning rather than relying on Postgres

**The hybrid pattern** (common in practice): keep the live Postgres `events` table for OLTP writes, and use Debezium CDC or nightly Spark ingestion to replicate it into an Iceberg table on MinIO. Run your heavy analytical queries against the Iceberg copy; use Trino federation only for lightweight lookups against recent data.

---

### Summary

| Question | Answer |
|---|---|
| Does Trino see Postgres child partitions separately? | No — one parent table = one split. |
| Does Postgres partition pruning help? | Yes, but inside Postgres invisibly. Reduces data over JDBC; Trino still reads from one connection. |
| Do Postgres partitions enable Trino parallelism? | No. Use `partition-column` property if you need that. |
| How do I get parallel Postgres reads in Trino? | Set `partition-column` to split into N numeric ranges; each read by a separate JDBC connection/worker. |
| Best long-term approach for large event tables? | Replicate to Iceberg via CDC/Spark for analytics; federate only for recent/lightweight lookups. |
