# Iter283 Q1 — Cross-Catalog Atomicity: START TRANSACTION Across Postgres and Iceberg

## Answer

No, `START TRANSACTION` in Trino does NOT give you cross-catalog atomicity. Each catalog commits independently the moment its DML statement finishes, regardless of the transaction block. If your Iceberg write succeeds and then your Postgres write fails, the Iceberg rows are already visible and there's no way to roll them back.

## What actually happens

When you write this:

```sql
START TRANSACTION;
  INSERT INTO iceberg.analytics.billing_events SELECT ...;
  INSERT INTO app_pg.public.billing_events SELECT ...;
COMMIT;
```

Here's what Trino actually does:
1. **Iceberg INSERT finishes.** Trino writes rows to MinIO, commits the metadata to Hive Metastore immediately. Those rows are now queryable.
2. **Postgres INSERT finishes (or fails).** If it fails, Trino rolls back the Postgres transaction — but the Iceberg rows are **already committed and visible**.
3. **COMMIT is a no-op.** Trino's `COMMIT` does not coordinate across catalogs. Both writes have already landed in their respective systems independently.

The fundamental reason: **Trino does not implement two-phase commit (2PC) across catalogs.** Each connector commits to its own backend the moment the DML statement completes. There is no distributed transaction coordinator, no XA protocol, no way to ask "freeze both systems and only commit if both succeed."

Postgres and Iceberg have completely different transaction models: Postgres uses MVCC and can roll back a statement if something goes wrong; Iceberg is immutable — snapshots are appended to the metadata log and there's no "undo" for a committed snapshot.

## What you should do instead

### Pattern 1: App-level coordination with idempotent retries (recommended)

Use a small **outbox/event table** in Postgres as your source of truth. Write the event as "pending" first, then asynchronously push to Iceberg, then mark "synced":

```python
# Backend handler: write to Postgres first (your source of truth)
with postgres_connection.begin():
    cursor.execute("""
        INSERT INTO billing_events (event_id, customer_id, amount, status)
        VALUES (%s, %s, %s, 'pending')
    """, (unique_event_id, customer_id, amount))
    postgres_connection.commit()

# Async worker (Spark job or Trino cron): read pending rows, push to Iceberg
with postgres_connection.begin():
    cursor.execute("""
        INSERT INTO iceberg.analytics.billing_events 
        SELECT event_id, customer_id, amount FROM app_pg.public.billing_events
        WHERE status = 'pending'
    """)
    cursor.execute("""
        UPDATE billing_events SET status = 'synced' WHERE status = 'pending'
    """)
    postgres_connection.commit()
```

If the Iceberg write fails, the Postgres row stays `'pending'` and the worker retries. Because you used a unique `event_id`, retrying is idempotent — no duplicates.

### Pattern 2: Postgres as source of truth, CDC to Iceberg

Write **only to Postgres** (your normal app write path). Use **Debezium + Kafka** to capture changes from Postgres's WAL and materialize them into Iceberg asynchronously:

```
Billing event → Postgres → Debezium reads WAL → Kafka → Consumer writes to Iceberg
```

Postgres is always the source of truth. Iceberg is eventually consistent (typically seconds to minutes behind). No two-phase commit needed — Kafka handles retries automatically.

### Pattern 3: Batch reconciliation

If sub-minute freshness for Iceberg is not critical, run a nightly or hourly batch job:

```sql
-- Hourly: sync pending events from Postgres into Iceberg
MERGE INTO iceberg.analytics.billing_events AS tgt
USING (
  SELECT event_id, customer_id, amount, created_at
  FROM app_pg.public.billing_events
  WHERE created_at >= (current_timestamp - INTERVAL '2' HOUR)  -- overlap for safety
) AS src ON tgt.event_id = src.event_id
WHEN NOT MATCHED THEN INSERT (event_id, customer_id, amount, created_at)
  VALUES (src.event_id, src.customer_id, src.amount, src.created_at);
```

The upper-bound watermark (`current_timestamp - INTERVAL '2' HOUR`) prevents the race condition where new rows arrive during the MERGE window.

## Key takeaway

Trino is an analytics query engine, not a distributed transaction coordinator. Design your billing pipeline to treat Postgres as the durable source of truth, then propagate to Iceberg using one of the three patterns above. START TRANSACTION in Trino is per-catalog only.
