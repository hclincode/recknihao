# Answer to Q2: Real-Time vs Batch Analytics Trade-offs (Iter 315)

## Your Situation in Context

You're running a daily batch job (nightly at 2 AM), which gives you 7-10 hours of staleness by 9 AM. Your customer wants "today's data" so they can see current campaign performance. The question is: what does it actually cost to close that gap?

The answer: it depends on **how fresh** "today's data" really needs to be, and the costs explode the fresher you go.

## Think in Tiers, Not Binary Choices

Stop thinking "real-time or batch." Data freshness is a spectrum with tiers. Here's what each tier costs on your stack (Spark + Iceberg + Trino on-prem):

**Current state — Daily batch (7–10 hour lag):**
- One Spark job per night reading all changed rows from Postgres.
- Simple, predictable, low overhead.

**Option 1 — Fresh batch (1–4 hour lag) — probably what you actually want:**
- Spark job runs every 1–2 hours during business hours (e.g., 7 AM, 9 AM, 11 AM).
- Same JDBC-to-Iceberg pattern you have now, just more frequently.
- By 9 AM your customer sees data through 7 AM or 8 AM (1–2 hours stale).
- Added complexity: **medium**. You need a scheduler (Airflow, K8s CronJob) running 4–6 jobs per day instead of 1.

**Option 2 — Near-real-time (1–15 minute lag) — requires streaming infrastructure:**
- Set up Debezium to read Postgres's Write-Ahead Log (WAL), push changes to Kafka, then have Spark Structured Streaming apply those changes to Iceberg every 1–2 minutes.
- Added complexity: **10× more complex and expensive.** You now operate Kafka (cluster, ZooKeeper, monitoring), Debezium (a separate service), plus a long-running Spark streaming job. One new piece of infrastructure to on-call for.
- New failure modes to handle: late-arriving events, exactly-once semantics, streaming offsets, watermarking.

**Option 3 — Real-time (<1 second lag) — not practical for your use case:**
- Query Postgres directly, or materialize views in Postgres itself.
- Defeats the purpose of Iceberg/Trino for analytics dashboards.

## The Rule of Thumb

**Each freshness tier is roughly 10× more complex and expensive than the one above it.** The cost jump is not in Postgres or Iceberg — they can handle it fine. The cost is in **operational complexity**: more software to run, more things to monitor, more failure modes, more on-call burden.

## What You Should Actually Do

**Before building anything, ask your customer: "Is 2–3 hours stale acceptable?"**

If yes — **move to hourly or 2-hourly batch.** This is a 10-line change to your Spark job scheduler. Still runs the same JDBC→Iceberg pattern. You add maybe 4–6 more pod starts per business day. Your operations team barely notices. Your customer gets data through breakfast time.

If no — **then ask "Is 10–15 minutes acceptable?"**

Only then consider streaming. And even then, start by proving the business metric actually requires it. "We want real-time" is not a metric. "We need to detect fraud within 10 minutes to block the transaction" is.

## The Late-Arriving Events Gotcha

One thing that gets overlooked: events don't always arrive in order. A mobile app loses Wi-Fi at 9:00 AM, the user keeps clicking locally, the phone reconnects at 9:30 AM and dumps 30 minutes of buffered events at your server. The timestamp says 9:00 AM but the server received it at 9:30 AM.

Your event table **must have two timestamps:**
- `occurred_at` — when it really happened (user's device time).
- `ingested_at` — when your system got it (server time, monotonic).

When querying for "today's data," use `occurred_at` for business logic (funnels, campaign metrics) but **add a buffer window.** Don't query "today's data" at 00:00:01 — wait until 02:00 so late events settle in. Or mark dashboards as "data through 2 hours ago."

In Iceberg, partition by `ingested_at` (predictable and monotonic, helps Iceberg prune files efficiently), but query and aggregate by `occurred_at` (the business timeline).

## Your Three Next Steps

1. **Measure the actual cost.** Run your current nightly job and measure wall-clock time and Postgres read load. Then estimate: what if it ran every 2 hours? Postgres doesn't care — it's a read-replica. Spark will just spin up more pods.

2. **Ask the customer to quantify "today."** Can they live with data through 8 AM if they check at 9 AM? Or must they see events from 9:00–9:05 AM while they're actively in the dashboard at 9:05 AM? The answer determines whether you need fresh batch or streaming.

3. **If you do go to hourly batch:** keep your existing JDBC-to-Iceberg logic. You don't need to learn Debezium, Kafka, streaming offsets, or exactly-once semantics. Just run the job more often. It's boring, predictable, and fits your on-prem stack perfectly.

**Streaming (Debezium + Kafka + Spark Structured Streaming) is a valid path, but only after you've exhausted hourly batch and measured that it's not enough.** Most SaaS teams ship with daily or hourly batch well into the tens of millions of ARR. Streaming is rarely the bottleneck early on.
