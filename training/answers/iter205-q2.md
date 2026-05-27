# Iter 205 Q2 — Postgres Declarative Partitioned Tables in Trino Federation

## Answer

### 1. How Trino's PostgreSQL Connector Sees Postgres Partitioned Tables

**The critical fact: Trino does NOT see Postgres declarative partitions as separate entities.** When you query a Postgres parent table with declarative partitioning (e.g., `events` with children `events_2025_01`, `events_2025_02`, etc.) through Trino's PostgreSQL connector, Trino creates **one single split for the entire parent table** — regardless of how many child partitions exist underneath.

One split means one JDBC connection on one Trino worker. Postgres itself handles the child-partition logic server-side.

---

### 2. Does Postgres Partition Pruning Fire When Trino Pushes a WHERE Predicate?

**Yes — if your predicate pushes down successfully.** Here's what happens:

1. **Trino evaluates whether your `WHERE created_at >= '2026-04-01'` can push down** to Postgres. Timestamp/date literals generally do push down.

2. **If pushdown succeeds**, Trino embeds the predicate into the JDBC query it sends to Postgres:
   ```sql
   SELECT id, created_at, ... FROM events WHERE created_at >= '2026-04-01'
   ```

3. **Postgres then applies its declarative-partition pruning server-side.** The Postgres query planner sees the constraint on `created_at` and identifies which child partitions are relevant (`events_2026_04`, `events_2026_05`, etc.), skipping the older ones entirely.

4. **Trino receives only the filtered rows** — not the entire 400M-row table.

The good news: **no additional Trino-side configuration is required.** Postgres partition pruning happens automatically when a selective predicate reaches Postgres server-side.

---

### 3. Verifying Partition Pruning with EXPLAIN

You must verify pushdown happened — do not assume it.

**Step 1: Check the plan with `EXPLAIN (TYPE DISTRIBUTED)`**

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.events
WHERE created_at >= DATE '2026-04-01';
```

**What to look for — successful pushdown:**
```
TableScan[table = app_pg:public.events, ...]
    constraint on [created_at]
        created_at >= DATE '2026-04-01'
```

**What a failed pushdown looks like:**
```
ScanFilterProject[filterPredicate = (created_at >= DATE '2026-04-01')]
    TableScan[table = app_pg:public.events, ...]
```

If you see `ScanFilterProject` above `TableScan` with your predicate in the filter — the predicate is NOT going to Postgres. Trino is pulling all 400M rows over JDBC and filtering them locally in-memory. This is the disaster case.

**Step 2: Runtime verification with `EXPLAIN ANALYZE`**

```sql
EXPLAIN ANALYZE
SELECT COUNT(*) FROM app_pg.public.events
WHERE created_at >= DATE '2026-04-01' AND created_at < DATE '2026-05-01';
```

Look for the **`Filtered:` line** on the TableScan node:
```
TableScan[table = app_pg:public.events, ...]
    Input: 33000000 rows (2.8GB)    ← only April rows returned
    Filtered: 91.8%                 ← Postgres pruned 91.8% server-side
    constraint on [created_at]
        created_at >= DATE '2026-04-01' AND created_at < DATE '2026-05-01'
```

`Filtered: 91.8%` confirms Postgres pruned 91.8% of rows before returning them to Trino. If `Filtered: 0%` or absent, pruning failed.

---

### 4. When Postgres Partitioning Helps vs. Doesn't Help

**Helps (with successful pushdown):**
- Simple range predicates on the partition key: `WHERE created_at >= '2026-04-01'` — pushes down, Postgres prunes child partitions
- For a 400M-row monthly-partitioned table querying one month, this can reduce data returned by 97%+
- Queries also benefit from any indexes Postgres has on the partition key

**Doesn't help (or hurts):**
- **String range predicates**: By default, string ranges do NOT push down to Postgres without the experimental `enable_string_pushdown_with_collate` flag (and even then, collation mismatches are risky). Trino pulls all 400M rows and filters locally — partition pruning never fires.
- **Complex expressions wrapping the partition column**: `WHERE YEAR(created_at) = 2026` or `WHERE DATE_TRUNC('month', created_at) = '2026-04-01'` — Trino can't always guarantee these match Postgres's partition-elimination logic. Stick to simple ranges: `created_at >= DATE '2026-04-01'`.
- **No parallelism gain in Trino**: Even with pushdown succeeding, Trino still creates **one split** for the entire parent table — one JDBC connection, one worker thread. Your 20-worker Trino cluster gets no parallelism benefit from partitioning. Partition pruning reduces the data Postgres sends; it does NOT allow Trino to read partitions in parallel.

**Important**: The PostgreSQL connector properties `partition-column` and `partition-count` (which would allow Trino to create multiple splits for parallel reads) exist **only in Starburst Enterprise** — they do NOT exist in open-source Trino 467. Your 400M-row table will always scan through a single JDBC connection regardless of Postgres partitioning.

---

### 5. Practical Recommendations for Your 400M-Row Events Table

**Step 1: Verify pushdown is happening now**

Run the `EXPLAIN (TYPE DISTRIBUTED)` above. If pushdown is working, your existing partitioning is helping — stop here for selective queries.

**Step 2: If pushdown is failing**

Simplify your predicate. Avoid wrapping the partition column in functions. Use direct range comparisons: `created_at >= DATE '...'` instead of `DATE_TRUNC('month', created_at) = ...`.

**Step 3: For analytical queries spanning multiple months**

If your typical queries scan 3+ months (150M+ rows) with aggregations like `SELECT SUM(amount) GROUP BY day`, consider **ingesting the events table into Iceberg**:

- Iceberg is columnar with partition pruning + file-skip + predicate pushdown into Parquet. A 150M-row scan is vastly faster in Iceberg than over a single JDBC stream.
- Ingest via Spark batch (`INSERT INTO iceberg_events SELECT * FROM app_pg.public.events`) for historical data, with Debezium CDC for ongoing replication.
- Trade-off: Iceberg tables have batch lag (minutes to hours), but for historical aggregations the parallelism and columnar compression more than compensate.

**Step 4: Monitor network throughput**

Even with partition pruning, single-threaded JDBC is your bottleneck. Watch your Postgres replica's outbound network during Trino scans:
- **Good**: 50–200 MB/s outbound, query completes in seconds
- **Bad**: <10 MB/s or query stalls — likely pushdown failed or predicate is too loose

---

### Summary

| Question | Answer |
|---|---|
| Does Trino see Postgres partitions as separate entities? | No — one split for the parent table |
| Does Postgres partition pruning fire with Trino's predicates? | Yes, if the predicate pushes down (date/timestamp ranges do; string ranges generally don't) |
| How to verify? | `EXPLAIN (TYPE DISTRIBUTED)` for plan shape; `EXPLAIN ANALYZE` for `Filtered:` % |
| Does partitioning give Trino parallelism? | No — still one JDBC connection regardless of partition count |
| Long-term recommendation for large analytical scans? | Ingest to Iceberg for columnar, parallel query performance |
