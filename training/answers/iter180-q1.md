# Iter 180 Q1 — When to Stop Federation and Replicate to Iceberg

## Answer

### The Core Problem: JDBC Single-Split Architecture

OSS Trino 467's PostgreSQL connector has a hard architectural limit: for each non-partitioned Postgres table, Trino creates exactly **one split** — one worker, one JDBC connection, one thread reading rows sequentially. There is no `partition-column` or parallel-read property in OSS Trino 467 (that's Starburst Enterprise only). A 10M-row scan takes roughly 50–200 seconds minimum, with zero ability to add workers to speed it up.

This is why federation works fine for small lookups but breaks for large analytical scans.

---

### Rule-of-Thumb Thresholds

Stop attempting federation and replicate when **two or more** of these are true:

| Signal | Threshold | Why it matters |
|---|---|---|
| **Table size** | >10M rows and growing >10%/month | Incremental ingestion becomes more efficient; single-thread JDBC throughput is the ceiling |
| **Query latency** | >2s p95 with predicate pushdown in place | Signals scan is network-bound or hitting JDBC throughput ceiling |
| **Query frequency** | >3–5 queries/min on the same table | Single JDBC connection under concurrent load saturates |
| **Result set size** | >1M rows returned per query | Streaming millions of rows over one JDBC connection becomes the bottleneck |
| **Connection pressure** | Hitting PgBouncer pool size or role CONNECTION LIMIT during peak | Federation is saturating replica connection slots |

**Most reliable single indicator:** Run `EXPLAIN ANALYZE` on your federation query. If `Filtered:` on the Postgres `TableScan` is below 80%, you're pulling too much data over the wire — replicate instead.

---

### The Trade-Off

**Federation is the right choice when:**
- Table is <10M rows
- WHERE clauses are highly selective and push down (equality on indexed columns, ranges on timestamps)
- Queries are infrequent

**Replication is worth the overhead when:**
- Table is >10M rows OR queries are slow even with pushdown OR concurrent volume is high
- You can tolerate ingestion lag (hours to minutes depending on freshness SLA)
- You have Spark and Iceberg already running (you do — it's in your stack)

---

### Three Ingestion Patterns (in your stack: Spark + Iceberg + MinIO)

**Pattern A: Full Refresh (Simplest)**
Nightly Spark reads the entire Postgres table and overwrites the Iceberg table.

```python
df = spark.read.jdbc(
    url="jdbc:postgresql://replica:5432/appdb",
    table="public.orders",
    properties={"user": "trino_reader", "password": "..."})
df.writeTo("iceberg.analytics.orders").using("iceberg").createOrReplace()
```

Use when: table is <10M rows, daily freshness is acceptable.

**Pattern B: Incremental Append (Most Common)**
Spark reads only rows changed since the last watermark and appends to Iceberg.

```python
last_ts = read_watermark()
df = spark.read.jdbc(
    url="jdbc:postgresql://replica:5432/appdb",
    table=f"(SELECT * FROM public.orders WHERE updated_at > '{last_ts}') as t",
    properties={...})
df.write.mode("append").format("iceberg").save("s3a://lakehouse/orders")
write_watermark(df.agg({"updated_at": "max"}).collect()[0][0])
```

Use when: table is >10M rows, same-day freshness needed, rows are mutable.

**Watermark column guide:**
- `created_at` — catches inserts only, misses UPDATEs
- `updated_at` — catches both inserts and updates (most common choice); index it in Postgres
- `xmin` — Postgres system column; catches both, but not indexable and wraps at ~4B transactions

**Pattern C: Change Data Capture via Debezium**
Stream inserts/updates/deletes from Postgres WAL → Kafka → Spark → Iceberg.

Use when: sub-hour freshness required, hard DELETEs must propagate, or real-time analytics needed. More operational overhead (Debezium + Kafka + Spark all running in k8s).

---

### Two Critical Gotchas

**1. Late-arriving events with `overwritePartitions()`**

If `occurred_at` and `updated_at` can differ (mobile apps queue old-timestamped events), `overwritePartitions()` silently deletes data in the old partition. Fix: use `MERGE INTO` or expand the DataFrame to include all rows for affected partitions, not just the delta.

**2. Missing index on the watermark column**

Before running the first incremental job:
```sql
SELECT indexname FROM pg_indexes
WHERE tablename='orders' AND indexdef LIKE '%updated_at%';
```
If empty, add it:
```sql
CREATE INDEX CONCURRENTLY idx_orders_updated_at ON orders (updated_at);
```
Without it, nightly incremental jobs do a full sequential scan of 50M rows instead of a quick index range scan.

---

### Decision Framework

```
Table > 10M rows?
├─ No → Stay on federation (use read replica + predicate pushdown)
└─ Yes → Queries < 2s p95 after tuning?
        ├─ Yes → Federation is fine
        └─ No → Replicate
               ├─ Append-only? → Pattern A (full refresh nightly)
               └─ Mutable rows? → Pattern B (incremental + updated_at)
                                  └─ Sub-hour freshness? → Pattern C (CDC/Debezium)
```
