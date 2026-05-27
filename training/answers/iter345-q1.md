# Answer to Q1: Debezium + Postgres Schema Change (Column Added) — What Happens? (Iter 345)

Your pipeline will not crash. Debezium detects the schema change automatically. But your Iceberg target table does need a manual update before the new column data arrives, or the Spark consumer will throw an error. Here's exactly what happens and what you need to do.

## What happens when someone runs ALTER TABLE ADD COLUMN

**Step 1 — Postgres handles it instantly.** Adding a nullable column is a metadata-only operation in modern Postgres — milliseconds, no table lock, Debezium is not interrupted.

**Step 2 — Debezium picks it up via WAL RELATION messages.** The Postgres write-ahead log includes a RELATION message describing the new table layout every time a row changes after the ALTER. Debezium's default `schema.refresh.mode = columns_diff` compares its known schema to what the WAL says and silently adopts the new layout — no restart needed.

**Step 3 — New Debezium events include the new column.** Starting with the very first INSERT/UPDATE/DELETE on that table after the ALTER, Debezium emits events with the new column included in the payload.

**Step 4 — Your Spark consumer errors.** When the consumer reads an event containing the new column and tries to execute the MERGE INTO against your Iceberg table, Spark throws an `AnalysisException` — the column exists in the source event but not in the Iceberg schema. The batch fails, the Kafka offset doesn't commit, and the consumer retries the same error in a loop until you fix the Iceberg schema.

This is where you wake up to an alert — not a silent failure, but a clear `AnalysisException` in the consumer logs.

## The runbook: pause → alter Iceberg → resume

**Step 1: Pause the Spark consumer** (NOT Debezium — keep Debezium running)

```bash
kubectl scale deployment spark-events-consumer --replicas=0
```

Debezium continues streaming events into Kafka. Kafka holds them (default 7-day retention gives you plenty of headroom).

**Step 2: Add the column to your Iceberg table** (metadata-only, milliseconds)

```sql
-- Run in Trino or Spark SQL — syntax is identical
ALTER TABLE iceberg.analytics.events ADD COLUMN new_col VARCHAR;
```

Iceberg schema evolution is field-ID-based, not name-based. Adding a column creates a new field ID internally and assigns the column name to it. Existing data files are unaffected — they simply don't have values for the new field, and Iceberg returns NULL for those rows automatically.

**Step 3: Resume the consumer**

```bash
kubectl scale deployment spark-events-consumer --replicas=1
```

The consumer picks up from its last committed Kafka offset, processes the buffered events (including those with the new column), and the MERGE INTO succeeds. New column values appear in Iceberg for rows inserted/updated after the Postgres ALTER; older rows return NULL for the new column.

**Total downtime: under 60 seconds** — the bottleneck is consumer pod startup time. The Iceberg ALTER itself takes milliseconds.

## Do NOT restart Debezium

Many teams instinctively restart the Debezium connector after a schema change. Don't. The connector has already detected the schema change via the WAL RELATION message and is already emitting events correctly with the new column. A restart doesn't help and risks offset loss or re-snapshotting.

## Edge case: NOT NULL column without a default

If someone tries `ALTER TABLE events ADD COLUMN new_col VARCHAR NOT NULL` on a populated Postgres table, Postgres rejects the command immediately with an error (can't add a NOT NULL column to existing rows that have no value for it). The ALTER never commits. Debezium sees nothing. Your pipeline keeps running normally with no intervention needed.

The correct Postgres pattern is: add column as nullable → backfill values → add constraint. That's a separate conversation with your database team.

## What to build into your runbook

Document these three steps for your on-call team. Better yet, automate it: detect the `AnalysisException` in consumer logs → trigger a PagerDuty alert with the schema change runbook link. The whole process is repeatable and takes under a minute.

**Resources cited:** `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md` (sections 4–6 cover Debezium schema change detection, pause-ALTER-resume sequence, and Iceberg field-ID semantics)
