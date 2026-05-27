# Answer to Q2: Moving from Nightly Batch to Real-Time with CDC

## What is CDC (Change Data Capture)?

CDC stands for Change Data Capture. Instead of periodically reading your entire Postgres table or just the rows changed since yesterday, CDC captures every single database change — every INSERT, UPDATE, and DELETE — the moment it happens.

Here's how CDC works on your stack (Postgres + Iceberg + Spark):

1. **Postgres Write-Ahead Log (WAL)** — Every change to Postgres is first written to the WAL for crash recovery. CDC taps into this log.
2. **Debezium** — A connector that reads the Postgres WAL and converts each row change into a structured message ("user 123 updated plan_name at 14:32:05").
3. **Kafka** — Acts as a reliable queue holding all those change messages, decoupling when Postgres writes from when you consume them.
4. **Spark Structured Streaming** — A long-running job that reads from Kafka every 30-60 seconds in mini-batches and applies those changes to your Iceberg table using MERGE INTO.
5. **Iceberg on MinIO** — The destination; each mini-batch commit becomes an atomic snapshot.

## How CDC differs from your current batch approach

**Your current nightly approach:**
- Run `SELECT * FROM table WHERE updated_at > last_sync_time` once per night
- Simple, low operational burden
- Result: dashboards are 12-24 hours stale
- Hard DELETEs in Postgres never appear in your lakehouse (the row just vanishes)

**CDC approach:**
- Continuously stream row changes (inserts, updates, deletes) as they happen
- Every change flows to Iceberg within 1-15 minutes typically
- You capture hard DELETEs accurately
- Result: enterprise dashboards can be updated within minutes instead of overnight

## The freshness spectrum: each tier is ~10x harder

| Tier | Lag | Effort | When to use it |
|---|---|---|---|
| Daily batch | 24 hours | Very simple (your current state) | Most analytics, reporting |
| Hourly batch | 1 hour | Add hourly Spark jobs (24x more runs) | Internal dashboards |
| 15-minute batch | 15 min | Careful watermarking, incremental reads | Operational metrics |
| CDC streaming | 1-5 minutes | Debezium + Kafka + streaming Spark + monitoring | Enterprise dashboards, compliance |

Your customers want "within a few minutes," which is the CDC tier.

## Should you just run batch more frequently?

You could run your `updated_at`-based sync every 5 minutes instead of nightly. This would be simpler than CDC:

**Pros:**
- Keep your existing Postgres read replica approach
- No Debezium or Kafka infrastructure to set up
- Easy to debug (Spark jobs you already know)
- Re-run safely on failure

**Cons:**
- You'd run a Spark JDBC job 288 times per day — significant Postgres read load
- Still won't capture hard DELETEs — rows deleted in Postgres simply disappear
- The incremental window can miss late-arriving rows (mobile apps that buffered events offline)

Running hourly is reasonable. Running every 5 minutes starts to hurt: 288 `SELECT` queries per day, JDBC connection overhead, failures and retries stacking up.

## When CDC is worth it

Adopt CDC when:

1. **You genuinely need sub-5-minute freshness** — If customers check dashboards every few minutes and expect live data, hourly batch won't satisfy them.
2. **You must capture hard DELETEs accurately** — If rows deleted from Postgres must immediately vanish from Iceberg (compliance, data retention), batch ingestion misses them entirely.
3. **Your batch frequency is creeping up** — If you're already running hourly and still getting complaints, CDC often becomes cheaper than running batch every 5-10 minutes.

## The real cost of CDC — don't underestimate it

CDC buys you freshness but costs you operational burden. On your stack:

**Postgres prerequisites:**
- Enable logical replication (`wal_level = logical` in postgresql.conf — requires a Postgres restart)
- Create a Debezium role with `REPLICATION` permissions
- Add `REPLICA IDENTITY FULL` to tables you want full before-images for (this increases WAL volume ~2x on UPDATE-heavy tables)

**New infrastructure you'd own:**
- Kafka broker deployments and maintenance in Kubernetes
- Debezium connector configuration and troubleshooting
- Consumer lag monitoring (is Spark keeping up with Kafka?)
- WAL retention management (Postgres won't delete WAL until Debezium acknowledges it — if Debezium falls behind, Postgres disk fills up)

**Streaming Spark jobs (different from batch jobs):**
- Runs 24/7 (not a cron job) — you need on-call monitoring
- Exactly-once delivery semantics (careful handling of duplicates on restart)
- Schema evolution handling (when Postgres adds a column, the streaming job must adapt)
- Small-file compaction every hour (`rewrite_data_files` — each micro-batch creates new Parquet files)

**New on-call burden:** Kafka health, Debezium connector stuck or rebalancing, Spark Structured Streaming job crashing and losing Kafka offsets.

Most SaaS teams reach $10M ARR on daily or hourly batch before CDC is needed.

## My recommendation for your situation

**Step 1 — Try hourly incremental batch first.** Run your existing `SELECT * FROM X WHERE updated_at > last_ts` job every hour instead of nightly. This gets you from 12-24 hour staleness to 1-hour staleness with almost no additional work. For most enterprise customers, 1-hour staleness is acceptable.

**Step 2 — If hourly doesn't cut it: propose a tiered dashboard approach.** Show enterprise customers their most critical metrics on a 5-minute CDC stream (e.g., "active sessions," "transactions in last 5 min") while keeping less time-critical metrics on the hourly batch. This defers CDC investment while addressing the business need.

**Step 3 — If you do move to CDC:** Start with one small, non-critical table (e.g., `subscriptions` or `orders`) to learn the ops model before migrating everything. The Postgres WAL setup, Debezium configuration, and Spark Structured Streaming logic are all non-trivial. Learn on a 100K-row table before applying it to your 400M-row events table.

## Summary: batch vs CDC decision

| Factor | Stay on batch (more frequent) | Move to CDC |
|---|---|---|
| Target freshness | 15 min to 1 hour acceptable | Need under 5 min |
| Hard DELETE tracking | Not required | Required (compliance) |
| Team ops bandwidth | Limited | Can run streaming infra 24/7 |
| Current batch frequency | Running daily or hourly | Already at 5-10 min intervals |

If your enterprise customers need 1-hour freshness, do hourly batch. If they truly need under 5 minutes, plan for CDC — but start small, start with one table, and add monitoring before you go wide.
