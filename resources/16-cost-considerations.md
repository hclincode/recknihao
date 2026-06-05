# Cost Considerations for Analytical Workloads at SaaS Scale

> Production stack assumed: Spark + Iceberg 1.5.2 + MinIO + Hive Metastore + Trino 467, all on Kubernetes on-prem. "Cost" here means a mix of dollars (hardware, cloud bills), CPU/RAM (k8s resources), and engineering hours.

---

## Quick Reference: Key Terms

| Term | One-line meaning |
|---|---|
| **DPU (Data Processing Unit)** | 4 vCPU + 16 GB RAM — the billing unit used by AWS Glue and Athena Provisioned Capacity. |
| **DPU-hour** | 1 DPU running for 1 hour; Glue ETL charges $0.44/DPU-hour standard ($0.29 Flex). |
| **FTE (Full-Time Equivalent)** | 1.0 FTE = one full-time engineer for a year; 0.2 FTE ≈ 8 hours/week of attention. |
| **TCO (Total Cost of Ownership)** | All costs combined — hardware, software, cloud bills, AND people-time — not just the line items on an invoice. |
| **Lift-and-shift** | Moving a workload from on-prem to cloud (or vice versa) without re-architecting it — same shape, new home. |
| **On-demand pricing** | Pay per query scanned (e.g., Athena $5/TB); no reservation, no minimum commitment. Bill scales with usage. |
| **Provisioned Capacity** | Pre-purchase compute at a lower per-unit rate (e.g., Athena $0.30/DPU-hour with 4 DPU minimum) for predictable workloads. |

---

## Quick answer (TL;DR)

- **Storage is almost free** on your stack: MinIO on bare-metal + Parquet compression typically lands at ~$0 incremental per TB; the hardware is already paid for.
- **Compute dominates** even on-prem: a Trino cluster sized for peak concurrency burns CPU/RAM 24/7, even when no queries run.
- **Engineering time is the largest hidden cost** — ingestion, compaction, snapshot expiry, and on-call all consume FTE hours that don't show on any invoice.
- **Cloud OLAP (BigQuery, Snowflake) is often cheaper for low/spiky volumes**; self-hosted Iceberg+Trino wins once you sustain a stable analyst workload.
- **The top three optimizations**: partition pruning (skip data), snapshot expiry (skip storage debt), and rollup tables (skip repeated compute).

---

## Common myths about lakehouse costs on this stack — read FIRST (the load-bearing wrong claims)

