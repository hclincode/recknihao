# Iter49 Q2 Answer — CDC Debezium vs watermark for deletes and deduplication

**Question**: Incremental ingestion with `updated_at` watermark has two problems: (1) hard-deleted rows stay in Iceberg forever (GDPR issue), (2) duplicate events appear when Spark job retries. How does CDC with Debezium differ, and would it fix both?

---

## How CDC differs from your watermark approach

Your watermark approach asks: "which rows in Postgres have `updated_at > last_ts`?" It polls for *existing* rows that changed. It can only see rows that still exist.

CDC (Change Data Capture) via Debezium asks: "what operations happened in Postgres?" It reads from Postgres's write-ahead log (WAL) — the internal journal that records every INSERT, UPDATE, and DELETE before they're applied. Debezium streams these change events to Kafka:

- INSERT → `{op: "c", after: {id: 42, ...}}`
- UPDATE → `{op: "u", before: {...}, after: {...}}`  
- DELETE → `{op: "d", before: {id: 88, ...}, after: null}` (tombstone event)

This is the fundamental difference: **Debezium captures DELETE operations that your watermark approach is completely blind to.**

## Does CDC fix Problem 1 (hard deletes / GDPR)?

**Yes, completely.** When Postgres deletes a row, Debezium captures the DELETE event, publishes it to Kafka, and your streaming consumer can execute:

```sql
MERGE INTO iceberg.analytics.users AS t
USING (SELECT id FROM deleted_events) AS s
ON t.id = s.id
WHEN MATCHED THEN DELETE
```

The row is deleted from Iceberg in real time. This is CDC's primary advantage over watermarking — it's the only automatic pattern that propagates hard deletes without requiring soft-delete discipline in your application.

## Does CDC fix Problem 2 (duplicates on retry)?

**Mostly yes, but requires careful configuration.** CDC fixes this because Kafka holds the authoritative change history with position tracking (LSN — Log Sequence Number). If the streaming job crashes after processing events 1–100 but before committing the offset, the next run picks up at event 100 and reprocesses it. When your job uses MERGE INTO (upsert by primary key), reprocessing the same change event is idempotent — the same UPDATE or INSERT produces the same result.

The catch: this only works if your streaming job is configured for **exactly-once semantics** with proper offset management. Appending with `append()` instead of MERGE INTO would still cause duplicates on retry. The deduplication guarantee is at the change-event level; the write pattern must still be idempotent.

## The operational cost of CDC

Adding Debezium adds significant complexity:
- Postgres must have `wal_level = logical` and a replication slot created for Debezium
- Kafka cluster for the event stream (you own operations, consumer lag monitoring, rebalancing)
- Long-running Spark Structured Streaming job instead of a nightly batch job
- Exactly-once semantics configuration, state recovery on crashes
- Schema evolution handling under CDC (adding a column requires updating the Debezium schema registry)

## What to do right now without CDC

Before adopting Debezium, you can fix both problems using your existing Spark + Iceberg stack:

**For hard deletes (GDPR):**
- Switch to **soft-deletes** in Postgres: add a `deleted_at` column, change `DELETE` to `UPDATE ... SET deleted_at = NOW()`
- Add a Trino view that filters out deleted rows: `CREATE VIEW events_active AS SELECT * FROM events WHERE deleted_at IS NULL`
- Run weekly Iceberg `DELETE FROM iceberg.analytics.events WHERE deleted_at IS NOT NULL`, then `rewrite_data_files` + `expire_snapshots` to physically purge the bytes from MinIO

**For duplicates on retry:**
- Switch from `append()` to `overwritePartitions()` with a fixed batch window (e.g., "process all events from 2026-05-23") passed as a job parameter. Re-running for the same day replaces the same partition — no duplicates regardless of how many times it retries.

Both fixes are deployable today with zero new dependencies.

## When to adopt CDC

Consider CDC when you have:
- A product requirement for sub-hour freshness (not just delete hygiene)
- Hard-delete propagation in real time (GDPR with immediate erasure SLA, not just nightly cleanup)
- A data engineering team ready to own Kafka and streaming job operations

For most SaaS tables where nightly batch is acceptable, the soft-delete + `overwritePartitions()` pattern covers 90% of real-world workloads with far less operational complexity.
