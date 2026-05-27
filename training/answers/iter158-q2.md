# Iter 158 Q2 — Kafka-to-Iceberg Streaming: Near-Real-Time Ingestion

## Answer

## Short answer

Yes, Iceberg supports streaming writes directly via Spark Structured Streaming. However, "streaming from Kafka" is a different architecture than "running batch more frequently" — and you should clarify whether your customers actually need minutes of freshness or if they'd accept hourly. Moving from daily to near-real-time (minutes) is roughly **10x more complex**, not a simple config flip.

---

## The freshness spectrum

First, let me level-set what "near-real-time" actually means in practice. Freshness is not binary; it's a spectrum:

- **Daily batch** (your current setup): 24-hour lag. Your nightly Kafka-to-Iceberg job.
- **Hourly batch**: 1-4 hour lag. Run your Spark job every hour instead of every night.
- **Near-real-time**: 1-15 minute lag. Continuous streaming using Kafka + Spark Structured Streaming.

Each tier up is roughly **10x more complex and expensive**. Before you build, ask your PM: "Would hourly freshness (data updated every 1-4 hours during the workday) actually solve the customer complaint?" Most PMs who say "real-time" actually mean "within an hour" once you push back.

---

## Your options

### Option 1: Run hourly batch jobs (easiest)

Keep your current Spark job architecture. Instead of nightly, run it every hour (or every 30 minutes). This is just a Kubernetes cron job scheduling change. Your events sit in Kafka; once per hour, Spark reads everything since the last run and appends it to Iceberg.

**Pros**: Same code, same operational model, simple debugging.
**Cons**: Still 1-4 hours of lag. Requires slightly more compute and careful offset management if Kafka retention doesn't guarantee coverage.

**When this works**: If customers can actually tolerate hourly freshness (and many will).

---

### Option 2: Streaming (Kafka → Spark Structured Streaming → Iceberg)

This is a fundamentally different architecture:

1. Kafka holds your `user.signed_up`, `subscription.upgraded`, `feature.used` events (exactly what you have now).
2. A **long-running Spark Structured Streaming job** reads from Kafka continuously, processes events in micro-batches (e.g., every 60 seconds), and writes to Iceberg.
3. Each micro-batch becomes an atomic Iceberg commit — data appears in Iceberg within seconds to minutes.

**Iceberg supports this natively** (Iceberg 1.5.2, which is your version) via `spark.readStream().format("kafka").writeStream().format("iceberg")`.

**Pros**: Minutes of freshness (sub-5 minutes if tuned well).
**Cons**: Much more complex. New infrastructure, new failure modes, higher compute cost.

---

## Key gotchas with streaming

**Small-files problem**: Spark Structured Streaming creates one data file per micro-batch. A 60-second micro-batch creates 1,440 files per day per partition. This breaks query performance unless you run **hourly compaction** (Iceberg's `rewrite_data_files` procedure).

**Trigger interval**: Iceberg recommends a **minimum 60-second trigger** for streaming writes. Sub-minute triggers create too many tiny files without proportional benefit. So your "within a few minutes" freshness goal is realistic, but not "sub-minute."

**Monitoring complexity**: You now need to monitor Kafka consumer lag, Spark streaming checkpoint progress, Iceberg small-file accumulation, and compaction success separately.

---

## My recommendation

1. **First**: Ask your customers "would hourly freshness work?" If yes, implement hourly batch runs (Option 1). It costs far less in operations and compute.

2. **Only if they really need sub-5-minute freshness**: Build Kafka → Spark Structured Streaming → Iceberg (Option 2). This is worth it for fraud detection, live-in-app metrics, or operational alerting — not for "analytics dashboards."

3. **For app events specifically**: They're append-only (no UPDATEs or DELETEs), so streaming is simpler than CDC from a state perspective. Use Iceberg's native `writeStream` sink directly — no need for the complex `MERGE INTO` logic that Debezium-sourced CDC requires.