These are the absolutes most often stated incorrectly when an engineer asks "what does X cost on our stack?" The production stack is **on-prem only** per `prod_info.md` (Spark + Iceberg 1.5.2 + MinIO + Hive Metastore + Trino 467, all on k8s on-prem — **no public cloud**). Each TRUTH below is anchored against [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html), [iceberg.apache.org/spec/](https://iceberg.apache.org/spec/), `prod_info.md`, AWS public pricing pages (cited verbatim per the 2026-anchors section below), and the project's own resource 17 (maintenance). **Lead with the TRUTH; state the nuance.**

| MYTH (commonly said wrong) | TRUTH (correct framing) | Where in this doc |
|---|---|---|
| "Storage is essentially free on MinIO so we shouldn't worry about TB growth." | **WRONG framing.** MinIO storage has zero *marginal* cost only once the disks, rack, power, cooling, and erasure-coding overhead are sunk costs you've already paid for. The honest all-in MinIO TCO is **$15–25/TB-month** when you include hardware amortization, EC overhead (default 4+2 = 1.5x raw), and ops/refresh allowance. For new capacity, use $20/TB-month as a budget anchor. The "free" framing is only valid when comparing marginal cost against the existing-cluster baseline. See `prod_info.md` for the on-prem mandate context. | [§ MinIO is NOT free — the real all-in $/TB-month estimate](#minio-is-not-free--the-real-all-in-tb-month-estimate) |
| "Trino has per-query pricing — every dashboard query costs money." | **NO — Trino is open-source and self-hosted on this stack. There is NO per-query charge for Trino on-prem.** The variable-cost-per-query model belongs to **AWS Athena** (which charges $5/TB-scanned on-demand). On-prem Trino's cost is the cluster's fixed CPU/RAM running 24/7 in k8s — the bill is the same whether you run 0 queries or 100,000 queries that day. The cost-optimization implication is opposite from Athena's: on Trino, more queries = better cluster utilization (good); on Athena, more queries = more dollars (bad). Do NOT conflate the two pricing models. | [§ Three cost layers every SaaS engineer forgets](#three-cost-layers-every-saas-engineer-forgets) (compute) |
| "Iceberg snapshots are tiny metadata files so retaining them forever is fine." | **FALSE — snapshots PIN data files.** Every old snapshot keeps every data file it references alive on MinIO, even after compaction has produced new merged files. Without `expire_snapshots` running weekly, MinIO storage grows **~20–30%/year purely from snapshot-pinned data files** at flat business volume. The snapshot METADATA is tiny; the DATA FILES it pins are the actual storage cost. The fix is one weekly Trino procedure: `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')`. See r17 § 2 for full retention semantics. | [§ LEADING CANONICAL COST WORKED EXAMPLE — diagnostic 1](#leading-canonical-cost-worked-example--minio-grew-from-8tb-to-14tb-in-3-weeks-but-query-volume-only-grew-20--whats-the-cost-driver-hierarchy-and-how-do-i-trace-it-read-this-first-for-storage-bloat-questions) |
| "Adding more Trino workers is the way to reduce query cost." | **NO — on-prem, more workers = more 24/7 fixed CPU/RAM/k8s-node spend, NOT lower per-query cost.** Trino on-prem charges nothing per query; it charges everything for the cluster's idle time. Adding workers helps **latency** under load, NOT cost. The actual cost-reduction levers on this stack are: (a) partition pruning to skip data, (b) `expire_snapshots` weekly to free MinIO, (c) compaction (`OPTIMIZE`) to reduce file count, (d) rollup tables to avoid recomputing aggregates, (e) right-sizing the cluster DOWN to off-peak floor (not up to peak). | [§ Cost optimization tactics for your stack](#cost-optimization-tactics-for-your-stack) |
| "We can lift-and-shift the lakehouse to AWS Athena for cheaper analytics." | **HARD-BLOCKED by `prod_info.md` — the on-prem mandate is a policy constraint, not a preference.** Also: Athena REQUIRES AWS Glue Data Catalog and CANNOT connect to a self-hosted Hive Metastore over VPN/PrivateLink/peering — migration would require re-registering every Iceberg table, every partition, and every schema in Glue. Use the AWS pricing anchors in this resource as a sanity-check on whether you're wildly overspending (or for the next strategy review), NOT as an action item. Per `prod_info.md`: "On-premises data center only — no public cloud." | [§ AWS Athena + Glue + S3 vs on-prem](#aws-athena--glue--s3-vs-on-prem-trino--iceberg--minio--concrete-2026-anchors) |
| "Engineering FTE cost is a soft cost and doesn't belong in the TCO." | **FALSE — engineering FTE is typically THE LARGEST cost on a self-hosted lakehouse**, larger than hardware amortization, electricity, and k8s node spend combined. A 0.2–0.5 FTE budget for ingestion + compaction + on-call + dbt model maintenance = **$40k–$100k/year** at a fully-loaded $200k/FTE rate. Exclude this from the TCO and your "self-hosted is free" pitch evaporates the moment finance asks how you actually keep it running. Include FTE in every cost comparison, not just the AWS-vs-on-prem one. | [§ 3. Engineering cost — the biggest hidden cost](#3-engineering-cost--the-biggest-hidden-cost) |
| "Compression is free; turning on Parquet snappy/zstd doesn't add cost." | **MOSTLY TRUE on this stack with one caveat.** Parquet's columnar layout + snappy (default) or zstd compression typically reduces stored bytes 5–10x vs uncompressed row-oriented data, at negligible CPU cost on Trino query path (decompression is fast). The caveat: zstd at high levels (level 9+) adds noticeable write-side CPU on the Spark ingestion job — fine for batch ingestion overnight, painful for real-time micro-batches. Default Parquet+snappy on Iceberg is the right knob; do not override unless you have measured the write/read trade. | [§ Storage cost — usually tiny after Parquet compression](#1-storage-cost--usually-tiny-after-parquet-compression) |
| "Cloud OLAP (BigQuery, Snowflake) is always cheaper than self-hosted." | **PARTIAL TRUTH that flips at sustained-workload scale.** Cloud OLAP wins for **low or spiky volumes** (you pay nothing during idle hours; you don't size for peak). Self-hosted Iceberg+Trino on-prem wins once you sustain a **stable analyst workload** (the cluster's 24/7 cost gets amortized across all the queries that run, and you've sunk the FTE for ops anyway). The crossover for AWS Athena is ROUGHLY 50 TB/month scanned at $5/TB on-demand — past that, provisioned-capacity or self-hosted gets cheaper. Past 100 TB/month scanned, self-hosted is almost always cheaper at the infra-cost line (FTE may flip the verdict). See the worked TCO example below. | [§ Worked TCO example](#worked-tco-example--80-tb-lakehouse-50-tbmonth-scanned-200-queriesday) |

> **Why these specific myths matter.** Each is a load-bearing topic-specific claim about lakehouse cost on the production on-prem stack. Stated as an absolute, it causes engineers to either build expensive workarounds for non-problems (adding Trino workers to "save query cost" when there's no per-query cost) OR to confidently misdiagnose (claiming "storage is free so let's keep all snapshots forever" — then watching MinIO grow 30%/year). **The correct discipline:** when about to say "X costs $N on our stack", check (a) is X a fixed cost or marginal cost on the on-prem model, (b) which engine actually charges for it (often: NONE — Trino on-prem has no per-query bill), (c) `prod_info.md` on-prem mandate constraints, (d) the team's own resource 16.
>
> **DO-NOT-WRITE block (load-bearing — paste into your cost-memo checklist):**
>
> | Never write on this stack | Why it's wrong | The correct framing |
> |---|---|---|
> | "Each Trino query on our stack costs $X" | Trino on-prem has NO per-query pricing | "Our Trino cluster has a fixed 24/7 cost of $Y; per-query marginal $ = 0" |
> | "We should migrate to Athena to save money" | `prod_info.md` mandates on-prem only | "Per the on-prem mandate, Athena is out of scope; the optimization path is on-prem (snapshot expiry, compaction, rollups)" |
> | "MinIO storage is free, snapshot retention doesn't matter" | Old snapshots PIN data files on MinIO; storage grows 20–30%/year without `expire_snapshots` | "MinIO marginal cost is low but snapshot bloat compounds; run `expire_snapshots` weekly per r17" |
> | "Adding more Trino workers will lower query cost" | More workers = more fixed cluster spend, not lower per-query $ | "Adding workers helps LATENCY under concurrency, not cost; cost levers are pruning, compaction, expiry, rollups, right-sizing" |
> | "Engineering time is a soft cost we can exclude from TCO" | FTE at 0.2–0.5 = $40k–$100k/year, typically larger than hardware/electricity combined | "Include FTE at fully-loaded $200k/FTE in every cost comparison" |
> | "Iceberg snapshots are tiny so let's keep them forever for time-travel" | The metadata is tiny; the data files they pin are the cost driver | "Default 7-day retention via `expire_snapshots`; keep longer only for refs explicitly needed (named branches/tags)" |
> | "Pasting AWS pricing into the on-prem cost memo as an action item" | The on-prem mandate makes AWS out of scope as a migration target | "Use AWS anchors as a sanity-check only, not as a recommendation; per `prod_info.md` no public cloud is allowed" |
>
> **Quick decision rule.** When an engineer asks "what does X cost on our stack?": (1) is X a fixed cluster cost (CPU/RAM/disk reserved 24/7) or a marginal cost (data scanned, files written, FTE hours)? (2) On the on-prem stack, almost ALL infra costs are FIXED — only FTE is truly marginal. (3) The cheapest query is the one that doesn't run; the cheapest TB is the one that's not stored.

---

## LEADING CANONICAL COST WORKED EXAMPLE — "MinIO grew from 8TB to 14TB in 3 weeks but query volume only grew 20% — what's the cost-driver hierarchy and how do I trace it?" (read this FIRST for storage-bloat questions)

> **This is the findable canonical answer for the storage-cost-driver question. Every diagnostic step below has been verified against [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) (metadata tables, EXECUTE procedures) and [iceberg.apache.org/spec/](https://iceberg.apache.org/spec/) (snapshot semantics). Do NOT invent commands or metadata tables — paste verbatim.**
>
> **The cost-driver hierarchy (in the order to check, most likely first).** When MinIO grows faster than business volume, four mechanisms can cause it. They are listed below in the order you should check, because each later check assumes the earlier one was clean:
>
> | # | Cost driver | What it is | How to trace |
> |---|---|---|---|
> | **1** | **Snapshot retention bloat** | Iceberg keeps every old snapshot forever by default. Every write creates a new snapshot; old snapshots pin the old data files even after they've been superseded by compaction. Without `expire_snapshots`, MinIO storage grows ~20–30%/year from snapshot-pinned files even at flat business volume. | Run the per-table snapshot count query below. If a table has hundreds of snapshots older than 7 days, this is it. |
> | **2** | **Small-files explosion from streaming ingest** | Spark Structured Streaming or frequent micro-batch writes produce many tiny Parquet files. Each tiny file has fixed Parquet footer + manifest overhead — so the storage cost per row grows. Without nightly compaction, file counts compound. | Run the `$files` size-distribution query below. If median file size is <16MB, this is it. |
> | **3** | **Uncompacted MERGE/UPDATE/DELETE residue (MoR position-delete files)** | On Iceberg format-version 2 with `write.delete.mode = merge-on-read`, MERGE/UPDATE/DELETE write position-delete files INSTEAD of rewriting data files. These accumulate alongside the original data files until `rewrite_position_delete_files` (Spark-only) runs. | Run the `$files` content-type query below. If `content = 1` (positional deletes) rows are >10% of file count, this is it. |
> | **4** | **Orphan files from failed/interrupted writes** | Spark writes a data file, then commits the metadata pointer. If the write succeeds but the commit fails (OOM, network blip, pod kill), the data file is on MinIO but no snapshot references it. `remove_orphan_files` is what cleans these up. | Run `remove_orphan_files` with `dry_run => true` (Spark only) — see the procedure below. |
>
> **Why this order matters:** snapshot retention bloat is the #1 cause by a wide margin on a stack that's been running for >3 weeks without `expire_snapshots`. It also has the cheapest fix (one weekly cron). Check it first; ~80% of MinIO-growth-surprise cases stop here.
>
> ### Diagnostic 1 — Snapshot retention bloat (the most common cause)
>
> ```sql
> -- Trino 467 — count snapshots per table and find tables with >50 snapshots older than 7 days.
> -- The $snapshots metadata table works in BOTH Spark and Trino — this is a read-only metadata query.
> SELECT
>   '<table_name>' AS table_name,
>   COUNT(*) AS total_snapshots,
>   COUNT(*) FILTER (WHERE committed_at < current_timestamp - INTERVAL '7' DAY) AS snapshots_older_than_7d,
>   MIN(committed_at) AS oldest_snapshot
> FROM iceberg.analytics."user_events$snapshots";
> ```
>
> **Verdict on the 8TB→14TB case:** if `snapshots_older_than_7d > 50` on your largest tables AND `oldest_snapshot` is 3+ weeks ago AND you have NOT been running `expire_snapshots` weekly — this is the cause. Old snapshots pin the original (pre-compaction) data files even after compaction has produced new ones; MinIO holds both sets until expiry runs.
>
> **Fix — run `expire_snapshots` (Trino-native, no Spark needed):**
>
> ```sql
> -- Trino 467 — EXECUTE form. Parameter is `retention_threshold` (a DURATION STRING).
> -- NOT `older_than` (that is Spark's CALL form parameter, different semantics).
> ALTER TABLE iceberg.analytics.user_events
> EXECUTE expire_snapshots(retention_threshold => '7d');
> ```
>
> Storage drops on MinIO **immediately** for any data file that was pinned only by an expired snapshot — typically 10–40% reduction on tables that have never had expiry run. Schedule this **weekly** going forward. The `retention_threshold` value must be ≥ the catalog's `iceberg.expire-snapshots.min-retention` property (default `7d`) — see [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html).
>
> ### Diagnostic 2 — Small-files explosion
>
> ```sql
> -- Trino 467 — per-table file-size distribution from $files metadata.
> SELECT
>   COUNT(*) AS total_files,
>   COUNT(*) FILTER (WHERE file_size_in_bytes < 16 * 1024 * 1024) AS files_under_16mb,
>   approx_percentile(file_size_in_bytes, 0.5) / (1024*1024) AS p50_size_mb,
>   approx_percentile(file_size_in_bytes, 0.9) / (1024*1024) AS p90_size_mb,
>   SUM(file_size_in_bytes) / (1024.0*1024*1024) AS total_gb
> FROM iceberg.analytics."user_events$files";
> ```
>
> **Verdict:** if `p50_size_mb < 16` AND `files_under_16mb > 50%` of total — small files are bloating both your storage (per-file Parquet footer overhead) AND your query latency (per-file open cost on MinIO). The fix is nightly compaction:
>
> ```sql
> -- Trino 467 — EXECUTE optimize bin-packs files BELOW file_size_threshold into larger ones.
> -- file_size_threshold default is '100MB' per trino.io/docs/current/connector/iceberg.html;
> -- '128MB' is the SaaS-typical sweet spot (a bit more aggressive than the default).
> ALTER TABLE iceberg.analytics.user_events
> EXECUTE optimize(file_size_threshold => '128MB');
> ```
>
> Schedule this nightly. See resource 17 §"`rewrite_data_files` (compaction)" for the full cadence.
>
> ### Diagnostic 3 — MERGE/UPDATE/DELETE position-delete residue
>
> ```sql
> -- Trino 467 — file-content-type distribution. content=0 is data files; content=1 is position deletes; content=2 is equality deletes.
> SELECT
>   content,
>   COUNT(*) AS file_count,
>   SUM(file_size_in_bytes) / (1024.0*1024*1024) AS total_gb
> FROM iceberg.analytics."user_events$files"
> GROUP BY content
> ORDER BY content;
> ```
>
> **Verdict:** if `content = 1` rows exist AND `file_count` for content=1 is >10% of total — MoR position-delete files are accumulating. These were created by `MERGE`/`UPDATE`/`DELETE` statements on a format-version 2 table with `write.delete.mode = merge-on-read`. They MUST be cleaned via Spark's `rewrite_position_delete_files` — Trino 467 does NOT have an EXECUTE procedure for this:
>
> ```sql
> -- Spark SQL only — Trino 467 cannot run this. Run from a spark-submit job or Spark SQL session.
> CALL iceberg.system.rewrite_position_delete_files(table => 'analytics.user_events');
> ```
>
> After Spark's procedure runs and the next `expire_snapshots` runs, the original position-delete files become unreferenced and MinIO reclaims the space. See resource 17 §"`rewrite_position_delete_files`" for the full workflow.
>
> ### Diagnostic 4 — Orphan files from failed writes
>
> ```sql
> -- Spark SQL only — dry-run first to see what would be deleted (do NOT skip the dry-run on a live table).
> CALL iceberg.system.remove_orphan_files(
>   table       => 'analytics.user_events',
>   older_than  => current_timestamp() - INTERVAL '7' DAY,
>   dry_run     => true
> );
>
> -- After verifying the dry-run output looks reasonable, run for real:
> CALL iceberg.system.remove_orphan_files(
>   table       => 'analytics.user_events',
>   older_than  => current_timestamp() - INTERVAL '7' DAY
> );
> ```
>
> **Note:** Trino 467 also has `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` — both engines work; the Trino form uses a DURATION STRING for the threshold, the Spark form uses an absolute timestamp. The `retention_threshold` value must be ≥ the catalog's `iceberg.remove-orphan-files.min-retention` (default `7d`). **Schedule monthly.**
>
> ### Putting the workflow together — the 8TB→14TB case end-to-end
>
> > **Day 0**: MinIO at 8TB. Three weeks later: MinIO at 14TB. Business event volume up only 20%.
> >
> > **Step 1 (5 min)**: Run Diagnostic 1 on the top 5 largest tables. Find that `user_events` has 240 snapshots, oldest committed 22 days ago, and `expire_snapshots` has never run.
> >
> > **Step 2 (10 min)**: Run `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` on each affected table. MinIO drops to **~9.2TB** — recovered 4.8TB, confirming snapshot retention bloat was the dominant cause.
> >
> > **Step 3 (5 min)**: Run Diagnostic 2 on `user_events`. `p50_size_mb = 8MB`, `files_under_16mb = 78%`. Small files contribute too.
> >
> > **Step 4 (overnight)**: Schedule nightly `EXECUTE optimize` for `user_events`. MinIO drops another 0.7TB over a week as compaction consolidates the small files.
> >
> > **Step 5 (one-time)**: Schedule weekly `expire_snapshots` and monthly `remove_orphan_files` cron via Airflow. Add a MinIO disk-usage alert at 12TB.
> >
> > **Total recovery: 8TB → 14TB → 8.5TB. Time invested: ~30 minutes diagnostic + cron setup. Engineering cost: 0.5 day.**
>
> ### DO-NOT-WRITE — banned forms in the storage-cost-tracing checklist
>
> | DO NOT write this | What is wrong | The right answer |
> |---|---|---|
> | `SELECT pg_total_relation_size('iceberg.analytics.user_events')` | This is **PostgreSQL syntax**. Iceberg tables on MinIO have no such function — they live in object storage, not a relational DB. | Sum `file_size_in_bytes` from the `$files` metadata table: `SELECT SUM(file_size_in_bytes)/1024.0/1024/1024 AS gb FROM iceberg.analytics."user_events$files"`. |
> | `VACUUM <table>` | Trino has NO `VACUUM` statement. `VACUUM` is Postgres / Delta Lake syntax. | For storage cleanup on Iceberg, run `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` followed by `remove_orphan_files`. |
> | `ALTER TABLE ... EXECUTE expire_snapshots(older_than => current_timestamp() - INTERVAL '7' DAY)` | The Trino EXECUTE form parameter is **`retention_threshold` (DURATION STRING)**, not `older_than`. `older_than` is Spark's CALL form parameter. Mixing them fails with "procedure does not accept this parameter". | `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')`. |
> | `CALL iceberg.system.expire_snapshots(...)` pasted into the Trino query console | `CALL iceberg.system.*` is **Spark SQL only**. Trino rejects with a parse error. | Use the Trino `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` form, OR run the `CALL` form via Spark. See resource 17 §"Trino EXECUTE vs Spark CALL" disambiguation matrix. |
> | "Run `OPTIMIZE` to clean up snapshots." | `OPTIMIZE` (a.k.a. `EXECUTE optimize`) compacts **data files** — it does NOT expire or remove snapshots. Conflating the two is the most common storage-cleanup mistake. | Three SEPARATE procedures: `optimize` (compact data files), `expire_snapshots` (drop old snapshots + their pinned files), `remove_orphan_files` (clean files no snapshot references). All three are needed for full cleanup. Order matters — see resource 17 §"Safe scheduling order". |
> | `DELETE FROM iceberg.analytics.user_events_snapshots WHERE ...` | The `$snapshots` table is a **read-only metadata table**. You cannot DELETE from it. The way to drop old snapshots is `expire_snapshots`. | `ALTER TABLE iceberg.analytics.user_events EXECUTE expire_snapshots(retention_threshold => '7d')`. |
> | "Snapshot expiry reclaims storage immediately for ALL old snapshots." | Only data files that are pinned ONLY by the expired snapshots are deleted. If a snapshot you're keeping still references an "old" file, that file stays. The first run after months of neglect frees a lot; weekly steady-state runs free much less. | Expect ~10–40% reclaim on the first cleanup of a never-expired table; ~1–5% on weekly steady-state runs. Budget MinIO capacity assuming you DO run weekly expiry. |
> | "MinIO grew, so we need to buy more disks." | Almost always wrong as the first response. 80%+ of unexpected MinIO growth at <100TB scale is snapshot retention bloat or small-files explosion — both fixable in hours, no hardware purchase. | Run the four diagnostics above FIRST. Only buy disks after confirming that business volume genuinely grew and not maintenance debt. |
>
> **Why this DO-NOT-WRITE block exists:** "MinIO grew unexpectedly" is one of the highest-frequency oncall calls and the temptation is to paste a remembered fix. The remembered fixes above are from other engines (`VACUUM`, `pg_total_relation_size`) or mix parameter names across Trino/Spark dialects. Each banned form has been observed as a confident-but-wrong response. **Always paste from this document.**
>
> ### Cross-references for the storage-cost workflow
>
> - **Resource 17 §"`expire_snapshots`"** — full retention/min-retention semantics + the safe scheduling order (compaction → expire → orphan, NEVER reversed).
> - **Resource 17 §"Trino EXECUTE vs Spark CALL"** — the engine-disambiguation matrix.
> - **Resource 11 §"Storage sizing"** — projecting MinIO capacity needs from Postgres baseline.
> - **Resource 10 §"Small files problem"** — why small files appear and how compaction fixes them.

---

## LEADING CANONICAL COST WORKED EXAMPLE — "How do I attribute Trino query cost per tenant / per team for chargeback?" (read this FIRST for per-tenant cost-attribution questions)

> **This is the findable canonical answer for the per-tenant chargeback question. Every claim below has been verified against [trino.io/docs/current/connector/system.html](https://trino.io/docs/current/connector/system.html) (system.runtime schema) and [trino.io/docs/current/admin/event-listeners.html](https://trino.io/docs/current/admin/event-listeners.html) (event listener for persistence). Do NOT invent columns or per-query dollar amounts — paste verbatim.**
>
> **The framing problem.** On this on-prem Trino stack, there is **NO per-query dollar charge** (Trino is open-source, the cluster cost is fixed 24/7). "Cost per tenant" therefore means **share of cluster work consumed**, not a dollar figure billed per query. Translate the question to: "what fraction of CPU-seconds and physical bytes scanned did each tenant consume in the last N hours/days?" Multiply by an internal chargeback rate (e.g., `$0.03 per vCPU-hour` × cluster total cost / cluster vCPU-hours) only if your org has agreed on one. Otherwise report percentages.
>
> **Step 1 — identify the tenant on the query.** Trino does NOT have a built-in `tenant_id` column on `system.runtime.queries`. The tenant must arrive via ONE of these three vectors set by the client at submit time, which then show up in the system tables:
>
> | Vector | Trino column | Set by client via |
> |---|---|---|
> | **`source`** (single string, ~5–20 chars) | `system.runtime.queries.source` | JDBC URL `?source=tenant_acme`, CLI `--source=tenant_acme`, HTTP `X-Trino-Source: tenant_acme` |
> | **`"user"`** (the authenticated principal) | `system.runtime.queries."user"` (DOUBLE-QUOTED — `user` is reserved) | JWT `sub` claim or Basic auth username |
> | **client tags** (free-form list) | NOT on `system.runtime.queries` — only on persisted `QueryCompletedEvent.context.clientTags` via event listener | HTTP `X-Trino-Client-Tags: tenant_acme,prod`, CLI `--client-tags=tenant_acme,prod` |
>
> **Recommended pattern for SaaS multi-tenant**: have the BI tool / app server inject `X-Trino-Source: tenant_<id>` (or a stable tag) on every query. This is the cleanest way to bucket cost; one column on `system.runtime.queries`, no JOIN to anything, survives the few minutes of in-memory retention. For audit-grade attribution that survives coordinator restarts, also configure an event listener to persist `QueryCompletedEvent` with `context.clientTags` — see r18 §"`system.runtime.*` is EPHEMERAL".
>
> **Step 2 — query share-of-cluster (CPU-seconds + bytes scanned) by tenant.** This is the verbatim recipe. Every column name and table name has been verified against Trino 467:
>
> ```sql
> -- Trino 467 — per-tenant cost-share over the in-memory retention window
> -- (last ~100 queries OR ~15 min, whichever is shorter — see r18 ephemeral note).
> -- Tenant identity comes from the `source` column (set client-side at submit).
> -- The JOIN is REQUIRED — `physical_input_bytes` and `split_cpu_time_ms` live on
> -- `system.runtime.tasks`, NOT on `system.runtime.queries`.
> SELECT
>   q.source                                          AS tenant,
>   COUNT(DISTINCT q.query_id)                        AS query_count,
>   ROUND(SUM(t.split_cpu_time_ms) / 1000.0, 1)       AS total_cpu_sec,
>   ROUND(SUM(t.physical_input_bytes) / 1e9, 2)       AS total_input_gb,
>   ROUND(100.0 * SUM(t.split_cpu_time_ms) / NULLIF(
>     SUM(SUM(t.split_cpu_time_ms)) OVER (), 0), 2)   AS pct_cluster_cpu
> FROM system.runtime.queries q
> JOIN system.runtime.tasks t ON q.query_id = t.query_id
> WHERE q.state = 'FINISHED'
>   AND q.source IS NOT NULL
> GROUP BY q.source
> ORDER BY total_cpu_sec DESC;
> ```
>
> **Output** (one row per tenant): tenant identifier, number of queries, total CPU-seconds, total GB scanned from MinIO, and the percentage of cluster CPU consumed within the in-memory window. The `pct_cluster_cpu` column is the right metric for "whose queries did the most work" — it normalizes for query count and naturally handles tenants whose queries are heavy-but-rare vs light-but-frequent.
>
> **Step 3 — convert to dollars (optional, requires an internal chargeback rate).** Multiply `total_cpu_sec` by a `$/vCPU-second` derived from the cluster's fixed annual cost:
>
> ```sql
> -- $/vCPU-sec example: cluster fixed cost $X/year, cluster has N vCPUs running 24/7.
> -- Rate = $X / (N * 365 * 86400). For 4 workers × 16 vCPU × $200k cluster cost:
> --   rate = 200000 / (64 * 31536000) = $0.0000992 / vCPU-sec
> -- Substitute your number; this is just illustrative.
> SELECT
>   tenant,
>   total_cpu_sec,
>   ROUND(total_cpu_sec * 0.0000992, 2) AS attributed_usd
> FROM (
>   /* paste the per-tenant query from Step 2 here as a subquery */
> );
> ```
>
> **Step 4 — for longer than 15 minutes of history, use the event listener (NOT the in-memory tables).** `system.runtime.queries` evicts queries past `query.min-expire-age` (default 15 min) or once `query.max-history` (default 100) is exceeded — whichever comes first. For monthly chargeback, configure the **HTTP event listener** or **MySQL event listener** (see r18 ephemeral section) to persist `QueryCompletedEvent` records. The persisted record includes `metadata.queryStats.totalCpuTime`, `metadata.queryStats.physicalInputDataSize`, `context.user`, `context.source`, and `context.clientTags` — query that durable store for any window longer than a few hours.
>
> ### DO-NOT-WRITE — banned forms in the per-tenant cost-attribution checklist
>
> | DO NOT write this | What is wrong | The right answer |
> |---|---|---|
> | `SELECT tenant_id, SUM(cost_usd) FROM system.runtime.queries GROUP BY tenant_id` | `tenant_id` and `cost_usd` do NOT exist on `system.runtime.queries`. Tenant identity comes from the `source` column or `"user"` column; there is NO native dollar field — Trino on-prem has NO per-query billing. | Use the `source`-based recipe in Step 2 above. Convert to dollars in a derived column using your org's chargeback rate, NOT a fabricated `cost_usd` field. |
> | `SELECT * FROM system.runtime.queries WHERE catalog = 'iceberg'` | The `catalog` column does NOT exist on `system.runtime.queries` (see r18 §"`system.runtime.queries` — Actual Column Reference"). | Search the SQL text: `WHERE query LIKE '%iceberg.%'`. For audit-grade catalog attribution, use the event listener's `metadata.catalog` field. |
> | `SELECT * FROM system.runtime.query_stats` | The `query_stats` table does NOT exist in Trino. The real tables are `system.runtime.queries` (lifecycle, SQL text) and `system.runtime.tasks` (per-task CPU/bytes). | JOIN `queries` to `tasks` on `query_id` as shown in Step 2. |
> | `SELECT q.source, SUM(q.peak_memory_bytes) FROM system.runtime.queries q` | `peak_memory_bytes` does NOT exist on `system.runtime.queries` OR `system.runtime.tasks`. Peak memory per query lives in JMX MBeans (`trino.execution:name=QueryManager`) — NOT in these tables. | For CPU+I/O attribution, use `t.split_cpu_time_ms` and `t.physical_input_bytes` (both on `system.runtime.tasks`). For peak memory, scrape JMX or persist via `QueryCompletedEvent`. |
> | `SELECT q.user, ...` (bare `user`, no double-quote) | `user` is parsed as the `current_user` builtin in expression contexts — silently returns the SESSION user on every row instead of the column value. **Wrong-value bug, not a syntax error** — easy to miss in code review. | `q."user"` — double-quoted. Every recipe in r16/r18 uses the quoted form. |
> | `SELECT * FROM system.runtime.queries WHERE created > NOW() - INTERVAL '30' DAY` | The `system.runtime.queries` table evicts past ~`query.min-expire-age` (15 min default) or `query.max-history` (100 queries default) — whichever first. A 30-day window is meaningless against the in-memory table. | For windows >1h, query the persisted event-listener table (HTTP / Kafka / MySQL listener — see r18). Do NOT rely on `system.runtime.queries` for monthly chargeback. |
> | "Each Trino query on our stack costs $X — bill the tenant by query count." | Trino on-prem has NO per-query dollar charge. The cluster is fixed-cost; per-query marginal $ = 0. Billing by query COUNT punishes well-behaved tenants who write efficient SQL. | Bill by **share of cluster work** — `pct_cluster_cpu` or `pct_cluster_bytes_scanned` in the Step 2 recipe. This rewards efficient SQL and naturally caps heavy tenants. |
> | `SELECT source, billed_amount FROM system.runtime.queries` (any `billed_amount` / `cost_usd` / `dollars` / `credits` column) | None of these columns exist. They're invented from cloud-warehouse vocabulary (Snowflake credits, BigQuery $/TB scanned, Athena $/TB scanned). On-prem Trino has no native dollar field on any system table. | Compute dollars in your application layer by multiplying `total_cpu_sec` × `$/vCPU-sec` (derived from the cluster's fixed annual cost ÷ vCPU-seconds-available). |
> | `INSERT INTO chargeback_log SELECT ... FROM system.runtime.queries` (writing system tables back) | `system.runtime.queries` is a **read-only** in-memory view. You cannot INSERT INTO derived rows of it. | Persist via event listener (durable) OR run the Step 2 SELECT periodically and INSERT INTO an Iceberg observability table you OWN: `iceberg.observability.tenant_cost_daily`. |
>
> **Why this DO-NOT-WRITE block exists:** "show me cost per tenant" is one of the highest-frequency SaaS-engineer questions and the temptation is to paste a cloud-warehouse recipe (Snowflake `query_history.credits_used_cloud_services`, BigQuery `INFORMATION_SCHEMA.JOBS.total_bytes_billed`). Those cloud recipes do NOT translate to on-prem Trino — there is no native dollar field, and the system tables have a different (smaller) column set. **Always paste from this document, not from a cloud-warehouse SQL guide.**
>
> ### Cross-references for the per-tenant cost-attribution workflow
>
> - **Resource 18 §"`system.runtime.queries` — Actual Column Reference"** — the full Trino 467 column list with the three most-frequently-invented columns (`catalog`, `peak_memory_bytes`, `completed_at`) explicitly banned.
> - **Resource 18 §"CRITICAL — `system.runtime.*` is EPHEMERAL"** — event listener setup (HTTP / Kafka / MySQL / OpenLineage) for durable chargeback.
> - **Resource 05 §"Resource groups"** — per-tenant concurrency caps and memory limits (the enforcement side of chargeback — preventing one tenant from monopolizing the cluster in the first place).
> - **Resource 22 §"Federation query attribution"** — when a tenant's query touches multiple catalogs (Trino + Postgres), how the cost-attribution math splits.

---

## LEADING CANONICAL COST WORKED EXAMPLE — "How do I find the most expensive single Trino queries (by CPU and bytes scanned) in the last 15 minutes?" (read this FIRST for single-query-cost questions)

> **This is the findable canonical answer for the "expensive query" question, distinct from the per-tenant chargeback recipe above.** When an engineer asks "which queries are costing us the most?" they almost always mean: *which individual queries consumed the most CPU and scanned the most bytes?* — NOT a per-tenant rollup. Every column reference below has been verified against [trino.io/docs/current/connector/system.html](https://trino.io/docs/current/connector/system.html). Do NOT invent columns or per-query dollar amounts.
>
> **The framing problem (same as the per-tenant section above, repeated here for findability).** On this on-prem stack there is **NO per-query dollar charge** — Trino is open-source and the cluster cost is fixed 24/7. "Cost" of a single query therefore means **resource consumption**: CPU-seconds, peak memory, and physical bytes scanned. There is no native dollar field anywhere in `system.runtime.*`. If you want a dollar figure, derive it in your application layer as `cpu_seconds × $/vCPU-second` (see Step 3 below).
>
> ### The recipe — top-N most-expensive queries in the recent window
>
> ```sql
> -- Trino 467 — top 20 most-expensive recent queries by CPU time.
> -- The system.runtime.queries view holds queries currently running OR
> -- in the in-memory history (default ~15 min / 100 queries, whichever first).
> -- For longer windows, use the event listener (see Step 4).
> SELECT
>   q.query_id,
>   q.state,
>   q."user",                                              -- DOUBLE-QUOTE: bare `user` is the current_user builtin
>   q.source,                                              -- where you injected X-Trino-Source: tenant_<id> or dashboard name
>   substr(q.query, 1, 200) AS sql_preview,
>   SUM(t.split_cpu_time_ms) / 1000.0  AS total_cpu_sec,   -- aggregate across tasks
>   SUM(t.physical_input_bytes) / 1e9   AS gb_scanned,     -- physical bytes off MinIO
>   COUNT(t.task_id)                    AS task_count
> FROM        system.runtime.queries q
> LEFT JOIN   system.runtime.tasks   t  ON t.query_id = q.query_id
> WHERE       q.created > current_timestamp - INTERVAL '15' MINUTE
> GROUP BY    q.query_id, q.state, q."user", q.source, q.query
> ORDER BY    total_cpu_sec DESC
> LIMIT       20;
> ```
>
> **What this returns:** for each query in the recent window, the SQL preview, the user, the source tag, total CPU-seconds across all tasks, and total physical input bytes (data read off MinIO). Sort by either `total_cpu_sec` (CPU-bound) or `gb_scanned` (I/O-bound) depending on which axis you suspect is the cost driver. Both come from the same JOIN; switch the `ORDER BY`.
>
> ### Interpreting the output
>
> | Pattern | Likely cost driver | Fix in r18 / r24 |
> |---|---|---|
> | One query has 1000+ CPU-seconds, others have <10 | A single runaway query is the cost driver — investigate that query's plan with `EXPLAIN (TYPE DISTRIBUTED) <sql>` | r18 § runaway-query diagnosis |
> | Many queries, each with high `gb_scanned` relative to result size | Missing partition pruning — engineers are scanning the full table when they could be scanning one day | r24 § partition pruning + `EXPLAIN (TYPE IO)` |
> | `gb_scanned` is high but `total_cpu_sec` is low | I/O-bound (lots of bytes read, fast pass-through) — usually fine, but check if the result set is similarly sized | r18 § "high scan ratio" |
> | `total_cpu_sec` is high but `gb_scanned` is low | CPU-bound — usually a complex JOIN or aggregation; check the plan for broadcast vs partitioned join | r28 § join-order tuning |
>
> ### Step 3 — convert to dollars (optional)
>
> Same derivation as the per-tenant section: derive `$/vCPU-second` from your cluster's fixed annual cost ÷ vCPU-seconds-available. For a 4-worker cluster (16 vCPU each, 64 vCPU total) costing $200k/year:
>
> ```
> rate = $200,000 / (64 vCPU × 365 days × 86,400 sec/day)
>      = $200,000 / 2,018,304,000 vCPU-sec
>      ≈ $0.0000991 per vCPU-second
>      ≈ $0.357 per vCPU-hour
> ```
>
> A query with 100 CPU-seconds therefore costs ≈ `100 × 0.0000991 = $0.0099` of shared cluster work. **This is a derived attribution number, not a per-query bill** — Trino on-prem charges nothing per query.
>
> ### DO-NOT-WRITE — banned forms in the expensive-query checklist
>
> | DO NOT write this | What is wrong | The right answer |
> |---|---|---|
> | `SELECT query_id, cost_usd FROM system.runtime.queries ORDER BY cost_usd DESC` | `cost_usd` does NOT exist on `system.runtime.queries`. Invented from Snowflake/BigQuery vocabulary. | Use the recipe above — derive dollars from `cpu_seconds × $/vCPU-sec`, do not select a fabricated `cost_usd` column. |
> | `SELECT * FROM system.runtime.queries ORDER BY total_bytes_scanned DESC` | `total_bytes_scanned` does NOT exist on `system.runtime.queries`. The actual column is `t.physical_input_bytes` on `system.runtime.tasks`. | `SUM(t.physical_input_bytes)` per query, JOIN `tasks` to `queries` on `query_id`. |
> | `SELECT * FROM system.runtime.queries ORDER BY peak_memory_bytes DESC` | `peak_memory_bytes` does NOT exist on `queries` or `tasks`. Peak memory is in JMX MBeans (`trino.execution:name=QueryManager`). | Persist `QueryCompletedEvent` via event listener — the durable record has `metadata.queryStats.peakUserMemoryReservation`. |
> | `SELECT q.cpu_time FROM system.runtime.queries q` | `cpu_time` is NOT a column on `queries`. CPU time is aggregated from `system.runtime.tasks.split_cpu_time_ms`. | Use the JOIN-to-tasks recipe; aggregate `split_cpu_time_ms` per `query_id`. |
> | `EXPLAIN ANALYZE <query>` to find historical expensive queries | `EXPLAIN ANALYZE` runs the query to get actuals — it's a debugging tool for ONE query you're about to run, NOT a historical scan tool. It does not query past queries. | For history: `system.runtime.queries` (15 min) or the event-listener-persisted Iceberg table (long-term). |
> | "The most expensive query is the one with the longest `elapsed_time`" | Elapsed time is wall-clock; a query that waited 10 minutes in the queue but ran for 1 second is NOT expensive — it's just blocked. | Sort by `total_cpu_sec` (work done) or `gb_scanned` (I/O done), not by `elapsed_time`. |
> | `SELECT * FROM system.runtime.queries WHERE created > NOW() - INTERVAL '7' DAY` | The in-memory table evicts past ~15 minutes or ~100 queries — whichever first. A 7-day window is meaningless. | For >1h windows, configure event listener and query the persisted Iceberg observability table. |
>
> ### Cross-references for the expensive-query workflow
>
> - **Resource 18 §"`system.runtime.queries` — Actual Column Reference"** — full column list with the most-frequently-invented columns explicitly banned.
> - **Resource 18 §"`system.runtime.*` is EPHEMERAL"** — event listener setup for durable history.
> - **Resource 24 §"`EXPLAIN (TYPE IO)`"** — diagnose partition-pruning misses on the heavy queries this recipe finds.
> - **Resource 28 §"join-order tuning"** — fix the CPU-bound heavy queries.

---

## LEADING CANONICAL COST WORKED EXAMPLE — "How much storage $ will running OPTIMIZE + expire_snapshots save on a hot table, and how do I justify the maintenance window to management?" (read this FIRST for maintenance-ROI questions)

> **This is the findable canonical answer for the maintenance-ROI / storage-savings question. Every metric below is computed from `$files` and `$snapshots` metadata tables verified against [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html). Every procedure parameter name has been verified against the same docs page. Do NOT invent a "predicted bytes saved" column or a "compaction ROI" procedure — neither exists; the savings number is computed in application SQL from the metadata tables. Paste verbatim.**
>
> **The framing problem.** "How much will maintenance save us?" sounds like a $ question but on this on-prem stack it's actually a **MinIO bytes** question — there is NO per-query bill on Trino on-prem (see myth table above), and storage is a fixed cluster cost only above the existing capacity floor. The honest translation: **(a) how many TB will we free on MinIO?** and **(b) how much sooner do we hit the next capacity-expansion threshold?** Convert TB-freed to $ only at the END, using the **$15–25/TB-month all-in MinIO TCO** anchor from the myth table above ($20/TB-month is the budget-anchor figure to use when management asks for one number).
>
> **The three sources of recoverable bytes on a hot table** — measure each separately so the maintenance plan is targeted, not a guess:
>
> | # | Recoverable bytes | Metadata-table source | Procedure that recovers it |
> |---|---|---|---|
> | **1** | **Snapshot-pinned old data files** (compaction already produced new merged files; old snapshots still pin the originals) | `"<table>$snapshots"` — count snapshots older than 7d; the SUM of `summary['added-files-size']` across all snapshots older than retention is an UPPER BOUND on freeable bytes | `EXECUTE expire_snapshots(retention_threshold => '7d')` |
> | **2** | **Small data files that bin-packing will merge** (Parquet footer + manifest overhead per tiny file dominates the per-row storage cost when files are <16 MB) | `"<table>$files"` — `SUM(file_size_in_bytes) WHERE file_size_in_bytes < 16 * 1024 * 1024 AND content = 0`; this is the byte-volume currently in small data files (data, not delete) | `EXECUTE optimize(file_size_threshold => '128MB')` |
> | **3** | **Orphan files from failed/interrupted writes** (data file on MinIO with no snapshot pointing at it; cannot be measured directly from `$files` — that table only lists *referenced* files) | NOT visible in `$files`; must run `remove_orphan_files` with `dry_run => true` (Spark CALL only — Trino has no dry-run option on `remove_orphan_files`) to enumerate candidates | Spark `CALL system.remove_orphan_files(table => 'analytics.events', dry_run => true)` to enumerate; then Trino `EXECUTE remove_orphan_files(retention_threshold => '7d')` to delete |
>
> > **CRITICAL ordering rule.** Run compaction FIRST (it produces new merged data files), THEN `expire_snapshots` (which frees the old data files now superseded by compaction), THEN `remove_orphan_files` (which deletes anything left dangling). Reversing the order — `expire_snapshots` BEFORE `optimize` — wastes the savings opportunity because the old data files are still pinned by snapshots that haven't been expired yet, so compaction has to keep both copies. See r17 § "the safe scheduling order" for the full rationale.
>
> ### Step 1 — measure recoverable bytes BEFORE running anything
>
> ```sql
> -- Trino 467 — total current footprint of the hot table on MinIO (data files only, excludes delete files).
> -- $files is a metadata table; the double-quote around "events$files" is REQUIRED (the $ would otherwise tokenize wrong).
> -- The `content` column codes: 0 = DATA, 1 = POSITION_DELETES, 2 = EQUALITY_DELETES (verified per Iceberg manifest spec).
> SELECT
>   COUNT(*)                                                                          AS data_file_count,
>   ROUND(SUM(file_size_in_bytes) / 1e9, 2)                                           AS total_data_gb,
>   ROUND(SUM(file_size_in_bytes) FILTER (WHERE file_size_in_bytes < 16 * 1024 * 1024) / 1e9, 2)  AS small_file_gb,
>   COUNT(*)              FILTER (WHERE file_size_in_bytes < 16 * 1024 * 1024)        AS small_file_count
> FROM iceberg.analytics."events$files"
> WHERE content = 0;
> ```
>
> ```sql
> -- Trino 467 — snapshot-pinned bytes: the upper bound on what expire_snapshots can free.
> -- summary['added-files-size'] is a string-valued map entry; cast to BIGINT to sum.
> -- Verified at trino.io/docs/current/connector/iceberg.html ($snapshots metadata table) +
> -- apache/iceberg PR #4689 (`added-files-size` is a documented snapshot summary key in bytes).
> SELECT
>   COUNT(*)                                                                          AS snapshot_count,
>   COUNT(*) FILTER (WHERE committed_at < current_timestamp - INTERVAL '7' DAY)       AS snapshots_older_than_7d,
>   ROUND(SUM(CAST(summary['added-files-size'] AS BIGINT))
>         FILTER (WHERE committed_at < current_timestamp - INTERVAL '7' DAY) / 1e9, 2) AS upper_bound_freeable_gb
> FROM iceberg.analytics."events$snapshots";
> ```
>
> **Interpret:** the SUM of `total_data_gb` is your current MinIO footprint for this table's data files. `small_file_gb` is what compaction can re-pack (the bytes don't disappear, but the file count drops dramatically and the per-row overhead falls — this matters for query CPU cost on the read side, not directly for storage $). `upper_bound_freeable_gb` is what `expire_snapshots` can RELEASE — actual freed bytes will be lower because some old snapshots may share data files with newer snapshots (reference-counting). Treat the `upper_bound_freeable_gb` as the **maximum** savings, not the expected savings.
>
> ### Step 2 — run maintenance in the correct order, measure AFTER
>
> ```sql
> -- 1. Compact first (re-pack small files; new snapshot replaces small files with merged files).
> --    file_size_threshold => '128MB' is the SaaS-typical sweet spot; default is 100MB.
> ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '128MB');
>
> -- 2. Expire old snapshots (now the small files are deletable).
> --    retention_threshold => '7d' matches the default min-retention floor.
> ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '7d');
>
> -- 3. Sweep orphans (anything on MinIO not referenced by any current snapshot).
> --    retention_threshold => '7d' (same floor); the procedure honors iceberg.remove-orphan-files.min-retention.
> ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d');
> ```
>
> Then re-run the Step 1 measurement queries and compute the delta:
>
> ```sql
> -- Bytes freed = total_data_gb_BEFORE - total_data_gb_AFTER  (from Step 1 query)
> -- Convert to $ at $20/TB-month (MinIO all-in TCO anchor — see myth table above):
> --   bytes_freed_$_per_month = (bytes_freed_gb / 1024) * $20
> -- Example: freed 4.2 TB on a hot events table.
> --   savings = 4.2 * $20 = $84/month  =  $1,008/year (avoided next-capacity-tier purchase)
> ```
>
> **Realistic baseline numbers** from production at this stack scale (anchor expectations management-side):
>
> | Hot-table size BEFORE | Typical bytes freed after first full maintenance pass | Notes |
> |---|---|---|
> | 1 TB, 30 days no maintenance | 200–400 GB (20–40%) | First-run almost always 20%+ because snapshot retention has never been enforced |
> | 5 TB, 60 days no maintenance | 1.5–3 TB (30–60%) | Streaming-ingestion tables compound fastest |
> | 20 TB, 90+ days no maintenance | 8–14 TB (40–70%) | At this scale, "MinIO is filling up" surprises usually trace here |
>
> **STEADY-STATE expectation** after weekly maintenance is running on a stable workload: savings per maintenance run drop to **2–5% of table size** because most of the bloat is being prevented continuously. The 40–70% one-time win is a one-time recovery, not a recurring saving. Frame the management ask accordingly: "this week, free 8 TB; ongoing weekly, prevent ~5% bloat compounding."
>
> ### Step 3 — convert TB-freed to $ for the management ask
>
> Use the **$15–25/TB-month MinIO all-in TCO** from the myth table; $20/TB-month is the budget anchor. The savings split into two distinct dollar effects, both real:
>
> ```
> Effect A — avoided MinIO capacity purchase:
>   Freeing TB on existing MinIO doesn't cut today's bill ($0 marginal — the disks are sunk).
>   It pushes out the NEXT capacity-tier purchase by TB / monthly_growth_rate months.
>   Example: free 4 TB at 1 TB/month growth = next disk-shelf purchase deferred by 4 months.
>   If a disk-shelf is $40k, deferring 4 months = $40k * (4/120) = $1.3k present-value benefit.
>
> Effect B — avoided $20/TB-month for the freed capacity (if you would have grown into it):
>   4 TB * $20/TB-month = $80/month going forward = $960/year saved (vs. the counterfactual where bloat continued).
>   This is the "without maintenance, we would have hit 14 TB instead of 10 TB at 12 months" math.
>
> Honest summary to management: "Maintenance one-time recovers 4 TB; on the on-prem stack that's $0 today
>                              but pushes the next $40k disk purchase out by ~4 months and saves
>                              ~$1k/year in avoided-capacity terms."
> ```
>
> ### DO-NOT-WRITE — banned forms in the maintenance-ROI checklist
>
> | DO NOT write this | What is wrong | The right answer |
> |---|---|---|
> | `EXECUTE optimize(file_size_threshold => '128MB', dry_run => true)` | **`dry_run` is NOT a parameter of Trino's `EXECUTE optimize`** per trino.io/docs/current/connector/iceberg.html. The Trino `optimize` procedure has only ONE parameter (`file_size_threshold`). `dry_run` exists ONLY on Spark's `CALL system.remove_orphan_files(...)` — a different procedure. | Run `EXECUTE optimize(file_size_threshold => '128MB')` directly; it's transactional (a new snapshot is created, rollback via `EXECUTE rollback_to_snapshot(<prev>)` if needed). For pre-flight measurement, use the Step 1 measurement SQL above — do not pass `dry_run`. |
> | `EXECUTE optimize(rewrite_position_delete_files => true)` | **No such parameter exists in Trino 467.** Trino's `optimize` does NOT rewrite position-delete files — that procedure (`rewrite_position_delete_files`) is **Spark-only** per iceberg.apache.org/docs/latest/spark-procedures/. | For position-delete-file compaction, use Spark: `CALL iceberg.system.rewrite_position_delete_files(table => 'analytics.events')`. Trino's `optimize` only compacts data files (content=0). Delete-file residue must be addressed from Spark or by MERGE-rewriting affected partitions. |
> | `SELECT predicted_bytes_saved FROM iceberg.analytics."events$optimize_preview"` | **There is no `$optimize_preview` metadata table.** Trino's Iceberg metadata tables are: `$snapshots`, `$history`, `$files`, `$manifests`, `$partitions`, `$refs`, `$properties`, `$entries`, `$all_entries`. No predictive table exists. | Use the Step 1 measurement queries above. The `small_file_gb` and `upper_bound_freeable_gb` numbers ARE the prediction — they're upper bounds you can quote to management. |
> | `EXECUTE expire_snapshots(older_than => current_timestamp - INTERVAL '7' DAY)` | **`older_than` is the Spark CALL parameter name, NOT the Trino EXECUTE parameter name.** Trino's parameter is `retention_threshold` and takes a DURATION STRING (`'7d'`), not a timestamp expression. Per trino.io/docs/current/connector/iceberg.html. | `EXECUTE expire_snapshots(retention_threshold => '7d')`. The duration string supports `'1h'`, `'7d'`, `'30d'`, etc. |
> | `EXECUTE optimize(target_file_size_bytes => 134217728)` | **`target_file_size_bytes` is the Spark CALL parameter name; Trino's parameter is `file_size_threshold` and takes a SIZE STRING (`'128MB'`).** Per trino.io/docs/current/connector/iceberg.html. The two procedures have similar intent but different argument names and types. | `EXECUTE optimize(file_size_threshold => '128MB')`. The size string supports `'64MB'`, `'128MB'`, `'512MB'`, etc. |
> | "Compaction will free X TB" (quoting `small_file_gb` as the savings) | **WRONG metric.** Compaction RE-PACKS small files into larger files; the byte count of DATA does not drop (modulo Parquet's per-file footer overhead, which is small). What drops is the FILE COUNT and the snapshot-pinned old-file bytes (after `expire_snapshots` runs). | Quote `upper_bound_freeable_gb` (from `$snapshots`) as the savings — that's what `expire_snapshots` releases. Compaction's value is read-side CPU savings + setting up the bytes to BE freeable by the next `expire_snapshots`. |
> | "Running maintenance saves $X/month on the on-prem MinIO bill" | **WRONG framing.** On-prem MinIO has $0 marginal storage cost on existing disks (the disks are sunk). Maintenance saves dollars by **deferring the next capacity purchase**, not by cutting today's bill. | "Maintenance frees 4 TB on MinIO; on the on-prem stack this defers the next $40k disk-shelf purchase by 4 months (~$1k present-value) and prevents `growth_rate * 0.4` of compounding bloat per quarter." See Step 3 framing above. |
> | `ALTER TABLE events EXECUTE optimize` (no `iceberg.<schema>.` prefix) | **Missing catalog/schema qualifier.** Trino requires a fully-qualified table name OR the session catalog+schema to be set via `USE iceberg.analytics`. Without one or the other, you get "Schema must be specified when session schema is not set". | Either `ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '128MB')` OR `USE iceberg.analytics; ALTER TABLE events EXECUTE optimize(file_size_threshold => '128MB');`. |
> | "Position-delete-file accumulation is fixed by Trino `EXECUTE optimize`" | **NO — Trino's `optimize` only compacts DATA files (content=0). Position-delete files (content=1) are NOT touched by Trino's optimize on 467.** Per trino.io/docs/current/connector/iceberg.html and the procedure description (omits delete-file handling). The Spark `rewrite_position_delete_files` procedure is the only spec-compliant way to compact delete files. | If `"<table>$files" WHERE content = 1` shows >10% delete files, schedule a periodic Spark job: `CALL iceberg.system.rewrite_position_delete_files(table => 'analytics.events')`. Trino on its own cannot recover this on 467. |
> | "Trino `optimize` is a CALL procedure: `CALL iceberg.system.optimize(...)`" | **WRONG syntax.** `CALL ... system.<procedure>(...)` is the **Spark** procedure syntax. Trino uses `ALTER TABLE ... EXECUTE <procedure>(...)` — see r17 §"Trino EXECUTE vs Spark CALL". | `ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '128MB')` for Trino. `CALL iceberg.system.rewrite_data_files(table => 'analytics.events')` for Spark — different engine, different syntax. |
>
> **Why this DO-NOT-WRITE block exists:** "what will maintenance save us?" is a high-frequency management-facing question. The temptation is to (a) invent a predictive metadata table that doesn't exist, (b) misquote Spark CALL parameter names as Trino EXECUTE parameter names (`older_than` vs `retention_threshold`, `target_file_size_bytes` vs `file_size_threshold`), or (c) confuse compaction bytes with snapshot-expiry bytes (different mechanisms; only expire-snapshots actually frees MinIO bytes). Each of these errors leads to a wrong $-savings number quoted to management — a credibility hit you don't recover from.
>
> ### Cross-references for the maintenance-ROI workflow
>
> - **Resource 17 §"the safe scheduling order"** — full rationale for compact → expire → orphan order (NEVER reversed).
> - **Resource 17 §"Trino EXECUTE vs Spark CALL"** — the procedure-name + parameter-name disambiguation matrix.
> - **Resource 11 §"Storage sizing"** — projecting MinIO capacity growth (the denominator for the "defer next-purchase by N months" math).
> - **Resource 10 §"Small files problem"** — why small files appear in the first place (so prevention reduces the recurring maintenance burden).
> - **This resource §"MinIO is NOT free"** — the $15–25/TB-month all-in TCO anchor used in Step 3 dollar conversion.

---

## LEADING CANONICAL — "How do I tier hot vs cold storage on Trino + Iceberg + MinIO? Can I move old partitions to cheaper / archive storage?" (read this FIRST for hot/cold/tiering/archive/storage-class/lifecycle questions)

> **This is the findable canonical answer for storage-tiering questions on the on-prem Trino 467 + Iceberg 1.5.2 + MinIO stack. Every capability claim below is verified against [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) (table-property list + EXECUTE registry) and [docs.min.io/enterprise/aistor-object-store/administration/object-lifecycle-management/](https://docs.min.io/enterprise/aistor-object-store/administration/object-lifecycle-management/) (object tiering). Keywords this block answers: "tier", "tiering", "hot", "cold", "warm", "archive", "storage class", "storage tier", "lifecycle", "move old partitions", "cheaper storage", "S3 Glacier equivalent". Read this BEFORE inventing DDL — there is no `SET STORAGE TIER` statement on Trino 467.**
>
> ### The honest capability bound — there is NO per-partition storage-tier DDL on Trino 467 + Iceberg 1.5.2
>
> **State this upfront so the engineer does not waste a sprint hunting for a SQL knob that does not exist.** Trino 467 with the Iceberg connector has **no SQL way to put a specific partition (or specific data files) on a different MinIO bucket / storage class / tier through Trino DDL or Iceberg table properties.** Specifically:
>
> | What engineers often expect to exist | Does it exist on Trino 467 + Iceberg 1.5.2? | Verified against |
> |---|---|---|
> | `ALTER TABLE x SET STORAGE TIER = 'cold' WHERE event_date < ...` SQL statement | **NO. Does not exist.** Trino has no `SET STORAGE TIER` clause in any form. | trino.io/docs/current/connector/iceberg.html (no such ALTER TABLE form documented) |
> | Iceberg table property `storage_tier` / `storage_class` / `tier` in `CREATE TABLE x WITH (...)` | **NO. Not in the Iceberg table-property list.** The complete supported list is exactly: `format`, `compression_codec`, `partitioning`, `sorted_by`, `location`, `format_version`, `max_commit_retry`, `delete_after_commit_enabled`, `max_previous_versions`, `orc_bloom_filter_columns`, `orc_bloom_filter_fpp`, `parquet_bloom_filter_columns`, `object_store_layout_enabled`, `data_location`, `extra_properties`. | trino.io/docs/current/connector/iceberg.html § "Table properties" |
> | Per-partition storage-tier selector visible in EXPLAIN (`TableScan(storage_tier=cold)`) | **NO. No such annotation.** EXPLAIN does not surface storage-tier choices because Trino does not pick a tier per scan. | trino.io/docs/current/sql/explain.html |
> | Iceberg automatically moves cold partitions to a cheaper backend | **NO. Iceberg has no built-in tiering.** Iceberg writes every data file to the catalog-configured warehouse location; movement (if any) is the *object store's* job, not Iceberg's. | iceberg.apache.org/docs/latest/ |
> | A Trino catalog property like `iceberg.storage-tier.*` to declare hot/cold zones | **NO. No such catalog property family.** The Trino Iceberg connector exposes file-system and metastore properties, not storage-tier-routing properties. | trino.io/docs/current/connector/iceberg.html § "Configuration" |
>
> **The deeper truth:** Iceberg's design point is that the *object store* owns the physical-placement decisions. Iceberg's job is "this snapshot references these data file paths"; whether the MinIO object behind `s3a://lakehouse/warehouse/events/data/event_date=2024-01-01/x.parquet` lives on fast NVMe or a slower spinning-rust pool is a property of the **MinIO storage backend**, not a property the Iceberg table or Trino plan negotiates.
>
> ### The three real mechanisms (state honestly, with engine/layer labels)
>
> Tiering on this stack is real but lives at one of three layers — and **none of them is a Trino-side per-partition DDL**. Pick the one that matches what you actually need.
>
> #### Mechanism A — MinIO object-lifecycle tiering (the canonical prod-side mechanism for "cold storage class for old objects")
>
> **Layer:** MinIO ops. **Visibility to Trino:** transparent — Trino reads the same `s3a://...` path; cold-tier reads simply pay higher latency. **Granularity:** prefix-scoped or age-scoped at the MinIO bucket level (not Iceberg-partition aware, but Iceberg lays data files under partition-named prefixes like `event_date=2024-01-01/...`, so prefix scoping effectively gives partition-age control if your table is partitioned by date).
>
> **The mechanism in one sentence:** the MinIO operator registers a remote/cheaper storage location as a "tier" with `mc ilm tier add`, then attaches a lifecycle transition rule (`mc ilm rule add --transition-days N --transition-tier <TIER_NAME>`) to the warehouse bucket; MinIO migrates qualifying objects from the hot pool to the registered tier on the configured schedule.
>
> **The two-step MinIO setup (run by the MinIO operator, NOT in Trino SQL):**
>
> 1. **Register the remote tier** with `mc ilm tier add`. Exact subcommand shape: `mc ilm tier add <TIER_TYPE> <TARGET_ALIAS> <TIER_NAME> [flags]`. `TIER_TYPE` is one of `minio`, `s3`, `gcs`, `azure`; `TARGET_ALIAS` is the local MinIO alias hosting the rule; `TIER_NAME` is an all-caps label (e.g., `COLD_POOL`) that the rule will reference. Common flags include `--endpoint`, `--access-key`, `--secret-key`, `--bucket`, `--prefix`, `--storage-class`. **For the precise flag set on your MinIO version (some flag names and defaults vary across MinIO releases), consult [docs.min.io/enterprise/aistor-object-store/reference/cli/mc-ilm-tier/mc-ilm-tier-add/](https://docs.min.io/enterprise/aistor-object-store/reference/cli/mc-ilm-tier/mc-ilm-tier-add/) before running — do NOT guess flag names.**
>
> 2. **Attach the lifecycle transition rule** with `mc ilm rule add`. Per [docs.min.io/enterprise/aistor-object-store/reference/cli/mc-ilm-rule/mc-ilm-rule-add/](https://docs.min.io/enterprise/aistor-object-store/reference/cli/mc-ilm-rule/mc-ilm-rule-add/), the transition flags are `--transition-days <N>` (days since object creation before transition eligibility) and `--transition-tier <TIER_NAME>` (the tier registered in step 1). For object versions that have become non-current (versioning enabled), use `--noncurrent-transition-days` and `--noncurrent-transition-tier`. Scope the rule to a path prefix with the rule's prefix argument so you only tier the data subtree, not Iceberg's metadata subtree (see below).
>
> > **CRITICAL — transitions are by OBJECT AGE (`--transition-days N`), NOT by access time / access pattern / last-read timestamp.** MinIO's `mc ilm rule add` transitions trigger purely on `days since object creation` (or `days since noncurrent` for noncurrent versions when versioning is on). MinIO ILM rules do NOT inspect the object's last-access timestamp, last-read timestamp, S3 GET-frequency, or any access-pattern signal — there is no `--transition-access-days` flag, no `--last-accessed-days` flag, no "move objects that haven't been read in N days" mode. The mental model is "objects older than N days move to the cold tier whether or not anyone has touched them recently." This matters because: (a) a heavily-read 6-month-old hot dashboard table will still get tiered if your rule says `--transition-days 90` — age, not heat, is the trigger; (b) if you actually want access-aware tiering (which is what AWS S3 Intelligent-Tiering offers), you have to implement it yourself at the application layer (Mechanism C), MinIO ILM will not do it for you. Anyone who says "MinIO tiers based on access time" or "MinIO moves cold-read objects to cheap storage" is wrong — the trigger is creation age, period.
>
> **CRITICAL — keep Iceberg metadata on the HOT tier.** Iceberg's `metadata/` subtree (the `v*.metadata.json`, `snap-*.avro`, and `*.metadata.json` manifests) is touched on *every* query for snapshot resolution and partition pruning. If you let the lifecycle rule sweep `metadata/` to a cold tier, every Trino query pays cold-tier latency before it even starts reading data — that's a planning-time regression you do not want. **Scope the lifecycle prefix to the `data/` subtree only** (Iceberg's default layout puts data files under `<table>/data/...` and metadata under `<table>/metadata/...`). The standard rule shape is to set the prefix to the `data/` path or to specific partition subprefixes like `data/event_date=2023-*`.
>
> **What Trino sees:** nothing changes in Trino. The Trino Iceberg connector continues to ask MinIO for `s3a://lakehouse/warehouse/events/data/event_date=2024-01-01/part-00001.parquet`; if that object has been transitioned to the cold tier, MinIO transparently rehydrates or proxies the read at higher latency. **No Trino config change, no Iceberg table-property change, no Trino restart.** This is why "tiering on this stack" is fundamentally a MinIO-ops conversation, not a Trino-SQL conversation.
>
> **Tradeoffs to surface:** (a) cold-tier reads are slower — queries that hit cold data run longer (factor of 2x–10x is typical depending on the cold backend); (b) the lifecycle policy is bucket-/prefix-scoped, not Iceberg-snapshot-aware, so if `expire_snapshots` later prunes the snapshot that referenced a cold-tier file, MinIO's separate orphan-cleanup still has to remove it from the cold tier (cold-tier deletes may bill differently if the cold backend is external); (c) cold-tier compatibility with MinIO's erasure-coding and replication settings depends on the cold target — verify on the specific MinIO version per the docs link above.
>
> #### Mechanism B — Per-table compression choice (zstd for archive vs snappy for hot) via Trino `WITH (compression_codec = 'ZSTD')`
>
> **Layer:** Iceberg table property (Trino SQL). **Visibility to Trino:** Trino chooses the codec on write per table. **Granularity:** WHOLE-TABLE only — Iceberg's `compression_codec` is a table-level property, NOT per-partition. **This is NOT tiering** in the storage-class sense — it does not move data to cheaper hardware. It just reduces the bytes-on-disk for a given table by trading CPU at write/read for storage.
>
> **The mechanism:** when creating the archive-shaped table (lower-write-rate, cold-read-rate), declare a higher-compression codec. Trino + Iceberg 1.5.2 support `compression_codec` values `NONE`, `SNAPPY` (default), `LZ4`, `ZSTD`, `GZIP` per [trino.io/docs/current/connector/iceberg.html § "Table properties"](https://trino.io/docs/current/connector/iceberg.html).
>
> ```sql
> -- Trino 467 — archive-shaped table with zstd compression for cold storage cost reduction
> CREATE TABLE iceberg.analytics.events_archive (
>   event_id     BIGINT,
>   tenant_id    VARCHAR,
>   occurred_at  TIMESTAMP(6) WITH TIME ZONE,
>   event_type   VARCHAR,
>   payload      JSON
> )
> WITH (
>   format            = 'PARQUET',
>   compression_codec = 'ZSTD',                       -- vs default SNAPPY; ~30-40% smaller files, slower write
>   partitioning      = ARRAY['month(occurred_at)']
> );
> ```
>
> **From dbt-trino:**
>
> ```python
> {{ config(
>     materialized='table',
>     properties={
>         'format': "'PARQUET'",
>         'compression_codec': "'ZSTD'",
>         'partitioned_by': "ARRAY['month(occurred_at)']"
>     }
> ) }}
> SELECT * FROM {{ source('events', 'events_raw') }}
> WHERE occurred_at < CURRENT_DATE - INTERVAL '90' DAY
> ```
>
> **Tradeoffs to surface:** (a) `compression_codec` is WHOLE-TABLE — you cannot say "ZSTD for the 2023 partition, SNAPPY for the 2025 partition" in one Iceberg table; if you want age-split compression, use Mechanism C (separate tables); (b) ZSTD costs measurable CPU on write (often 1.5-3x SNAPPY on the Spark ingestion side); read decompression cost is small but non-zero; (c) changing `compression_codec` on an existing table affects only NEW writes — pre-existing data files stay in their original codec until rewritten by `ALTER TABLE ... EXECUTE optimize(...)` (which may or may not rewrite them depending on file-size threshold).
>
> #### Mechanism C — Application-layer recent-vs-archive split (two Iceberg tables behind a dbt UNION ALL view)
>
> **Layer:** application/dbt. **Visibility to Trino:** the view is what users query; Trino prunes the union branches by partition predicate. **Granularity:** age-boundary controlled by the SaaS team, can pair with Mechanism A on the archive table only.
>
> **The mechanism:** maintain two Iceberg tables — `events_recent` (last 90 days, default SNAPPY, on hot MinIO prefix) and `events_archive` (90+ days, ZSTD, on a prefix subject to a MinIO lifecycle transition rule from Mechanism A). Move rows from recent → archive on a scheduled dbt model. Expose a dbt view that UNIONs both for the analytics caller.
>
> ```sql
> -- Trino 467 — UNION ALL view; partition pruning skips the archive branch when the predicate is recent-only
> CREATE OR REPLACE VIEW iceberg.analytics.events AS
>   SELECT event_id, tenant_id, occurred_at, event_type, payload FROM iceberg.analytics.events_recent
>   UNION ALL
>   SELECT event_id, tenant_id, occurred_at, event_type, payload FROM iceberg.analytics.events_archive;
> ```
>
> A query `SELECT count(*) FROM iceberg.analytics.events WHERE occurred_at > CURRENT_DATE - INTERVAL '7' DAY` will (a) read only `events_recent`'s partitions matching the date predicate, (b) read zero data from `events_archive` because no archive partition satisfies the predicate — partition pruning skips the entire archive branch. The cold-tier read latency from Mechanism A is therefore paid only by queries that explicitly reach into archive dates.
>
> **Tradeoffs to surface:** (a) the boundary is *manual* — a scheduled dbt model has to move rows from recent → archive and DELETE them from recent (use Iceberg `MERGE` or `DELETE FROM ... WHERE`); the move is at the application layer, with its own correctness/idempotency burden; (b) snapshot IDs and time-travel queries are per-table — a "show me row state as of yesterday" query against the view does not cleanly reconcile across two tables; (c) queries that span the boundary pay the union cost; (d) schema changes (ADD COLUMN, DROP COLUMN) must be applied to BOTH tables AND the view in lockstep; (e) but: this is the only mechanism that gives true age-segmented control with each segment configurable independently (compression, partitioning, MinIO prefix, lifecycle rule).
>
> ### Picking the mechanism — decision rule
>
> | If your need is | The right mechanism is |
> |---|---|
> | "Reduce $/TB on the cold pool for objects older than N days, transparently to Trino, no SQL changes" | **A. MinIO lifecycle tiering** — scope the rule to the `data/` prefix; keep `metadata/` on the hot tier. |
> | "Make a specific *table* (e.g., `events_archive`) consume fewer bytes on MinIO, on the hot tier still" | **B. ZSTD compression** at table create time. WHOLE-TABLE, not per-partition. |
> | "Old rows should physically live on cheaper hardware AND be compressed harder AND have their own retention/partitioning policy" | **C. Two tables (recent + archive) UNION ALL view**, plus A on the archive table's prefix. The combination pattern. |
> | "Per-partition storage-tier DDL like Snowflake/Redshift's tiering" | **Does not exist on Trino 467 + Iceberg 1.5.2.** Use A or C; do NOT invent SQL. |
>
> ### DO-NOT-WRITE — banned tiering forms (paste into the storage-tiering memo checklist)
>
> | Never write on this stack | Why it's wrong | The correct framing |
> |---|---|---|
> | `ALTER TABLE iceberg.analytics.events SET STORAGE TIER = 'cold'` | Trino has NO `SET STORAGE TIER` ALTER form. Iceberg has no storage-tier concept in DDL. The clause does not exist. | Use Mechanism A (MinIO lifecycle) for transparent tiering, or Mechanism C (separate archive table) for table-level age split. |
> | `ALTER TABLE iceberg.analytics.events ... SET STORAGE TIER ... WHERE event_date < DATE '2024-01-01'` | Same as above PLUS Trino ALTER TABLE has no `WHERE` clause. The whole statement is a fabrication. | Use Mechanism A and scope the MinIO lifecycle rule's prefix to `data/event_date=2023-*` (or a similar pattern matching the partition directory layout). |
> | `CREATE TABLE x (...) WITH (storage_tier = 'cold')` or `WITH (storage_class = 'COLD')` or `WITH (tier = 'archive')` | None of `storage_tier`, `storage_class`, or `tier` is in the Iceberg table-property list. Trino will reject with `Catalog 'iceberg' table property 'storage_tier' does not exist`. | The supported properties are listed above (`format`, `compression_codec`, `partitioning`, `sorted_by`, `location`, `format_version`, `max_commit_retry`, `delete_after_commit_enabled`, `max_previous_versions`, `orc_bloom_filter_columns`, `orc_bloom_filter_fpp`, `parquet_bloom_filter_columns`, `object_store_layout_enabled`, `data_location`, `extra_properties`). |
> | "Trino automatically moves cold partitions to cheaper storage" | Trino has no storage-tier scheduler. Trino reads what the catalog points to — it does not migrate objects. | "MinIO's object-lifecycle tiering migrates objects per ops-configured rules; Trino sees no change in catalog or SQL." |
> | "Iceberg has built-in storage tiering / Iceberg natively supports hot/cold partitions" | Iceberg's spec does not include a tier concept on data files. Files live where the warehouse location points; movement is the object store's job. | "Iceberg references file paths; the *object store* (MinIO) decides physical placement. Use MinIO lifecycle rules." |
> | `SET SESSION iceberg.storage_tier = 'cold'` or any session-level tier knob | No such session property in the Iceberg connector. | Storage placement is not a session-level knob anywhere in Trino 467. |
> | `EXPLAIN` annotation `TableScan(storage_tier=cold)` showing per-scan tier choice | EXPLAIN does not surface a tier dimension because Trino does not pick one per scan. | EXPLAIN shows operator, source, predicate, columns; tier-of-physical-storage is invisible to the planner. |
> | A Trino catalog property like `iceberg.storage-tier.hot-prefix` / `iceberg.storage-tier.cold-prefix` to declare zones | No such catalog property family in the Iceberg connector. | Tiering policy lives in MinIO (`mc ilm tier add` + `mc ilm rule add`), not in Trino catalog config. |
>
> ### Cross-references
>
> - **This resource §"MinIO is NOT free"** — the $15–25/TB-month all-in TCO anchor that motivates wanting cheaper-per-TB cold capacity in the first place.
> - **This resource §"Cost optimization tactics for your stack"** — the broader optimization menu (compaction, snapshot expiry, rollups, right-sizing). Tiering sits alongside these, not above them.
> - **Resource 11 §"Cost-saving tactics — Tiered retention"** — the resource-11 short pointer that links here for the canonical mechanism.
> - **Resource 17 §"the safe scheduling order"** — `expire_snapshots` is the prerequisite for tiering to actually reclaim cold-tier space (a cold-tier data file pinned by a 200-day-old snapshot still costs cold-tier $).
> - **prod_info.md** — the on-prem mandate that makes MinIO the only object store in scope; AWS S3 storage classes (Standard-IA, Glacier Instant Retrieval, Glacier Flexible Retrieval, Glacier Deep Archive) are NOT applicable to the production stack.

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

## AWS Athena + Glue + S3 vs on-prem Trino + Iceberg + MinIO — concrete 2026 anchors

When the CTO asks "should we lift-and-shift the lakehouse to AWS instead?", the answer hinges on actual dollar figures, not vibes. This section gives the 2026 AWS pricing anchors you need to do the math, a worked TCO example at SaaS scale, and a crossover heuristic.

**Hard constraint reminder:** `prod_info.md` mandates on-prem only — no public cloud. AWS is out of scope as a real migration target for your stack. Use this section as a sanity-check on whether you're wildly overspending, and as ammo for the next strategy review. Do **not** propose AWS as an action item without an explicit policy change from leadership.

### 2026 AWS pricing anchors (verified against official AWS pricing pages)

| Service | 2026 price | Notes |
|---|---|---|
| **Athena (on-demand)** | **$5/TB scanned** | The classic per-query model. Min charge 10 MB per query. Compressed columnar data scans much less than raw size — Parquet typically reduces scanned bytes 5–10x vs CSV. |
| **Athena Provisioned Capacity** | **$0.30/DPU-hour** | Reserved compute, available since Feb 2026. Cheaper than on-demand once sustained scan rate gets large (rough crossover: > ~50 TB/month scanned). |
| **Glue ETL (standard)** | **$0.44/DPU-hour** | A DPU = 4 vCPU + 16 GB RAM. Glue is Spark-as-a-service; substitutes for your on-prem Spark ingestion jobs. |
| **Glue ETL (Flex)** | **$0.29/DPU-hour** | ~34% cheaper, but jobs may start with cold-start delay (minutes). Good for nightly compaction; bad for time-sensitive ingestion. |
| **Glue Data Catalog** | **First 1M objects free**, then **$1 per 100K accesses** | Replaces your Hive Metastore. Note: Athena *requires* Glue Catalog — you cannot point Athena at an arbitrary external Hive Metastore. This is a lift-and-shift constraint, not a preference. |
| **S3 Standard (tiered)** | **First 50 TB: $0.023/GB = $23.55/TB-month**<br>**Next 450 TB: $0.022/GB = $22.53/TB-month**<br>**Over 500 TB: $0.021/GB = $21.50/TB-month** | Replaces MinIO. Tiered pricing applies per account per region per month. Add request costs (~$0.005 per 1K PUT, ~$0.0004 per 1K GET) — usually a rounding error at lakehouse scale. **For quick estimates at <100 TB, $23/TB-month is within 4% of actual and acceptable for VP-level memos.** |

**Critical lift-and-shift constraint — Athena requires AWS Glue Data Catalog:** Athena requires AWS Glue Data Catalog — **it cannot connect to a self-hosted Hive Metastore**. Migration to Athena means one of:

- **(a) Migrate all table metadata to Glue Catalog** — requires re-registering every table, every partition, and every schema. For an Iceberg lakehouse, every Iceberg table's metadata-pointer entry must be re-created in Glue. This is a metadata project on top of the data move.
- **(b) Run AWS Lake Formation as the catalog layer** — fronts Glue Catalog with row/column-level governance and tag-based access. Adds setup complexity but supports fine-grained access policies.

**There is no path (c)** — you cannot point Athena at your existing self-hosted Hive Metastore over a VPN, VPC peering, or PrivateLink. The Athena → Glue binding is hard-wired in the service.

**Glue Catalog pricing reality**: first 1M objects free, then $1 per 100,000 API accesses beyond that. Each table, partition, and column counts as objects; each table/partition lookup from a query counts as accesses. For a **100-table lakehouse with moderate dashboard traffic, Glue Catalog typically adds $50–200/month** in API access fees — small relative to the Athena query bill but a real recurring line item to budget for, and easy to forget in lift-and-shift estimates. Heavy partition scanners (e.g., dashboards that hit thousands of partitions per query) can push this materially higher.

For the production on-prem stack (`prod_info.md`), this constraint matters as ammunition for "no, we cannot lift-and-shift to Athena without rebuilding the catalog layer" — not as a planning input for any actual migration.

### Worked TCO example — 80 TB lakehouse, 50 TB/month scanned, 200 queries/day

Representative SaaS scale: 80 TB stored in Parquet, 50 TB scanned per month after partition pruning, ~6,000 queries/month (~200/day), nightly compaction job using ~20 DPU-hours/day.

**AWS monthly cost:**

| Line item | Math | Monthly |
|---|---|---|
| S3 Standard storage (tiered) | First 50 TB × $23.55/TB = $1,177.50; next 30 TB × $22.53/TB = $675.90 | **$1,853** |
| Athena on-demand queries | 50 TB scanned × $5/TB | **$250** |
| Glue ETL (compaction + ingestion) | 20 DPU-hr/day × 30 days × $0.44/DPU-hr | **$264** |
| Glue Data Catalog accesses | typically free tier | **~$0** |
| **AWS subtotal** | | **~$2,367/month** |
| **AWS annual** | × 12 | **~$28,400/year** |
| Engineering FTE (managed = less ops, but still need data owner) | 0.1 FTE × $200k | **~$20,000/year** |
| **AWS total annual** | | **~$48,400/year** |

**On-prem (your existing stack) annual cost:**

| Line item | Annual | Notes |
|---|---|---|
| Hardware amortization (already provisioned) | **$0** | Sunk cost on existing k8s cluster |
| MinIO storage (already provisioned) | **$0** | 80 TB fits in existing capacity |
| k8s compute (Trino + Spark capacity) | **$0 cash** | Reserved cluster capacity, no marginal $ |
| Engineering FTE | **$40k – $100k** | 0.2 – 0.5 FTE × $200k fully loaded |
| **On-prem total annual** | **$40k – $100k** | Dominated entirely by FTE |

**Reading this table honestly:** the AWS infra bill ($28k) is *less than* the on-prem FTE cost ($40k – $100k). So why does on-prem still win for this scale? Because the FTE cost doesn't disappear in the AWS world — you still need someone owning ingestion logic, schema design, dbt models, and dashboard reliability. The "0.1 FTE on AWS vs 0.3 FTE on-prem" delta is real but smaller than the headline numbers suggest. Also: the on-prem hardware here is sunk cost. The moment you have to *buy new hardware specifically for analytics*, the math shifts toward AWS.

#### MinIO is NOT free — the real all-in $/TB-month estimate

The "$0 marginal storage cost" line for on-prem is a sunk-cost framing — true once the hardware is bought, but misleading if you're sizing new capacity or comparing TCO honestly against S3. **MinIO on-prem storage is NOT free.** The all-in cost is **$15–25/TB-month** when you include:

- **Disk hardware**: NVMe/SSD at $0.05–0.10/GB amortized over 5 years (HDD is cheaper but rarely used for lakehouse hot data).
- **Rack, power, cooling**: applies a roughly 1.5–2x multiplier on the raw hardware spend. Data center floor space and electricity are real recurring costs.
- **Erasure coding overhead**: MinIO's default EC 4+2 = **1.5x raw storage for 1 TB usable** (4 data shards + 2 parity shards). EC 8+4 is also 1.5x; EC 8+2 is 1.25x but with lower durability. You always pay for parity.
- **Ops and refresh allowance**: disk failures, node retirements, 5-year hardware refresh cycle.

**For a quick budget estimate, use $20/TB-month all-in for MinIO.** That compares against **S3 Standard at $23.55/TB-month** — roughly equivalent at small scale. **On-prem gets relatively cheaper at >50 TB** because (a) better EC ratios become viable at higher disk counts, (b) hardware amortization spreads across more usable TB, and (c) S3 tiered pricing only drops to $21.50/TB-month above 500 TB whereas on-prem fixed costs (rack, power) stop scaling linearly.

**What this means for the "$0 marginal cost" framing above:** when comparing against S3, you should add ~$20/TB-month to the on-prem column for any new capacity that isn't truly sunk. The 80 TB example above adds ~$19k/year in honest MinIO TCO. That brings on-prem total annual to **$59k–$119k/year** vs AWS **$48k/year** — still close, with the decision dominated by FTE cost, ops appetite, and on-prem mandate (per `prod_info.md`).

### Crossover heuristic — when each side wins (indexed on TB/month SCANNED)

**Critical axis correction:** Athena's per-query cost scales with **TB scanned per month**, *not* TB stored. A 100 TB lakehouse where analysts only scan 2 TB/month (well-partitioned, rollups in place) costs Athena $10/month in queries. A 5 TB lakehouse where analysts run `SELECT *` and scan 50 TB/month costs $250/month. The right question is "at what *scan* volume does on-prem become cheaper?", not "at what *storage* volume?"

Use this as a back-of-the-envelope filter, not a final answer:

| Monthly scan volume | Winner | Why |
|---|---|---|
| **< 5 TB/month scanned** | **Athena on-demand** | $25/month in query costs. Cloud infra is likely cheaper total if you don't have existing hardware. No idle-cluster tax. |
| **5 – 30 TB/month scanned** | **Gray zone** | Depends on whether hardware is already provisioned and how high your FTE cost is. Athena costs $25–$150/month in queries; on-prem hardware is $0 if sunk. The decision is dominated by FTE budget and ops appetite, not the query bill. |
| **> 30 TB/month scanned** | **On-prem Trino + Iceberg** (if hardware is provisioned) | Athena would cost $150+/month just in query fees; steady queries at this volume mean predictable load that on-prem handles cheaply on sunk hardware. The Trino-always-on tax is amortized across enough query volume to win. |
| **> 175 TB/month scanned** | **Re-evaluate Athena Provisioned Capacity** | At $0.30/DPU-hour, Athena Provisioned Capacity may become competitive again against on-prem at scale. On-demand at this scan rate would be $875+/month; provisioned capacity caps it. Evaluate both. |
| **Any workload requiring on-prem (compliance, data sovereignty, your `prod_info.md`)** | **On-prem (mandatory)** | Not a cost decision. |

**Note: Athena's minimum charge per query is 10 MB** — if you have many small queries scanning <10 MB, each costs the 10 MB minimum. At 5 TB/month with small queries, effective cost per query may be much higher than $5/TB implies. A workload of 1 million dashboard queries each scanning ~1 MB still bills as 10 TB scanned (= $50), not 1 TB. Aggregate small queries into rollup tables or batch them where possible.

**Break-even rule of thumb (scan axis):** somewhere around **5 – 30 TB/month scanned with moderate query volume**. Below that, AWS Athena on-demand is cheaper (you don't pay the Trino-cluster-always-on tax). Above 30 TB/month, on-prem pays for itself quickly because Athena's per-TB-scanned bill scales linearly while on-prem hardware is one-time.

**Don't forget:** the crossover analysis assumes the FTE work gets done either way. If you're underbudgeting engineering on the on-prem side and the system rots (stale dashboards, missed compaction, runaway snapshots), the real on-prem cost is much higher than the table shows. AWS forces a baseline level of reliability via managed services; on-prem forces you to staff for it.

**Storage-volume guidance (separate axis):** stored TB still matters for the S3-vs-MinIO storage cost line — see the worked TCO example above where 80 TB stored costs ~$1,853/month in S3 alone. Use stored TB for storage-cost tradeoffs; use scanned TB for the query-cost crossover decision. Conflating the two axes is the most common mistake in cloud-vs-on-prem analyses.

---

## Trino on-prem reading AWS S3 vs local MinIO — cost and performance

A subtly different question from "should we lift-and-shift to AWS Athena?" is: **what if we keep our on-prem Trino cluster but point it at AWS S3 instead of local MinIO for some tables?** Common motivation: archival/cold data that's too big for the MinIO cluster, or data that's already living in S3 from another system. This is a real architectural choice — and the cost model is **completely different** from Athena. Get the distinction right before you pitch it.

**Critical clarification — this is NOT Athena:**

- **Athena** is a managed query service. You pay **$5/TB scanned** because AWS runs the query engine for you.
- **Trino on-prem reading S3** is *your* query engine reading from S3 as an object store. AWS only sees `GET` requests against S3 — there is no per-TB-scanned query fee. The pricing model is **S3 object-store pricing**, not Athena pricing. Conflating these is a common and expensive mistake in build-vs-buy memos.

### Cost breakdown for Trino on-prem reading S3 (NOT Athena)

| Cost line | 2026 price | Reality for a typical query workload |
|---|---|---|
| **S3 storage** | $0.023/GB = **$23.55/TB-month** | Same as the S3 line in the Athena section above. Tiered pricing applies above 50 TB / 500 TB. |
| **S3 GET requests** | $0.0004 per 1,000 GET requests | **Negligible.** Each Parquet file opened = 1 GET. 10,000 files per query = $0.004. Even at 1 million GETs/day, this is ~$12/month. |
| **S3 egress to your on-prem Trino workers** | **$0.09/GB out of AWS region** | **THE MAIN COST.** A query scanning 100 GB from S3 to your data center costs **$9 in egress alone**. At a sustained 50 TB/month scanned, that's **$4,500/month JUST in egress fees** — completely dominating the storage line. |
| **AWS Direct Connect** (optional) | ~$0.02/GB egress + **$0.30/port-hour minimum** | Reduces egress per-GB by ~4.5x, but the port-hour fee adds ~$220/month baseline regardless of traffic. Worth it above ~5 TB/month sustained egress. |

**The egress fee is what kills this architecture.** S3 storage is cheap; pulling that data across the public internet to your on-prem Trino cluster is not. Every byte Trino reads from S3 leaves the AWS region and hits the egress meter. Partition pruning matters even more here than locally because skipped data = skipped egress = real dollars saved per query.

**This is completely separate from Athena.** Athena's $5/TB-scanned fee is the *query service*. If you used Athena to scan that same 100 GB you'd pay ~$0.50 in query fees plus zero egress (Athena results return as a small CSV). The Trino-on-prem + remote-S3 architecture is **not** competing with Athena on the same axis; they're different products with different bills. Don't write "Athena $5/TB" when the actual cost is "S3 egress $0.09/GB."

### Latency comparison (order of magnitude)

Network round-trip dominates small-file workloads. Trino opens one network connection per Parquet file for metadata (footer + row group offsets), then again for data. At 10,000 files per query, latency stacks fast.

| Backend | Per-file metadata latency | Throughput | Practical for 10K-file query |
|---|---|---|---|
| **Local MinIO, same rack** | ~1–5 ms | 100–500 MB/s | ~10–50 sec metadata + fast reads |
| **Local MinIO, same k8s cluster (same DC)** | ~5–20 ms | 100–500 MB/s | ~50–200 sec metadata |
| **AWS S3 from on-prem over public internet** | ~50–200 ms | 100–300 MB/s (limited by your internet pipe) | **~500–2,000 sec just in metadata round-trips** before any data is read |
| **AWS S3 with Direct Connect** | ~10–50 ms | 500 MB/s+ | ~100–500 sec metadata |

**Practical impact:** for a query that opens 10,000 Parquet files, local MinIO adds roughly **~50 seconds** of metadata fetch overhead; remote S3 over the public internet adds **~500 seconds** (8+ minutes). This is overhead the user sees *before* any actual data scanning starts. The metadata-fetch latency is the single biggest reason remote-S3 queries feel slow.

**Mitigation — Trino metadata cache is CRITICAL for remote S3:**

```properties
# etc/catalog/iceberg.properties
iceberg.metadata-cache-enabled=true
iceberg.metadata-cache.ttl=10m
iceberg.metadata-cache.max-size=1000
```

With the cache hot, repeat queries against the same table skip most metadata GETs and only pay egress on the actual data reads. Without it, every query pays the full metadata round-trip cost. This config is optional for MinIO; it's effectively mandatory for remote S3.

### Key config properties for S3 backend in Trino 467

For `etc/catalog/iceberg.properties` — these are the native S3 filesystem properties (the legacy `hive.s3.*` properties are deprecated in Trino 467):

```properties
# AWS S3 backend
fs.native-s3.enabled=true
s3.endpoint=https://s3.amazonaws.com
s3.region=us-east-1
s3.path-style-access=false
# Credentials via instance profile, IAM role, or static keys
# s3.aws-access-key=...
# s3.aws-secret-key=...

# MinIO backend (for comparison)
# fs.native-s3.enabled=true
# s3.endpoint=http://minio.internal:9000
# s3.region=us-east-1            # MinIO ignores region but Trino requires the property
# s3.path-style-access=true      # MinIO requires path-style; AWS uses virtual-host-style
```

The `s3.path-style-access` flag is the most common gotcha when switching between MinIO and AWS — MinIO requires `true`, AWS S3 requires `false`.

### Bottom-line rule of thumb

**Remote S3 + on-prem Trino is expensive and slower unless you have Direct Connect.** Use it only for:

- **Cold or archival data** where you can tolerate slow queries (minutes instead of seconds).
- **Datasets you cannot fit in your MinIO cluster** and where the egress savings vs the storage cost savings actually break even — do the math on monthly scan volume.
- **Data already living in S3** from another system (e.g., a SaaS vendor that drops Parquet into your S3 bucket) where copying to MinIO would duplicate cost without operational benefit.

For your normal hot-tier analytical workload — daily dashboards, recent fact tables, frequently-scanned event data — **keep it on local MinIO**. The egress fees and metadata round-trip latency make remote S3 a poor fit for active query patterns.

---

## The hidden costs of self-hosted

These don't show up in any cost dashboard. They show up as a slow dashboard, a stale report, or a 3 a.m. page.

- **Idle Spark pods**: if you keep a long-running SparkSession (e.g., a streaming app), idle executors consume RAM even between batches.
- **Compaction jobs**: nightly (or hourly for streaming-heavy tables) — every compaction reads N small files, writes one big file, and burns CPU on both reads and writes. Budget for this in your k8s capacity plan.
- **Snapshot expiry forgotten**: Iceberg keeps every old snapshot forever by default. Without `expire_snapshots`, MinIO storage grows ~20–30%/year from orphaned files even if your raw data volume is flat. This is the most common storage cost surprise.
- **No built-in cost alerts**: BigQuery and Snowflake have billing alarms ("alert me when this user spends >$500"). Trino has none — a runaway `SELECT * FROM events` from a curious analyst can burn the cluster for hours with no warning. You must build query-cost monitoring yourself by scraping `system.runtime.queries` + `system.runtime.tasks` (JOIN on `query_id`; sum `t.physical_input_bytes` and `t.split_cpu_time_ms`) or by configuring an event listener for durable `QueryCompletedEvent` records. **Do NOT write `system.runtime.query_stats` — that table does NOT exist in Trino.** See the LEADING CANONICAL per-tenant attribution block earlier in this doc + r18 §"`system.runtime.queries` — Actual Column Reference".
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

6. **Set a soft per-query memory cap.** Trino's `query_max_memory_per_node` (session, underscores) / `query.max-memory-per-node` (config, dots/hyphens) prevents one bad query from monopolizing the cluster. Default in Trino 467 is **30% of the JVM max heap** per [trino.io/docs/current/admin/properties-resource-management.html](https://trino.io/docs/current/admin/properties-resource-management.html); tune lower if analysts run many concurrent heavy queries. Note: the session form can only LOWER the limit, not raise it. See r18 LEADING CANONICAL ONCALL TUNING-LEVERS for the underscore-vs-dot/hyphen distinction.

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

1. **What does this query/table cost today?** Use the per-tenant attribution recipe in the "LEADING CANONICAL COST WORKED EXAMPLE — How do I attribute Trino query cost per tenant" section above (JOIN `system.runtime.queries` to `system.runtime.tasks` on `query_id` and SUM `physical_input_bytes` + `split_cpu_time_ms`). Do **NOT** write `system.runtime.query_stats` — that table does **NOT** exist in Trino; the real surface is `queries` + `tasks` joined by `query_id`.
2. **What's the cheapest fix?** (Usually: better partitioning, a rollup table, or a `WHERE` clause.)
3. **What's the engineering hour cost vs the compute savings?** If a 2-hour fix saves 5 minutes of compute per day, that's a year-long payback. If it saves 30 minutes, it pays back in a month. Optimize the second case first.

The biggest mistake is over-engineering early. A SaaS at 500 GB doesn't need a 50-node Trino cluster, doesn't need streaming compaction, and doesn't need a real-time cost dashboard. It needs partitions, nightly compaction, weekly snapshot expiry, and one engineer paying part-time attention.

---

## Cross-references

- `11-lakehouse-storage-sizing.md` — how to estimate storage from your Postgres baseline.
- `10-lakehouse-partitioning.md` — partition design (the #1 cost lever).
- `15-tools-comparison.md` — pricing details for BigQuery / Snowflake / ClickHouse / DuckDB.
- `06-when-to-add-olap.md` — when the FTE cost of self-hosted Iceberg+Trino is *not* worth it yet.
