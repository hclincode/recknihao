# Iter128 Q2 — Answer

**Question**: Our current analytics pipeline is a nightly Spark job that pulls changes out of Postgres and lands them in Iceberg. Works fine, but a couple of enterprise customers are asking for "near real-time" dashboards — they want to see what happened in the last few minutes, not last night. I've heard people mention CDC and streaming, but I genuinely don't know what that means operationally. How different is it from what we're already doing? Like, is it just running the batch job more often, or is it a fundamentally different setup? And is it actually worth it — what does it cost us in complexity and infrastructure to go from nightly to, say, five-minute-fresh data?

---

## The difference between nightly batch and near-real-time: it's not just more often

You're right to sense this is bigger than "run the job every 5 minutes." Here are the concrete operational differences, the cost, and when it's actually worth doing.

### What you're doing now vs. what CDC/streaming is

**Your current setup (nightly batch):**
- Spark job runs once per night. It queries Postgres for all rows changed since yesterday (the `updated_at > last_run_ts` pattern).
- Writes to Iceberg in MinIO. One commit, maybe 5–20 new files.
- Trino queries the latest snapshot. Data freshness: last night.

**The CDC + streaming alternative (5-minute fresh):**
- Debezium (which you already have at 2.x) watches Postgres's write-ahead log (WAL). Every INSERT, UPDATE, DELETE becomes a structured message.
- Those messages land in Kafka (a new dependency) as a durable queue.
- Spark Structured Streaming (a long-running Spark job, not a cron job) reads Kafka in micro-batches every 30 seconds, applying changes to Iceberg.
- Each micro-batch becomes a new Iceberg commit — dozens per hour instead of one per night.
- Trino still queries Iceberg, just reads fresher snapshots.

**The key insight:** You're not running the batch job 288 times a day. You're moving from **pull-based** (Spark asks "what changed?") to **push-based** (Postgres pushes "here's what changed") plus a streaming consumer. It's architecturally different, not just faster.

---

## Operational complexity jump

Each tier of freshness is roughly **10x more complex.** Here's what that means for your stack:

**Going from nightly → hourly (still batch, more frequent):**
- 24 more Spark jobs per day. More pod churn, more Hive Metastore connections.
- More file accumulation: 10 files/night becomes 240 files/day. Compaction must run hourly.
- **New burden:** failure detection. A failed hourly job needs alerting — you have a 1-hour window before dashboards go stale.

