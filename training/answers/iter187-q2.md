# Iter 187 Q2 — Cross-Catalog Consistency: Trino Has No Atomic Cross-System Transactions

## Answer

**Short answer: You're on your own to handle this crash scenario. Trino has no way to atomically update both Postgres and the data lake in one transaction — each system is independent. This is a critical architectural gap to plan for before you move billing data.**

---

## The core problem: Trino federation is NOT transactional across catalogs

Your scenario is: "Read from Postgres, write to Iceberg (the data lake). If something crashes in the middle, we're stuck in an inconsistent state."

Trino cannot solve this. When you write a statement like:

```sql
INSERT INTO iceberg.analytics.billing_snapshot
SELECT * FROM billing_pg.public.billing_accounts
WHERE status = 'active';
```

Trino splits this into two independent operations:
1. **Read side (Postgres)**: Trino's PostgreSQL connector queries your Postgres database. This executes inside Postgres's own transaction isolation — and from Postgres's perspective, the read is a completed, committed operation the moment Trino receives the rows.
2. **Write side (Iceberg)**: Trino writes Parquet files to object storage, then updates the Hive Metastore metadata pointer. This is governed by Iceberg's ACID guarantees — NOT shared with the Postgres read.

**There is NO user-facing transaction that wraps both operations together.** If Trino crashes, the network fails, or Hive Metastore goes down after the read but before the metadata commit, your state is:
- Postgres has already committed the read (it never knew about the write)
- Object storage may or may not have the Parquet files
- The metastore may or may not have the metadata pointer
- You don't know which side won

---

## What can fail in the middle and leave you inconsistent

1. **HMS fails after the SELECT but before the metadata commit**: Object storage gets the Parquet files (orphaned, invisible to queries), Postgres has committed the read, but Iceberg doesn't know the files exist.

2. **Trino worker dies mid-write**: Some Parquet files may have been flushed, others may not. The files that made it to object storage are orphaned.

3. **Network between Trino and object storage drops**: Partial Parquet files, orphaned metadata. Postgres is already done.

4. **Postgres replica fails after the SELECT**: The read transaction has already committed and closed. The write to Iceberg is now decoupled. If the write fails, Postgres doesn't roll anything back.

---

## How to actually handle this

**Option 1: Two-phase commit outside Trino (recommended for billing data)**

Do NOT use Trino INSERT...SELECT for this. Instead, use a dedicated Spark or Flink job (or even a Python script with proper SDK) that:

1. Reads from Postgres and buffers data or checkpoints progress
2. Writes to Iceberg and gets a commit confirmation (metadata pointer updated, HMS confirms)
3. **Only after the Iceberg write is visible** marks the Postgres read as "synced" (a flag column, a control table, or a timestamp)
4. If anything fails mid-pipeline, the job dies and you retry from the checkpoint

This gives you real atomicity because you control the order and can add idempotence.

**Option 2: Idempotence + retry (if two-phase is too complex)**

Design the read and write to be **idempotent**:
- Add a `sync_batch_id` column to the Iceberg table (UUID identifying this batch)
- Add a `synced_at` column or control table in Postgres recording this batch was migrated
- If the job crashes and retries, it detects the `sync_batch_id` already exists in Iceberg and skips the duplicate write
- Postgres' "synced_at" flag is the source of truth — NULL means not yet migrated, a timestamp means confirmed migrated

This doesn't prevent the crash itself but ensures safe retries without data corruption.

**Option 3: Accept the risk with monitoring (only for non-critical analytics)**

For non-critical snapshot tables (not billing):
- Run the Trino INSERT...SELECT, but add HMS health checks before and after
- Monitor for orphan files in object storage (use the `remove_orphan_files` procedure to clean up periodically)
- Alert on "Trino INSERT failed" — if it did, inspect the state manually and clean up

**Do NOT use this for billing data.**

---

## Why Trino doesn't and can't solve this

Trino is a **query engine**, not a **transaction coordinator**. It can query Postgres and Iceberg separately, but it has no mechanism to:
- Enroll Postgres and Iceberg in a single distributed transaction
- Coordinate a two-phase commit across them
- Roll back the Postgres read if the Iceberg write fails (Postgres has already committed; you can't un-read)

Postgres and Iceberg use different storage engines, different metadata layers (PostgreSQL transaction log vs. Iceberg `metadata.json`), and different consistency models. There is no shared transaction log. Trino cannot unify them.

---

## Bottom line for billing data

Move billing data into your lakehouse carefully:

- **Always use a dedicated job** (Spark, Flink, or a script with proper SDK) with explicit checkpointing, idempotence, and a two-phase commit discipline
- The extra operational overhead is cheap compared to a half-migrated billing table at 2 AM
- For the Iceberg side specifically: if a large INSERT fails mid-write, orphan data files accumulate in object storage. Clean them up periodically with `CALL iceberg.system.remove_orphan_files(schema_name=>'...', table_name=>'...')`
- Trino's cross-catalog INSERT is fine for non-critical analytics snapshots; it is **not** the right tool for transactional billing data movement
