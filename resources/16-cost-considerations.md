# Cost Considerations for Analytical Workloads at SaaS Scale

> Production stack assumed: Spark + Iceberg 1.5.2 + MinIO + Hive Metastore + Trino 467, all on Kubernetes on-prem. "Cost" here means a mix of dollars (hardware, cloud bills), CPU/RAM (k8s resources), and engineering hours.

---

## Quick answer (TL;DR)

- **Storage is almost free** on your stack: MinIO on bare-metal + Parquet compression typically lands at ~$0 incremental per TB; the hardware is already paid for.
- **Compute dominates** even on-prem: a Trino cluster sized for peak concurrency burns CPU/RAM 24/7, even when no queries run.
- **Engineering time is the largest hidden cost** — ingestion, compaction, snapshot expiry, and on-call all consume FTE hours that don't show on any invoice.
- **Cloud OLAP (BigQuery, Snowflake) is often cheaper for low/spiky volumes**; self-hosted Iceberg+Trino wins once you sustain a stable analyst workload.
- **The top three optimizations**: partition pruning (skip data), snapshot expiry (skip storage debt), and rollup tables (skip repeated compute).

---

## Three cost layers every SaaS engineer forgets

When engineers think "analytics cost" they usually picture only #1. The big bills hide in #2 and #3.

### 1. Storage cost — usually tiny after Parquet compression

Parquet with ZSTD or Snappy compresses typical SaaS event data 5–10x (see `11-lakehouse-storage-sizing.md`). On bare-metal MinIO, the marginal cost of one extra TB is effectively the cost of disks (a few hundred dollars amortized over years). On managed cloud (S3, GCS), storage is ~$23/TB/month — still cheap relative to compute.

**Rule of thumb:** if your bill is dominated by storage, you forgot to expire snapshots (see "hidden costs" below).

### 2. Compute cost — your Trino cluster is always running

Trino is a long-lived query engine. On Kubernetes, the worker pods reserve CPU and RAM whether or not anyone is querying. A 4-worker cluster sized for 16 vCPU / 64 GB RAM each consumes 64 vCPU and 256 GB constantly. That's hardware capacity you can't allocate to other workloads.

Spark adds compute cost on top: ingestion jobs and nightly compaction need executors, which (on k8s) means scheduled pod allocations.

**Rule of thumb:** compute, not storage, is your real recurring cost. Plan k8s node budget around peak Trino + Spark concurrency, not average.

### 3. Engineering cost — the biggest hidden cost

The bill you don't see on any dashboard:

- Writing and tuning Spark ingestion jobs.
- Maintaining the Hive Metastore.
- Scheduling and monitoring compaction.
- Snapshot expiry policies.
- On-call when ingestion silently fails and dashboards go stale.
- Onboarding new analysts to Trino syntax and partition strategy.

A rough industry number: 0.2 to 0.5 full-time-equivalent engineering year per 10TB of actively-maintained lakehouse. At fully-loaded $200k/FTE that's $40k–$100k/year — typically larger than any hardware or cloud bill at this scale.

---

## Key terms (defined inline for first use)

- **FTE (full-time equivalent):** one person working full-time for a year. "0.3 FTE" = roughly 1 day per week of engineering attention.
- **Idle compute:** CPU and RAM reserved by long-running pods (Trino workers) even when no queries are running. You pay for capacity, not utilization.
- **Compaction:** merging many small Parquet files into fewer large (~128 MB) files. Adds compute cost but saves much more on query side.
- **Snapshot expiry:** the Iceberg maintenance call (`expire_snapshots`) that physically deletes old data file versions that no live snapshot references.
- **Rollup table:** a pre-aggregated, much smaller table (e.g., daily metrics) maintained by dbt or Spark so dashboards don't re-scan raw events on every load.
- **Per-TB-scanned pricing:** the BigQuery on-demand model — you pay per terabyte of (uncompressed-equivalent) data read by each query. As of 2026 the on-demand rate is **~$6.25/TB scanned** (first 1 TB/month is free). BigQuery also offers **capacity-based pricing** (reserved "slots") as an alternative for high-volume workloads where flat-rate compute is cheaper than per-query.
- **Warehouse credit:** Snowflake's billing unit. A "medium" warehouse burns ~2 credits per hour while running.

---

## The real cost comparison: managed vs self-hosted

Scenario: **500 GB analytical data, 10 analysts, 50,000 queries/month, average 10 GB scanned per query.**

