# Real-Time vs Batch Analytics: What SaaS Engineers Actually Need to Know

## Quick answer (TL;DR)

- Data freshness is a **spectrum**, not a binary choice between "real-time" and "batch."
- Each freshness tier (daily, hourly, 15-min, sub-second) is roughly **10x more complex and expensive** than the one above.
- When a PM says "real-time," they usually mean "within an hour" — push back before building Kafka.
- Every event table needs two timestamps: `occurred_at` (when it happened) and `ingested_at` (when you got it). Use the right one for the right query.
- On your stack (Iceberg + Spark + Trino), start with **hourly incremental Spark jobs**. Add streaming only when a real business metric demands it.

---

## The spectrum of data freshness

Stop thinking "real-time vs batch." Think in tiers:

| Freshness tier | Typical lag | How it works | When you need it |
|---|---|---|---|
| Real-time | <1 second | Direct DB query, or streaming materialized views | Live feature flags, in-app metrics shown to end users right now |
| Near-real-time | 1–15 minutes | Micro-batch Spark, or Kafka + Spark Structured Streaming writing to Iceberg | Operational dashboards, alerting, fraud signals |
| Fresh batch | 1–4 hours | Incremental Spark job: `SELECT ... WHERE updated_at > last_run_ts` | Internal dashboards, daily reporting refreshed during the workday |
| Daily batch | 24 hours | Nightly full or incremental load | Deep analytics, cohort analysis, funnels, monthly invoicing |

Pick the **slowest tier that satisfies the real requirement.** Cheaper to operate, simpler to debug, easier to backfill.

---

## The cost of freshness

Moving up a tier is not a 2x jump — it is closer to 10x in complexity and ops burden:

- **Daily to hourly**: 24x more Spark job runs per day, more k8s pod churn, more job-failure noise to triage.
- **Hourly to 15-minute**: you can no longer afford to re-scan source tables. You need true incremental ingestion with careful watermarking (tracking "what is the latest event time I have safely seen?").
- **15-minute to sub-minute**: you now need CDC (Change Data Capture), Kafka, streaming joins, stateful aggregations, exactly-once semantics, schema evolution handling, and a Kafka operator on call.

The rule: **choose the slowest tier that satisfies your PM's real requirement.** Most PMs who say "real-time" actually mean "within an hour" once you ask "would 30 minutes be acceptable?"

---

## The late-arriving events problem

Scenario: a mobile app loses Wi-Fi at 9:00 AM. The user keeps clicking. The app buffers events locally. At 9:30 AM the phone reconnects and dumps 30 minutes of events at your server.

The event timestamp says 9:00 AM. Your server received it at 9:30 AM. Your 9:15 AM dashboard already "closed the window" without that data.

**Every SaaS event table should have two timestamp columns:**

- `occurred_at` — when the event happened on the user's device (user/client time).
- `ingested_at` — when your system received and wrote it (server time, monotonic).

Which to use when:

