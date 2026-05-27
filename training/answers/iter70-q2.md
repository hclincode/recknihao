# Iter70 Q2 — Answer

**Question**: I'm building a pipeline to copy several related Postgres tables into Iceberg so we can run analytics on them in Trino. The tables have foreign key relationships — `orders` references `users`, and `order_items` references `orders`. In Postgres, the database enforces these relationships so you'd never end up with an orphaned order_item. But I assume Iceberg is just storing files and has no idea these relationships exist. Two things I'm not sure about: first, does the order I ingest these tables into Iceberg matter — should I always finish ingesting `users` before I start on `orders`, and `orders` before `order_items`? Second, what actually happens in practice if the pipeline partially fails and some `order_items` rows make it into Iceberg before the corresponding `orders` rows do? Will JOIN queries in Trino silently drop those rows and give me wrong counts, or will something error, or is there a standard way teams handle this to prevent bad data from reaching the dashboard?

---

## Answer

You're right to be concerned — Iceberg has no foreign key constraints, and handling multi-table dependencies is a real pain point in pipeline design. Here's what actually happens and the safe patterns.

### Does ingestion order matter?

**Yes, but only from a consistency standpoint.** Iceberg won't error if you ingest `order_items` before `orders` — there's no constraint to violate. But your queries will silently give you wrong numbers.

**The safe rule:** always ingest parent tables before child tables:
1. Ingest `users` first
2. Then ingest `orders`
3. Finally ingest `order_items`

This isn't required by Iceberg, but it means if the pipeline crashes mid-run, you'll have parents complete and children potentially stale — a safer half-state than the reverse.

### What happens when child rows arrive without parents (the real problem)

If `order_items` rows exist in Iceberg without corresponding `orders` rows, and your analyst runs:

```sql
SELECT o.order_id, COUNT(*) AS item_count
FROM order_items oi
LEFT JOIN orders o ON o.order_id = oi.order_id
WHERE o.order_id IS NOT NULL
GROUP BY o.order_id;
```

The `WHERE o.order_id IS NOT NULL` silently drops the orphaned rows. No error fires. The dashboard shows the wrong number. You'd only catch it with a manual reconciliation query:

```sql
SELECT COUNT(*) AS orphaned_items
FROM iceberg.analytics.order_items oi
WHERE NOT EXISTS (SELECT 1 FROM iceberg.analytics.orders o WHERE o.order_id = oi.order_id);
```

If this returns > 0, you have a problem. This is the key point: **Trino does not error on orphaned child rows — it silently drops them from INNER JOINs and misrepresents them in LEFT JOINs.** There's no safety net at read time.

### The standard fix: idempotent batch ingestion with a shared window

The root cause of partial-failure orphan rows is usually non-idempotent pipelines. Consider what happens with a mutable watermark:

1. T1: Ingest `orders` — 50,000 rows land in Iceberg. Watermark advances.
2. T2: Spark crashes before `order_items`.
3. T3: You restart the job. The watermark already advanced past the `orders` batch, so `orders` doesn't re-read. But `order_items` starts fresh from the old watermark.
4. T4: Some `order_items` reference `orders` that now exist in Iceberg (from T1), but others reference orders written AFTER T2 — which never made it.

The fix: **use `overwritePartitions()` with a fixed batch-date parameter, not a mutable watermark.**

```python
batch_date = "2026-05-25"

# Step 1: users (parent)
users_df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM users WHERE updated_at >= '{batch_date}' AND updated_at < '{batch_date}'::date + interval '1 day') t",
    properties=PG_PROPS,
)
users_df.writeTo("iceberg.analytics.users").overwritePartitions()

# Step 2: orders (child of users)
orders_df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM orders WHERE created_at >= '{batch_date}' AND created_at < '{batch_date}'::date + interval '1 day') t",
    properties=PG_PROPS,
)
orders_df.writeTo("iceberg.analytics.orders").overwritePartitions()

# Step 3: order_items (child of orders)
order_items_df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM order_items WHERE created_at >= '{batch_date}' AND created_at < '{batch_date}'::date + interval '1 day') t",
    properties=PG_PROPS,
)
order_items_df.writeTo("iceberg.analytics.order_items").overwritePartitions()
```

The job is **stateless** — no watermark file. Re-running for `batch_date=2026-05-25` 100 times produces the exact same Iceberg state every time. This is idempotent. Partial failures become harmless: re-run the job for the same date and it overwrites whatever partial state exists.

**Critical: set pgjdbc fetchsize.** By default, the Postgres JDBC driver fetches ALL rows into memory at once (`fetchsize=0`). For large tables like `order_items`, this will exhaust heap. Add to your JDBC properties:

```python
PG_PROPS = {
    "user": "...",
    "password": "...",
    "driver": "org.postgresql.Driver",
    "fetchsize": "10000",
    "sessionInitStatement": "SET work_mem = '256MB'",
}
```

Without this, your Spark driver will OOM on any sufficiently large table.

### Run all three tables in a single Spark job

Don't create a DAG where `users` completes, then `orders` starts as a separate job, then `order_items` starts as another. That multiplies partial-failure scenarios. One job, three sequential table writes, runs all-or-nothing:

```
spark-submit ingest_related_tables.py --batch_date 2026-05-25
```

If any step fails, the whole job fails. Re-run it for the same date and it overwrites. Clean state guaranteed.

### Monitor for orphaned rows as a canary

Add a daily data quality check:

```sql
-- No rows should ever appear here if your pipeline is idempotent
SELECT COUNT(*) AS orphaned_items
FROM iceberg.analytics.order_items oi
WHERE NOT EXISTS (
  SELECT 1 FROM iceberg.analytics.orders o
  WHERE o.order_id = oi.order_id
);
```

If this ever returns > 0, it means either:
- Your pipeline had a partial failure and the idempotent re-run hasn't happened yet
- Postgres itself violated referential integrity (very unlikely but check anyway)
- A different pipeline is writing to these tables without the same safety guarantees

Alert on this. It's your earliest warning that something is wrong before analysts start reporting wrong numbers.

### For sub-day freshness: MERGE INTO with staggered watermarks

If you genuinely need near-real-time freshness and can't wait for a daily batch, use MERGE INTO (upsert) instead of `overwritePartitions()`, and stagger your watermarks:

- All three tables read up to timestamp `T - 15min` (not the current moment)
- The lag buffer ensures that by the time `order_items` reads, the corresponding `orders` rows have been ingested in a prior run
- Never read up to "now" — always read up to a fixed lag behind real-time

This is significantly more complex. Use it only if daily freshness is genuinely insufficient for your use case.

### One thing you cannot do: enforce FK constraints in Iceberg

Iceberg does not support FOREIGN KEY constraints. There is no way to make Iceberg reject an `order_items` row at write time because the referenced `order_id` doesn't exist in `orders`. The protection must come from your pipeline design (idempotency + parent-first ordering), not from the storage layer.

This is actually fine — once your pipeline is idempotent, partial states are impossible, so orphaned rows can only happen if Postgres itself violated referential integrity.

### Summary

| Concern | Answer |
|---|---|
| Does ingestion order matter? | Yes — always parent before child (users → orders → order_items) |
| What happens with orphaned child rows? | JOINs silently drop them, wrong counts, no error |
| How to prevent orphans? | `overwritePartitions()` with fixed batch-date, all tables in one Spark job |
| How to detect orphans? | Daily SQL reconciliation query; alert if count > 0 |
| Can Iceberg enforce FK constraints? | No — protection must come from pipeline design |