| Option | Monthly cost (rough) | What you trade |
|---|---|---|
| **BigQuery** (per-TB-scanned, on-demand) | ~$1,560/month query + ~$10/month storage. Math: 50% cache hit → 25,000 queries × 10 GB = 250 TB scanned; first 1 TB/month is free, so 249 TB × ~$6.25/TB ≈ $1,556. | Zero ops. Pay per query — wild swings if someone runs `SELECT *`. **Capacity-based pricing (slots)** is an alternative for high-volume workloads: you reserve compute capacity for a flat monthly rate, which can be cheaper than on-demand once sustained scan volume gets large. Cloud-only (incompatible with your on-prem rule). |
| **Snowflake** (warehouse credits) | ~$400/month. Math: medium warehouse at $2/credit, ~200 credits/month for this load. | Zero ops, but always-on warehouse can balloon if not auto-suspended. Cloud-only. |
| **ClickHouse Cloud** | ~$50–$150/month for this volume. | Very cheap at small scale. Different query semantics from Trino. Cloud-only. |
| **Self-hosted Iceberg + Trino (your stack)** | **Marginal query cost ≈ $0/month** (hardware paid). **Engineering cost: 0.2–0.5 FTE/year** = ~$3k–$8k/month fully loaded. | Full ops responsibility, but no per-query surprises and meets the on-prem requirement in `prod_info.md`. |

**The crossover point:** at very low volumes (<10 analysts, occasional queries), managed cloud is genuinely cheaper because you don't pay the FTE tax. At sustained moderate-to-high volumes — which is what you're sized for — self-hosted Iceberg + Trino wins on dollars per query, but only if the engineering work gets done. If the FTE budget is missing, the system silently rots (see hidden costs).

---

## The hidden costs of self-hosted

These don't show up in any cost dashboard. They show up as a slow dashboard, a stale report, or a 3 a.m. page.

- **Idle Spark pods**: if you keep a long-running SparkSession (e.g., a streaming app), idle executors consume RAM even between batches.
- **Compaction jobs**: nightly (or hourly for streaming-heavy tables) — every compaction reads N small files, writes one big file, and burns CPU on both reads and writes. Budget for this in your k8s capacity plan.
- **Snapshot expiry forgotten**: Iceberg keeps every old snapshot forever by default. Without `expire_snapshots`, MinIO storage grows ~20–30%/year from orphaned files even if your raw data volume is flat. This is the most common storage cost surprise.
- **No built-in cost alerts**: BigQuery and Snowflake have billing alarms ("alert me when this user spends >$500"). Trino has none — a runaway `SELECT * FROM events` from a curious analyst can burn the cluster for hours with no warning. You must build query-cost monitoring yourself (Trino exposes `query_stats` you can scrape).
- **Failure recovery**: a crashed Spark ingestion job means stale dashboards until someone notices. Without a dead-job alerting layer, the first signal is usually a Slack message from a confused analyst.
- **Metastore as single point of failure**: Hive Metastore is shared by Spark, Trino, and dbt. If it goes down, the entire stack stops. Treat it as Tier-1 infra; budget HA and backups.

---

## Cost optimization tactics for your stack

Concrete, ordered roughly by impact-per-effort:

1. **Partition pruning is the single biggest lever.** A well-partitioned query on 1 TB might only read 5 GB after pruning — 200x less compute. Make sure every fact table is partitioned by `day(event_ts)` and (for B2B) `tenant_id`. See `10-lakehouse-partitioning.md`.

2. **Build rollup tables for dashboards.** A nightly dbt model that pre-aggregates Weekly Active Users (WAU) and Monthly Active Users (MAU) turns a 30-second dashboard query into a 300 ms one. You spend the compute once at night instead of 100 times per day from the BI tool. Often saves 80–90% of Trino's daily load.

3. **Expire snapshots weekly.** `CALL iceberg.system.expire_snapshots('analytics.events', TIMESTAMP '2026-05-16')`. Keeps MinIO from accumulating historical file debt. Pair with `remove_orphan_files` monthly.

4. **Tune Parquet compression by tier.** Use Snappy for hot recent data (fast decompress). Use ZSTD for cold data older than 90 days — 20–30% smaller files, slightly slower reads. Both can coexist in the same Iceberg table over time.

5. **Autoscale Trino workers if your traffic is bursty.** Run k8s HPA on Trino workers based on CPU. If your analyst usage is concentrated 9 AM – 6 PM, scale workers down at night (you still need at least 1 to serve any straggler queries).