**Going from hourly → 5-minute streaming (the jump you're considering):**
- Kafka as a new stateful service (broker failures, consumer lag, topic cleanup).
- Debezium as a new operational component (WAL connections, schema drift handling, offset management).
- Spark Structured Streaming is fundamentally different from batch Spark — it's a long-running job (weeks at a time), not one-shot. Requires understanding stateful computation, exactly-once semantics, and watermarks.
- **Small-files problem gets severe:** a 30-second micro-batch creates 1–2 Iceberg files. Over a day: 2,880–5,760 files. Compaction must run hourly and be carefully tuned.
- **New on-call skills:** Kafka consumer lag, Debezium connector restarts, Spark streaming backpressure, exactly-once vs. at-least-once delivery semantics.

From the resources: *"Streaming introduces schema-drift handling, exactly-once delivery semantics, Kafka operations, consumer lag monitoring, state-store size management, and a new on-call rotation."*

---

## Infrastructure cost

**New permanent additions (on-prem, not cloud):**

| Component | Sizing | vCPU | RAM |
|---|---|---|---|
| Kafka cluster | 3 brokers (HA minimum) | ~12 | ~24 GB |
| Debezium connector | 1–2 pods | ~2 | ~4 GB |
| Spark Streaming job | Driver + 8 executors | ~20 | ~40 GB |
| Hourly compaction (increase) | Up from 1x/night to 24x/day | +8 burst/hr | +16 GB burst/hr |

**Total new reserve:** ~40–50 vCPU / 80–100 GB RAM, often idle. On-prem means this is capacity you can't allocate to your SaaS product. If your k8s cluster is already at 70%+ utilization, streaming ingestion may force a hardware purchase.

---

## Engineering cost (usually the biggest)

**Setup:** Plan 4–8 engineer-weeks. Designing the Debezium connector config (WAL properties, offsets, schema handling), Kafka retention policies, Spark exactly-once guarantees — this isn't a weekend project.

**Ongoing operations:** 
- Weekly: check Kafka consumer lag, restart stuck Debezium connectors.
- Monthly: tune Kafka retention, archive old topics, handle schema evolution.
- On-call: when Debezium loses its WAL position (Postgres recycles WAL files faster than Debezium consumes them), the connector stops. A human fixes it. This is not automated.

**Debugging is harder:** If a nightly batch job fails, you see it in the morning and rerun it. If a streaming job silently falls 10 minutes behind, Kafka buffers the messages; dashboards appear to work but are stale. Discovering staleness requires active monitoring.

---

## The freshness cost spectrum

| Freshness | When you need it | Complexity vs. daily |
|---|---|---|
| Daily (what you have) | Deep analytics, cohort analysis, reporting | 1x |
| Hourly | Internal dashboards, daytime reporting | ~10x (more frequent batch + compaction) |
| 15-minute | Operational dashboards, fraud signals | ~100x (CDC + streaming basics) |
| 5-minute | Live in-app counters, active fraud detection | ~1000x (full streaming stack + expert ops) |

---

## When streaming is actually worth it

**First: ask the customer what "near real-time" actually means to them.** When a PM says "real-time," they usually mean "within an hour."

Test questions:
- "If the dashboard refreshed every hour, would that be acceptable?" (Most say yes.)
- "If it refreshed every 15 minutes?" (Many still say yes.)
- "If we refreshed every 5 minutes, would that change your business?" (This is where you get the real answer.)

**Streaming makes sense when:**
- A customer uses your SaaS to detect fraud, and every 5-minute delay costs them money.
- You're building an in-app live dashboard ("how many active users right now").
- A regulatory requirement mandates "data available within N minutes."

**Streaming doesn't make sense for most SaaS when:**
- Dashboards analysts refresh once per day.
- Business intelligence on historical trends.
- Operational metrics that shift over hours, not minutes.

---

## Practical recommendation

**Start here — before writing any code:**

1. **Ask the customer:** "Is hourly fresh enough?" If yes, skip streaming entirely.
2. **If hourly works:** switch from nightly to hourly incremental Spark batch jobs. That's a 1-line change to your k8s CronJob schedule. 20x better freshness, zero new infrastructure. Watch for: more file accumulation (run compaction hourly) and more Spark pod churn (check cluster headroom).
3. **If 5-minute is non-negotiable:** commit to a 4–8 week project with a dedicated engineer. Your stack already has all the ingredients (Debezium 2.x, Spark 3.x, Iceberg 1.5.2 all support streaming). But budget for the Kafka cluster, streaming overhead, hourly compaction, consumer lag monitoring, and documentation on "what to do when Debezium gets stuck."

**The majority of SaaS teams reach $10M+ ARR on hourly batch.** You almost certainly don't need full streaming yet — but when you do, you have the right stack to do it.

---

## Implementation sketch (if you decide to do it)

Architecture for your stack:

1. **Debezium 2.x** → watches Postgres WAL → emits change events to Kafka topic.
2. **Kafka** → buffers changes durably. Retention: 7 days.
3. **Spark Structured Streaming** (long-running k8s pod):
   ```python
   df = spark.readStream \
       .format("kafka") \
       .option("kafka.bootstrap.servers", "kafka:9092") \
       .option("subscribe", "postgres.public.events") \
       .load()

   df.writeStream \
       .format("iceberg") \
       .option("path", "s3a://lakehouse/analytics/events") \
       .option("checkpointLocation", "s3a://lakehouse/checkpoints/events") \
       .trigger(processingTime="30 seconds") \
       .start() \
       .awaitTermination()
   ```
4. **Hourly compaction job** (Spark batch, new):
   ```sql
   CALL iceberg.system.rewrite_data_files('analytics.events',
     options => map('min-input-files', '10'));
   ```
5. **Trino** queries the same Iceberg table. No query-side changes — it just reads fresher snapshots.

Postgres side: set `wal_level = logical`, create a Debezium replication user, point Debezium at it. Debezium handles WAL reading automatically.
