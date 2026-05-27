# Answer to Q2: CDC — How Change Data Capture Works, and What Happens to Updates and Deletes (Iter 306)

## The Architecture: Postgres WAL → Debezium → Kafka → Spark → Iceberg

CDC streams only the actual changes — INSERTs, UPDATEs, DELETEs — the moment they happen, instead of dumping the whole table every night. Here's what happens under the hood.

### 1. Postgres Write-Ahead Log (WAL) — the source of truth

Every change in Postgres is first written to the **Write-Ahead Log (WAL)** before it commits. The WAL is a sequential, append-only log Postgres uses for crash recovery — it's an audit trail of every atomic change ever made.

Debezium taps into this WAL via **logical replication**, reading changes the moment they commit. It never reads your tables directly — it reads the WAL stream.

### 2. Debezium connector — parsing WAL into structured events

Debezium runs a **logical replication slot** in Postgres (a bookmark that says "I've read up to WAL position X; don't reclaim that WAL yet"). It reads every change and emits a structured JSON message:

```json
{
  "op": "u",
  "before": {
    "user_id": "user-42",
    "email": "alice@example.com",
    "status": "active"
  },
  "after": {
    "user_id": "user-42",
    "email": "alice@newemail.com",
    "status": "active"
  }
}
```

Operation codes: `"c"` (INSERT), `"u"` (UPDATE), `"d"` (DELETE). The `before` image shows the row before the change; `after` shows it after. Debezium captures both.

### 3. Kafka — the event bus

Debezium pushes change events to a Kafka topic (e.g., `postgres.public.users`). Kafka buffers events durably so that if your Spark job goes down, it replays from where it left off when it comes back up.

### 4. Spark Structured Streaming — consuming micro-batches

A long-lived Spark Structured Streaming job reads Kafka in micro-batches (e.g., every 60 seconds). Each micro-batch applies changes to Iceberg via MERGE INTO — not a blind append.

### 5. Iceberg — the analytics table

Every micro-batch is a single atomic snapshot. Readers see either the state before the batch or after it, never partial results.

## How Updates and Deletes Are Handled on the Analytics Side

This is the critical part. You can't append CDC events — that creates duplicate rows on UPDATE and never removes rows on DELETE.

**INSERT events:** become new rows in Iceberg, matched by primary key.

**UPDATE events:** The Debezium `before` image provides the join key. Spark executes MERGE INTO:

```sql
MERGE INTO iceberg.analytics.users t
USING kafka_updates s
  ON t.user_id = s.user_id
WHEN MATCHED THEN
  UPDATE SET email = s.after.email, status = s.after.status, updated_at = now()
WHEN NOT MATCHED THEN
  INSERT (user_id, email, status, updated_at) VALUES (s.after.user_id, s.after.email, s.after.status, now())
```

For every UPDATE in the Kafka batch, Iceberg finds the matching row by primary key and updates it in place. No duplicate — the old row is replaced.

**DELETE events:** Debezium emits `op = "d"` with only the `before` image populated (`after` is null). Spark executes:

```sql
MERGE INTO iceberg.analytics.users t
USING kafka_deletes s
  ON t.user_id = s.user_id
WHEN MATCHED THEN DELETE
```

The row is removed from the analytics table by primary key. On the analytics side, rows physically disappear (or are marked for deletion in Merge-on-Read mode).

## Postgres Prerequisites — Three Non-Negotiables

**1. Set `wal_level = logical`** in `postgresql.conf`:

```ini
wal_level = logical
max_wal_senders = 10
max_replication_slots = 10
```

Restart Postgres. This is the only change that requires a restart.

**2. `REPLICA IDENTITY FULL` on every replicated table:**

```sql
ALTER TABLE users REPLICA IDENTITY FULL;
ALTER TABLE orders REPLICA IDENTITY FULL;
```

By default, Postgres only logs PK columns in the WAL for UPDATE/DELETE. Without `REPLICA IDENTITY FULL`, Debezium's `before` image has nulls for every non-PK column, which breaks most use cases. Tradeoff: ~2x WAL volume on write-heavy tables.

**3. Create replication slot and user:**

```sql
CREATE ROLE debezium_user WITH LOGIN REPLICATION PASSWORD '...';
GRANT CONNECT ON DATABASE app TO debezium_user;
GRANT USAGE ON SCHEMA public TO debezium_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO debezium_user;

CREATE PUBLICATION debezium_pub FOR ALL TABLES;
SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
```

## Copy-on-Write vs Merge-on-Read for CDC Tables

This choice matters for high-frequency update pipelines.

**Copy-on-Write (CoW) — Iceberg's default:**  
Every MERGE INTO rewrites the entire Parquet file containing the matched row. One row changed = one full file rewrite. For 50,000 UPDATEs/minute hitting 50,000 different files, this can generate terabytes of rewrites per minute. MinIO gets hammered.

**Merge-on-Read (MoR) — right choice for high-frequency CDC:**  
Instead of rewriting files, Iceberg writes small delete files (marking rows to suppress) and appends new rows. The original files are untouched. A 50,000-UPDATE batch writes only ~50K rows of new data plus a tiny index file.

Tradeoff: reads are 5–30% slower (scans must merge data files with delete files). But the pipeline doesn't collapse under write load.

**Enable MoR for high-churn CDC tables:**

```sql
ALTER TABLE iceberg.analytics.users SET TBLPROPERTIES (
  'write.delete.mode' = 'merge-on-read',
  'write.update.mode' = 'merge-on-read',
  'write.merge.mode'  = 'merge-on-read'
);
```

Run hourly compaction to collapse accumulated delete files:

```sql
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.users',
  options => map(
    'target-file-size-bytes', '268435456',
    'delete-file-threshold', '5'
  )
);
```

**Decision rule:** Use MoR if you receive >1,000 UPDATEs per micro-batch on large tables. Otherwise CoW is simpler.

## Expected Latency and Throughput

- **Change latency:** 10–120 seconds from Postgres commit to Iceberg visibility
- **Throughput:** 10,000–100,000 changes per second depending on table size and compaction overhead
- **MinIO ingress:** Much lower than a nightly full dump for update-heavy tables

## The Honest CDC Tradeoff: Start With Hourly Batch First

CDC is not a simple upgrade. You're introducing:
- **Kafka infrastructure** — 3+ broker cluster with monitoring and failover
- **Debezium connector** — another long-running service that can fail or get stuck
- **Exactly-once semantics** — ensuring every change is applied once, not skipped or duplicated
- **Schema drift handling** — if Postgres adds a column while Debezium runs, your Spark job must handle it

**Most teams don't need CDC yet.** If your pain is "dashboards are 18 hours behind," the first fix is **hourly batch ingestion** — run your existing nightly Spark job every hour instead of once a night. This is 10x simpler than CDC and gets you to 1-hour freshness with zero new infrastructure.

Move to CDC only when:
- A business metric needs **sub-minute freshness** (fraud detection, live in-app counters)
- Hard DELETE propagation matters within minutes (GDPR right-to-erasure compliance)

**Timeline estimate for full CDC pipeline:** 2–4 weeks to stabilize (Postgres config, Kafka failures, CDC state recovery, compaction tuning).