6. **Set a soft per-query memory cap.** Trino's `query_max_memory_per_node` prevents one bad query from monopolizing the cluster. Default in Trino 467 is 30% of pool; tune lower if analysts run many concurrent heavy queries.

7. **Use `approx_distinct`** instead of `COUNT(DISTINCT user_id)` for cardinality estimates on large tables — 100x less memory, ~2% error. Cheap compute trade.

8. **Use `approx_distinct()` for internal operational metrics (WAU, DAU) to cut query memory by 100x — but use `COUNT(DISTINCT)` for customer-facing retention dashboards where 2% error causes support tickets.** The 2% figure is a *standard deviation*, not a ceiling: ~5% of estimates land outside ±4%, and customers staring at "active users: 9,847" in their dashboard will notice if the number drifts between page loads. See the "`approx_distinct` vs `COUNT(DISTINCT)` — when to use each" subsection in `07-analytical-query-patterns.md` for the full decision rule and a validation recipe.

---

## Cost signals that mean you're growing into the stack

Watch these as leading indicators. They tell you the system is approaching capacity *before* it actually fails.

- **Trino worker count is permanently maxed.** If your workers are at >70% CPU for the majority of business hours, you need more nodes (or rollup tables to cut load).
- **Nightly compaction takes > 4 hours.** You're either creating too many small files (Spark write parallelism too high) or you need bigger Spark executors. Compaction that runs into business hours hurts query latency.
- **MinIO grows > 500 GB/month** with flat business volume. Usually means orphaned files — revisit `expire_snapshots` and `remove_orphan_files` cadence. If business volume is actually growing, revisit partition strategy (over-partitioning creates many small files; see `10-lakehouse-partitioning.md`).
- **Average query latency creeping up week-over-week.** Often means small-file accumulation from streaming ingestion. Increase compaction frequency.
- **Hive Metastore connection pool exhaustion.** Means too many concurrent Spark + Trino sessions; size up the metastore DB.

---

## One-year cost estimate template (CTO/CFO version)