- **Funnel queries, retention, cohort analysis** → `occurred_at` (you care about the real user behavior timeline).
- **Monitoring your ingestion pipeline / SLAs** → `ingested_at` (you care about your system's behavior).
- **DAU/WAU dashboards** → `occurred_at`, but **add a buffer window**. Don't query yesterday's data at 00:00:01 — wait until 02:00 so late arrivals settle. Or, mark dashboards as "data through 2 hours ago."

In Iceberg, partition by `ingested_at` (predictable, monotonic — good for pruning files during incremental reads) and query/aggregate by `occurred_at` (business-meaningful).

> **Performance warning: querying by `occurred_at` on an `ingested_at`-partitioned table bypasses partition pruning.**
>
> When you partition by `day(ingested_at)` but filter only by `occurred_at` in your query, Iceberg **cannot use the partition index for `occurred_at`** (because `ingested_at` is the partition column, not `occurred_at`). The query planner falls back to file-level column statistics (per-file min/max for `occurred_at`). For large tables this can be significantly slower than a partition-pruned scan — every manifest entry must be evaluated and many more files opened.
>
> **The "correct" answer that returns right results but scans the whole table:**
> ```sql
> -- CORRECTNESS-OK, PERFORMANCE-BAD: no partition pruning, falls back to file stats only.
> SELECT tenant_id, COUNT(*) FROM iceberg.analytics.events
> WHERE occurred_at >= TIMESTAMP '2026-05-21 00:00:00'
>   AND occurred_at <  TIMESTAMP '2026-05-22 00:00:00'
> GROUP BY tenant_id;
> ```
>
> **Fix — add a bounded `ingested_at` predicate alongside the `occurred_at` filter to recover partition pruning:**
> ```sql
> -- PARTITION-PRUNED via the bounded ingested_at window; same correct result.
> SELECT tenant_id, COUNT(*) FROM iceberg.analytics.events
> WHERE occurred_at >= TIMESTAMP '2026-05-21 00:00:00'
>   AND occurred_at <  TIMESTAMP '2026-05-22 00:00:00'
>   AND ingested_at >= TIMESTAMP '2026-05-21 00:00:00'   -- prune via partition key
>   AND ingested_at <  TIMESTAMP '2026-05-27 00:00:00'   -- 6 days covers a 5-day late-arrival window
> GROUP BY tenant_id;
> ```
>
> **How to size the `ingested_at` window:** set it to your known **maximum late-arrival delay plus 1 day of buffer**. For a mobile-app event source where the worst observed late arrival is 5 days (devices that have been offline that long), use a 6-day `ingested_at` window. Without the bounded `ingested_at` predicate, every query that filters only on `occurred_at` must scan files across all ingestion partitions in the table — months of data for a one-day question.
>
> **Why not just partition by `day(occurred_at)` instead?** It's a valid alternative pattern: partition by `day(occurred_at)`, accept that late-arriving files land in correct historical partitions, and use `MERGE INTO` to deduplicate on re-delivery. This is simpler for teams that don't mind writes touching historical partitions, but it complicates incremental compaction (any day's partition can grow at any time) and breaks the "files are immutable once a day closes" mental model that some teams rely on for archival workflows. The `ingested_at`-partitioned pattern is the standard choice for high-throughput event tables; the `occurred_at`-partitioned pattern is the standard choice for low-throughput tables where simplicity matters more than incremental-write isolation.

---

## What "streaming" actually means for your stack

The typical CDC streaming pipeline, one sentence per component:

1. **Postgres WAL (Write-Ahead Log)** — every change to your operational DB is written here for crash recovery; we tap into it.
2. **Debezium** — a connector that reads the WAL and emits each row change as a structured message.
3. **Kafka** — a durable message queue holding those change events, decoupling the producer (Debezium) from consumers.
4. **Spark Structured Streaming** — a long-running Spark job that reads Kafka in micro-batches (e.g., every 30 seconds) and applies the changes.
5. **Iceberg table on MinIO** — the destination; Iceberg supports streaming writes natively and handles the metadata commits.

**Why you probably don't need this yet:**

- Most SaaS teams reach $10M ARR on daily or hourly batch ingestion. Streaming is rarely the first bottleneck.
- Streaming introduces: schema-drift handling, exactly-once delivery semantics, Kafka operations, consumer lag monitoring, state-store size management, and a new on-call rotation.
- The standard path: **start with hourly incremental Spark jobs reading from a read-replica of Postgres.** Add Debezium + Kafka only when a business metric (fraud detection, live in-app counters) genuinely requires sub-minute freshness.

---

## Iceberg streaming support on your stack

Iceberg 1.5.2 supports streaming writes natively via Spark Structured Streaming. You can `writeStream` directly to an Iceberg table — each micro-batch becomes an atomic Iceberg commit.

### Operational considerations — the small-files problem from high-frequency commits

**This is the single biggest operational cost of streaming or micro-batch writes into Iceberg.** It is the reason most teams should not adopt streaming until a business metric demands it.

**Why it happens.** Every Iceberg commit produces at least one new data file per partition being written. A streaming job with a 30-second trigger creates **2,880 commits per day** — and each commit produces small Parquet files (typically a few MB each, far below the 128–512 MB target file size). After a week of streaming into a daily-partitioned table, a single partition can hold 20,000+ tiny files.

**Why it hurts queries.** Trino must open every file in the scanned partition set. Each file open costs:
- A metadata round-trip to MinIO (network latency).
- A Parquet footer read (to learn schema, row groups, column stats).
- A worker thread slot (parallelism is bounded by files, not bytes).

A query that should scan 1 GB across 4 files takes seconds. The same 1 GB spread across 10,000 files takes minutes — file-open overhead dominates the actual data scan. Memory pressure on Trino workers also rises sharply because each open file holds its footer in memory.

**The solution: schedule `rewrite_data_files` every 30–60 minutes for streaming sinks.** Don't wait for the nightly maintenance window — small files accumulate too fast.

```sql
-- Run this every 30-60 minutes for any table receiving streaming writes
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',   -- 256 MB
    'min-input-files',        '5'             -- compact when ≥5 small files in a partition
  )
);
```

See `11-lakehouse-storage-sizing.md` for the full snapshot management command reference.

**Additional mitigations:**
- Run `expire_snapshots` and `remove_orphan_files` daily — streaming creates many short-lived snapshots that pile up fast.
- Tune the trigger interval up (e.g., 2-minute micro-batches instead of 10-second) if your SLA allows. The Iceberg docs recommend a **minimum 60-second trigger** for streaming writes — anything sub-minute creates too many tiny files without proportional throughput benefit.
- Restrict compaction to historical (non-hot) partitions to avoid commit conflicts with the active streaming writer; see the Copy-on-Write vs Merge-on-Read section below.

### Postgres prerequisites for Debezium CDC

Before Debezium can read your Postgres WAL, several Postgres-side configurations must be in place. Miss any of them and the connector either fails to start or silently emits incomplete events.

**Postgres server settings (`postgresql.conf`):**

```ini
wal_level = logical            # required — default is 'replica'; logical adds the metadata Debezium needs
max_wal_senders = 10           # at least one slot per Debezium connector
max_replication_slots = 10     # at least one slot per Debezium connector
```

A Postgres restart is required after changing `wal_level`. Plan a maintenance window.

**Postgres role & permissions:**

```sql
CREATE ROLE debezium_user WITH LOGIN REPLICATION PASSWORD '...';
GRANT CONNECT ON DATABASE app TO debezium_user;
GRANT USAGE ON SCHEMA public TO debezium_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO debezium_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO debezium_user;
```

The `REPLICATION` attribute is mandatory — without it Postgres refuses the replication slot connection.

**Publication and replication slot (created by Debezium on first connect, but you can pre-create):**

```sql
CREATE PUBLICATION debezium_pub FOR ALL TABLES;
SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
```

`pgoutput` is Postgres's built-in logical decoding plugin (Postgres 10+); Debezium uses it by default. No extension install required.

**`pg_hba.conf`** — allow replication connections from the Debezium host:

```
host    replication    debezium_user    10.0.0.0/8    md5
```

Reload Postgres after editing (`SELECT pg_reload_conf();`).

**`REPLICA IDENTITY FULL` on each replicated table — required for complete `before` images on UPDATE/DELETE:**

```sql
ALTER TABLE users REPLICA IDENTITY FULL;
ALTER TABLE orders REPLICA IDENTITY FULL;
-- repeat for every replicated table
```

By default, Postgres only logs the **primary key** in the WAL for UPDATE and DELETE events. So Debezium's `before` image for those operations contains **only the PK column** — every other column is null. This is broken for several common downstream use cases:

- **Audit trails** that need to record what the row looked like before the change.
- **MERGE INTO logic that joins on or compares non-PK columns** in `before` (e.g., conditional updates that only fire if a specific column changed).
- **Soft-delete reconciliation** where the application wants the full deleted row for retention or compliance.
- **Trigger-style downstream pipelines** ("when status changes from 'pending' to 'paid', fire X") — requires comparing `before.status` to `after.status`, but `before.status` will be NULL without `REPLICA IDENTITY FULL`.

`REPLICA IDENTITY FULL` tells Postgres to log every column's old value to the WAL for UPDATE/DELETE. The cost: ~2× WAL volume for write-heavy tables, marginally more disk I/O on the primary. For most analytical CDC pipelines this cost is worth it; the alternative is wrong data downstream.

If you cannot afford the WAL overhead on a hot table (e.g., a multi-million-writes-per-day `events` table), the fallback is `REPLICA IDENTITY USING INDEX <some_unique_index>` — logs only the columns of that index — but for analytical CDC this is rarely worth the trouble. Default to `REPLICA IDENTITY FULL` and only optimize away from it if WAL volume becomes a measurable problem.

**Verifying it took effect:**

```sql
SELECT relname, relreplident FROM pg_class WHERE relname = 'users';
-- relreplident values:
--   d = default (primary key only)    <- the bad default
--   n = nothing
--   f = full                          <- what you want
--   i = using index
```

### Spark Structured Streaming — correct CDC sketch (Debezium → Iceberg)

The naive sketch — `spark.readStream.format("kafka")...writeStream.format("iceberg")` — is **wrong** for CDC. The Kafka source produces rows with columns `key, value, topic, partition, offset, timestamp`, where `value` is the raw bytes of the Debezium JSON envelope. Writing that frame directly to Iceberg stores the **raw Kafka envelope bytes**, not the actual event fields, and it appends every event blindly — so a Postgres `UPDATE` produces a duplicate row in Iceberg instead of updating the existing one, and a `DELETE` adds yet another duplicate instead of removing the row.

A correct sketch parses the Debezium envelope (`{"op": "c/u/d/r", "before": {...}, "after": {...}}`) and applies `MERGE INTO` per micro-batch:

```python
from pyspark.sql.functions import col, from_json
from pyspark.sql.types import StructType, StructField, StringType, LongType

# Debezium envelope schema (simplified — adjust fields to match your table).
# Debezium emits Postgres timestamps as epoch microseconds by default; convert
# downstream if you want them stored as Iceberg TIMESTAMP.
after_schema = StructType([
    StructField("event_id",    StringType()),
    StructField("tenant_id",   StringType()),
    StructField("user_id",     StringType()),
    StructField("event_name",  StringType()),
    StructField("occurred_at", LongType()),  # epoch microseconds
])

def process_batch(batch_df, batch_id):
    """Process one micro-batch: parse Debezium envelope, apply MERGE INTO."""
    if batch_df.isEmpty():
        return

    # Parse the Debezium JSON envelope out of the Kafka `value` column.
    # The envelope has shape: {"op": "c|u|d|r", "before": {...}, "after": {...}, ...}
    #   op = 'c' (create / INSERT)
    #   op = 'u' (update / UPDATE)
    #   op = 'd' (delete / DELETE)
    #   op = 'r' (read / snapshot — initial bulk load of existing rows)
    parsed = batch_df.select(
        from_json(col("value").cast("string"), StructType([
            StructField("op",     StringType()),
            StructField("after",  after_schema),   # post-change row (INSERT/UPDATE/SNAPSHOT)
            StructField("before", after_schema),   # pre-change row  (DELETE has this populated)
        ])).alias("envelope")
    ).select("envelope.*")

    # Upserts: INSERT, UPDATE, and snapshot reads all write the `after` image.
    upserts = parsed.filter(col("op").isin("c", "u", "r")).select("after.*")
    if not upserts.isEmpty():
        upserts.createOrReplaceTempView("cdc_upserts")
        spark.sql("""
            MERGE INTO iceberg.analytics.events t
            USING cdc_upserts s ON t.event_id = s.event_id
            WHEN MATCHED THEN UPDATE SET *
            WHEN NOT MATCHED THEN INSERT *
        """)

    # Deletes: tombstone events — match on the `before` primary key and drop the row.
    deletes = parsed.filter(col("op") == "d").select("before.event_id")
    if not deletes.isEmpty():
        deletes.createOrReplaceTempView("cdc_deletes")
        spark.sql("""
            MERGE INTO iceberg.analytics.events t
            USING cdc_deletes s ON t.event_id = s.event_id
            WHEN MATCHED THEN DELETE
        """)

# Long-running streaming job. foreachBatch lets us run arbitrary Spark SQL
# (the MERGE INTO calls above) per micro-batch — you cannot do MERGE INTO from
# a bare .writeStream.format("iceberg") sink.
query = (
    spark.readStream
        .format("kafka")
        .option("kafka.bootstrap.servers", "kafka:9092")
        .option("subscribe", "postgres.public.events")
        .option("startingOffsets", "latest")
        .load()
    .writeStream
        .foreachBatch(process_batch)
        .option("checkpointLocation", "s3a://lakehouse/streaming-checkpoints/events")
        .trigger(processingTime="60 seconds")   # 60s minimum for Iceberg streaming
        .start()
)
query.awaitTermination()
```

> **Key differences from a bare `.format("iceberg").writeStream`:**
> - **The Debezium envelope must be parsed.** The Kafka `value` column contains JSON bytes with `op`, `before`, and `after` fields — raw Kafka bytes cannot be written to Iceberg directly. A bare `writeStream.format("iceberg")` on the readStream frame stores Kafka metadata columns (`key`, `value`, `topic`, `partition`, `offset`, `timestamp`) — none of your actual event fields.
> - **UPDATEs and DELETEs require MERGE INTO, not append.** Postgres CDC includes UPDATEs and DELETEs. An append-only `writeStream` would create a duplicate row in Iceberg for every UPDATE (one row per change event) instead of updating the existing row in place — and DELETEs would never actually remove rows.
> - **Use `foreachBatch` when you need MERGE INTO logic per micro-batch.** Spark's `.format("iceberg").writeStream` sink only supports append/complete output modes; arbitrary `MERGE INTO` requires the `foreachBatch` escape hatch, which gives you a regular DataFrame per micro-batch that you can run any Spark SQL against.
> - **Kafka is a new on-prem infrastructure component.** This pipeline assumes a Kafka cluster running in your environment — separate from your Trino/Spark/MinIO stack. Plan for: 3+ Kafka brokers for HA, KRaft mode setup (ZooKeeper-free since Kafka 3.3, fully removed in Kafka 4.0 — 2025), broker storage sizing, retention policy configuration, consumer group lag monitoring, and an on-call rotation for the Kafka cluster itself. Debezium also runs as a Kafka Connect worker, which is another component to deploy and monitor. None of this exists in a pure batch-Spark pipeline reading directly from a Postgres read-replica.
> - **Trigger interval ≥ 60 seconds.** Iceberg's streaming-writes guidance recommends a minimum 1-minute trigger to bound small-file accumulation. Sub-minute triggers create too many tiny Parquet files without proportional throughput benefit — and they make `rewrite_data_files` compaction (which you now must run hourly) work much harder.
> - **Checkpoint location is mandatory.** Spark Structured Streaming requires a `checkpointLocation` so it can recover Kafka offsets and processed batch IDs after a restart. Store it in MinIO (`s3a://...`), not in a worker pod's ephemeral disk — pod restarts would otherwise replay every Kafka event since the topic's retention horizon.

### Debezium offset storage — where the state actually lives

A common and high-impact mistake: assuming Debezium tracks its progress in Kafka **consumer group offsets** (the `__consumer_offsets` topic). It does NOT. Debezium is a Kafka Connect **source** connector, and its offset state lives in a completely separate place. Getting this wrong leads to bogus diagnoses when CDC pipelines replay or get stuck.

A Postgres → Kafka → Iceberg CDC pipeline has **three independent state layers**. Each is stored in a different place, tracks a different thing, and fails in a different way.

| Layer | What it tracks | Where it's stored | Who reads/writes it |
|---|---|---|---|
| **1. Debezium source offsets** | "Which WAL LSN has Debezium already published to Kafka?" | The Kafka Connect **`connect-offsets`** topic (default name; configurable via `offset.storage.topic` in the Kafka Connect worker config). | Kafka Connect worker on behalf of the Debezium source connector. |
| **2. Postgres replication slot** | "Which WAL position has the downstream consumer acknowledged? WAL before this position can be reclaimed." | Postgres itself — visible in `pg_replication_slots`. | Postgres writes; Debezium advances it by acknowledging LSNs back. |
| **3. Downstream consumer group offsets** | "Which Kafka offsets has the downstream consumer (e.g., Spark Structured Streaming) already processed?" | The Kafka **`__consumer_offsets`** topic, keyed by consumer group name. | The downstream consumer (Spark, a Kafka consumer app, a Kafka Connect **sink** connector). |

**Key correction to a common myth:** `__consumer_offsets` is used by Kafka consumer **group** clients and by Kafka Connect **sink** connectors. Kafka Connect **source** connectors like Debezium do NOT use `__consumer_offsets` at all. Deleting a Kafka consumer group has **zero effect** on Debezium's source offset state.

**What gets lost when each layer's state is lost:**

- **Lost `connect-offsets` topic (Layer 1)** → Debezium has no record of how far it published. On restart, behavior depends on `snapshot.mode`:
  - `initial` (default): re-runs a full snapshot of the source tables, then resumes streaming from the slot's current LSN.
  - `never`: skips snapshot and streams from the slot's current LSN — fine if the slot still has all needed WAL, broken if WAL was already reclaimed.
  - `always`: always snapshots on every restart.
- **Lost Postgres replication slot (Layer 2)** → Postgres has no obligation to retain WAL for that consumer anymore. WAL files for the missing range may be purged. Debezium must re-snapshot to recover a consistent baseline.
- **Lost downstream consumer group (Layer 3)** → the **downstream** consumer (Spark Structured Streaming job, custom Kafka consumer, sink connector) replays Kafka messages from its `auto.offset.reset` position (`earliest` or `latest`). Debezium itself is **unaffected** — it keeps publishing as if nothing happened. This is the most commonly misdiagnosed scenario: "we deleted a consumer group and the whole pipeline replayed" almost always means the downstream consumer replayed, not Debezium.

**How to prevent unwanted replay in each layer:**

1. **Debezium source (Layer 1)** — protect `connect-offsets` and pick the right `snapshot.mode`:
   - In the Kafka Connect worker config, the `connect-offsets` topic must have **high retention** (`cleanup.policy=compact`, never delete). Worker bootstrap creates it as compacted by default, but verify in your cluster.
   - For an established pipeline that has already snapshotted, set `snapshot.mode: never` on the connector. Then even if the Kafka Connect worker restarts with empty offsets, Debezium will resume from the slot's current LSN instead of re-snapshotting. Only safe when the slot still exists and the target Iceberg table is already fully populated.
   - **Do NOT** use `consumer.group.id` on a Debezium source connector — it is not a valid property. Source connectors do not have a consumer group. Setting it does nothing.

2. **Postgres replication slot (Layer 2)** — monitor and alert:
   ```sql
   SELECT slot_name, active, restart_lsn,
          pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS slot_lag_bytes
   FROM pg_replication_slots;
   ```
   Alert if `active = false` for more than a few minutes (means Debezium disconnected and WAL is piling up), and alert if `slot_lag_bytes` exceeds a safe threshold (e.g., 10 GB) — left unchecked, an unread slot fills the Postgres WAL disk and takes the primary down.

3. **Downstream consumer (Layer 3)** — protect the consumer group name and pick safe startup defaults:
   - Never delete a downstream consumer group name without understanding the replay cost.
   - For new Spark Structured Streaming deployments where you don't want to re-read history: set `startingOffsets = "latest"` on first run, then let the checkpoint take over.
   - The Spark checkpoint directory (`checkpointLocation`) is what actually persists Spark's processed offsets; the Kafka consumer group name is more of a label. Losing the checkpoint causes Spark to replay according to `startingOffsets`.

**`snapshot.mode: never` — when to use it.** Use it on a connector that has already completed its initial snapshot and whose target table is fully populated. Example connector config snippet:

```json
{
  "name": "users-cdc",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "postgres.internal",
    "database.dbname":   "app",
    "slot.name":         "debezium_slot",
    "publication.name":  "debezium_pub",
    "snapshot.mode":     "never",
    "topic.prefix":      "postgres"
  }
}
```

Valid `snapshot.mode` values for the Debezium PostgreSQL connector (as of Debezium 2.x): `always`, `initial` (default), `initial_only`, `never`, `no_data`, `exported`, `custom`, `when_needed`. Pick deliberately — the default `initial` will re-snapshot the entire source table set if `connect-offsets` is ever wiped, which on a multi-TB table is a long, expensive operation.

**Debugging checklist when CDC "replays unexpectedly":**

1. Did the `connect-offsets` topic get wiped or the Kafka Connect worker get reconfigured with a new `offset.storage.topic`? → Layer 1 replay (Debezium re-snapshots if `snapshot.mode=initial`).
2. Was the connector deleted and recreated with a different `name`? → Kafka Connect treats this as a new connector with no offset history → Layer 1 replay.
3. Was `snapshot.mode` changed to `always`? → Every restart re-snapshots regardless of offsets.
4. Was the Postgres replication slot dropped or recreated? → Layer 2 replay; forces re-snapshot.
5. Was a downstream consumer group deleted (Spark job's group, a sink connector's group)? → Layer 3 replay only — Debezium is fine, the downstream consumer is the one re-reading Kafka.

If symptoms are "the Spark job reprocessed a day of Kafka messages but Postgres WAL was untouched," it is almost certainly #5 — not Debezium.

---

### Copy-on-Write vs Merge-on-Read for high-frequency CDC

Iceberg supports two strategies for row-level updates and deletes — **Copy-on-Write (CoW)** and **Merge-on-Read (MoR)** — and the choice has a large impact on CDC pipeline cost. On Iceberg 1.5.2, **CoW is the default for all three operations** (UPDATE, DELETE, MERGE). It is the right default for low-frequency updates, and the wrong default for high-frequency CDC into large tables.

**How they differ:**

| Mode | What MERGE INTO does | Read cost | Write amplification |
|---|---|---|---|
| **Copy-on-Write (CoW)** — default | For every matched row, **rewrites the entire data file** that contained the row. A file with 1M rows is fully rewritten to change 1 row. | Zero overhead at read time — every file is a self-contained, post-merge image. | Very high. 1 changed row → 1 rewritten file (~256 MB). 10K UPDATEs touching 10K different files → 2.5 TB of rewrites. |
| **Merge-on-Read (MoR)** | Writes a small **delete file** (list of row positions or equality predicates to drop) and a new data file with the updated rows. Original data files are untouched. | Reads pay a merge cost: every scan combines data files with their delete files in memory. Slower scans (5–30% typical overhead). | Low. Each MERGE writes only ~the affected rows plus a tiny delete-file index. |

**The CoW write-amplification trap on high-frequency CDC.** Consider a `users` table receiving 50,000 UPDATEs per minute via Debezium → Spark Structured Streaming → MERGE INTO. With CoW and one micro-batch per minute:

- Each micro-batch's 50K UPDATEs touch (worst case) up to 50K different data files.
- Each touched file is fully rewritten — say ~256 MB average.
- Worst-case writes per minute: 50K files × 256 MB = **~12 TB rewritten per minute**.
- Even with 90% file-locality (most updates hit the same hot files), that's still **~1.2 TB rewrites/min**.

This pace overwhelms MinIO write bandwidth, exhausts your S3-compatible egress budget, and produces a long-running compaction backlog. Reads stay fast, but the pipeline collapses under its own write volume.

**Switch to MoR for high-frequency CDC tables.** Enable MoR via table properties:

```sql
-- Spark SQL only
ALTER TABLE iceberg.cdc.users SET TBLPROPERTIES (
  'write.delete.mode' = 'merge-on-read',
  'write.update.mode' = 'merge-on-read',
  'write.merge.mode'  = 'merge-on-read'
);
```

Set all three. `write.merge.mode` controls `MERGE INTO`; the other two control standalone `UPDATE` and `DELETE` statements. Defaults are `copy-on-write` for all three on Iceberg 1.5.2.

After enabling MoR, the same MERGE INTO pipeline writes only delete files plus small append files per micro-batch — write volume drops 100×–1000× on heavily updated tables. The cost shifts to readers: every scan must merge data files with their delete files, adding ~5–30% to query latency on un-compacted partitions.

**Compaction matters even more with MoR.** Run `rewrite_data_files` hourly with `delete-file-threshold` to collapse accumulated delete files into rewritten data files, restoring read performance. On Iceberg 1.5.2 from Spark:

```sql
CALL iceberg.system.rewrite_data_files(
  table   => 'cdc.users',
  options => map(
    'target-file-size-bytes', '268435456',
    'delete-file-threshold',  '5'         -- rewrite any file with ≥5 delete files attached
  )
);
```

**Schedule compaction on cold partitions only.** For CDC tables, the hot partition (the one currently receiving streaming writes) commits constantly. Running `rewrite_data_files` on the hot partition causes **commit conflicts** between the streaming job and the compaction job — both try to commit overlapping snapshots, one loses and retries. Either:
- Restrict compaction to historical partitions (e.g., `WHERE day < current_date - 1`) so the hot partition is left to the streaming job alone, or
- Use the `partial-progress.enabled = true` option so the compactor commits one partition at a time and a streaming commit conflict only retries that one partition's compaction.

**Quick decision rule:**

| Workload | Mode |
|---|---|
| Daily/hourly batch MERGE INTO, <1K updates per run | CoW (default) — keep it simple, fast reads |
| Streaming CDC, <100 updates per micro-batch | CoW is borderline — measure write volume first |
| Streaming CDC, >1K updates per micro-batch on large tables | MoR — switch before write amplification breaks the pipeline |
| Append-only event tables (no UPDATE/DELETE) | Mode doesn't apply — no merge operations happen |

---

## Key terms

- **Watermark**: the streaming system's estimate of "the latest event time I have probably seen everything for." Used to decide when to finalize a time window.
- **CDC (Change Data Capture)**: pattern of capturing every INSERT/UPDATE/DELETE from a source DB as a stream of events.
- **Micro-batch**: streaming implemented by running tiny batch jobs every N seconds. Spark Structured Streaming works this way.
- **Exactly-once**: each source event causes exactly one effect on the destination, even after failures and retries. Hard to achieve; easy to confuse with "at-least-once."
- **Backfill**: re-running a pipeline over historical data — vastly easier with batch than with streaming.
- **REPLICA IDENTITY FULL**: Postgres table-level setting that causes the WAL to include every column's old value on UPDATE/DELETE. Required for Debezium to emit complete `before` images; default is PK-only.
- **Copy-on-Write (CoW)**: Iceberg merge mode that rewrites entire data files on each row-level change. Default in Iceberg 1.5.2. Fast reads, expensive writes — wrong choice for high-frequency CDC.
- **Merge-on-Read (MoR)**: Iceberg merge mode that writes small delete files instead of rewriting data files. Cheap writes, slightly slower reads (until compaction collapses the delete files). The right choice for high-frequency CDC.
- **Delete file**: small Iceberg metadata file that lists rows (by position or equality) to suppress at read time. Created by MoR operations; collapsed by `rewrite_data_files` during compaction.
- **`connect-offsets` topic**: the Kafka topic where Kafka Connect **source** connectors (including Debezium) store their progress offsets. Default name; configurable via `offset.storage.topic` in the Kafka Connect worker config. Separate from `__consumer_offsets` and not affected by consumer-group deletion.
- **`__consumer_offsets` topic**: the Kafka topic where consumer **group** clients (and Kafka Connect **sink** connectors) store the offsets they have processed. Not used by Debezium or any other source connector.
- **`snapshot.mode`**: Debezium connector setting that controls whether and when an initial snapshot of the source tables is taken. Valid values include `initial` (default), `never`, `always`, `initial_only`, `no_data`, `exported`, `custom`, `when_needed`. Use `never` on established pipelines to prevent re-snapshots if `connect-offsets` is ever lost.
- **Replication slot (Postgres)**: server-side bookmark in `pg_replication_slots` recording the WAL position that a downstream consumer (Debezium) has acknowledged. Postgres will retain WAL until the slot advances; an abandoned slot will fill the WAL disk and stall the primary.