When a CTO asks "what does our analytics stack cost us per year," do **not** invent a number. Walk the four line items below, fill in the values honestly, and add them up. The template separates sunk costs (already paid, doesn't change with usage) from marginal costs (will change if you grow). Numbers shown are illustrative for a SaaS at ~500 GB to a few TB of lakehouse data — adjust to your scale.

### Line item 1 — Hardware amortization

Two cases, and the distinction matters a lot:

| Case | Annual cost line | Notes |
|---|---|---|
| **Servers already provisioned** (the typical on-prem case) | **$0** — treat as sunk cost | The hardware was bought for the broader k8s cluster or data center. Adding the analytics workload to existing capacity costs nothing new. Be honest with yourself: are you actually using slack capacity, or did you need to buy more nodes because Trino ate all the headroom? |
| **New hardware purchase needed** | (purchase price) / (amortization years, usually 3–5) | E.g., a $36,000 server amortized over 4 years = $9,000/year. Include power/cooling if your facility bills it separately. |

**The honest test:** if removing the analytics stack tomorrow would let you cancel or repurpose specific hardware, that hardware is a marginal cost. If it wouldn't, it's sunk and goes in column 1.

### Line item 2 — k8s node budget

This is the *running* cost of pods on the cluster. Even on owned hardware, k8s nodes have a budget — every vCPU and GB of RAM that Trino and Spark hold is capacity that can't run another workload. Quantify it in cluster terms even if you don't pay a cloud bill:

- Estimate peak concurrent Trino worker pods × (vCPU + RAM) per pod.
- Estimate average Spark executor pods during ingestion windows × (vCPU + RAM) per pod.
- Convert to a fraction of total cluster capacity: "Trino + Spark consume X% of cluster CPU and Y% of RAM at peak."

If the internal chargeback rate is, say, $0.03 per vCPU-hour, multiply through. If your org doesn't chargeback, report this as "X% of cluster capacity reserved" — it's still a real number the CTO needs.

### Line item 3 — Engineering FTE (this is usually the largest cost — be honest)

The single biggest line item, and the one most often left at zero in optimistic plans. Estimate honestly:

| Activity | Typical effort | Notes |
|---|---|---|
| Routine maintenance (compaction monitoring, snapshot expiry, metastore care, on-call) | **0.3 – 0.5 FTE** for a SaaS at <10 TB and a few daily ingestion jobs | Goes up if you add streaming ingestion, more source tables, more analysts |
| New feature work (new fact tables, new dashboards, new dbt models, schema evolution) | **0.5 – 1.5 FTE** depending on roadmap | This is project work, not keep-the-lights-on — it can be deferred but rarely is |
| Incident response and stale-dashboard triage | **0.1 – 0.2 FTE** burst, hard to predict | Set up alerting up front to keep this small |
| **Total** | **0.8 – 2.0 FTE/year** | At fully-loaded $200k/FTE in many US markets, that's **$160k – $400k/year** |

**How to estimate honestly:** look at the last 90 days. Pull tickets/PRs related to the analytics stack. Count engineer-days. Multiply by 4 for an annual estimate. If you've never tracked it, ask "what would break if the team owning this went on vacation for 2 weeks" — the bigger your panic, the more FTE you're spending.

This line item is usually 2–10x larger than hardware and compute combined. Hiding it makes the build-vs-buy comparison look artificially favorable to the self-hosted side.

### Line item 4 — Storage on MinIO

**For most teams on already-provisioned MinIO, this is $0 incremental** — the disks are bought, the cluster is running, adding 2 TB of Parquet doesn't cost anything new. Treat as sunk cost.

**Exceptions where storage moves to a marginal line:**
- You're running out of MinIO capacity and need to add disks/nodes specifically to hold analytics data.
- Your MinIO cluster is sized so tightly that growth from the lakehouse forces a hardware purchase within the year.
- You're using a managed object store (S3, GCS) where you pay per-GB-month.

If you're adding disks: estimate growth from `11-lakehouse-storage-sizing.md`, multiply by your per-TB hardware cost, divide by amortization years.

### Putting it together — example one-year cost

A realistic write-up for a SaaS with already-provisioned hardware and ~2 TB of lakehouse data:

| Line item | Annual cost | Notes |
|---|---|---|
| Hardware amortization | **$0** | Already-provisioned k8s nodes; no new servers needed for this scale |
| k8s node budget (compute) | **$0 cash, ~8% of cluster capacity reserved** | Trino: 4 workers × 16 vCPU / 64 GB; Spark: ~10 executor-pods at peak ingestion |
| Engineering FTE | **~$140,000** | 0.7 FTE @ $200k fully loaded — split across one senior engineer at ~30% and one mid-level at ~40% |
| Storage on MinIO | **$0** | Already-provisioned; 2 TB fits within current MinIO capacity |
| **Total annual cost** | **~$140,000** | ~$0 in net new infra, dominated by engineering time |

**Compare to managed cloud (for the same workload, illustrative):**

| Line item | Annual cost (Snowflake-style) |
|---|---|
| Storage (~$23/TB/month × 2 TB × 12) | ~$550 |
| Warehouse credits (medium warehouse, ~200 credits/month × $2 × 12) | ~$4,800 |
| Engineering FTE (less maintenance, more dbt/dashboard work) | ~$60,000 (0.3 FTE) |
| **Total** | ~$65,000/year |

The cloud path looks cheaper *if* you can actually reduce engineering headcount — but that often doesn't happen because you still need someone owning the data model. If headcount stays the same, the on-prem path is cheaper because you avoid the cloud query bill while paying the same FTE either way.

**The big caveat for your stack:** the on-prem requirement in `prod_info.md` rules out the managed cloud comparison as a real alternative. Use the cloud column as a sanity check on "are we wildly overspending?" not as an actionable migration path.

---

## A simple mental model for "is it worth it"

Ask three questions before you spend a dollar (or an hour) optimizing:

1. **What does this query/table cost today?** Use Trino's `query_stats` to find the top 10 most expensive queries per week.
2. **What's the cheapest fix?** (Usually: better partitioning, a rollup table, or a `WHERE` clause.)
3. **What's the engineering hour cost vs the compute savings?** If a 2-hour fix saves 5 minutes of compute per day, that's a year-long payback. If it saves 30 minutes, it pays back in a month. Optimize the second case first.

The biggest mistake is over-engineering early. A SaaS at 500 GB doesn't need a 50-node Trino cluster, doesn't need streaming compaction, and doesn't need a real-time cost dashboard. It needs partitions, nightly compaction, weekly snapshot expiry, and one engineer paying part-time attention.

---

## Cross-references

- `11-lakehouse-storage-sizing.md` — how to estimate storage from your Postgres baseline.
- `10-lakehouse-partitioning.md` — partition design (the #1 cost lever).
- `15-tools-comparison.md` — pricing details for BigQuery / Snowflake / ClickHouse / DuckDB.
- `06-when-to-add-olap.md` — when the FTE cost of self-hosted Iceberg+Trino is *not* worth it yet.
