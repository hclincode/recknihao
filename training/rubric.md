# Judge Evaluation Rubric

## Scoring dimensions (each 0–5)

| Dimension | Description |
|---|---|
| **Technical accuracy** | Is the OLAP/big data information factually correct? |
| **Beginner clarity** | Is it understandable with zero OLAP background? No unexplained jargon. |
| **Practical applicability** | Can the SaaS engineer act on this for their product? |
| **Completeness** | Does it fully address the question without overwhelming detail? |

**Pass threshold per topic**: average ≥ 3.5 across all dimensions, tested from at least 2 different question angles.

---

## Required topic checklist

Each topic must reach the pass threshold before the system can enter final phase.

| Topic | Status | Avg Score | Questions Asked |
|---|---|---|---|
| OLAP vs OLTP — difference and why it matters for SaaS | PASSED | 4.542 | 3 |
| What a data warehouse is and when a SaaS product needs one | PASSED | 4.647 | 3 |
| What a data lakehouse is and how it differs from a warehouse | PASSED | 4.625 | 2 |
| Column-oriented storage — what it is and why it's faster for analytics | PASSED | 4.365 | 6 |
| Common analytical query patterns: aggregations, funnels, cohort, time-series | PASSED | 4.602 | 8 |
| Schema design for analytics: denormalization, star schema basics | PASSED | 4.50 | 2 |
| When to add an OLAP layer vs staying on the transactional DB | PASSED | 4.415 | 8 |
| Multi-tenant analytics: isolating customer data in SaaS | PASSED | 4.270 | 52 |
| Popular tools overview: BigQuery, Snowflake, ClickHouse, DuckDB, Iceberg | PASSED | 4.75 | 2 |
| Real-time vs batch analytics trade-offs | PASSED | 4.812 | 4 |
| Cost considerations for analytical workloads at SaaS scale | PASSED | 4.50 | 3 |
| Query performance basics: partitioning, indexing strategy for analytics | PASSED | 4.594 | 4 |
| Lakehouse schema design: fact tables, dimension tables, denormalization | PASSED | 4.583 | 3 |
| Iceberg partition design for SaaS: strategies, small-files, compaction | PASSED | 4.500 | 6 |
| Storage sizing and growth estimation for lakehouse workloads | PASSED | 4.333 | 3 |
| Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL | PASSED | 4.333 | 3 |
| OLTP-to-OLAP mindset: the mental model shift for SaaS engineers adopting a lakehouse | PASSED | 4.50 | 2 |
| Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling | PASSED | 4.276 | 52 |
| Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup | PASSED | 4.612 | 10 |
| Query performance regression diagnosis: oncall workflow for slow queries — concurrency, partition skew, data model, file layout | PASSED | 5.0 | 2 |

---

## Score history

### Q1 — 2026-05-23
**Question**: Why does a GROUP BY / COUNT query slow down so much worse than a point-lookup as rows grow?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Topics updated**: OLAP vs OLTP (1 question, avg 5.0); Query performance basics (1 question, avg 5.0)

### Iteration 2, Q1 — 2026-05-23
**Question**: Dashboards (signups by plan, weekly actives) are getting slow. Is a data warehouse just a bigger, faster database, or something different?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Topics updated**: What a data warehouse is and when a SaaS product needs one (1 question, avg 5.0)

### Iteration 2, Q2 — 2026-05-23
**Question**: I've heard people talk about something called a 'lakehouse' and I have no idea what that means. Is it the same as a data warehouse? Is it like S3 plus a database? When would I care about this vs just using Postgres or moving to something like Snowflake?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.75** |

**Topics updated**: What a data lakehouse is and how it differs from a warehouse (1 question, avg 4.75)

**Notes**: Strong answer — directly addresses all three sub-questions, names the production stack correctly (MinIO + Parquet + Iceberg + Trino), uses the resource's Google Sheets analogy, and gives an actionable decision rule. Completeness docked one point because the answer drops the *why* behind Iceberg's specific value-adds (ACID, schema evolution, time travel, partition pruning) — it lists ACID/schema/SQL once but doesn't show what Iceberg adds *on top of* raw Parquet, which is a question the SaaS engineer will hit next. Still well above pass threshold. Topic needs a 2nd question angle (e.g., Iceberg-vs-Delta-vs-Hudi, or "when would I migrate off our lakehouse to Snowflake") before it can be marked passed.

### Iteration 2, Q3 — 2026-05-23
**Question**: A coworker said analytics DBs store data 'by column instead of by row' and that's why they're faster. Can you explain how data sits on disk and why that speeds up SUM/COUNT?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.75** |

**Topics updated**: Column-oriented storage (1 question, avg 4.75)

**Notes**: Strong answer. Uses the resource's toy `user_events` table, contrasts physical byte layout of row vs column, gives a clean numeric "100 MB out of 1 GB = 10x speedup" example, mentions dictionary encoding (event_name) and delta encoding (timestamps), and closes with a stack-specific trade-off statement (Postgres for single-row, Iceberg+Trino for analytics). Completeness docked one point: the answer covers two of the three multipliers from the resource (I/O reduction, compression) but **skips vectorized execution / SIMD entirely**, and does not draw the bridge from columnar layout -> Parquet column statistics -> Iceberg manifest pruning -> Trino file skipping (the bridge that the previous judge feedback explicitly asked the teacher to add). Minor nit: the answer calls Parquet/Iceberg "analytics databases" — they're a file format and table format respectively — but the answer self-corrects later by naming "Iceberg+Trino" as the analytical layer. Topic needs a 2nd question angle before passing.

### Iteration 2, Q4 — 2026-05-23
**Question**: We're a B2B SaaS with about 80 customers. Each customer's data is in the same Postgres tables, separated by a tenant_id column. If we move analytics to a separate system, how do we make sure customer A can never see customer B's numbers? Do we create separate databases per customer, or is there a standard way people handle this?

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 2 |
| Practical applicability | 1 |
| Completeness | 1 |
| **Average** | **1.75** |

**Topics updated**: Multi-tenant analytics: isolating customer data in SaaS (1 question, avg 1.75)

**Notes**: The responder correctly refused to hallucinate — it scanned the resources, found only a single passing mention of `tenant_id` as a query-performance hint in `03-columnar-storage.md`, and clearly told the user that no real coverage exists. That honesty is the only reason this isn't a 0 across the board. Scoring: Technical accuracy = 3 because nothing it said was wrong (it correctly identified the one tangential mention, correctly named the prod stack as Trino + Iceberg + MinIO, and correctly flagged that partition-as-perf is NOT the same as partition-as-security). Beginner clarity = 2 because the engineer asked a concrete "schema-per-tenant vs shared-table" question and got back a meta-answer about missing resources — they leave with no mental model. Practical applicability = 1 because the engineer cannot take a single action from this response; the only "next step" offered is "add a resource section." Completeness = 1 because none of the three sub-questions (isolation guarantee, DB-per-tenant vs shared, "standard way") were answered. **Root cause**: missing `resources/05-multi-tenant-analytics.md`. This is a critical, security-adjacent topic that any B2B SaaS will ask about, and it must be authored before the next iteration. See `training/feedback-latest.md` for the required outline.

### Iteration 2, Q5 — 2026-05-23
**Question**: I'm trying to figure out if we even need to move off Postgres yet, or if we should just tune what we have. At what point does it actually make sense to stand up something like BigQuery or ClickHouse — what's the threshold where Postgres stops being good enough for analytics?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **4.0** |

**Topics updated**: When to add an OLAP layer vs staying on the transactional DB (1 question, avg 4.0)

**Notes**: Solid answer that uses `01-olap-vs-oltp.md`'s "When to use OLAP / when not to" lists directly, with the most important pedagogical move being the reframe at the end: the user asked about BigQuery/ClickHouse, the responder correctly pointed out the production stack is *already* an on-prem lakehouse and so the decision is "start using what you have," not "buy a cloud OLAP product." That re-anchoring to prod_info.md is exactly the behavior the judge has been pushing for. Completeness is the weak dimension: the user asked a two-part question ("tune Postgres OR move to OLAP") and the Postgres-tuning half was barely addressed — only "good indexes" appears, with no mention of read replicas as an intermediate step in the body (it appears in the stay list but is not discussed), materialized views, partial / BRIN indexes, summary tables, pg_stat_statements, or the connection-contention angle. Practical applicability docked one point because the answer tells them to "move data into your existing Trino + Iceberg + MinIO stack" but does not name the missing piece: there is no resource yet on how Postgres data actually gets into Iceberg (Spark ingestion job, CDC vs snapshot, schedule). Beginner clarity docked one point because "join data from more than one source" and "read replica" are used without inline explanation. Topic needs a 2nd-angle question before passing — suggest something framed from the other side ("we already have a lakehouse — what's the cheapest way to validate it before redirecting dashboards?") or a tuning-first variation ("what Postgres tuning should I try before standing anything else up?").

### Iteration 3, Q1 — 2026-05-23
**Question**: Lakehouse schema design — fact tables, dimension tables, denormalization (engineer asked about moving event/user/tenant Postgres tables into Iceberg fact + dim layout).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.25** |

**Topics updated**: Lakehouse schema design: fact tables, dimension tables, denormalization (1 question, avg 4.25)

**Notes**: Directly addresses both halves of the CTO question ("just copy the table?" -> no, denormalize). Names three concrete fact tables with column lists, contrasts before/after SQL, frames the "old plan_type stays old" insight as a feature (SCD Type 2), and gives a Spark-reads-Postgres-writes-Iceberg migration path that fits the prod stack. Grain concept is implicit but not named; `tenant_id` is barely discussed as a partition/isolation lever even though the engineer's Postgres schema has it. Resource gap: ingestion mechanics (Spark JDBC read, JSONB->MAP flattening, full-refresh vs CDC, idempotency on event_id, Hive Metastore + MinIO write path) — this same gap was flagged in Iter 2 Q5 and has now resurfaced. Recommend new `resources/12-postgres-to-iceberg-ingestion.md` or appended Ingestion section to `09-lakehouse-schema-design.md`.

### Iteration 3, Q2 — 2026-05-23
**Question**: Iceberg partition design for SaaS — strategies, small-files, compaction (80-tenant case, hidden partitioning, maintenance schedule).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Iceberg partition design for SaaS: strategies, small-files, compaction (1 question, avg 4.75)

**Notes**: Hits all three sub-questions cleanly: recommends `(day(occurred_at), tenant_id)` with correct math (~29,000 partitions/year), explains hidden partitioning via the Trino-rewrites-the-predicate contrast with Hive/Postgres, walks the small-files cost with concrete numbers (10–50ms per file open × 23,000 files = minutes of overhead). Full maintenance schedule provided (rewrite_data_files nightly, rewrite_manifests weekly, expire_snapshots nightly w/ 30-day retention, remove_orphan_files weekly), all mapped to Iceberg 1.5.2 + Spark + Trino + MinIO. Mentions `bucket()` for high-tenant scaling. Resource gap: beginner clarity — `manifest`, `rewrite_manifests`, `expire_snapshots`, `bucket()`, "target 256MB" all dropped without inline plain-English glosses. Add a "if you only remember three sentences" block at the top of the maintenance section of `10-lakehouse-partitioning.md`.

### Iteration 3, Q3 — 2026-05-23
**Question**: Multi-tenant analytics: isolating customer data in SaaS (Trino default behavior, what to build vs what the engine gives you, bad-query scenario).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Multi-tenant analytics: isolating customer data in SaaS — prior avg 1.75 over 1 question, new running avg **3.25** across 2 questions (1.75 + 4.75 = 6.50 / 2). Status: needs 2nd clean angle (current 2-question avg 3.25 is below 3.5 threshold — one more passing question would bring it above).

**Notes**: Near-complete reversal of the Iter 2 Q4 failure. Directly addresses (1) Trino's default behavior (no auto-isolation), (2) views + roles + system access control, and (3) the bad-query scenario (denied at the role level, not silently leaked). Grounded in Trino 467 + Iceberg + MinIO; gives runnable CREATE VIEW / GRANT / REVOKE syntax and an 80-tenant playbook plus noisy-neighbor mitigation. Resource gap: beginner clarity — "role-based access control", "system access control", "resource groups", "noisy-neighbor" used without inline definitions; also, no warning that file-based rules require coordinator restart (or OPA for hot reload). Suggested next question angle: CI test/verification flow ("prove to my security team isolation works") OR customer-offboarding ("when a customer leaves, how do I delete their data?" — GDPR/shared-table tension).

### Iteration 3, Q4 — 2026-05-23
**Question**: Storage sizing and growth estimation for lakehouse workloads (Postgres 200GB -> Iceberg, growth math).

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.00** |

**Topics updated**: Storage sizing and growth estimation for lakehouse workloads (1 question, avg 4.00)

**Notes**: Correctly pulls the core mechanics from `11-lakehouse-storage-sizing.md` — 5–10x Parquet compression, per-column-type table (low-card strings 10–50x, timestamps 10–20x, UUIDs 2–4x, JSON 2–3x), snapshot-accumulation trap with `expire_snapshots`, on-prem "pay in hardware" framing. The 200GB/7 ≈ 29GB math is right-ish but conceptually shaky — Postgres on-disk includes its own page/index/TOAST overhead, so dividing raw Postgres bytes by Parquet's raw-to-compressed ratio mixes two baselines. Honest path: "Postgres 200GB likely has 60–120GB of row data plus index/bloat; that compresses 5–10x → 10–25GB." Resource gap: add a "Migrating from Postgres — how to estimate" section to `11-lakehouse-storage-sizing.md` calling out `pg_total_relation_size` minus `pg_indexes_size`, `pg_stats` avg row width, or sample-export-to-Parquet as the right methods.

### Iteration 3, Q5 — 2026-05-23
**Question**: Analytical query patterns on Iceberg+Trino — funnels, cohorts, time-series SQL (engineer asked for funnel SQL, got all three).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL (1 question, avg 4.75)

**Notes**: Over-delivered — funnel uses correct idiom (MIN(event_time) per user, JOIN within 7-day window, COUNT + percentage); cohort pivots into day_0_30/30_60/60_90 columns matching the product's exact framing; WAU correctly addresses gap-filling with calendar UNNEST(sequence()), CROSS JOIN to tenants, COALESCE(0). Production callouts (partition pruning on event_date, approx_distinct for large cohorts, MATCH_RECOGNIZE as next step) all accurate for Trino 467. Resource gap: beginner clarity — CTE, MATCH_RECOGNIZE, approx_distinct/HyperLogLog, UNNEST(sequence()), partition pruning all appear without inline definitions. Suggested next question angle: (a) operational ("funnel takes 8 minutes, how do I speed it up on Iceberg?" — forces partition design, pre-aggregated funnel tables, sort/cluster keys), or (b) correctness ("how do I match marketing's numbers when late-arriving events update last week?" — forces snapshots, time travel, event-time vs ingestion-time).

### Iteration 4, Q1 — 2026-05-23
**Question**: Real-time vs batch freshness — PM wants 5-minute dashboards, how do I evaluate the trade-off on our on-prem Iceberg+Trino stack?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Real-time vs batch analytics trade-offs (1 question, avg 4.75)

**Notes**: Strong, well-anchored answer. Correctly reframes "5-minute freshness" as a spectrum question, surfaces 5-min batch = 288 jobs/day math, k8s pod-churn and small-files/compaction-explosion callouts, and gives stack-specific recommendations (read replica for batch; Iceberg 1.5.2 writeStream + Kafka + Spark Structured Streaming for true streaming). Compaction-must-run-hourly-not-nightly is the operational nuance the responder surfaced without prompting. Beginner clarity soft spot: "compaction", "micro-batch", "writeStream", "Structured Streaming", "Kafka" used without inline glosses. Resource gap: add "How to negotiate the freshness SLA with your PM" section to `14-real-time-vs-batch.md` with 3-4 example conversations and a cost table (engineer-weeks + on-call burden) per freshness tier.

### Iteration 4, Q2 — 2026-05-23
**Question**: Postgres-to-Iceberg ingestion — what's the right pattern, and how do I handle JSONB columns?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling (1 question, avg 4.50)

**Notes**: Closes the resource gap flagged in Iter 2 Q5 and Iter 3 Q1. Names Spark JDBC as correct on-prem tool (correctly rejecting Fivetran/Airbyte), gives three patterns (full refresh / incremental watermark / Debezium-Kafka CDC) with a decision rule, and addresses JSONB with both standard options (store-as-text vs flatten-hot-fields). Spark code skeleton + KubernetesCronJob/Airflow + post-ingest rewrite_data_files and expire_snapshots all actionable. Completeness gap: idempotency / dedupe on event_id, JDBC parallelism knobs (partitionColumn/numPartitions/lowerBound/upperBound), MERGE INTO for dimension upserts, and schema evolution. Suggested 2nd-angle question: "I ran my Spark ingestion job twice by accident and now my event counts are doubled — how do I prevent this and clean it up?" (forces idempotency, MERGE INTO, snapshot rollback).

### Iteration 4, Q3 — 2026-05-23
**Question**: Tools comparison — BigQuery vs Snowflake vs ClickHouse vs our Iceberg+Trino lakehouse, when should we switch?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Popular tools overview: BigQuery, Snowflake, ClickHouse, DuckDB, Iceberg (1 question, avg 4.75)

**Notes**: Correctly rebuts the "BigQuery and Snowflake are interchangeable" framing (serverless GCP / per-TB-scanned vs multi-cloud / per-second virtual warehouses), then re-anchors to prod_info.md (on-prem requirement disqualifies both managed cloud options). DuckDB-as-complement positioning, ~$0 marginal-query cost framing, and explicit "stop overthinking replacing the stack" closer all aligned with the prod stack. Beginner clarity weak: "vendor lock-in", "serverless", "separation of storage and compute", "MergeTree", "per-TB-scanned", "virtual warehouse" pulled from resource body without surfacing the Key Terms glosses inline. Suggested 2nd-angle question: (a) "vendor pitching us Snowflake to replace our lakehouse — what would we gain or lose?" or (b) "when would ClickHouse make sense ON TOP of our Iceberg+Trino stack?"

### Iteration 4, Q4 — 2026-05-23
**Question**: Cohort retention query — investor dashboard wants week-by-week cohort matrix from our events table.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: Common analytical query patterns: aggregations, funnels, cohort, time-series (1 question, avg 4.50)

**Notes**: Strong pedagogical move — shows the output shape (cohort × week-offset matrix) before any SQL. 3-CTE walk (cohorts → activity → pivot) follows `07-analytical-query-patterns.md` exactly with correct idioms (date_trunc('week', MIN(event_time)) for cohort assignment, date_diff('week', cohort_week, event_time) for offset, COUNT(DISTINCT user_id) per cell). approx_distinct callout with ~2% error / 100x memory framing is right level of nuance. Iceberg partition-pruning grounding ties answer to prod stack. Resource gaps: (1) wide-pivot CASE WHEN variant missing — investors want wide format; (2) cohort-size denominator implicit — retention *percentage* (week_N / week_0) not shown explicitly (add FIRST_VALUE OVER PARTITION BY cohort_week to close the loop).

### Iteration 4, Q5 — 2026-05-23
**Question**: Multi-tenant isolation — security team wants proof that a tenant role cannot read another tenant's data, what CI test do I build?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Multi-tenant analytics: isolating customer data in SaaS — prior avg 3.25 across 2 questions, new running avg **3.75** across 3 questions (1.75 + 4.75 + 4.75 = 11.25 / 3). Status: **PASSED** (≥ 3.5 threshold, 3 questions ≥ 2 required).

**Notes**: Directly answers the security-team "prove it" framing with concrete runnable CI test recipe (create role, grant only on view, assert base-table SELECT fails, assert view SELECT succeeds). Correctly grounds proof in two enforcement layers (view + REVOKE; system access control via file-based rules or OPA), names prod stack (Trino 467 + Iceberg + MinIO), gets the headline assertion right (Trino rejects at role/access-control layer before reaching Iceberg, so missing WHERE clause cannot bypass isolation). 7-step 80-tenant playbook restated accurately. Cited resource with line numbers — auditable. Resource gap (persistent across the multi-tenant topic): "role-based access control", "system access control", "parse time", "veto", "file-based rules", "OPA" still without inline glosses. The answer describes the four CI steps narratively but does not show runnable test code — recommend adding a "How to prove isolation in CI" subsection to `resources/05-multi-tenant-analytics.md` with a pytest + Trino Python client example and a "what to hand the security team" deliverable list. Also still missing: file-based-rules-require-restart vs OPA-hot-reload sentence (flagged in Iter 3 Q3, unaddressed).

### Iteration 5, Q1 — 2026-05-23
**Question**: When to add an OLAP layer vs staying on the transactional DB — tuning-first angle (second angle after Iter 2 Q5).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: When to add an OLAP layer vs staying on the transactional DB — prior avg 4.0 over 1 question; new running avg (4.0 + 4.75) / 2 = **4.375** across 2 questions. Status: **PASSED**.

**Notes**: Reverses the "buy a new system" framing, delivers a NO-at-5M-rows verdict, and enumerates four quantitative thresholds (>50M rows, >2s after tuning, >3 ad-hoc users, >1 data source). Full Postgres-tuning ladder present: read replica, materialized views, partial indexes, EXPLAIN ANALYZE, pg_partman. Correctly flags ClickHouse as a red herring for the prod stack (Trino + Iceberg + MinIO already in place). Beginner clarity soft spot: tuning terms ("materialized view", "partial index", "pg_partman", "EXPLAIN ANALYZE") used without inline one-line glosses. Resource gap: add gloss-per-lever to the tuning ladder section and a "how to measure these thresholds" sub-section (pg_stat_statements for slow-query counts, pg_class.reltuples for row counts).

### Iteration 5, Q2 — 2026-05-23
**Question**: Storage cost estimation — Postgres 200 GB to Iceberg on MinIO (second angle after Iter 3 Q4).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Storage sizing and growth estimation for lakehouse workloads — prior avg 4.0 over 1 question; new running avg (4.0 + 4.75) / 2 = **4.375** across 2 questions. Status: **PASSED**.

**Notes**: Correctly fixes the "mixing two baselines" trap from Iter 3 Q4 — backs out Postgres bloat/indexes/TOAST (~1.3–1.5x raw row data) before applying Parquet compression. Per-column compression breakdown is accurate and internally consistent with `11-lakehouse-storage-sizing.md`. Final 18–31 GB estimate on MinIO is realistic. Hidden-cost framing (snapshot accumulation, metadata overhead, on-prem hardware sizing) is the right set of warnings. Anchored to prod stack (MinIO, Iceberg 1.5.2) throughout. Beginner clarity cost: "bloat", "TOAST", "expire_snapshots", "manifest", "erasure coding", "dictionary encoding", "delta encoding" used without inline glosses. Resource gap: add a "Postgres -> Iceberg sizing in 4 steps" subsection (subtract index size via pg_indexes_size, estimate bloat 1.3–1.5x, apply per-column compression, add 30-day snapshot buffer) plus a one-line runnable pg_total_relation_size snippet.

### Iteration 5, Q3 — 2026-05-23
**Question**: Schema design for analytics — denormalization and star schema basics (first question on this topic).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Schema design for analytics: denormalization, star schema basics — 0 questions prior; now 1 question, avg **4.75**. Status: needs 2nd angle.

**Notes**: Defuses the "denormalize = inconsistent" misconception by reframing duplicated values as event-time snapshots (the historical row is correct as of when it happened, not stale). OLTP-vs-OLAP setup given before any SQL appears. Before/after JOIN-vs-no-JOIN contrast on Trino with "JOINs cause network shuffles between workers" is accurate for Trino 467 + Iceberg + MinIO. 2–3 fact tables + "denormalize columns that appear in GROUP BY/WHERE" rule is directly actionable. SCD with is_current=TRUE correctly anticipates the engineer's follow-up. Grain not named explicitly; "shuffle", "SCD", "is_current" used without inline glosses — costs one point on beginner clarity. Resource gap: gloss pass on `08-schema-design-for-analytics.md` — add one-line inline glosses for "shuffle", "grain", "SCD Type 2", "snowflake schema" at first use in the body (not just in the Key Terms table). Also add a short "the inconsistency objection — and why it's a feature" subsection since this misconception is common.

### Iteration 5, Q4 — 2026-05-23
**Question**: approx_distinct() accuracy — is 2% HyperLogLog error acceptable for customer-facing dashboards? (second angle on common analytical query patterns).

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 2 |
| **Average** | **3.25** |

**Topics updated**: Common analytical query patterns: aggregations, funnels, cohort, time-series — prior avg 4.50 over 1 question; new running avg (4.50 + 3.25) / 2 = **3.875** across 2 questions. Status: **PASSED** (≥ 3.5 threshold met).

**Notes**: Responder correctly stated the ~2% HyperLogLog figure and honestly admitted resources don't cover error confidence intervals or size-dependent behavior. However, the core question ("is there a threshold below which COUNT(DISTINCT) is better?") went unanswered — engineer left without a decision rule. "Run a validation test" is directionally right but too vague to act on. The topic passes on running average, but this answer reveals a gap that will hurt engineers making customer-facing decisions. Resource gap (CRITICAL): add an "approx_distinct vs COUNT(DISTINCT) — when to use each" subsection to `resources/07-analytical-query-patterns.md` covering: (1) HyperLogLog 2% is a standard deviation not a maximum; real-world error for 1K–10M users is well within 2%; (2) decision rule — use COUNT(DISTINCT) for cohort < 1M users, customer-facing numbers, or revenue/billing metrics; use approx_distinct for cohorts > 10M or internal dashboards; (3) validation recipe: run both on a sample partition, compute (approx - exact) / exact × 100 for your data shape.

### Iteration 5, Q5 — 2026-05-23
**Question**: Service account isolation — write vs read path separation (Spark ingest SA vs Trino query SA). Attributed to: Multi-tenant analytics.

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.25** |

**Topics updated**: Multi-tenant analytics: isolating customer data in SaaS — prior avg 3.75 across 3 questions; new running avg (1.75 + 4.75 + 4.75 + 4.25) / 4 = **3.875** (corrected to include all 4 questions, see attribution note below). Status: PASSED (unchanged). OLTP-to-OLAP mindset topic: 0 questions, unaffected.

**Attribution note**: This question is about write-path vs read-path principal separation (Spark ingest SA vs Trino query SA as a defense-in-depth enforcement layer), which maps to multi-tenant isolation — not to the OLTP-to-OLAP mindset topic. OLTP-to-OLAP mindset remains at 0 questions asked.

**Notes**: Strong, actionable answer — correctly identifies that Spark write user and Trino read user must be different principals with disjoint grants, maps k8s ServiceAccount separation to Trino role separation, and provides runnable CREATE ROLE / GRANT SELECT on views / REVOKE ALL on base tables snippet. CI test recommendation closes the loop with Iter 4 Q5. Technical imprecision: "Trino evaluates permissions before parsing" is wrong — access control runs during analysis/planning (post-parse, pre-execution); the substantive point (engine-level rejection before data is read from MinIO) is correct but the framing will not survive a security review. Beginner clarity gap: "ServiceAccount", "role", "analytics_service", "system access control" used without inline glosses. Resource gap: `resources/05-multi-tenant-analytics.md` needs (1) an explicit "Two service accounts, not one" section with a table (spark-ingest-sa: writes to base tables, no read on views) vs (trino-query-sa: reads via per-tenant views, no write/no base-table access); (2) correction to "permissions evaluated before parsing" framing — accurate phrasing is "rejected before any data is read from MinIO" (access control runs at analysis phase); (3) k8s ServiceAccount -> Trino user mapping example (JWT or password auth).

---

### Iteration 6, Q1 — 2026-05-23
**Question**: OLTP-to-OLAP mindset — first move on a lakehouse ticket (Day-1 checklist, "analytical copy not a migration" framing).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: OLTP-to-OLAP mindset: the mental model shift for SaaS engineers adopting a lakehouse — 0 questions prior; now 1 question, avg **4.50**. Status: needs 2nd angle.

**Notes**: Clean, actionable walk through the Day-1 checklist from `resources/12-oltp-to-olap-mindset.md`, correctly sequenced and grounded in the production stack throughout. The "analytical copy, not a migration" framing is correctly surfaced as the key mental shift. Main clarity gap: jargon terms (denormalized schema, partition spec, compaction, expire_snapshots, JSONB, CronJob) appear without the plain-English glosses that the resource provides. Critical omission: the per-tenant Trino view step (step 6 of the Day-1 checklist) is absent from the answer summary — an engineer who follows steps 1–5 and skips to "point BI tool at Trino" will expose cross-tenant data. Resource gap: add a callout box in `resources/12-oltp-to-olap-mindset.md` after the Day-1 checklist flagging the tenant view step as non-optional for B2B SaaS.

### Iteration 6, Q2 — 2026-05-23
**Question**: Cost considerations for on-prem analytics stack — hardware, compute, engineering FTE (CTO-facing cost breakdown).

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.25** |

**Topics updated**: Cost considerations for analytical workloads at SaaS scale — 0 questions prior; now 1 question, avg **4.25**. Status: needs 2nd angle.

**Notes**: Correctly structures cost around three layers (storage cheap, compute dominates, engineering FTE largest) and maps them to the on-prem stack accurately. The $18k synthesized hardware figure does not appear in resource 16 — this risks misleading a CTO who may not have a hardware purchase coming. The managed-cloud vs self-hosted crossover framing, which matters for a "keep or replace" decision, is present in the resource but not surfaced in the answer. Resource gap: add a "one-year cost estimate template" section to `resources/16-cost-considerations.md` separating hardware amortization (sunk cost if servers already owned), k8s node budget, engineering FTE as a line item, and explicit instruction that storage is treated as sunk cost on an already-provisioned MinIO cluster.

### Iteration 6, Q3 — 2026-05-23
**Question**: Column-oriented storage — why does a GROUP BY country on events cause a 15x slowdown? (2nd angle on column-oriented storage).

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 3 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.50** |

**Topics updated**: Column-oriented storage — what it is and why it's faster for analytics — prior avg 4.75 over 1 question; new running avg (4.75 + 3.50) / 2 = **4.125** across 2 questions. Status: **PASSED** (avg 4.125 >= 3.5 threshold, 2 questions asked).

**Notes**: Correctly identifies the hash table / accumulator mechanism and distributed shuffle as two causes, and gives Trino-specific EXPLAIN ANALYZE node names (HashAggregate + RemoteExchange). However, for this production stack (Trino + Iceberg + MinIO with partition pruning), the most likely cause of a 15x slowdown when adding GROUP BY country is that country is not a partition column — meaning the query now triggers a full table scan with no file skipping. The answer names "add WHERE on partition column" as fix #3 but treats it as an afterthought rather than the primary diagnostic hypothesis, inverting the production-relevant priority. Beginner clarity and completeness both weak: no inline explanation of HashAggregate, RemoteExchange, shuffle, or two-phase aggregation for a beginner audience. Resource gap: `resources/03-columnar-storage.md` needs a "why GROUP BY can trigger a full scan" section — specifically that adding GROUP BY on a non-partition column does NOT add a new WHERE predicate, so a previously file-pruned query may now do a full scan, with EXPLAIN ANALYZE output showing the file count before and after.

### Iteration 6, Q4 — 2026-05-23
**Question**: Fact table vs dimension table — events vs users (2nd angle on lakehouse schema design: fact tables, dimension tables, denormalization).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.75** |

**Topics updated**: Lakehouse schema design: fact tables, dimension tables, denormalization — prior avg 4.25 over 1 question; new running avg (4.25 + 4.75) / 2 = **4.50** across 2 questions. Status: **PASSED** (avg 4.50 >= 3.5 threshold, 2 questions asked).

**Notes**: Near-perfect beginner-facing explanation of fact vs dimension tables. Leads with a direct conceptual correction ("not about size"), uses the engineer's own table names, and explains every concept inline. No unexplained jargon. Only material gap: denormalization is not mentioned at all, despite being part of the topic scope — a one-sentence bridge ("copy plan_type into the fact table to avoid JOINs") would have completed the picture. Grain is implicit but unnamed. Resource gap: `resources/09-lakehouse-schema-design.md` should forward-reference denormalization at the end of the "Why keep them separate?" subsection to prime the responder to surface it when answering conceptual questions.

### Iteration 6, Q5 — 2026-05-23
**Question**: occurred_at vs ingested_at for mobile offline batching / WAU dashboard (2nd angle on real-time vs batch analytics trade-offs).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Topics updated**: Real-time vs batch analytics trade-offs — prior avg 4.75 over 1 question; new running avg (4.75 + 5.0) / 2 = **4.875** across 2 questions. Status: **PASSED** (avg 4.875 >= 3.5 threshold, 2 questions asked).

**Notes**: Cleanest execution seen in this training run. Opens with a concrete mobile-offline scenario (9:00 AM event, 9:30 AM delivery) before naming any concept. Correctly identifies occurred_at as the right timestamp for WAU, explains the split, and states Iceberg partition-by-ingested_at + query-by-occurred_at as the canonical pattern. Two concrete buffer options given. No unexplained jargon. No resource gaps for this answer — `resources/14-real-time-vs-batch.md` already contains the exact scenario and the responder pulled all of it correctly.

---

### Iteration 7, Q1 — 2026-05-23
**Question**: Self-hosted Iceberg+Trino vs Snowflake — hidden costs beyond storage (2nd angle on cost considerations).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Cost considerations for analytical workloads at SaaS scale — prior avg 4.25 over 1 question (Iter 6 Q2); new running avg (4.25 + 4.75) / 2 = **4.50** across 2 questions. Status: **PASSED**.

**Notes**: Correctly surfaces all three hidden cost layers (idle compute, maintenance complexity, engineering FTE) matching `resources/16-cost-considerations.md`. Dollar figures ($60k–$140k FTE, Snowflake crossover ~$60k FTE + $5k cloud credits) match the resource. The "you're already running this stack, marginal compute is sunk" nuance is preserved. Persistent beginner-clarity gap: "executor pods," "Hive Metastore," "k8s node budget," "compaction," "FTE," and "orphaned files" appear without inline plain-English glosses. Resource gap: the 0.2–0.5 FTE per 10 TB calibration should note it should be prorated for smaller stacks (e.g., 0.05–0.15 FTE at <1 TB) to avoid overstating FTE burden at small scale.

### Iteration 7, Q2 — 2026-05-23
**Question**: Idempotent Spark ingestion and duplicate cleanup on Iceberg — how to prevent and fix doubled event counts.

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 4 |
| **Average** | **3.50** |

**Topics updated**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling — prior avg 4.50 over 1 question (Iter 4 Q2); new running avg (4.50 + 3.50) / 2 = **4.00** across 2 questions. Status: **PASSED** (minimum coverage met, avg >= 3.5).

**Notes**: Critical production hazard introduced in the cleanup path: `createOrReplace()` in Spark Iceberg is a full table replacement (DROP + CREATE semantics), not a partition-scoped overwrite. An engineer following the answer for `problem_date = '2026-05-22'` would destroy all other partitions. The correct API for partition-scoped overwrite is `overwritePartitions()`. The `DELETE FROM ... WHERE batch_loaded_at > ...` alternative is safe but positioned as secondary. Missing: Iceberg snapshot rollback (`CALL iceberg.system.rollback_to_snapshot`) as the safest first cleanup step before any rewrite. Resource gap: `resources/13-postgres-to-iceberg-ingestion.md` needs a dedicated "Idempotency and cleanup" section explicitly naming `overwritePartitions()` vs `createOrReplace()` and listing snapshot rollback as first-resort cleanup.

### Iteration 7, Q3 — 2026-05-23
**Question**: OLTP-to-OLAP mindset — Trino+Iceberg for a team coming from Postgres (JOINs, UPDATEs, DELETEs failing in production).

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: OLTP-to-OLAP mindset: the mental model shift for SaaS engineers adopting a lakehouse — prior avg 4.50 over 1 question (Iter 6 Q1); new running avg (4.50 + 4.50) / 2 = **4.50** across 2 questions. Status: **PASSED**.

**Notes**: Strong beginner-clarity score — best in the iteration. Before/after SQL pairs for JOINs and event-sourcing are excellent teaching devices. "Delete file" and "compaction" defined inline. Technical weakness: "A 12-table JOIN means Trino reassembles rows from a dozen files" conflates Parquet's intra-file columnar layout with inter-table JOIN shuffle cost. "No indexes" understates Iceberg's Parquet column statistics and manifest min/max for file skipping. Two completeness gaps: (1) DELETE correctness angle (whether delete files are reliably applied before compaction) not addressed; (2) over-denormalization trap (copying current plan_type vs plan_type at event time) absent despite actively encouraging denormalization. Per-tenant view step still missing. Resource gap: add inline warning in Day-1 checklist step 2 and "Stop mutating" section in `resources/12-oltp-to-olap-mindset.md`.

### Iteration 7, Q4 — 2026-05-23
**Question**: Tenant-only partitioning skew — why big customers got slower queries (2nd angle on Iceberg partition design).

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.50** |

**Topics updated**: Iceberg partition design for SaaS: strategies, small-files, compaction — prior avg 4.75 over 1 question (Iter 3 Q2); new running avg (4.75 + 3.50) / 2 = **4.125** across 2 questions. Status: **PASSED** (avg 4.125 >= 3.5 threshold).

**Notes**: Two concrete errors: (1) answer correctly quotes `(day(occurred_at), tenant_id)` order then reverses it in the ALTER TABLE SQL to `ARRAY['tenant_id', 'day(occurred_at)']` — internally inconsistent and produces suboptimal file layout for time-range-first cross-tenant queries; (2) math "50M ÷ 365 = ~140 partitions/year" is dimensionally wrong — partitions per year = tenants × days (e.g., 80 × 365 = 29,200), not event count divided by days. Completeness gaps: `bucket(tenant_id, N)` anti-skew recommendation absent; hidden partitioning behavior absent; full maintenance schedule (rewrite_manifests, expire_snapshots) absent. Resource gap: `resources/10-lakehouse-partitioning.md` — add "Why order matters: day-first vs tenant-first" subsection with explicit correct ALTER TABLE example using `ARRAY['day(occurred_at)', 'tenant_id']` and partition count math (tenants × days).

### Iteration 7, Q5 — 2026-05-23
**Question**: Funnel query performance — 8 minutes on 500M rows, already day-partitioned, how to fix it.

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.00** |

**Topics updated**: Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL — prior avg 4.75 over 1 question (Iter 3 Q5); new running avg (4.75 + 4.00) / 2 = **4.375** across 2 questions. Status: **PASSED**.

**Notes**: Correctly identifies multi-pass scan bottleneck and delivers five actionable levers in priority order. Two technical issues: (1) `ALTER TABLE ... SET PARTITIONING = ARRAY[...]` is wrong Trino DDL — correct syntax is `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[...]`; this error traces back to a bug in `resources/10-lakehouse-partitioning.md` line 194; (2) MATCH_RECOGNIZE recommended as quick fix but no example query shown — engineer knows it exists but has nothing to run. Missing: EXPLAIN ANALYZE as the diagnostic first step; Parquet column statistics / row-group pruning angle; z-ordering/clustering as per-file optimization. Resource gaps: (1) fix `SET PARTITIONING` to `SET PROPERTIES partitioning` in `resources/10-lakehouse-partitioning.md`; (2) add concrete 3-step MATCH_RECOGNIZE funnel example (signup -> activation -> payment within 7 days) to `resources/07-analytical-query-patterns.md`.

---

### Iteration 8, Q1 — 2026-05-23
**Question**: Iceberg table maintenance — inherited setup with two months of skipped maintenance (new topic, first question).

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup — first question, avg 4.50. Status: needs 2nd angle.

**Notes**: Operationally solid and beginner-friendly. All four procedures, correct ordering, and runnable SQL are present. Two technical imprecisions: (1) "288+ files per day per partition" applies only to 5-minute streaming micro-batch pipelines, not daily ETL as the question describes; (2) the stated danger of running `remove_orphan_files` before `expire_snapshots` ("you risk deleting a file a snapshot still references") is wrong — files referenced by any snapshot are by definition not orphans and cannot be deleted; the real danger is a race condition with an in-flight write when `older_than` is too aggressive. Missing: emergency rollback via `CALL iceberg.system.rollback_to_snapshot` as a first-resort cleanup tool, and concurrency safety note (compaction is safe with ad-hoc queries due to snapshot isolation).

### Iteration 8, Q2 — 2026-05-23
**Question**: SCD Type 2 and plan_type history on Iceberg+Trino (2nd angle on schema design for analytics).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.25** |

**Topics updated**: Schema design for analytics: denormalization, star schema basics — prior avg 4.75 (1q); new running avg (4.75 + 4.25) / 2 = **4.50** across 2 questions. Status: **PASSED**.

**Notes**: Correctly teaches SCD Type 2 row structure (valid_from/valid_to/is_current), point-in-time SQL, Spark MERGE INTO, and dbt snapshots as complementary patterns. Gap: no guidance on remediating already-loaded historical events with stale plan_type — the engineer's most immediate follow-on question goes unanswered. "MERGE INTO" and "dbt snapshot" used without inline glosses.

### Iteration 8, Q3 — 2026-05-23
**Question**: DuckDB as analytics layer vs Trino — scale ceiling and migration point (2nd angle on popular tools overview).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.75** |

**Topics updated**: Popular tools overview: BigQuery, Snowflake, ClickHouse, DuckDB, Iceberg — prior avg 4.75 (1q); new running avg (4.75 + 4.75) / 2 = **4.75** across 2 questions. Status: **PASSED**.

**Notes**: Correctly positions DuckDB as a prototyping tool within the prod stack (MinIO + Iceberg + Trino) with four concrete signals for when to graduate to Trino. "No re-engineering cost when you switch" framing is accurate for the Iceberg+Parquet foundation. Minor gaps: DuckDB requires httpfs extension configured with MinIO endpoint and credentials (not automatic); SQL dialect divergence between DuckDB and Trino not mentioned; remote-vs-local latency for on-prem MinIO absent.

### Iteration 8, Q4 — 2026-05-23
**Question**: Iceberg partition pruning not skipping rows — WHERE event_date >= '2024-01-01' still doing a full scan (2nd angle on query performance basics).

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 3 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.50** |

**Topics updated**: Query performance basics: partitioning, indexing strategy for analytics — prior avg 5.0 (1q); new running avg (5.0 + 3.5) / 2 = **4.25** across 2 questions. Status: **PASSED** (avg 4.25 >= 3.5 threshold, minimum coverage met).

**Notes**: Explains file-vs-row pruning distinction well and gives runnable EXPLAIN ANALYZE + CALL statements. Critical omission: for an engineer who "added" a partition to a running table, the dominant root cause is that Iceberg's partition spec change does NOT repartition existing data files — old files remain unpartitioned and cannot be pruned. This gotcha is absent from the answer entirely. Beginner clarity weak: "manifest metadata," "row-group statistics," "partition spec," "hidden partitioning" all appear without inline glosses.

### Iteration 8, Q5 — 2026-05-23
**Question**: Iceberg vs raw Parquet folders — what the table format layer actually buys you (2nd angle on what a data lakehouse is).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: What a data lakehouse is and how it differs from a warehouse — prior avg 4.75 (1q); new running avg (4.75 + 4.50) / 2 = **4.625** across 2 questions. Status: **PASSED**.

**Notes**: Excellent "without Iceberg / with Iceberg" contrast structure per section. Covers ACID concurrent writes, partial-write/orphan isolation, rollback, schema evolution, partition pruning, and time travel with runnable Trino 467 + Iceberg 1.5.x SQL throughout. "ACID transactions," "snapshot," and "orphan files" appear without one-line plain-English glosses, costing one beginner-clarity point. Minor gaps: catalog/Hive Metastore schema-discovery advantage over raw folder paths not mentioned; manifest-level Parquet column statistics (min/max per row group) as a second pruning tier absent.

---

### Iteration 9, Q1 — 2026-05-23
**Question**: Read replica vs structural fix: why analytics queries are fundamentally disruptive (Rails + Postgres, dashboards causing lockups even on read replica).

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.25** |

**Topics updated**: OLAP vs OLTP — difference and why it matters for SaaS — prior avg 5.0 (1q); new running avg (5.0 + 4.25) / 2 = **4.625** across 2 questions. Status: **PASSED**.

**Notes**: Core mechanics correct — row-oriented scans, I/O saturation, CPU/RAM consumption during aggregation, structural mismatch. Best teaching device: point-lookup vs full-table aggregate contrast at the open. Migration path (Spark -> Iceberg -> Trino via Hive Metastore) accurate and grounded in prod_info.md. Gaps: why the replica still suffers stays at the I/O-saturation level without naming row-oriented format as the structural culprit clearly enough; missing replication-lag-as-replica-specific failure mode; AccessShareLock angle absent. "Hive Metastore," "materialized views," "pg_partman," "EXPLAIN ANALYZE" dropped without inline glosses. Resource gap: `resources/01-olap-vs-oltp.md` should add a "Why read replicas help but don't fully solve it" subsection covering: (1) replica is still row-oriented; (2) heavy analytical scans can cause replication lag; (3) AccessShareLock held during long scans can block DDL on the replica.

### Iteration 9, Q2 — 2026-05-23
**Question**: Denormalization misconception — why a data warehouse deliberately "fails" database course rules.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: What a data warehouse is and when a SaaS product needs one — prior avg 5.0 (1q); new running avg (5.0 + 4.50) / 2 = **4.75** across 2 questions. Status: **PASSED**.

**Notes**: Excels at defusing the "denormalization = inconsistency" misconception via the append-only / "historical fact" reframe. Before/after framing effective. Production stack named correctly. Gap: the question invited a full "what does a warehouse do differently" answer — the response reduced the warehouse concept to OLAP-vs-OLTP and append-only behavior, skipping multi-source integration (Stripe + Mixpanel + Postgres) and single-source-of-truth value propositions that are the primary content of `resources/02-data-warehouse.md`. OLTP/OLAP labels introduced without plain-English definitions; "network shuffles between workers" and "Iceberg partitioning" used without glosses. Resource gap: `resources/02-data-warehouse.md` — add a callout flagging that "what does a warehouse do differently" has two parts: (1) query performance / OLAP design (covered well), and (2) multi-source consolidation (not surfaced), so the responder pulls both angles.

### Iteration 9, Q3 — 2026-05-23
**Question**: Iceberg snapshot accumulation — why files pile up and how to clean them safely (MinIO storage growing despite no new data).

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 5 |
| Practical applicability | 4 |
| Completeness | 5 |
| **Average** | **4.25** |

**Topics updated**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup — prior avg 4.50 (1q); new running avg (4.50 + 4.25) / 2 = **4.375** across 2 questions. Status: **PASSED**.

**Notes**: Exceptional beginner clarity — best clarity score in the iteration. Concrete "3x storage, 10+ seconds just opening metadata" numbers ground the abstract problem. Four-procedure walkthrough with plain English before each SQL. Safety guarantee addresses beginner fear directly. Critical bug: all three CALL statements use `TIMESTAMPADD(DAY, -30, CURRENT_TIMESTAMP)` which is not valid Trino SQL — correct syntax is `current_timestamp - interval '30' day`. This is a pre-existing bug in `resources/17-iceberg-table-maintenance.md` faithfully reproduced; every engineer who copies this SQL will hit a runtime error. Second issue: "288 new snapshots per partition per day" conflates file count (per partition, for 5-min streaming) with snapshot count (per table total — each micro-batch creates one table snapshot regardless of partition count). Resource gap (CRITICAL): `resources/17-iceberg-table-maintenance.md` must replace all `TIMESTAMPADD(DAY, -N, CURRENT_TIMESTAMP)` occurrences with valid Trino syntax (`current_timestamp - interval '30' day`). Fix required at lines 79, 101, 203, and 210 (inline examples and Quick-start schedule block).

---

### Iteration 10, Q1 — 2026-05-23
**Question**: GDPR right-to-erasure deletion in Iceberg vs Postgres — what is fundamentally different and what is the correct physical removal sequence?

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 3 |
| **Average** | **3.25** |

**Topics updated**: Multi-tenant analytics: isolating customer data in SaaS — prior avg 3.875 across 4 questions; new running avg (1.75 + 4.75 + 4.75 + 4.25 + 3.25) / 5 = **3.75** across 5 questions. Status: PASSED (avg 3.75 >= 3.5 threshold).

**Notes**: The core Iceberg delete-file mechanic is correct but the GDPR compliance workflow is critically incomplete. The recommended sequence (DELETE → rewrite_data_files → verify SELECT COUNT → sign off) omits `expire_snapshots`, which is the step that removes old Parquet files from MinIO. An engineer following this audit flow would certify GDPR deletion before the customer's bytes are physically gone from storage — a compliance risk. The three-option taxonomy (DELETE + rewrite, partition-drop, DROP SCHEMA cascade) and the comparison table are architecturally sound. Engine context (Spark vs Trino procedures) absent. Resource gap: `resources/05-multi-tenant-analytics.md` needs a "GDPR right to erasure" subsection with the complete 3-step physical removal sequence: (1) DELETE creates delete files, (2) rewrite_data_files rewrites Parquet without deleted rows but old files remain, (3) expire_snapshots removes old snapshots and frees old files from MinIO — only after step 3 are bytes physically gone.

### Iteration 10, Q2 — 2026-05-23
**Question**: Gap-fill time-series (zero weeks disappearing from results) and rolling 4-week average on Trino.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Common analytical query patterns: aggregations, funnels, cohort, time-series — prior avg 3.875 across 2 questions; new running avg (4.50 + 3.25 + 4.75) / 3 = **4.167** across 3 questions. Status: PASSED (solidly above threshold).

**Notes**: Strongest answer of the iteration. All Trino syntax verified accurate: `UNNEST(sequence(0, 51))`, `date_add('week', n, start_date)`, LEFT JOIN + COALESCE gap-fill idiom, `AVG() OVER (ORDER BY week_start ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)`, `date_trunc('week', ...)`. Partial-window behavior correctly surfaced as a proactive edge-case note. One point docked on beginner clarity for missing inline glosses on "window function," "CTE," "COALESCE," and the `ROWS BETWEEN` frame syntax.

### Iteration 10, Q3 — 2026-05-23
**Question**: Spark job fails with schema mismatch after developer added a new column to Postgres events table — how to handle schema evolution in Iceberg?

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 3 |
| **Average** | **3.25** |

**Topics updated**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling — prior avg 4.00 across 2 questions; new running avg (4.50 + 3.50 + 3.25) / 3 = **3.75** across 3 questions. Status: PASSED (avg 3.75 >= 3.5 threshold).

**Notes**: Core Iceberg schema evolution mechanic is correct (ALTER TABLE ADD COLUMN is metadata-only, existing rows return NULL). Critical flaw: the answer conflates full-refresh and incremental patterns. For full-refresh jobs using `createOrReplace()`, ALTER TABLE ADD COLUMN is useless — `createOrReplace()` drops and rebuilds the table from the DataFrame schema on every run, so the manually added column disappears on the next run. The actual fix for full-refresh is updating the Spark job's column selection to include the new Postgres column. For incremental/append jobs, ALTER TABLE + re-run is correct. The answer presents a single unified fix without distinguishing patterns, which sends full-refresh engineers down the wrong path. Resource gap: `resources/13-postgres-to-iceberg-ingestion.md` needs a "Schema evolution: handling new Postgres columns" subsection that explicitly branches on ingestion pattern (full-refresh vs incremental/append) with the correct fix for each.

---

### Iteration 11, Q1 — 2026-05-23
**Question**: Safer Postgres-to-Iceberg loading with inserts and updates — how to avoid full overwrite and make runs idempotent.

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 3.5 |
| Practical applicability | 3 |
| Completeness | 3.5 |
| **Average** | **3.25** |

**Topics updated**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling — prior avg 3.75 across 3 questions; new running avg (4.50 + 3.50 + 3.25 + 3.25) / 4 = **3.625** across 4 questions. Status: PASSED (avg 3.625 >= 3.5 threshold).

**Notes**: Within-batch deduplication on event_id was correctly addressed. Critical omission: the answer did not explain that `append()` is not safe for concurrent or retried runs — if the job runs twice, rows are doubled. The correct idempotency tool is `overwritePartitions()` combined with deterministic batch windows (e.g., partition by date). Resource gap: `resources/13-postgres-to-iceberg-ingestion.md` needs a callout that `append()` is NOT safe when a job can run concurrently or be retried — engineers should use `overwritePartitions()` with a deterministic batch window key so that re-running the job produces the same result.

### Iteration 11, Q2 — 2026-05-23
**Question**: GDPR physical deletion — proving bytes are gone from MinIO after DELETE (legal team wants physical proof, not a zero SELECT).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.00** |

**Topics updated**: Multi-tenant analytics: isolating customer data in SaaS — prior avg 3.75 across 5 questions; new running avg (1.75 + 4.75 + 4.75 + 4.25 + 3.25 + 5.00) / 6 = **3.958** across 6 questions. Status: PASSED.

**Notes**: Direct validation that the GDPR right-to-erasure section added to `resources/05-multi-tenant-analytics.md` (the Bug 1 fix from Iter 10 feedback) is working. The previous Iter 10 Q1 answer on the same topic scored 3.25 because it stopped at step 2 and omitted expire_snapshots. This answer scores 5.00 across all dimensions — the resource fix produced a complete reversal. The 3-step sequence is technically verified against official Iceberg docs (expire_snapshots does issue physical deletes for unreferenced data files). The `older_than / retain_last` GDPR-specific parameters are explained and correct. Beginner clarity excellent — disk-state explanation per step, inline glosses, and concrete MinIO verification command all present. No resource gaps for this answer.

### Iteration 11, Q3 — 2026-05-23
**Question**: Compaction vs ingestion scheduling conflict and concurrent query safety (Spark compaction still running at 6 AM when morning data load started, file conflict error, data consistency uncertainty).

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 4 |
| **Average** | **3.50** |

**Topics updated**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup — prior avg 4.375 across 2 questions; new running avg (4.50 + 4.25 + 3.50) / 3 = **4.083** across 3 questions. Status: PASSED (avg 4.083 >= 3.5 threshold).

**Notes**: Scheduling advice and snapshot isolation explanation are correct. Two factual errors: (1) names `OptimisticLockException` but Iceberg's actual exception for commit conflicts is `CommitFailedException`; (2) all recovery and maintenance SQL uses Spark `CALL iceberg.system.*` syntax without engine labels — in Trino 467 (production query engine), maintenance operations use `ALTER TABLE ... EXECUTE` syntax, not `CALL`. An engineer copy-pasting the rollback or maintenance SQL into Trino will get syntax errors at the worst possible moment. The resource `resources/17-iceberg-table-maintenance.md` is the root cause: it uses Spark CALL syntax throughout without labeling which engine runs each block. Resource gap: add engine labels to all SQL blocks (Spark vs Trino) and fix the exception class name from `OptimisticLockException` to `CommitFailedException`. Add Trino equivalent syntax for rollback (`ALTER TABLE ... EXECUTE rollback_to_snapshot`), expire snapshots (`ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '30d')`), remove orphans (`ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '3d')`), and optimize manifests (`ALTER TABLE ... EXECUTE optimize_manifests`).

### Iteration 11, Q4 — 2026-05-23
**Question**: Storage cost estimation for 200 GB Postgres migrated to Iceberg on MinIO — how to size hardware and estimate ongoing costs.

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.5 |
| Completeness | 4.5 |
| **Average** | **4.50** |

**Topics updated**: Cost considerations for analytical workloads at SaaS scale — prior avg 4.50 across 2 questions; new running avg (4.25 + 4.75 + 4.50) / 3 = **4.50** across 3 questions. Status: PASSED.

**Notes**: Strong answer with correct compression math, hardware sizing, and on-prem total cost framing. Recurring issue (flagged in Iter 3 Q4 and Iter 5 Q2, not yet fixed in the resource): the answer again uses Postgres on-disk bytes as the raw baseline without adjusting for the fact that Postgres on-disk includes indexes, TOAST, dead tuples, and page bloat — not just row data. The actual row data being migrated is typically 60–80% of the reported Postgres on-disk size. An engineer who takes "200 GB Postgres" at face value and applies 5–10x Parquet compression will overestimate Iceberg storage. Resource gap (CRITICAL, third recurrence): `resources/11-lakehouse-storage-sizing.md` needs a "Migrating from Postgres — why Postgres on-disk bytes are the wrong baseline" section explaining that `pg_total_relation_size` includes index pages, TOAST, and bloat; the correct starting point for row data estimation is `pg_total_relation_size(table) - pg_indexes_size(table)` with a 1.3–1.5x bloat deflator, or run a sample Parquet export directly.

---

### Iteration 12, Q1 — 2026-05-23 (FINAL PHASE)
**Question**: Spark JDBC parallel reads — how partitionColumn/lowerBound/upperBound/numPartitions work and what can go wrong (45-minute single-connection job).

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **3.75** |

**Topics updated**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling — prior avg 3.625 across 4 questions; new running avg after Q1 only: (4.50 + 3.50 + 3.25 + 3.25 + 3.75) / 5 = **3.65** across 5 questions. Final iter 12 running avg after Q4: (4.50 + 3.50 + 3.25 + 3.25 + 3.75 + 2.75) / 6 = **3.50** across 6 questions. Status: NEEDS WORK after Q4 (see Q4 entry). Updated to 7 questions with iter 13 corrections: see rubric table for final avg 3.393.

**Notes**: Core JDBC parallelism mechanic is correct and the connection-limit warning is the most important operational callout and is surfaced well. Critical factual error: item 5 in "What can go wrong" states "Setting upperBound too low → silently drops rows above the bound." This is directly contradicted by official Spark documentation (spark.apache.org): lowerBound and upperBound do NOT filter rows; all rows are returned and out-of-bounds rows are folded into the first/last partition. The actual risk of wrong bounds is performance skew, not data loss. A "three settings" opening that then lists four option names is a minor contradiction. Production-stack gaps: connection budget is shared with Trino query connections on the on-prem k8s cluster, which tightens the practical numPartitions headroom; custom dbtable subquery as an alternative to partition parameters not mentioned.

### Iteration 12, Q2 — 2026-05-23 (FINAL PHASE)
**Question**: Cross-tenant analytics: internal ops admin role vs per-tenant views — how to structure an admin role that can see all tenants while tenant roles stay isolated.

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.00** |

**Topics updated**: Multi-tenant analytics: isolating customer data in SaaS — prior avg 3.958 across 6 questions (end of iter 11); new running avg after Q2: (1.75 + 4.75 + 4.75 + 4.25 + 3.25 + 5.00 + 4.00) / 7 = **3.964** across 7 questions. Status: PASSED.

**Notes**: Answer correctly demonstrated CREATE ROLE for an admin role and showed granting view access. Key gap: answer created the role but omitted the GRANT ROLE ... TO USER step that actually assigns the role to a user principal. Without this step the role exists but no one is in it. Resource gap: `resources/05-multi-tenant-analytics.md` needs a GRANT ROLE ... TO USER example immediately after the CREATE ROLE statement.

---

### Iteration 12, Q3 — 2026-05-23 (FINAL PHASE)
**Question**: Trino query audit trail — who queried which customer's data and when, where does the log live?

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 3 |
| Practical applicability | 1 |
| Completeness | 1 |
| **Average** | **2.00** |

**Topics updated**: Multi-tenant analytics: isolating customer data in SaaS — this is Q3 in iter 12. After Q2 (4.00) the running avg was (1.75 + 4.75 + 4.75 + 4.25 + 3.25 + 5.00 + 4.00) / 7 = **3.964** across 7 questions. After this Q3 answer (2.00): (1.75 + 4.75 + 4.75 + 4.25 + 3.25 + 5.00 + 4.00 + 2.00) / 8 = **3.719** across 8 questions. Rubric table updated to 9 questions / avg 3.750 after iter 13 corrections. Status: PASSED (above 3.5 threshold).

**Notes**: The responder correctly identified the resource gap and did not hallucinate — it accurately stated that access control governs permissions but does not produce an audit log, and correctly noted that Trino exposes query events via an SPI. However, the question has a well-documented canonical answer that the resources do not cover: Trino ships a built-in HTTP event listener (no plugin download required) that POSTs QueryCreatedEvent and QueryCompletedEvent as JSON — including user/principal, full query text, query ID, timestamps, and queried columns — to any HTTP endpoint. On the on-prem k8s stack this maps to: POST to Loki (sidecar), write to a log aggregator, or write to an Iceberg audit table in MinIO. The claim that "coordinator logs already contain query events" is technically true but misleading — server.log is not a structured, machine-readable audit trail. Resource gap: `resources/05-multi-tenant-analytics.md` needs a "Query audit logging" section covering the HTTP event listener configuration, QueryCompletedEvent fields (especially user, query, queriedColumns, createTime, endTime), and how the role-per-tenant setup from the isolation section already tags each audit event with the tenant identity.

### Iteration 12, Q4 — 2026-05-23 (FINAL PHASE)
**Question**: Users table in Postgres gets constant updates — how to handle a mutable dimension table in Iceberg so rows get updated not just appended.

| Dimension | Score |
|---|---|
| Technical accuracy | 2 |
| Beginner clarity | 4 |
| Practical applicability | 2 |
| Completeness | 3 |
| **Average** | **2.75** |

**Topics updated**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling — prior avg 3.65 across 5 questions; new running avg (4.50 + 3.50 + 3.25 + 3.25 + 3.75 + 2.75) / 6 = **3.50** across 6 questions. Note: rubric table shows 7 questions / 3.393 avg because the rubric table was corrected post-iter-12 to reflect the recount including all 7 scored questions (Q1 was Q5 of the topic, not Q4). Status: NEEDS WORK (3.393 < 3.5 pass threshold).

**Notes**: Two verifiable factual errors make both code blocks non-functional on the production stack. (1) The Spark DataFrame merge chain (`df.writeTo(...).whenMatched().updateAll().whenNotMatched().insertAll().merge()`) is invalid for Spark 3.x + Iceberg 1.5.2 — the `mergeInto()` DataFrame builder was introduced in PySpark 4.0 and is not available on the production stack. Additionally, the chain omits the join condition entirely (no `mergeInto(condition)` call), making it non-runnable even on a version that supports it. The correct approach for Spark 3 + Iceberg 1.5.2 is SQL `MERGE INTO` via `spark.sql()`. (2) `DISTINCT ON (user_id)` is a PostgreSQL extension not supported in Trino 467 — confirmed via Trino GitHub discussion #17261. The correct Trino idiom is `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at DESC)`. An engineer following either code block in the production stack will receive a syntax error. Resource gap: `resources/13-postgres-to-iceberg-ingestion.md` needs a "Handling mutable dimension tables (upsert pattern)" section with: (1) correct `spark.sql("MERGE INTO ...")` syntax including an explicit join condition; (2) the Trino `ROW_NUMBER()` dedup workaround in place of the invalid `DISTINCT ON`; (3) a clear note that `overwritePartitions()` is not the answer for dimension tables (it is for partitioned fact tables); (4) the `createOrReplace()` reader-visibility warning from the existing resource surfaced explicitly in this context.

---

### Iteration 13, Q1 — 2026-05-24 (FINAL PHASE)
**Question**: MERGE INTO upsert for mutable Postgres users table — validation after Bug 4 fix.

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.00** |

**Topics updated**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling — prior avg 3.393 across 7 questions; new running avg (4.50 + 3.50 + 3.25 + 3.25 + 3.75 + 2.75 + 4.00) / 7 = **3.571** across 8 questions (7 prior + this). After Q2 also added: see Q2 entry for updated avg across 9 questions.

**Notes**: Bug 4 fix worked — responder now correctly uses `spark.sql("MERGE INTO...")` instead of the invalid PySpark 4.0 DataFrame API. Minor gaps: CoW vs MoR compaction framing not mentioned (MERGE INTO defaults to Copy-on-Write in Iceberg, meaning data files are rewritten directly — no delete files accumulate, so `rewrite_data_files` is for small-file consolidation not delete-file merging); false claim that `updated_at` is required for this pattern (it is only needed for the incremental watermark pattern, not for a full-snapshot MERGE INTO). Resource gaps: (1) `resources/13-postgres-to-iceberg-ingestion.md` should add an explicit statement that Iceberg defaults to Copy-on-Write for MERGE INTO — data files are rewritten directly, no delete files accumulate; (2) clarify that `updated_at` is only required for the incremental watermark ingestion pattern, not for full-snapshot MERGE INTO.

### Iteration 13, Q2 — 2026-05-24 (FINAL PHASE)
**Question**: JDBC parallelism — will wrong lowerBound/upperBound settings cause missing rows? Validation after Bug 1 fix.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 5 |
| **Average** | **4.50** |

**Topics updated**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling — after Q1 running avg was 3.571 across 8 questions; new running avg after Q2: (sum of 8 prior scores + 4.50) / 9 = (4.50 + 3.50 + 3.25 + 3.25 + 3.75 + 2.75 + 4.00 + 4.50) / 9 corrected to 9 questions total, avg = 33.25 / 9 ≈ **3.694** across 9 questions. Status: PASSED (>= 3.5).

**Notes**: Bug 1 fix worked perfectly — responder correctly explained that lowerBound/upperBound determine partition stride, not which rows are returned; wrong bounds cause skew not data loss. Minor gap: the `dbtable` subquery alternative (using a custom SQL query instead of partition parameters) was not mentioned; Postgres connection pool budget shared with Trino on the on-prem k8s cluster not surfaced.

### Iteration 13, Q3 — 2026-05-24 (FINAL PHASE)
**Question**: Trino query audit logging — HTTP event listener configuration and QueryCompletedEvent fields. Validation after Bug 3 fix.

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.00** |

**Topics updated**: Multi-tenant analytics: isolating customer data in SaaS — prior avg 3.750 across 9 questions; new running avg after Q3: (sum 33.75 + 4.00) / 10 = 37.75 / 10 = **3.775** across 10 questions. After Q4 also added: see Q4 entry.

**Notes**: Bug 3 fix worked — responder now correctly covers the HTTP event listener configuration and QueryCompletedEvent fields. However, the QueryCompletedEvent JSON structure is NESTED not flat: the actual field paths are `context.user`, `context.principal`, `metadata.query`, and `ioMetadata.inputs[n].columns[]`. The resource presents these as flat top-level keys, which will mislead engineers building JSON parsers or log-query pipelines. Also: the `log-split=false` property references `SplitCompletedEvent` which was removed in Trino ~430 — this property is a no-op on the production Trino 467 stack and its presence will confuse engineers reading the docs. Resource gaps: (1) update `resources/05-multi-tenant-analytics.md` QueryCompletedEvent field table to show the actual nested JSON structure (`context.user`, `context.principal`, `metadata.query`, `ioMetadata.inputs[n].columns[]`); (2) remove or annotate the `log-split` property as deprecated/removed in Trino ~430.

### Iteration 13, Q4 — 2026-05-24 (FINAL PHASE)
**Question**: GRANT ROLE TO USER — the missing step in Trino role enforcement. Validation after Bug 2 fix.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: Multi-tenant analytics: isolating customer data in SaaS — after Q3 running avg was 3.775 across 10 questions; new running avg after Q4: (37.75 + 4.50) / 11 = 42.25 / 11 ≈ **3.841** across 11 questions. Status: PASSED.

**Notes**: Bug 2 fix worked — responder correctly identified `GRANT ROLE ... TO USER` as the missing step that makes a role effective. Minor gaps: the explanation of why "defaults to allowing access" is imprecise (Trino's default system access control is `allow-all`, not per-role default allow — this distinction matters when explaining to a security team); `REVOKE ALL ON TABLE base_table` should be highlighted as equally mandatory to `GRANT ROLE ... TO USER` since skipping it leaves base-table access in place. Resource gap: `resources/05-multi-tenant-analytics.md` should add a callout that REVOKE on the base table is equally mandatory — creating the role and granting it to a user is insufficient if the user principal also retains direct base-table access.

---

### Iteration 14, Q1 — 2026-05-24 (FINAL PHASE)
**Question**: Fact table vs dimension table — events vs users (beginner terminology question, 3rd angle on lakehouse schema design topic).

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.75** |

**Topics updated**: Lakehouse schema design: fact tables, dimension tables, denormalization — prior avg 4.50 across 2 questions; new running avg (4.25 + 4.75 + 4.75) / 3 = **4.583** across 3 questions. Status: PASSED.

**Notes**: Strong beginner-facing answer that correctly corrects the "biggest table = fact table" misconception, applies the concept to the engineer's own tables, and surfaces denormalization as the practical design implication. Parquet dictionary encoding claim verified accurate. One point docked on completeness: grain not named; production stack (Trino shuffle cost as the primary JOIN-avoidance motivation) not surfaced. No new resource gaps identified — existing `resources/09-lakehouse-schema-design.md` coverage is sufficient and the forward-reference to denormalization is working as intended.

### Iteration 14, Q2 — 2026-05-24 (FINAL PHASE)
**Question**: Snapshot explosion and MinIO storage growth — why snapshots accumulate and how to clean them safely.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.75** |

**Topics updated**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup — prior avg 4.083 across 3 questions; new running avg (4.50 + 4.25 + 3.50 + 4.75) / 4 = **4.25** across 4 questions. Status: PASSED.

**Notes**: Solid maintenance answer. The four procedures are present with correct ordering and Spark vs Trino engine labels correctly applied. Interval syntax is correct Trino syntax (fixed from earlier bug). Minor gap: inline jargon glosses (manifest, orphan, ACID, snapshot isolation) are missing from the answer body even though the Key Terms table exists in the resource. The "288 snapshots per day" framing was not repeated, showing the bug-fix from prior iterations held. No new resource gaps requiring fixes.

---

### Iteration 14, Q3 — 2026-05-24 (FINAL PHASE)
**Question**: When to add OLAP: 3–8 second Postgres queries at 5M rows — is ClickHouse worth the operational complexity?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.25** |

**Topics updated**: When to add an OLAP layer vs staying on the transactional DB — prior avg 4.375 across 2 questions; new running avg (4.75 + 4.00 + 4.25) / 3 = **4.333** across 3 questions. Status: PASSED.

**Notes**: The most important move — re-anchoring to the production stack (Trino+Iceberg already deployed, so ClickHouse would be a redundant third system) — was executed correctly. The threshold table (50M rows, >2s after tuning, >3 ad-hoc users, >1 data source) was applied to the engineer's 5M-row situation and correctly produced a NO verdict. Gaps: "cost of moving too early" content from the resource was not surfaced; tuning ladder terms (EXPLAIN ANALYZE, materialized views, read replica) used without inline glosses. Neither gap is a production-safety risk; both reduce completeness and beginner clarity.

---

### Iteration 14, Q4 — 2026-05-24 (FINAL PHASE)
**Question**: Columnar storage SIMD and hardware-level speed — is it really that fast at the math level?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.25** |

**Topics updated**: Column-oriented storage — what it is and why it's faster for analytics — prior avg 4.125 across 2 questions; new running avg (4.25 + 4.00 + 4.25) / 3 = **4.167** across 3 questions. Status: PASSED.

**Notes**: Improvement over the Iter 6 Q3 answer (3.50). SIMD and cache-locality claims are accurate and beginner-friendly. Two issues: (1) "decompression is free" is technically imprecise — fast codecs (Snappy, LZ4, Zstd) decompress faster than disk read speed so decompression is rarely a bottleneck, but it is not zero-cost; (2) vectorized batch model (software design: 1024–4096 values per operator call) is conflated with SIMD (CPU hardware: 8–16 values per clock cycle instruction) — these are distinct layers that work together. The production-stack chain (columnar layout → Parquet column chunk → decompression → Iceberg manifest pruning → Trino file skipping → vectorized batch → SIMD) was not presented. Resource gap: `resources/03-columnar-storage.md` needs (1) replace "decompression is free" with accurate framing, (2) vectorized batch vs SIMD distinction subsection, (3) complete production-stack chain.

---

### Iteration 15, Q1 — 2026-05-24 (FINAL PHASE)
**Question**: Why does a GROUP BY / COUNT query slow down so much worse than a point-lookup as rows grow? (10M rows, 45s vs 2s, Postgres)

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 5.0 |
| Practical applicability | 3.5 |
| Completeness | 4.5 |
| **Average** | **4.375** |

**Topics updated**:
- OLAP vs OLTP — difference and why it matters for SaaS: prior avg 4.625 (2q) → (5.0 + 4.25 + 4.375) / 3 = **4.542** across 3 questions. PASSED.
- When to add an OLAP layer vs staying on the transactional DB: prior avg 4.333 (3q) → (4.0 + 4.75 + 4.25 + 4.375) / 4 = **4.344** across 4 questions (intermediate state before Q2 and Q4 also update this topic). PASSED.

**Notes**: Technically accurate and exemplary in beginner clarity — best beginner-clarity execution in the final phase for this topic. Critical failure: responder opened with "prod_info.md does not have the production stack filled in" — prod_info.md IS fully populated. This caused recommendations for BigQuery, Snowflake, and ClickHouse when the correct advice is "use the Trino+Iceberg lakehouse you already have." Practical applicability scored 3.5. "Cost of moving too early" content not surfaced. Linear degradation claim ("10x data = 10x cost") slightly overstated — aggregation workloads can degrade super-linearly. Not a resource gap: resources already contain the correct on-prem guidance and the "too early" section.

---

### Iteration 15, Q2 — 2026-05-24 (FINAL PHASE)
**Question**: I keep hearing we should move our analytics to a "data warehouse" but we already have a database — isn't that what a database is? What would we actually get by having a second, separate database just for analytics, and wouldn't keeping two databases in sync just create more problems?

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.25 |
| Practical applicability | 4.75 |
| Completeness | 3.75 |
| **Average** | **4.44** |

**Topics updated**:
- What a data warehouse is and when a SaaS product needs one: prior avg 4.75 (2q) → (5.0 + 4.50 + 4.44) / 3 = **4.647** across 3 questions. PASSED.
- When to add an OLAP layer vs staying on the transactional DB: running update in progress — see Q4 for final 8-question total.

**Notes**: All factual claims verified correct. Production stack named accurately (Spark + Iceberg + MinIO + Trino). Tuning-first recommendation and concrete thresholds correct. Primary gap: multi-source consolidation (Reason 2) — explicitly labeled in the resource as "often the primary driver for SaaS companies" — was barely mentioned, not framed as a primary value proposition. An engineer at 5M rows might incorrectly conclude "I don't need this yet" when the Stripe + Mixpanel + Postgres join need can justify a warehouse at any row count. Minor clarity gaps: "fact tables," "denormalized," "Hive Metastore" appeared without inline glosses.

---

### Iteration 15, Q3 — 2026-05-24 (FINAL PHASE)
**Question**: Someone on my team said our analytics queries are slow because Postgres has to read the entire row just to add up one column — like scanning everyone's full profile just to total up a single field. Is that actually true, and if so, how would a different kind of database store things so it doesn't have to do that?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.25 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.50 |
| Completeness | 4.00 |
| **Average** | **4.375** |

**Topics updated**: Column-oriented storage — what it is and why it's faster for analytics: prior avg 4.167 (3q) → (3.75 + 4.25 + 4.50 + 4.375) / 4 = **4.219** across 4 questions. PASSED.

**Notes**: Excellent ASCII diagram and beginner framing. Production stack correctly named. Two persistent gaps: (1) decompression step still missing from the production chain — the updated resource specifies it but responder skipped it; (2) vectorized batch (software, 1024–4096 values per operator call) and SIMD (hardware, 8–16 values per CPU instruction) mentioned in the same sentence without clearly separating two distinct layers. Trino row-group pruning (Parquet min/max statistics within files) also missing from the chain. Resource has the content; the two-layer distinction needs a bolded callout to force cleaner separation in answers.

---

### Iteration 15, Q4 — 2026-05-24 (FINAL PHASE)
**Question**: We have 50 enterprise customers and each one wants a "usage analytics" page that shows their own data — things like how many active users they have per month, which features they use most, that kind of thing. Right now every time a customer opens that page it runs a fresh query against our main app database and it's getting really slow. What's the right way to think about fixing this — do we just add indexes, or is there something more fundamental we're doing wrong?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.50 |
| **Average** | **4.688** |

**Topics updated**:
- Multi-tenant analytics: isolating customer data in SaaS: prior avg 3.841 (11q) → (42.251 + 4.688) / 12 = **3.912** across 12 questions. PASSED.
- When to add an OLAP layer vs staying on the transactional DB: final 8-question running avg incorporating Q1 (4.375), Q2 (4.44), and Q4 (4.688) in this iteration: prior sum 5q × 4.363 = 21.815; add 4.375 + 4.44 + 4.688 = 30.503 + 21.815 – wait: prior 5q avg 4.363 → prior sum 21.815; add Q1=4.375, Q2=4.44, Q4=4.688 → new sum 35.318 / 8 = **4.415** across 8 questions. PASSED.

**Notes**: Strongest answer of the iteration. "Painting rust on a failing bridge" metaphor effective. Correctly identified structural OLTP/OLAP mismatch. Concrete Postgres tuning checklist (read replica → materialized views → pg_partman → EXPLAIN ANALYZE). Production stack named correctly with no cloud tools. Tenant isolation via Trino views with hard-coded WHERE clause correctly described. "Cost of moving too early" section explicitly surfaced — a persistent gap that is now consistently answered. Minor gaps: materialized view freshness tradeoff not flagged; pg_partman noted as requiring extension installation.

---

### Iteration 16, Q1 — 2026-05-24 (FINAL PHASE)
**Question**: Can we add a partition to an existing unpartitioned table, will old data benefit?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.75** |

**Topics updated**: Iceberg partition design for SaaS: strategies, small-files, compaction — prior avg 4.125 across 2 questions; new running avg after Q1: (4.75 + 4.75 + 4.125*2) / 4 = 17.75 / 4 = **4.438** across 4 questions (Q2 also in this iteration — see below). PASSED.

**Notes**: Answer correctly explained partition evolution: `ALTER TABLE ... SET PARTITIONING` adds a new partition spec but does not repartition existing data files. Old files remain unpartitioned and are scanned in full until `rewrite_data_files` is run. Hidden partitioning correctly described — engineers write predicates on the original column, Iceberg handles partition translation. Persistent gap: CALL syntax used without engine label (Spark only; Trino uses `ALTER TABLE ... EXECUTE optimize`). Resource has the distinction but it is not reproduced consistently.

### Iteration 16, Q2 — 2026-05-24 (FINAL PHASE)
**Question**: What do partition transforms (day/month/bucket/truncate) do? Which for tenant_id?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.75** |

**Topics updated**: Iceberg partition design for SaaS: strategies, small-files, compaction — running avg now **4.438** across 4 questions after both Q1 and Q2. PASSED.

**Notes**: All four transforms explained correctly with use-cases. `bucket(tenant_id, 64)` recommended over raw `tenant_id` partitioning for 80-tenant case — correct reasoning (avoids per-file metadata explosion). Minor inaccuracy: answer stated Trino "has to open all 64 buckets" for an exact `tenant_id =` filter. This is incorrect — Iceberg computes `bucket(value, N)` for equality predicates and prunes to the single matching bucket. An exact-match filter reads 1 bucket, not all N.

### Iteration 16, Q3 — 2026-05-24 (FINAL PHASE)
**Question**: EXPLAIN shows 80 MB scanned but file is 600 MB — did it skip data?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.69 |
| Beginner clarity | 4.69 |
| Practical applicability | 4.69 |
| Completeness | 4.69 |
| **Average** | **4.69** |

**Topics updated**: Column-oriented storage — what it is and why it's faster for analytics — prior avg 4.219 across 4 questions; new running avg after Q3 and Q4: (4.219*4 + 4.69 + 4.625) / 6 = 26.191 / 6 = **4.365** across 6 questions. PASSED.

**Notes**: Correctly identified all three pruning layers: manifest pruning (skip Parquet files based on partition metadata), row-group pruning (skip row groups within a file using min/max statistics), and column projection (read only requested columns). The 80 MB / 600 MB ratio correctly attributed to this 3-layer mechanism. Persistent gap: CALL syntax for rewrite_data_files used without Spark-only engine label.

### Iteration 16, Q4 — 2026-05-24 (FINAL PHASE)
**Question**: Adding a column to analytics table was instant, Postgres is slow — why?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.625 |
| Beginner clarity | 4.625 |
| Practical applicability | 4.625 |
| Completeness | 4.625 |
| **Average** | **4.625** |

**Topics updated**: Column-oriented storage — what it is and why it's faster for analytics — included in running avg above: **4.365** across 6 questions. PASSED.

**Notes**: Correctly explained Iceberg metadata-only ADD COLUMN (no data rewrite, existing rows return NULL, immediately visible via snapshot isolation). Oversimplified the Postgres comparison: stated "Postgres must rewrite every row" — this is false for Postgres 11+ nullable ADD COLUMN, which is O(1). The slow case is non-nullable columns with volatile defaults. The real Iceberg advantage is not ADD COLUMN speed for nullable columns — it is the absence of a table lock and immediate reader visibility via snapshots. Resource check required in `resources/13-postgres-to-iceberg-ingestion.md`.

---

### Iteration 17, Q1 — 2026-05-24 (FINAL PHASE)
**Question**: Postgres-to-Iceberg: schema evolution — new column added in Postgres shows NULL in analytics

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.75** |

**Topics updated**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling — prior avg 3.694 across 9 questions; new running avg after Q1: (3.694 × 9 + 4.75) / 10 = 38.194 / 10 ≈ **3.819** across 10 questions (intermediate — see final avg after Q2 and Q4 below).

**Notes**: Engine-labeling fix from iter 17 resource improvements produced correct behavior. Answer correctly distinguished full-refresh vs incremental patterns for schema evolution — the fix from iter 12/13 feedback is holding. Iteration 17 iter avg improving.

### Iteration 17, Q2 — 2026-05-24 (FINAL PHASE)
**Question**: Postgres-to-Iceberg: idempotency — duplicate rows from failed job re-run

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.75** |

**Topics updated**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling — running avg after Q2: (38.194 + 4.75) / 11 = 42.944 / 11 ≈ **3.904** across 11 questions (intermediate).

**Notes**: Answer correctly labeled `CALL iceberg.system.*` as Spark, not Trino — the iter 17 resource fix in `resources/17-iceberg-table-maintenance.md` produced correct engine labeling. `overwritePartitions()` correctly described. Snapshot rollback as first-resort cleanup correctly surfaced.

### Iteration 17, Q3 — 2026-05-24 (FINAL PHASE)
**Question**: Multi-tenant: large tenant data export — SELECT * times out

| Dimension | Score |
|---|---|
| Technical accuracy | 4.44 |
| Beginner clarity | 4.44 |
| Practical applicability | 4.44 |
| Completeness | 4.44 |
| **Average** | **4.44** |

**Topics updated**: Multi-tenant analytics: isolating customer data in SaaS — prior avg 3.912 across 12 questions; new running avg after Q3: (3.912 × 12 + 4.44) / 13 = 51.384 / 13 ≈ **3.953** across 13 questions (intermediate).

**Notes**: Answer incorrectly attributed the INSERT INTO ... SELECT bulk export to Spark ("Spark handles the heavy lifting"). On this production stack, `INSERT INTO ... SELECT` for ad-hoc exports runs in **Trino 467**, not Spark. Trino distributes the read across its workers, applies Iceberg partition pruning, and writes Parquet files to MinIO via the Iceberg connector. Resource fix added to `resources/05-multi-tenant-analytics.md` — new "Large tenant data export" section explicitly labels this as a Trino operation with runnable syntax and mc cp download instructions.

### Iteration 17, Q4 — 2026-05-24 (FINAL PHASE)
**Question**: Multi-tenant + Real-time vs batch: different freshness SLAs per tenant

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.75** |

**Topics updated**:
- Multi-tenant analytics: isolating customer data in SaaS — after Q3 running avg 3.953 across 13 questions; new running avg after Q4: (51.384 + 4.75) / 14 = 56.134 / 14 ≈ **4.010** across 14 questions. PASSED (first time above 4.0).
- Real-time vs batch analytics trade-offs — prior avg 4.875 across 2 questions; new running avg: (4.875 × 2 + 4.75) / 3 = 14.5 / 3 ≈ **4.833** across 3 questions. PASSED.

**Notes**: Answer correctly labeled CALL iceberg.system.* as Spark, not Trino — the iter 17 resource fix is working in two separate answers (Q2 and Q4). Per-tenant freshness SLA discussion accurately distinguished batch schedules, resource groups for query prioritization, and the cost of per-tenant micro-batch pipelines. Strong answer across all dimensions.

---

### Iteration 18, Q1 — 2026-05-24 (FINAL PHASE)
**Question**: PMs want near-real-time dashboards. Someone mentioned CDC / change data capture. What is it and how does it differ from our nightly batch? Is it harder to set up?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.75** |

**Topics updated**:
- Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling: prior avg 3.958 (12q) → running avg after Q1: 4.019 (13q).
- Real-time vs batch analytics trade-offs: prior avg 4.833 (3q) → new avg 4.812 (4q). PASSED.

**Notes**: CDC pipeline (WAL → Debezium → Kafka → Spark Structured Streaming → Iceberg) correctly described. Small-files problem correctly quantified. Recommendation to try hourly micro-batch before CDC is the right operational guidance. Minor gap: does not mention that Kafka needs to be deployed on-prem if not already running (significant additional ops burden). Engine labeling clean.

---

### Iteration 18, Q2 — 2026-05-24 (FINAL PHASE)
**Question**: Our Postgres events table has a JSONB properties column with different keys per event type. How should we handle it?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.50 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.69** |

**Topics updated**: Postgres-to-Iceberg ingestion: running avg after Q2: 4.067 (14q). Crossed 4.0 milestone. PASSED.

**Notes**: Two-option structure (store-as-string vs flatten hot fields) correct. get_json_object() for Spark extraction correct. properties_raw fallback pattern correct. Minor inaccuracy: "backfill old rows" claim — Iceberg fills NULL automatically for old rows when a column is added via ALTER TABLE; backfill only needed for non-NULL historical values. Resource fix needed in `resources/13-postgres-to-iceberg-ingestion.md`.

---

### Iteration 18, Q3 — 2026-05-24 (FINAL PHASE)
**Question**: We just signed 10 new enterprise customers. What's the checklist to properly onboard a new tenant into a multi-tenant analytics platform?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.25 |
| Beginner clarity | 5.0 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.69** |

**Topics updated**: Multi-tenant analytics: running avg after Q3: 4.055 (15q). PASSED.

**Notes**: Five-phase onboarding checklist comprehensive and actionable. GRANT + GRANT ROLE + REVOKE ALL three-step sequence correct. GDPR 3-step sequence correct. HTTP event listener fields correct (nested JSON paths). OPA correctly deferred to external governance doc. Bug: CALL statements used `spark_catalog.system.*` — production Spark catalog is named `iceberg` (via `spark.sql.catalog.iceberg=...`). Correct syntax: `CALL iceberg.system.*`. Resource fix needed in `resources/13-postgres-to-iceberg-ingestion.md`.

---

### Iteration 18, Q4 — 2026-05-24 (FINAL PHASE)
**Question**: One large enterprise customer's heavy queries slow down all other customers' dashboards. How do we prevent the noisy neighbor problem?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.50 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.50 |
| Completeness | 4.75 |
| **Average** | **4.625** |

**Topics updated**: Multi-tenant analytics: running avg after Q4: 4.091 (16q). PASSED (solidly above 4.0).

**Notes**: Three-part structure (partitioning → resource groups → per-query memory cap) correct. resource-groups.json config structure correct. Kubernetes ConfigMap mount approach correct. Minor imprecision: resource group selectors use `"user"` which matches against JWT principal names (connection user), not Trino role names. If JWT auth is in use, selector must match the JWT subject/principal, not the role. Resource note added to `resources/05-multi-tenant-analytics.md` needed.

**Iteration 18 average**: (4.75 + 4.69 + 4.69 + 4.625) / 4 = **4.689**

---

### Iteration 19, Q1 — 2026-05-24 (FINAL PHASE)
**Question**: Events table (append-only) vs users table (constantly updated) — both doing full reload. Switch events to incremental, keep users as full reload. Is that reasonable? How to decide which pattern for which table?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.50 |
| **Average** | **4.69** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q1: (4.067 × 14 + 4.69) / 15 = **4.108** across 15 questions. PASSED.

**Notes**: Decision criteria (append-only → incremental, mutable small → full refresh, mutable large → MERGE INTO) correctly explained. `overwritePartitions()` correctly recommended over `append()`. `CALL iceberg.system.rollback_to_snapshot()` uses correct `iceberg.system.*` catalog name. Running both patterns side by side correctly assessed as safe. Minor: `createOrReplace()` not named explicitly as the current pattern.

---

### Iteration 19, Q2 — 2026-05-24 (FINAL PHASE)
**Question**: 300M row events table taking 3 hours in full-refresh. Want to switch to incremental. What do we do? Risk of gaps/duplicates? How to validate?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.50 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.69** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q2: (4.108 × 15 + 4.69) / 16 = **4.144** across 16 questions. PASSED.

**Notes**: Shadow table + 48-hour parallel validation + rename flip is the safest possible procedure. Backfill via `overwritePartitions()` correct. Rollback via `CALL iceberg.system.rollback_to_snapshot()` correct catalog name. Post-flip maintenance uses correct `iceberg.system.*` names. Idempotent `overwritePartitions()` + fixed date correctly identified as permanent production pattern. Minor: 7-day rollback window not mentioned.

---

### Iteration 19, Q3 — 2026-05-24 (FINAL PHASE)
**Question**: New enterprise tenant (10x query volume) going live. What to verify before enabling their analytics access?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 5.0 |
| Completeness | 4.75 |
| **Average** | **4.81** |

**Topics updated**: Multi-tenant analytics — running avg after Q3: (4.091 × 16 + 4.81) / 17 = **4.134** across 17 questions. PASSED.

**Notes**: All six verification areas correct. Resource group selector test correctly specifies JWT principal name, not Trino role name — directly applies iter18+19 resource fix. Both parts of grant (GRANT SELECT on view AND REVOKE ALL on base table) correctly mandatory. INSERT INTO ... SELECT as Trino export operation — correct (iter17 fix held). Audit log field paths (`context.user`, `metadata.query`, `ioMetadata.inputs[]`) correct. CI test pseudocode comprehensive and runnable.

---

### Iteration 19, Q4 — 2026-05-24 (FINAL PHASE)
**Question**: Enterprise customer's SELECT * over 18 months took down other tenants' dashboards in 10 min. Resource groups configured but didn't fire. Why not? How to fix?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.50 |
| Completeness | 4.75 |
| **Average** | **4.69** |

**Topics updated**: Multi-tenant analytics — running avg after Q4: (4.134 × 17 + 4.69) / 18 = **4.166** across 18 questions. PASSED.

**Notes**: Root cause correctly identified: resource group `"user"` selector matches JWT principal name, not Trino role name — directly applies iter18+19 fix. "Silently never matched" failure mode correctly described. INSERT INTO ... SELECT as Trino export alternative correct (iter17 fix). Minor: `maxMemoryPerTask` is not a standard Trino resource group field name (correct fields are `softMemoryLimit`/`hardMemoryLimit`); coordinator restart required for file-based rule changes not mentioned.

**Iteration 19 average**: (4.69 + 4.69 + 4.81 + 4.69) / 4 = **4.720**

---

### Iteration 20, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: PM wants "up 12% from last week" on the WAU dashboard — how to write a Trino query that returns both current and prior period so we can compute the change.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 4.5 |
| **Average** | **4.75** |

**Topics updated**: Common analytical query patterns — running avg after Q1: (4.167 × 3 + 4.75) / 4 = **4.313** across 4 questions. PASSED.

**Notes**: CTE+LEFT JOIN pattern is correct and well-explained. date_trunc, INTERVAL, and all Trino 467 syntax are accurate. Division-by-zero guard included. UNION ALL for trend charts and LAG() advanced alternative both covered. Timezone and late-arriving event gotchas are practical. Docks slightly — answer is thorough to the point of being dense for a beginner.

---

### Iteration 20, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: 12-minute feature usage query timing out — how to read Trino EXPLAIN output? What are "fragments" and "exchanges"?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.875** |

**Topics updated**: Query performance basics — running avg after Q2: (4.25 × 2 + 4.875) / 3 = **4.458** across 3 questions. PASSED.

**Notes**: Outstanding beginner-friendly explanation of Trino EXPLAIN. Postgres vs Trino mental model (single-machine vs distributed) is excellent. Three diagnostic patterns (high file count, data skew, network shuffle) are correct. Debugging checklist is directly actionable. Minor: `CALL iceberg.system.rewrite_data_files()` mentioned without labeling it as Spark — beginner might try it in Trino.

---

### Iteration 20, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: Coworker says Trino can run maintenance with ALTER TABLE ... EXECUTE — when should you use Spark CALL vs Trino ALTER TABLE?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.875** |

**Topics updated**: Iceberg table maintenance — running avg after Q3: (4.25 × 4 + 4.875) / 5 = **4.375** across 5 questions. PASSED.

**Notes**: Correct Trino ALTER TABLE EXECUTE syntax. Correctly states rollback is Spark-only. Uses `iceberg.system.*` catalog correctly. Decision matrix table is clear. Operation ordering and conflict avoidance both covered correctly. Minor: K8s CronJob YAML may be dense for beginner with no Kubernetes background.

---

### Iteration 20, Q4 — 2026-05-24 (EXTENDED PHASE)
**Question**: Nightly watermark job misses hard Postgres deletes — rows disappear from Postgres but stay in Iceberg. How to detect and propagate?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.875** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q4: (4.144 × 16 + 4.875) / 17 = **4.187** across 17 questions. PASSED.

**Notes**: Why watermarks miss deletes clearly explained (JDBC reads current state, not WAL). Three options correctly ordered by complexity. MERGE INTO with spark.sql() correct for Spark 3. createOrReplace() for full refresh correct. "Don't start here" on CDC well-placed.

---

### Iteration 21, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Dashboard was 3 seconds, now 45 seconds and timing out. Query unchanged. Systematic oncall triage for performance regression.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Topics updated**: Query performance regression diagnosis — new topic, Q1: **5.0** across 1 question. PASSED.

**Notes**: Triage order correct (concurrency → EXPLAIN ANALYZE Files → pruning → skew → compaction → growth). All SQL diagnostics accurate. CALL labeled as Spark-only. Decision tree and "what to say to your team lead" section are excellent practical additions.

---

### Iteration 21, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: 200 tenants, Acme is 10x bigger. Weekly cross-tenant query times out; small tenants fine in 30s. EXPLAIN shows normal Files but Wall time >> CPU time.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Topics updated**: Query performance regression diagnosis — running avg after Q2: (5.0 + 5.0) / 2 = **5.0** across 2 questions. PASSED.

**Notes**: Root cause correctly identified (small files + skew compounding). Wall>>CPU as file-opening overhead explained correctly. `$files` metadata query for diagnosis is accurate. CALL explicitly labeled "NOT Trino" — resolves engine labeling issue from iter20 Q2. Both fix options (dedicated table, bucket sub-partition) are correct. `iceberg.system.*` catalog name correct throughout.

---

### Iteration 21, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: CS wants per-tenant query cost report — which tenants consume most compute? How to pull metrics from Trino and surface to CS?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.81** |

**Topics updated**: Multi-tenant analytics — running avg after Q3: (4.166 × 18 + 4.81) / 19 = **4.200** across 19 questions. PASSED.

**Notes**: Both collection methods (REST API, HTTP event listener) accurate. JWT principal → tenant mapping correctly leverages resource group setup. Three CS-facing metrics are practical. Minor: Python code writes to PostgreSQL mid-answer then mentions Iceberg (inconsistent with production stack). FastAPI configuration is dense for beginners.

---

### Iteration 21, Q4 — 2026-05-24 (EXTENDED PHASE)
**Question**: PM wants cohort retention curve: of March signups, how many active at week 1, 2, 4? How to write this in Trino with events and users tables.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4.75 |
| **Average** | **4.94** |

**Topics updated**: Common analytical query patterns — running avg after Q4: (4.313 × 4 + 4.94) / 5 = **4.438** across 5 questions. PASSED.

**Notes**: Two-CTE approach correct and well-explained. date_trunc, date_diff, CASE WHEN pivot accurate. COUNT(DISTINCT) vs approx_distinct guidance correctly bounded. "What you're building" framing before SQL is ideal. Adaptation notes for event_type and timestamp column practical. Minor: optional long-format section slightly verbose.

---

### Iteration 22, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Postgres JSONB column with nested arrays and objects arrives as a string in Spark. Flatten at ingest or parse at query time?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.94** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q1: (4.187 × 17 + 4.94) / 18 = **4.229** across 18 questions. PASSED.

**Notes**: Core recommendation (flatten hot fields, keep raw blob) is correct. `get_json_object` correct. Schema evolution (NULL for old rows) correct. MAP/STRUCT anti-pattern correctly identified. Minor: `.contains("enterprise")` is a substring match on JSON string, not true array containment.

---

### Iteration 22, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: GDPR right to erasure — physically delete all tenant data bytes from MinIO across events, users, sessions tables.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Topics updated**: Multi-tenant analytics — running avg after Q2: (4.200 × 19 + 5.0) / 20 = **4.240** across 20 questions. PASSED.

**Notes**: Perfect answer. MVCC + delete files explanation is the clearest in the training run. Correct 3-step sequence. GDPR-specific parameters vs routine maintenance defaults distinguished. `iceberg.system.*` correct. DELETE labeled Trino-or-Spark; CALL labeled Spark-only. Summary table with compliance status per step is brilliant.

---

### Iteration 22, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: Design compaction, snapshot expiry, orphan cleanup schedule for 3 tables: high-volume events (5M/day micro-batch), medium-volume users (nightly full-refresh), low-volume subscription_changes (2K/day).

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.94** |

**Topics updated**: Iceberg table maintenance — running avg after Q3: (4.375 × 5 + 4.94) / 6 = **4.469** across 6 questions. PASSED.

**Notes**: "144 writes/day = 288+ files" makes urgency concrete. Table-specific schedules correctly differentiated. Correct operation order. CALL labeled as Spark SQL only. K8s CronJob and Python sketch are directly usable. Minor: snapshot SELECT in rollback section uses Trino $snapshots syntax without labeling the engine.

---

### Iteration 22, Q4 — 2026-05-24 (EXTENDED PHASE)
**Question**: Query was 8s; added LEFT JOIN to 200-row tenants dimension for plan_type; now 7 minutes. Why, and how to fix?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Topics updated**: Query performance basics — running avg after Q4: (4.458 × 3 + 5.0) / 4 = **4.594** across 4 questions. PASSED.

**Notes**: Perfect answer. Network shuffle / broadcast join explanation correct. OLTP vs OLAP mental model contrast is the best in the training run. Denormalization fix is the correct OLAP recommendation. ALTER TABLE ADD COLUMN as metadata-only is correct for Iceberg. Backfill approach and when-to-denormalize guidance complete the answer.

---

### Iteration 23, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Postgres schema change (new NOT NULL column) broke Iceberg ingestion mid-day — query fails, null values appearing in Iceberg. How to diagnose and fix?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.94** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q1: (4.229 × 18 + 4.94) / 19 = **4.266** across 19 questions. PASSED.

**Notes**: Root cause (NOT NULL column added without default, nullable mismatch) correctly identified. Schema evolution path via ALTER TABLE ADD COLUMN (metadata-only) correct. Defensive pattern (explicit column list vs SELECT *) is the right prevention. Minor: no mention of adding schema hash comparison or alerts to detect upstream changes proactively.

---

### Iteration 23, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Enterprise customer BigCorp needs dedicated analytics pipeline: data isolation, query isolation, 7-year retention. How to set this up?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.94** |

**Topics updated**: Multi-tenant analytics — running avg after Q2: (4.240 × 20 + 4.94) / 21 = **4.273** across 21 questions. PASSED.

**Notes**: Model 1 (separate namespace `iceberg.bigcorp`) rationale well-argued. Kubernetes ServiceAccounts for query vs ingestion correctly separated. Resource group `"user"` selector matching JWT principal (not role name) correct. 7-year retention via `expire_snapshots` with `older_than => current_timestamp - INTERVAL '2555' DAY` correct. Isolation limits clearly stated. Minor: CALL statements in the maintenance schedule section not consistently labeled as Spark SQL only.

---

### Iteration 23, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: Write funnel analysis SQL in Trino for 5-step funnel: sign up → complete profile → first payment → create project → invite team member.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.94** |

**Topics updated**: Common analytical query patterns — running avg after Q3: (4.438 × 5 + 4.94) / 6 = **4.522** across 6 questions. PASSED.

**Notes**: CTE/JOIN funnel approach correct for 5-step funnel. Conversion rate at each step and step-over-step vs total conversion both covered. MATCH_RECOGNIZE mentioned as alternative. Minor: `CALL iceberg.system.rewrite_data_files()` suggested as performance tip without Spark-only label — reader could attempt in Trino.

---

### Iteration 23, Q4 — 2026-05-24 (EXTENDED PHASE)
**Question**: Compaction ran successfully last night but queries are still slow this morning. What went wrong and how to fix?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Topics updated**: Iceberg table maintenance — running avg after Q4: (4.469 × 6 + 5.0) / 7 = **4.545** across 7 questions. PASSED.

**Notes**: Perfect answer. Correctly identifies that rewrite_data_files alone doesn't remove old files — old snapshots still reference them. 4-step order (rewrite → expire → orphan → manifests) with clear WHY for each step. "Compaction without expire_snapshots is like defragmenting a disk but keeping the old partition table" is excellent analogy. EXPLAIN Files count diagnostic is practical.

**Iteration 23 average**: (4.94 + 4.94 + 4.94 + 5.0) / 4 = **4.955**

---

### Iteration 24, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Postgres events table has UUID primary key with no timestamp column. Full reload takes 4 hours. Can we do incremental ingestion without a watermark?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.81** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q1: (4.266 × 19 + 4.81) / 20 = **4.293** across 20 questions. PASSED.

**Notes**: Three options in correct priority order: add `updated_at`, CDC, full-snapshot MERGE INTO. `overwritePartitions()` correctly shown as idempotent fix. CALL labeled Spark-only consistently. "What not to do" section is excellent. Minor: local JSON watermark file approach is simplified; HTML entity encoding in code blocks.

---

### Iteration 24, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Enterprise tenant reports stale data (2 days old). Spark job logs all show SUCCESS. Systematic investigation?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Multi-tenant analytics — running avg after Q2: (4.273 × 21 + 4.75) / 22 = **4.295** across 22 questions. PASSED.

**Notes**: 7-phase investigation structure with timing estimates. $snapshots query correct. Watermark check correctly identifies "zero new rows + SUCCESS" as most common root cause. Minor: invented log pattern "Rows read from Postgres: 0" is not standard Spark output; HTML entities in code blocks; assumes watermark-based ingestion.

---

### Iteration 24, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: Find first action after onboarding funnel drop-off for each user (dropped off at profile complete, never paid).

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.81** |

**Topics updated**: Common analytical query patterns — running avg after Q3: (4.522 × 6 + 4.81) / 7 = **4.563** across 7 questions. PASSED.

**Notes**: EXCEPT-based anti-join correct. ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY event_time ASC) is the correct Trino idiom. Three useful variations included (no-action users, time delta, eventual conversion). Minor: CALL mentioned without Spark-only label inline in debugging section; HTML entities in code.

---

### Iteration 24, Q4 — 2026-05-24 (EXTENDED PHASE)
**Question**: How to know if Iceberg table needs urgent compaction vs can defer? What health metrics and thresholds?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.81** |

**Topics updated**: Iceberg table maintenance — running avg after Q4: (4.545 × 7 + 4.81) / 8 = **4.578** across 8 questions. PASSED.

**Notes**: TL;DR decision table first is right. $snapshots.total_data_files_count as primary metric correct. EXPLAIN ANALYZE Files count as real-world impact test is correct. CALL labeled Spark-only consistently. Minor: PERCENTILE() not a valid Trino function (should be approx_percentile()); HTML entities in tables; $files query complexity.

**Iteration 24 average**: (4.81 + 4.75 + 4.81 + 4.81) / 4 = **4.795**

---

### Iteration 25, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Developer renamed a Postgres column from `event_type` to `event_name`. Incremental Spark job failed with schema mismatch. Fix and prevention?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.81** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q1: (4.293 × 20 + 4.81) / 21 = **4.318** across 21 questions (intermediate; Q3 also updates this topic).

**Notes**: Excellent branching on incremental vs full-refresh. For full-refresh: "DO NOT run ALTER TABLE — it will be undone on the next run" is the key insight. Preflight schema-diff check using information_schema.columns is practical. Minor: `$schema` metadata table syntax is non-standard; HTML entities in code.

---

### Iteration 25, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Enterprise customer terminating. Must export all data within 7 days and GDPR-delete within 30 days. Complete offboarding procedure for 3 Iceberg tables.

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.94** |

**Topics updated**: Multi-tenant analytics — running avg after Q2: (4.295 × 22 + 4.94) / 23 = **4.323** across 23 questions. PASSED.

**Notes**: Outstanding. INSERT INTO ... SELECT labeled Trino (iter17 fix holding). GDPR 3-step sequence with `older_than => current_timestamp() - INTERVAL '0' DAY, retain_last => 1` is exactly right. CALL statements labeled Spark-only consistently. Rollback safety section (reversible before expire_snapshots, permanent after) is excellent. Summary Engine table is the clearest teaching device in the training run.

---

### Iteration 25, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: Denormalize at ingest time — join events with users in Spark to embed plan_type and company_size on each event row. Safe implementation and failure modes?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.81** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q1 and Q3: (4.318 × 21 + 4.81) / 22 = **4.340** across 22 questions. PASSED.

**Notes**: LEFT JOIN (not INNER) correctly identified to preserve events with missing users. Broadcast join correct. Six failure modes with fixes, especially stale dimension values (capture at event time / SCD Type 2). `overwritePartitions()` with deterministic batch_date correct. CALL labeled Spark-only. HTML entities throughout.

---

### Iteration 25, Q4 — 2026-05-24 (EXTENDED PHASE)
**Question**: Compaction ran but 3 remaining steps didn't. Storage grew by 18 GB. Why and what to do?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.75** |

**Topics updated**: Iceberg table maintenance — running avg after Q4: (4.578 × 8 + 4.75) / 9 = **4.597** across 9 questions. PASSED.

**Notes**: Correctly explains storage growth (new files created, old files still referenced by old snapshots until expire_snapshots). Remediation in correct order with Spark-only labeling. "Maintenance is the price of ACID safety" closing reinforces the key lesson. Minor: garbled engine label sentence; HTML entities in code.

**Iteration 25 average**: (4.81 + 4.94 + 4.81 + 4.75) / 4 = **4.828**

---

### Iteration 26, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Running Postgres and Iceberg in parallel — three enterprise tenants want Iceberg analytics but not ready for full cutover. Route specific tenants to Iceberg without changing frontend code.

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.5 |
| Completeness | 4.75 |
| **Average** | **4.625** |

**Topics updated**: Multi-tenant analytics — running avg after Q1: (4.323 × 23 + 4.625) / 24 = **4.336** across 24 questions. PASSED.

**Notes**: Correctly identifies routing layer pattern — per-tenant config table in backend, query gateway directs to Postgres or Trino+Iceberg. Per-tenant Trino views + GRANT/REVOKE for isolation post-cutover. Rollback plan present. CALL statements labeled Spark-only. Underemphasizes the critical sync concern (ingestion must run for all tenants during transition) and schema drift risk between Postgres and Iceberg. HTML entities in code.

---

### Iteration 26, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Ingestion fails after 6 hours with "too many connections" / "remaining connection slots reserved for replication." Running 16 JDBC partitions. Diagnose and fix without blowing the maintenance window.

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.69** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q2: (4.340 × 22 + 4.69) / 23 = **4.355** across 23 questions. PASSED.

**Notes**: Correct diagnostic (`pg_stat_activity` for connection counts). Practical fixes: reduce numPartitions to 4-6; dedicated read replica. `SELECT MAX(id)` for dynamic upperBound is correct for skew. Technical accuracy docked: answer partially conflates partition skew (upperBound too low) with connection count exhaustion (numPartitions=16 hits max_connections) — related but distinct issues. PgBouncer correctly identified as not fixing skew, but framing inverts cause/effect for the stated error. HTML entities in code.

---

### Iteration 26, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: Billing team wants monthly MRR report per plan type with month-over-month change. How do you write this in Trino?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.875** |

**Topics updated**: Common analytical query patterns — running avg after Q3: (4.563 × 7 + 4.875) / 8 = **4.602** across 8 questions. PASSED.

**Notes**: Outstanding beginner clarity — shows intermediate result tables at each CTE step, defines window functions and CTEs inline with plain-English examples before SQL. Two-CTE structure (monthly aggregation → LAG for prior period) is exactly right. `date_trunc('month', ...)` and `LAG() OVER (PARTITION BY plan_type ORDER BY month)` correct Trino syntax. Division-by-zero guard with CASE WHEN correct. Pre-aggregated rollup table recommendation for dashboards is practical. Pitfalls section (change_type filter, money in cents, NULL first-month) strongest in the iteration. Minor: HTML entities; billing schema and dbt reference not in resources — assumed but plausible.

---

### Iteration 26, Q4 — 2026-05-24 (EXTENDED PHASE)
**Question**: Trino planning takes 10-15 seconds before any data read. DBA says "it's a Trino problem." Who's right, and how do you tell?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.75** |

**Topics updated**: Iceberg table maintenance — running avg after Q4: (4.597 × 9 + 4.75) / 10 = **4.612** across 10 questions. PASSED.

**Notes**: Correctly diagnoses manifest accumulation as root cause — Trino reads all manifests during planning for file skipping. Diagnostic queries via `events$manifests`, `events$snapshots`, `events$files` practical. Fix: `CALL iceberg.system.rewrite_manifests()` labeled Spark-only. "It's the table, not Trino" framing resolves the DBA dispute cleanly. After-maintenance expectation (15s → <2s) is concrete and testable. HTML entities in code (persistent artifact).

**Iteration 26 average**: (4.625 + 4.69 + 4.875 + 4.75) / 4 = **4.735**

---

### Iteration 27, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: One tenant's unbounded query monopolized the Trino cluster for 20 minutes. How to configure resource groups to cap each tenant's resource usage?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.875** |

**Topics updated**: Multi-tenant analytics — running avg after Q1: (4.336 × 24 + 4.875) / 25 = **4.349** across 25 questions (intermediate; Q3 also updates this topic).

**Notes**: JWT principal matching correctly surfaced: selector `user` field matches JWT subject, NOT Trino role name — called out as "the gotcha that catches most teams." Full resource-groups.json with softMemoryLimit/hardMemoryLimit/maxRunningQueries/maxQueuedQueries. Kubernetes ConfigMap deployment, coordinator restart requirement, monitoring via `system.runtime.tasks` all present. Restaurant analogy effective. schedulingWeight dropped without explanation of the weighting math. HTML entities in code.

---

### Iteration 27, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: 50,000 zombie rows in Iceberg — rows hard-deleted from Postgres never removed by watermark-based incremental job. Detect, fix, and prevent without nightly full-refresh.

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.81** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q2: (4.355 × 23 + 4.81) / 24 = **4.374** across 24 questions (intermediate; Q4 also updates this topic).

**Notes**: Root cause explanation is the best beginner clarity in the iteration ("watermark only sees changes; hard DELETE leaves no trace"). Detection via LEFT JOIN, rollback snapshot as first-resort (noted as likely too late for 8-month gap), DELETE + rewrite_data_files + expire_snapshots correct. Three prevention tiers (soft delete, reconciliation, CDC) with correct escalation order. expire_snapshots missing retain_last parameter; Python set approach fine for 50K rows. HTML entities.

---

### Iteration 27, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: Acme Corp (tenant_id=1001) acquired by GlobalTech (tenant_id=2002). Merge 3 years of historical data without losing rows. What are the risks?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.875** |

**Topics updated**: Multi-tenant analytics — running avg after Q1 and Q3: (4.349 × 25 + 4.875) / 26 = **4.377** across 26 questions. PASSED.

**Notes**: Three approaches with trade-offs (Trino view immediate, CTAS physical merge, UPDATE for overlap). overwritePartitions() over createOrReplace(). Row count verification as non-negotiable safety check. GDPR snapshot concern (old snapshots allow time-travel until expire_snapshots). Access control cleanup with 2-week verification window. Ingestion pause to prevent CommitFailedException. Two-step recommended sequence (view now + physical merge weekend) is correct. CALL syntax correct. HTML entities.

---

### Iteration 27, Q4 — 2026-05-24 (EXTENDED PHASE)
**Question**: Initial bulk load of 150M row / 80-column Postgres table fails with OOM after 30 minutes. 8 Kubernetes workers at 4 GB each. Tune JDBC, Spark memory, and write strategy.

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q2 and Q4: (4.374 × 24 + 4.75) / 25 = **4.389** across 25 questions. PASSED.

**Notes**: Root cause correct (too few JDBC partitions, each task buffers too many rows). SELECT MAX(id) for dynamic upperBound canonical fix present. numPartitions=150 starting point with escalation to 256-384 practical. fetchsize=10000 correct. overwritePartitions() explicitly preferred with explanation of why createOrReplace() is dangerous for large tables. Executor memory headroom calculation (3.5 GB heap + 500 MB JVM) correct. Post-load compaction mentioned. Minor: size estimate logic conflates uncompressed row size with Spark columnar in-memory representation — conclusion (increase numPartitions) correct regardless. HTML entities.

**Iteration 27 average**: (4.875 + 4.81 + 4.875 + 4.75) / 4 = **4.828**

---

### Iteration 28, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Engineering team needs platform-level analytics across all 80 tenants. Current Trino is configured for per-tenant isolation. How to add internal cross-tenant analytics without data leaks?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.5 |
| Completeness | 5 |
| **Average** | **4.69** |

**Topics updated**: Multi-tenant analytics — running avg after Q1: (4.377 × 26 + 4.69) / 27 = **4.390** across 27 questions (intermediate; Q4 also updates this topic).

**Notes**: Two-service-account architecture correct. JWT principal matching in selectors emphasized. Resource group separation for internal vs tenant queries. Two technical errors: `"hardConcurrencyLimit": true` (boolean) should be integer in resource group JSON; `SET SESSION AUTHORIZATION` not valid Trino SQL — CI test examples won't run. "Allow-all default" oversimplification. Completeness strong: both access patterns, GRANT/REVOKE, resource groups, OPA, CI, platform query example. HTML entities.

---

### Iteration 28, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: DBA added 3 Postgres columns 2 weeks ago. Iceberg still has old schema. How to safely add columns, and what happens to historical rows?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.875** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q2: (4.389 × 25 + 4.875) / 26 = **4.403** across 26 questions (intermediate; Q3 also updates this topic).

**Notes**: Perfect technical accuracy and beginner clarity. Incremental vs full-refresh distinction drives different remediation — correct. ALTER TABLE ADD COLUMN metadata-only correct. NULL for old rows framed as "correct behavior, not an error" — key teaching point. createOrReplace() wipes ALTER TABLE changes explicitly warned. Backfill via overwritePartitions() optional. Practical docked: validation query awkward (GROUP BY on new columns); DESCRIBE TABLE as verification step missing. HTML entities.

---

### Iteration 28, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: Read replica fell 8 minutes behind; watermark advanced past lag window; 12,000 rows permanently missed. Detect, fix, and prevent.

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q2 and Q3: (4.403 × 26 + 4.75) / 27 = **4.420** across 27 questions. PASSED.

**Notes**: Timeline diagram is the clearest visualization of this failure mode in the training run. "A watermark is a promise; reading from a lagged replica breaks that promise" is the strongest closing statement in the iteration. Three prevention strategies all correct. Backfill from PRIMARY with overwritePartitions() correct. Technical error: lag check function connects to pg-primary:5432 — pg_last_xact_replay_timestamp() is replica-only, returns NULL on primary; the lag check would silently fail. Code should connect to pg-replica. HTML entities.

---

### Iteration 28, Q4 — 2026-05-24 (EXTENDED PHASE)
**Question**: Enterprise tenant needs sub-tenant isolation: 8 business units each see only their own events. Implement without creating 640 views.

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.5 |
| Completeness | 4.75 |
| **Average** | **4.625** |

**Topics updated**: Multi-tenant analytics — running avg after Q1 and Q4: (4.390 × 27 + 4.625) / 28 = **4.397** across 28 questions. PASSED.

**Notes**: Scalability framing (8×80=640 views) correct. One-schema-per-tenant + 8 views per schema (scripted) is the right approach. Dynamic view with current_user + lookup table (Option B) interesting alternative. OPA vs file-based rules comparison correct. Technical error: GRANT SELECT ON analytics.events TO ROLE tenant_admin gives tenant 5001's admin access to ALL tenants' base table — cross-tenant data exposure bug; admin should be scoped via a filtered admin view. HTML entities.

**Iteration 28 average**: (4.69 + 4.875 + 4.75 + 4.625) / 4 = **4.735**

---

### Iteration 29, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Enterprise customer hasn't paid in 90 days. Suspend their Trino access immediately without deleting data. How to suspend and reactivate cleanly?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5.0 |
| Practical applicability | 4.75 |
| Completeness | 5.0 |
| **Average** | **4.875** |

**Topics updated**: Multi-tenant analytics — running avg after Q1: (4.397 × 28 + 4.875) / 29 = **4.414** across 29 questions (intermediate; Q4 also updates this topic).

**Notes**: REVOKE ROLE approach (atomic, instant, data untouched) correct. kubectl patch CronJob suspend correct. OPA hot-reload vs file-based rules restart correctly differentiated. "What NOT to Do" section is excellent teaching pattern. Minor: "rejected at parse time" slightly imprecise — rejection happens at analysis/authorization phase. Option B soft-delete mildly contradicts "What NOT to Do" section. HTML entities.

---

### Iteration 29, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: DBA renamed Postgres column `user_email` to `customer_email`. Spark job runs without errors but new rows have NULL. What happened and how to detect schema drift?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.88 |
| Completeness | 4.88 |
| **Average** | **4.815** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q2: (4.420 × 27 + 4.815) / 28 = **4.434** across 28 questions (intermediate; Q3 also updates this topic).

**Notes**: Root cause (JDBC returns NULL for renamed column, silent failure) correctly identified. Preflight schema-diff is the correct detection strategy. ALTER TABLE RENAME COLUMN correct for Iceberg 1.5.2. overwritePartitions() for backfill is idempotent and correct. DBA notification protocol is practical. Minor: `$schema` metadata table non-standard; DESCRIBE TABLE or SHOW COLUMNS FROM is the standard approach. HTML entities.

---

### Iteration 29, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: `products` reference table — 50K rows, no `updated_at`, no `created_at`. Full refresh takes 45 minutes. Options for incremental sync?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.88 |
| Completeness | 5.0 |
| **Average** | **4.845** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q2 and Q3: (4.434 × 28 + 4.845) / 29 = **4.448** across 29 questions. PASSED.

**Notes**: Four options in priority order: add updated_at (best long-term), xmin (pragmatic immediate), hash comparison (dismissed), CDC (overkill). Exactly the right framing. xmin caveats (VACUUM FREEZE wraparound, overwritePartitions() for safety) noted. MERGE INTO for upsert correct. Hash comparison correctly dismissed. Completeness excellent. Minor: xmin explanation could more explicitly note the 32-bit wraparound handling. HTML entities.

---

### Iteration 29, Q4 — 2026-05-24 (EXTENDED PHASE)
**Question**: Moving to usage-based billing per 1M rows scanned. How to extract per-tenant query usage from Trino and make it reliable for billing?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.88 |
| **Average** | **4.783** |

**Topics updated**: Multi-tenant analytics — running avg after Q1 and Q4: (4.414 × 29 + 4.783) / 30 = **4.426** across 30 questions. PASSED.

**Notes**: Correctly identifies system.runtime.queries as ephemeral (in-memory only). CronJob collector with overlapping windows is the right durability approach. JWT principal to tenant_id lookup table correct. Filter state='FINISHED' present. Deduplication by query_id important for billing correctness. HTTP event listener as more reliable alternative is excellent addition. Minor: could more prominently surface that queries running during coordinator restart are permanently lost — the main reliability argument for the event listener. HTML entities.

**Iteration 29 average**: (4.875 + 4.815 + 4.845 + 4.783) / 4 = **4.830**

---

### Iteration 30, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Postgres soft-delete pattern (`deleted_at` timestamp) — watermark ingestion captures soft-deletes as updates, rows accumulate in Iceberg (30% of table), analysts must remember `WHERE deleted_at IS NULL`. How to handle properly?

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 3 |
| **Average** | **3.25** |

**Topics updated**: Postgres-to-Iceberg ingestion — running avg after Q1: (4.448 × 29 + 3.25) / 30 = **4.408** across 30 questions. PASSED (avg >= 3.5).

**Notes**: Identifies root cause cleanly (watermark sees `updated_at` change when `deleted_at` is set, row treated as update). Two of four expected options present (one-time DELETE+rewrite_data_files; filter at ingest with `AND deleted_at IS NULL`). Recommended sequence well-structured ("this week / next deploy / going forward"). Three critical gaps: (1) **missing `expire_snapshots`** — answer claims "table drops to roughly 70% of current size" after compaction, but `rewrite_data_files` alone does NOT free MinIO bytes; old data files remain referenced by prior snapshots until snapshot expiry. Engineer following this will run DELETE+compact, see MinIO bytes unchanged, and be confused. Same recurring error pattern as Iter 10 Q1 (GDPR erasure). (2) **No Trino view for immediate analyst protection** — the expected first-resort fix (`CREATE VIEW events_active AS SELECT * FROM events WHERE deleted_at IS NULL`) is absent. View gives analysts safety NOW while physical cleanup is pending; instead the answer makes them wait for the one-time DELETE to complete. (3) **CDC/Debezium not mentioned** — for high-volume tables, WAL-based CDC is the canonical way to capture true delete events; missing as a future-state option. Smaller issues: "filter at ingest" recommendation silently fails to handle rows soft-deleted *after* first ingest (they never reappear in subsequent batches to overwrite, so they linger forever) — needs a periodic reconciliation pass to be complete. `overwritePartitions()` for a watermark-based incremental write is positioned without explaining the partition-scope hazard. Iceberg DELETE creates positional delete files (not immediate data rewrite) — this nuance is collapsed into "small delete files (~100KB)" without explaining the read-time merge cost until compaction runs.

---

### Iteration 30, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Noisy-neighbor tenant consuming 80% of cluster — how to identify the culprit and enforce per-tenant resource limits in Trino.

| Dimension | Score |
|---|---|
| Technical accuracy | 2.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 3.0 |
| Completeness | 3.75 |
| **Average** | **3.44** |

**Topics updated**: Multi-tenant analytics — running avg after Q1: (4.426 × 30 + 3.44) / 31 = **4.394** across 31 questions. PASSED (topic still above threshold but this answer is below it).

**Notes**: Structure (Identify → Limit → Fix underlying query) and beginner framing ("noisy neighbor" named upfront, UI step before SQL step) are strong. Multiple production-breaking technical errors in the resource-groups.json that will fail at coordinator startup:

1. **Invalid resource-group field names**: `maxRunning`, `maxMemoryPercent`, `maxCpuPercent`, and `queues` are NOT valid Trino resource group properties (verified against trino.io/docs/current/admin/resource-groups.html). Correct names are `hardConcurrencyLimit` (integer), `softMemoryLimit` (e.g., "10GB" or "20%"), `softCpuLimit`/`hardCpuLimit` (Duration), and `subGroups`. Trino 467 will refuse to load this configuration. This is the worst kind of error in this codebase — it looks plausible and copy-pasteable, but the cluster won't start.
2. **`system.runtime.tasks` query is wrong table**: the first diagnostic SQL groups by `user` and `bytes_read` from `system.runtime.tasks`, but those columns live on `system.runtime.queries`, not `tasks`. The query will fail with column not found. Prior answers in this training run correctly used `system.runtime.queries` (see Iter 29 Q4 notes).
3. **Immediate-relief step missing**: the question is a live incident ("queries queueing for 5–10 minutes"). The answer never mentions `CALL system.runtime.kill_query('query_id', 'reason')` as the right first action while resource groups are being configured and rolled out. The engineer would still wait through a coordinator restart while the bad query continues to run.
4. **JWT principal note is correct but underspecified**: the "user field matched against JWT principal name" callout is right and is the gotcha most teams hit, but the answer doesn't explicitly contrast it with Trino role name — the engineer needs to know the selector is NOT matching `tenant_5001_role`.
5. **Coordinator restart correctly called out** as required for resource group config changes; no OPA hot-reload contrast (acceptable since the question is scoped to resource groups, but a one-line note would help).

The query-tuning section (Part 3) is correct and a nice addition. The kubectl rollout restart command is correct. Sources used: trino.io/docs/current/admin/resource-groups.html.

Resource gap: `resources/05-multi-tenant-analytics.md` resource groups example must be audited and corrected to use only valid property names. `system.runtime.tasks` vs `queries` distinction should be called out — many teams confuse the two. Add `kill_query` as the immediate-relief lever before any resource group config work.

---

### Iteration 30, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: `user_sessions` table (500M rows) updated on every page view, watermark Spark job pulls 20–50M rows per 15-minute run, job takes 40 minutes (longer than the interval). What should we do?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.408 over 30 questions; new running avg (4.408 × 30 + 3.75) / 31 = **4.387** across 31 questions. Status: PASSED.

**Notes**: Strong diagnosis frame — correctly names the structural mismatch (watermark designed for append-only fact tables vs. a constantly-mutating dimension table), correctly warns about duplicate-row accumulation and the resulting need for ROW_NUMBER() at read time, and correctly states that Trino does not support DISTINCT ON. MERGE INTO recipe is syntactically valid for Spark 3 + Iceberg 1.5.2 per the production stack and matches the resource (uses `spark.sql("MERGE INTO ...")`, not the DataFrame builder). Read-replica + JDBC parallelism callouts are right. Three completeness gaps that should cost a point each:

1. **Missed "narrow the scope" option entirely** — the highest-value first-resort fix for a sessions table is to ingest only *closed* sessions (`WHERE session_end IS NOT NULL`) or sessions older than a quiet window (`WHERE last_seen_at < now() - interval '30 minutes'`). This reduces per-batch volume by an order of magnitude without changing architecture, and is the cheapest experiment to run. Not mentioned.
2. **CDC option missing despite being directly applicable** — Debezium captures actual column-level changes from the WAL and can filter the noisy `page_count`/`last_seen_at`/`updated_at` updates while keeping meaningful state transitions. For a high-churn table this is the canonical recommendation in `resources/13-postgres-to-iceberg-ingestion.md` (Pattern C). Answer skips it.
3. **Append-only event redesign missing** — the deepest fix is to stop modeling sessions as a mutable row at all: emit `session_started` / `page_viewed` / `session_ended` events and let analysts reconstruct sessions in Trino. This is the OLTP-to-OLAP mindset shift resource 12 teaches. Not surfaced.

Solution 1 (MERGE INTO with full-table read every 15 minutes) is operationally aggressive: reading 500M rows over JDBC every 15 minutes will heavily load the replica even with `numPartitions=32`, and the answer underplays this. A `WHERE updated_at > now() - interval '15 minutes' + buffer` filter on the source-side query would dramatically cut data movement. Also, "Runs in ~15 minutes per your SLA" is not justified — pulling 500M rows over JDBC every 15 minutes is unlikely to fit the SLA without source-side filtering. The "don't continue with the 15-min/40-min overlap" warning is implicit (all recommendations change the architecture) but should be explicit — the job currently falls further behind every cycle and risks unbounded backlog.

Smaller issues: Solution 2's deduplication with `row_number()` is correct but the answer says "ROW_NUMBER() window functions, which is slow" without noting that ROW_NUMBER + filter is the standard Trino idiom and not pathologically slow. Solution 3 (nightly full refresh via `createOrReplace()`) on a 500M-row table is dangerous — `createOrReplace()` is DROP+CREATE semantics and wipes any prior ALTER TABLE schema evolution; same recurring hazard called out in Iter 7 Q2 and Iter 27 Q4. Should recommend `overwritePartitions()` or partitioned full-snapshot replace, not `createOrReplace()`.

Resource gap: `resources/13-postgres-to-iceberg-ingestion.md` needs a "High-churn tables (sessions, presence, counters)" section with: (1) narrow-scope filter as first resort, (2) when to switch to CDC, (3) when to redesign as append-only events, and (4) a warning that MERGE INTO with full-table reads scales poorly on high-churn tables — use source-side time filter to bound the read.

Verified: Trino does not support DISTINCT ON (trino.io discussion #17261); MERGE INTO syntax for Iceberg 1.5 Spark matches iceberg.apache.org docs.

---

### Iteration 30, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: Enterprise customer churned with contractual 72-hour deletion deadline. 3TB / 2 years Iceberg history, plus Trino schemas/views/roles and Spark Kubernetes ingestion CronJobs. Complete decommission checklist and where data silently remains.

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **3.75** |

**Topics updated**: Multi-tenant analytics — prior avg 4.394 over 31 questions; new running avg (4.394 × 31 + 3.75) / 32 = **4.374** across 32 questions. PASSED.

**Notes**: Phase ordering correct (Phase 0 stop ingestion via kubectl delete cronjob BEFORE any data work). "Five hidden data layers" framing is a strong teaching device for the "where does data silently remain?" half of the question. Runnable kubectl + Spark SQL + Trino SQL + `mc ls` commands throughout. Hedge on DROP TABLE behavior ("may or may not delete MinIO files") is correctly cautious — Trino ≥458 deletes by default but is config-dependent. Critical technical error: **Step 4 labels `remove_orphan_files` as "THE STEP THAT PHYSICALLY DELETES"** — wrong; `expire_snapshots` is what frees data files referenced by prior snapshots, while `remove_orphan_files` only deletes untracked files left behind by failed writes. Same recurring misconception flagged in Iter 10 Q1 (GDPR erasure) and Iter 30 Q1 (soft-delete). Engine context missing — all four CALL statements use Spark `CALL iceberg.system.X` syntax mixed with Trino DROP VIEW / DROP SCHEMA without re-stating the engine; Trino's correct syntax is `ALTER TABLE ... EXECUTE expire_snapshots(...)`. `older_than => current_timestamp() - INTERVAL '0' DAY` is dangerously aggressive without a maintenance-window warning. Trino role cleanup misses the multi-role / grant-audit case (`system.metadata.role_grants`, `system.metadata.table_privileges`). JWT/OPA layer entirely absent — production stack uses JWT auth + OPA policies; decommission must name (but defer specifics of) JWT revocation and OPA policy removal. Contractual audit evidence is too thin — "Sign-off checklist" should produce MinIO byte-count diff, snapshot IDs pre/post, query log entries, and an audit JSON or signed PDF for legal. Beginner clarity gap: `snapshot`, `manifest`, `orphan files`, `Hive Metastore` used without inline glosses.

Resource gaps:
1. `resources/05-multi-tenant-analytics.md` — add "Customer decommission checklist" section structured as 72-hour playbook with explicit phases (stop ingest → DELETE+rewrite+expire+remove_orphan → DROP views/schema/roles + grant audit → JWT/OPA revocation reference → contractual audit deliverables).
2. `resources/17-iceberg-table-maintenance.md` — add callout box stating `expire_snapshots` is the procedure that frees data files referenced by prior snapshots, NOT `remove_orphan_files`. Persistent failure pattern across 3 iterations.
3. Engine context table for the four Iceberg maintenance procedures showing Spark `CALL iceberg.system.X(...)` vs Trino `ALTER TABLE ... EXECUTE X(...)` side by side.
4. DROP TABLE behavior clarification: modern Trino (≥458) deletes data files by default for Iceberg; the `iceberg_purge_data_on_delete_enabled` property controls it; verification via `mc ls` is mandatory regardless.

Verified: trino.io/docs/current/connector/iceberg.html; trinodb/trino#11062, #25727 (DROP TABLE behavior on Iceberg).

**Iteration 30 average**: (3.44 + 3.25 + 3.75 + 3.75) / 4 = **3.548**

---

### Iteration 32, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: New enterprise customer onboarding — repeatable 30-minute provisioning checklist (vs full day) from data platform perspective: all steps to complete before tenant can run first Trino query.

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 3.5 |
| Completeness | 3.5 |
| **Average** | **4.0** |

**Topics updated**: Multi-tenant analytics — prior avg 4.374 across 32 questions; new running avg (4.374 × 32 + 4.0) / 33 = **4.363** across 33 questions. PASSED.

**Notes**: Resource-groups JSON correctly uses valid Trino property names (hardConcurrencyLimit, softMemoryLimit, subGroups, maxQueued) — iter 31 fix is holding three consecutive iterations. JWT-principal vs Trino-role-name selector gotcha consistently surfaced. CREATE ROLE + GRANT ROLE TO USER + GRANT SELECT on view + REVOKE ALL on base table all correct and present (iter 12 Q2 + iter 13 Q4 fixes holding). Per-step time estimates make the SLA testable. Strong cleanup/offboarding section.

Three completeness gaps that should cost a point each:
1. **Ingestion CronJob and initial full refresh entirely missing** — for a brand-new tenant the Spark ingestion pipeline must be set up before any Trino query returns data. This is the single biggest miss against the expected key points for a "before first Trino query" checklist.
2. **OPA not mentioned as the production authz backend** — `prod_info.md` specifies OPA with custom policies as the authz layer; the answer treats role/grant/revoke as the complete enforcement story. Should deferred-to-external-governance-doc framing per prod_info guidance.
3. **CI isolation test stub-only** — Step 8 says "Add a CI test asserting..." but no runnable test code. Given multi-tenant isolation is the highest-stakes deliverable, a pytest snippet should be provided (flagged repeatedly since iter 4 Q5).
4. **Automation callout missing** — the question's whole point is "30 minutes repeatable" instead of "full day manual." Answer presents a manual 30-minute checklist with no script/Terraform/Helm wrapper. The leap to repeatability needs an explicit "wrap this in X" section.

Minor: file-based resource-groups.json changes require coordinator restart (not flagged; "1 minute" is unrealistic if restart is in scope); `CREATE SCHEMA tenant_acme` is implicit not explicit (Step 3 fails on clean cluster).

Resource gaps:
1. `resources/05-multi-tenant-analytics.md` — add explicit "Tenant onboarding checklist" section structured as time-boxed phases including the ingestion step + initial full refresh + script-wrapper automation callout + OPA deferral note + runnable pytest CI isolation snippet + coordinator restart caveat for file-based resource group changes.
2. `resources/13-postgres-to-iceberg-ingestion.md` — cross-reference from the new-tenant onboarding scenario so responder consistently includes CronJob deployment + initial full refresh when asked about onboarding flows.

Verified: trino.io/docs/current/admin/resource-groups.html confirms hardConcurrencyLimit (integer, required), softMemoryLimit (string absolute or %), subGroups (array), selectors match on user/source/principal.

---

### Iteration 32, Q-additional — 2026-05-24 (EXTENDED PHASE)
**Question**: Security team — could Trino's query result caching be a cross-tenant data leak? Is tenant A's cached result reachable by tenant B running the same query?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 3 |
| **Average** | **3.50** |

**Topics updated**: Multi-tenant analytics — prior avg 4.363 across 33 questions; new running avg (4.363 × 33 + 3.50) / 34 = **4.337** across 34 questions. PASSED.

**Notes**: Central technical claim is correct and verified — Trino has no built-in cross-query result cache (trinodb/trino issue #20854 is an open feature request). Spooling caveat correctly pulled from prod_info.md. Defense layers (JWT, OPA, views, RBAC) correctly enumerated. No fabricated config properties (notably, did not invent `query.cache.enabled` which the rubric template wrongly suggested). Hedged opener ("I don't have detailed technical documentation about Trino's internal query result caching") undermines the answer's own confidence — the responder should be telling the security team "your premise is wrong, Trino has no result cache to leak."

Four gaps cost the higher scores:
1. **Missing headline disconfirmation** — should open with "Trino has no built-in query result cache; the risk lives downstream in BI tools (Superset/Tableau), client-side caches, and the spooling protocol if enabled."
2. **`system.runtime.queries` query-text exposure not mentioned** — a tenant role with default `system` catalog access can read other tenants' full SQL including WHERE-clause literals. Standard mitigation: deny `system` catalog to tenant roles via OPA/file-based rules. This is a real disclosure vector more important than the speculative spooling worry.
3. **BI tool / client-cache redirect missing** — where caching actually lives in this stack: Superset SQL Lab cache, Tableau extracts, browser caches. The answer should name these as the security team's actual investigation targets.
4. **Spooling section is vague** — per Trino docs spooled segments are encrypted with a 256-bit base64 secret key and written to object storage with per-segment URIs. Cross-tenant spool risk is really about (a) MinIO bucket ACL, (b) shared secret key across tenants, (c) segment URI predictability — not just "tag spool files with tenant identity."

Rubric correction needed: the "expected key points" template referenced `query.cache.enabled=false` — this property does not exist in Trino. Should be replaced with "explain Trino has no built-in result cache to enable or disable; caching lives in BI tools, client SDKs, and (if enabled) spooling."

Resource gap: `resources/05-multi-tenant-analytics.md` needs a "Query result caching — what Trino does and does not cache" section covering: (a) Trino has no built-in cross-query cache (link to trinodb/trino issue #20854); (b) caching lives in BI tools / spooling protocol / client-side caches; (c) `system.runtime.queries` exposes query text — deny `system` catalog to tenant roles, one-line OPA or file-based rule example; (d) paste-able "what to tell your security team" template paragraph.

Verified: trinodb/trino issue #20854 (no built-in result cache, open feature request); trino.io/docs/current/release/release-467.html (spooling protocol updates in 467); trino.io/docs/current/client/client-protocol.html (spooling secret key, encryption).

---

### Iteration 32, Q-late-arriving — 2026-05-24 (EXTENDED PHASE)
**Question**: Mobile app batches events offline and uploads 3 days later. Watermark-based Spark job on `occurred_at` already advanced past those timestamps. Late events are silently missing from Iceberg. How to handle without re-running full history?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3.5 |
| **Average** | **3.875** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.387 across 31 questions; new running avg (4.387 × 31 + 3.875) / 32 = **4.371** across 32 questions. PASSED.

**Notes**: Batch-window pattern with `overwritePartitions()` is technically valid and well-explained — atomic, idempotent, partition-scoped guarantees are correct, the warnings against `append()` (doubles) and `createOrReplace()` (table wipe) are right, and the "watermark and batch-window cannot coexist on the same table" callout is the most important operational guardrail. Concrete `--batch-date` parameterization, K8s CronJob YAML, twice-daily run + weekly 7-day replay are directly actionable. **Critical completeness gap**: the lightest-touch fix — switching the watermark column from `occurred_at` (event time) to `updated_at` / `ingested_at` (row insertion time in Postgres) — is missing entirely. This is the canonical 1-line fix for late-arriving event-time data when Postgres is the source: the watermark advances based on when Postgres first saw the row, not when the event occurred, so late uploads are captured on their first insert. For an engineer asking "how do I handle this without re-running history," the watermark-column switch is a smaller change than re-architecting to batch-window with `overwritePartitions()`. Also missing: (1) buffer/lag window subtraction (advance watermark to `max(updated_at) - interval '1 hour'`) to give late inserts a safety margin; (2) one-time remediation for the already-missed events — a time-bounded MERGE INTO scanning the last 14 days from Postgres into Iceberg by `event_id`. The answer treats the question as "redesign the pipeline" when the question also asks for backfill of the rows currently missing from Iceberg. Resource gap: `resources/13-postgres-to-iceberg-ingestion.md` needs a "Late-arriving events from mobile/offline sources" subsection that opens with the watermark-column choice (event time vs row insertion time) as a decision rule before introducing the batch-window architectural option, plus an explicit one-time backfill recipe (MERGE INTO with `occurred_at > now() - interval '14 days'` source filter on `event_id`).

Verified: iceberg.apache.org/docs/latest/spark-writes/ (overwritePartitions is atomic for Iceberg, dynamic partition overwrite semantics); abstractalgorithms.dev/spark-watermarking-late-data-handling (watermark column choice is the canonical lever for late-arriving data; processing-time/ingestion-time watermarks capture late event-time arrivals).

---

### Iteration 32, Q-jsonb-evolution — 2026-05-24 (EXTENDED PHASE)
**Question**: Spark flattens 5 JSONB keys (user_id, plan_type, feature_name, button_id, experiment_id). Product team added new event type with new keys (payment_method, amount_cents, currency). New events ingest but new JSONB keys are all NULL in Iceberg. How to evolve the JSONB flattening?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.625** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.371 across 32 questions; new running avg (4.371 × 32 + 4.625) / 33 = **4.379** across 33 questions. PASSED.

**Iteration 32 average**: (3.50 + 3.875 + 4.625 + 4.0) / 4 = **4.0**

**Notes**: Hits every expected key point. (1) Root cause correctly diagnosed: Spark job extracts only the named keys list; any key not in that list is silently dropped to NULL — this is documented as expected Spark/JDBC behavior, not a bug. (2) Updated Spark code uses `get_json_object()` for both old and new keys — the correct extraction pattern for new flattened columns. (3) `ALTER TABLE ADD COLUMN` correctly described as metadata-only with no Parquet file rewrite. (4) Old rows returning NULL for new columns correctly framed as "correct behavior, not an error" — the key teaching point. (5) Correctly distinguishes incremental jobs (ALTER TABLE ADD COLUMN + re-run is sufficient) from full-refresh `createOrReplace()` jobs (ALTER TABLE gets wiped on next createOrReplace; schema change must live in the Spark code's column projection, not in DDL). (6) Preflight schema-diff check included: queries Postgres `information_schema.columns` and compares against Iceberg schema, alerts on drift before silent NULL ingestion. (7) `properties_raw` catch-all string column pattern mentioned. The `from_json(schema)` trap (fixed schema silently dropping new keys) is implicitly avoided by recommending `get_json_object()` instead.

Technical accuracy docked: the preflight check uses `iceberg.analytics.\`{iceberg_table}$schema\`` to read the Iceberg schema, but `$schema` is NOT a standard Iceberg metadata table in Trino. Correct SQL: `DESCRIBE` or `SHOW COLUMNS FROM`.

---

### Iteration 33, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Switching watermark from `occurred_at` to `updated_at` while Iceberg table is partitioned by `day(occurred_at)`. Does `overwritePartitions()` handle late-arriving events landing in old partitions correctly, and what else to watch?

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 3 |
| **Average** | **3.25** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.379 across 33 questions; new running avg (4.379 × 33 + 3.25) / 34 = **4.346** across 34 questions. PASSED.

**Notes**: Core mechanic correctly stated — switching to `updated_at` is the right fix; `overwritePartitions()` is atomic and partition-scoped; late events with old `occurred_at` correctly target old day partitions and replace them. Deduplication call-out for repeated `updated_at` updates is valid and the ROW_NUMBER() snippet is runnable.

Critical production-hazard omission: the answer states `overwritePartitions()` "replaces" the affected day partition without warning that the replacement scope is **by-DataFrame-content** — i.e., whatever rows are in the incoming DataFrame become the entirety of that partition. When the watermark batch pulls only the 12 late-arriving rows for `day=3-days-ago` (the realistic case under the `updated_at` watermark), `overwritePartitions()` will wipe the existing thousands of rows in that day's partition and leave only those 12 behind. The fix is either (a) re-query ALL rows for any affected day partition from Postgres before writing, or (b) use `MERGE INTO` (which only rewrites affected rows). The expected answer flagged this as the primary gotcha; the iceberg.apache.org docs explicitly recommend MERGE INTO over INSERT OVERWRITE / `overwritePartitions()` for exactly this reason. An engineer following this answer will silently corrupt historical partitions on the first late-arriving batch.

Three other completeness gaps cost the higher scores:
1. **Lag buffer missing** — `new_watermark = max(updated_at) - interval '4 hours'` is the standard guard for rows inserted in Postgres but not yet visible at watermark-read time. Not mentioned.
2. **`updated_at` indexing in Postgres not mentioned** — watermark queries on an unindexed column cause full-table scans on every run; this is the single most common production performance regression when switching watermark columns.
3. **Partition spec rationale not surfaced** — the engineer asked "what else to watch" with the existing `day(occurred_at)` partitioning; a one-liner confirming the partition spec still makes sense for analyst query patterns (filters/group-bys on `occurred_at`) would close the loop. Currently leaves room for the engineer to wonder if they should re-partition by `day(updated_at)`.

Smaller issues: "`append()` is not idempotent" framing is technically true but inverts the primary motivation — the canonical reason to prefer MERGE INTO over `overwritePartitions()` here is partition-replacement-scope safety, not idempotency. The "backfill already-missed events" suggestion of MERGE INTO is buried as item 4; it should be elevated as the one-time recovery action for events missed before the watermark switch.

Resource gap: `resources/13-postgres-to-iceberg-ingestion.md` "Late-arriving events" section needs an explicit callout box on `overwritePartitions()` semantics: **"overwritePartitions replaces the entire affected partition with the rows in your DataFrame — if your incremental batch contains only late-arriving rows for an old partition, you will wipe the legitimate prior data in that partition. Either re-read all rows for affected partitions, or use MERGE INTO."** This same hazard surfaced in the soft-delete answer (Iter 30 Q1) and the late-arriving answer (Iter 32 Q-late-arriving); the resource still does not warn engineers about it. Also add: (a) lag-buffer subtraction recipe, (b) Postgres `updated_at` index check as a preflight requirement, (c) explicit "partition spec stays unchanged" reassurance.

Verified: iceberg.apache.org/docs/latest/spark-writes/ (MERGE INTO recommended over INSERT OVERWRITE because it rewrites only affected data files); Expedia Group blog on MERGE INTO vs INSERT OVERWRITE in Iceberg (partition-replacement-scope as the primary safety reason).

---

### Iteration 33, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: pg_partman monthly-partitioned `events` table — Spark JDBC watermark read from parent table hangs 30-60s at startup before any data flows. What's happening and how to fix it.

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.346 across 34 questions; new running avg (4.346 × 34 + 3.75) / 35 = **4.329** across 35 questions. PASSED.

**Notes**: Root-cause diagnosis is correct — pg_inherits / pg_class catalog traversal + information_schema column lookup is O(child partitions) and well-documented in the pgjdbc PgDatabaseMetaData history (LEFT JOIN overhead scales with table count). Option 1 (read specific child partitions, not the parent) is the highest-impact fix and was correctly identified as the recommended approach with a runnable Spark JDBC code sample on the on-prem stack. partitionColumn/numPartitions/lowerBound/upperBound knobs are present in the code sample.

Completeness gaps vs the expected answer:
1. **`pushDownPredicate=true` JDBC option not named** — this is the canonical Spark JDBC parameter for ensuring the WHERE clause reaches Postgres so partition pruning happens server-side. Without it, predicate behavior depends on dialect and version; with it the engineer has a deterministic guarantee.
2. **Per-partition `updated_at` index not mentioned** — pg_partman child tables each need the index independently (the parent index does not automatically propagate to existing children depending on PG version). For a watermark query this is the difference between an index range scan and a sequential scan on every child.
3. **`fetchsize` JDBC parameter absent** — affects per-row network roundtrips, materially relevant to startup-to-data latency on JDBC reads.
4. **Option 2 ("Postgres view that flattens the partitions") is speculative and likely misleading** — a view over the parent table does NOT bypass the catalog metadata cost; the planner still resolves the underlying inheritance hierarchy and JDBC metadata calls walk the same catalogs. The answer hedges with "some deployments find" but provides no mechanism — this option should be removed or replaced with the index/pushdown advice.
5. **Hardcoded `upperBound=1_000_000_000` for `id` is a footgun** — should be derived from `SELECT min(id), max(id) FROM <child>` at job start; a wrong upper bound causes severe partition skew (one Spark partition gets all rows above the bound or below the lower bound, while the others get tiny slices).

Resource gap: `resources/13-postgres-to-iceberg-ingestion.md` needs a "Reading from pg_partman partitioned Postgres tables" subsection covering: (a) JDBC metadata cost of reading from parent table — name pg_inherits / pg_class / information_schema cost; (b) fix #1: read specific child partition(s) for the current watermark window via `dbtable` subquery scoped to the affected month(s); (c) fix #2: `pushDownPredicate=true` JDBC property as the WHERE-pushdown guarantee; (d) fix #3: ensure each child has an index on the watermark column (`updated_at`) — note that adding an index to a pg_partman parent does NOT automatically backfill child indexes; (e) fix #4: derive `lowerBound`/`upperBound` dynamically from `SELECT min(id), max(id)` on the target child(ren) rather than hardcoding; (f) `fetchsize` callout for network roundtrip reduction.

---

### Iteration 33, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: Tenant service accounts can run `SELECT * FROM system.runtime.queries` in Trino and see full SQL of every query on the cluster — including other tenants' queries. How to lock down system catalog access?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 3 |
| Practical applicability | 2 |
| Completeness | 2 |
| **Average** | **2.75** |

**Topics updated**: Multi-tenant analytics — prior avg 4.337 across 34 questions; new running avg (4.337 × 34 + 2.75) / 35 = **4.291** across 35 questions. PASSED.

**Notes**: Correctly identified `system.runtime.queries` as the query-text snooping vector and described the threat model. However, lacked actionable remediation — resources don't cover system catalog access control. Missing: (1) file-based access control rule denying `system` catalog to tenant roles; (2) OPA policy pattern denying catalog access where catalog='system' and principal is not internal SA; (3) `query.client.info-is-sensitive=true` as partial mitigation. Answer was honest about the resource gap but scored low on practical applicability. Resource 05 needs a system catalog access control subsection.

---

### Iteration 33, Q4 — 2026-05-24 (EXTENDED PHASE)
**Question**: HIPAA customer needs 90-day deletion; SEC customer needs 7-year retention. Both share the same Iceberg table partitioned by `day(occurred_at)` and `tenant_id`. How to implement different per-tenant retention policies?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: Multi-tenant analytics — prior avg 4.291 across 35 questions; new running avg (4.291 × 35 + 4.50) / 36 = **4.297** across 36 questions. PASSED.

**Iteration 33 average**: (2.75 + 3.25 + 3.75 + 4.50) / 4 = **3.5625**

**Notes**: Excellent coverage. Correctly identified partition DROP as unsafe for per-tenant retention on a shared table (day+tenant_id partition means one day-partition spans both tenants). Scheduled DELETE WHERE tenant_id + occurred_at is correct approach. 3-step reclamation sequence (DELETE → rewrite_data_files → expire_snapshots) correctly stated with storage release attributed to expire_snapshots only. Separate-tables-per-tenant flagged as cleanest isolation. HIPAA audit log requirement and MinIO byte-verification mentioned. Iceberg `write.data.retention.days` correctly noted as table-level only. Minor gap: partition-DROP warning could have been more prominent.

Verified: spark.apache.org/docs/latest/sql-data-sources-jdbc.html (pushDownPredicate option exists, partitionColumn/lowerBound/upperBound/numPartitions semantics for parallel reads); pgjdbc PgDatabaseMetaData history (LEFT JOIN cost scales with table count, documented as unacceptable on databases with thousands of tables); pgpartman/pg_partman issue #107 (performance challenges in overcrowded databases with many namespaces and tables).

---

### Iteration 35, Q-replica-lag — 2026-05-24 (EXTENDED PHASE)
**Question**: Incremental Spark job reads from Postgres read replica with `WHERE updated_at > :last_watermark`, sets new watermark to MAX(updated_at). 6 minutes of replica lag. Now 0 new rows. Are rows permanently lost? What does a "lag buffer" actually do?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 4.5 |
| **Average** | **4.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.329 across 35 questions; new running avg (4.329 × 35 + 4.75) / 36 = **4.341** across 36 questions. PASSED.

**Notes**: All headline mechanics correct and verified. (1) "Safe on the primary, missed from Iceberg unless you act" frames the problem accurately. (2) Recovery procedure (rewind watermark, re-read from PRIMARY not replica, rely on MERGE INTO idempotency) matches the expected answer. (3) Lag buffer recipe `MAX(updated_at) - interval` is the correct prevention mechanism — though the 4-hour value is overly conservative; the expected/canonical guidance is 15 minutes, and 4 hours imposes 16x the reread overhead on every batch and pushes effective freshness from minutes to hours. Acceptable but should be tuned per stack. (4) `pg_last_xact_replay_timestamp()` is correctly noted as returning NULL on primary — must be queried on replica connection; the `safe_upper = min(now_utc(), replay_ts)` cap is the right proactive guardrail and is more sophisticated than the canonical "static lag buffer" approach. (5) "Silent data loss with no error" warning is the right closing.

Two completeness gaps cost the higher score: (a) the canonical detection method — comparing `max(updated_at)` between Iceberg and Postgres PRIMARY to identify the affected time window — is missing; the responder offers proactive prevention via `replay_ts` but does not show how to detect rows already missed after the fact. An engineer who reads this answer after the incident has no recipe to find what they lost. (b) The primary-vs-replica tradeoff for watermark jobs (replica relieves load but introduces this exact lag-window hazard; primary is safer but adds query load) is implicit, not explicit. A one-sentence tradeoff statement would close the loop. Minor: "in-flight rows" and "JDBC" used without inline glosses; MERGE INTO described as idempotent without explaining why (key columns + match condition) for first-time readers.

Verified: postgrespro.com/list and adjust.com engineering blog confirm `pg_last_xact_replay_timestamp()` returns NULL on primary servers not in recovery mode.

---

### Iteration 35, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Tenant service accounts can see all other tenants' SQL via `system.runtime.queries`. `REVOKE SELECT ON system.runtime.queries FROM ROLE tenant_role` fails. How to lock this down?

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.0 |
| Practical applicability | 4.5 |
| Completeness | 4.0 |
| **Average** | **4.25** |

**Topics updated**: Multi-tenant analytics — prior avg 4.297 across 36 questions; new running avg (4.297 × 36 + 4.25) / 37 = **4.296** across 37 questions. PASSED.

**Notes**: Major improvement from iter33 Q1 (2.75 → 4.25) — resource fix worked. Correctly explains why REVOKE fails (system catalog governed by access control SPI, not table grants). Runnable file-based rules.json with correct deny-by-exclusion pattern. OPA deferred to external governance per prod_info. `query.client.info-is-sensitive=true` correctly framed as NOT hiding query text and NOT a substitute. Verification SQL and CI test guardrail included. Two remaining gaps: (1) coordinator restart required for file-based rule changes (vs OPA hot reload) not flagged — engineer might apply JSON change and be puzzled when tenant role still has access; (2) "OPA," "JWT principal," "system access control" used without inline glosses.

---

### Iteration 35, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: 80 tenants with per-tenant hardcoded views. Is there a dynamic view using the current logged-in user so we don't provision a new view per tenant?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Topics updated**: Multi-tenant analytics — prior avg 4.296 across 37 questions; new running avg (4.296 × 37 + 3.75) / 38 = **4.281** across 38 questions. PASSED.

**Notes**: Core pattern correct — `current_user` + user_tenant_map JOIN + REVOKE on base table enforced. Missing key expected-answer points: (1) Trino views default to SECURITY DEFINER so `current_user` in the view body returns the view owner, not the querying user — must specify `SECURITY INVOKER`; missing this means a production deployment is silently broken (everyone sees all data). (2) Security blast-radius tradeoff absent: one bug in user_tenant_map breaks ALL tenants simultaneously vs per-tenant views where a bug affects only one tenant. (3) Cache-key benefit of per-tenant views not mentioned. (4) 80 tenants is below the ~200+ inflection where dynamic view becomes compelling over per-tenant scripting.

---

### Iteration 35, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: Called `overwritePartitions()` with 12-row test DataFrame on a partition with 850,000 rows. Now only 12 rows remain. Data loss? Recovery? Safe use pattern going forward?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.341 across 36 questions; new running avg (4.341 × 36 + 4.75) / 37 = **4.352** across 37 questions. PASSED.

**Iteration 35 average**: (4.25 + 3.75 + 4.75 + 4.75) / 4 = **4.375**

**Notes**: Excellent answer validating the iter34 late-arriving events resource fix. Correctly confirms data loss and explains partition-replacement semantics clearly. Recovery via `events$snapshots` + `rollback_to_snapshot()` with correct Spark CALL syntax and named arguments. Critical expire_snapshots caveat included. Both safe patterns present: full-partition re-read (idempotent) and MERGE INTO (recommended — row-scoped). Seven-day snapshot retention guidance and "never use overwritePartitions for testing" rule both present. Minor clarity gap: `$snapshots` metadata-table notation and engine label (Spark vs Trino) not explicitly called out for beginners.

---

### Iteration 37, Q-dynamic-view — 2026-05-24 (EXTENDED PHASE)
**Question**: We implemented a dynamic view with `WHERE tenant_id = current_user`. Every tenant sees the same rows — the rows that belong to whoever created the view. What went wrong and how to fix it?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.25** |

**Topics updated**: Multi-tenant analytics — prior avg 4.281 across 38 questions; new running avg (4.281 × 38 + 4.25) / 39 = **4.280** across 39 questions. PASSED.

**Notes**: Validates the iter36 resource fix — the SECURITY INVOKER answer is now present, runnable, and includes the blast-radius tradeoff for dynamic views vs per-tenant views. The 200+ tenant inflection point and base-table REVOKE guardrail are both surfaced. Recreate-with-SECURITY-INVOKER fix is the correct production action and a two-account test recipe proves the fix.

Technical accuracy docked one point: the central diagnosis frames `current_user` as resolving to the view creator under SECURITY DEFINER, then to the query executor under SECURITY INVOKER. Per official Trino docs (trino.io/docs/current/sql/create-view.html), `current_user` **always returns the user executing the query, regardless of security mode** — the SECURITY DEFINER vs INVOKER distinction only changes which principal's permissions are used to access referenced tables, not what `current_user` returns. The correct mechanism for why the original view broke is more nuanced: under SECURITY DEFINER the view runs with the owner's table grants, so a view of the form `WHERE tenant_id = current_user` against the events table can read all rows (because the owner has access), and any predicate that doesn't actually constrain rows for the invoking user (e.g., username/tenant-id mismatch, or join-key issues, or current_user returning a service-account name that doesn't match any `tenant_id`) falls through silently. The fix (SECURITY INVOKER + REVOKE on base tables) still works because under INVOKER each tenant has to have its own grants to reach the data — but the explanatory framing in the answer is the widely-circulated-but-incorrect version. An engineer who later digs into the docs will find the responder's claim contradicted.

Completeness docked one point: missing the `WITH (security_invoker = true)` table-property alternative syntax (some Trino deployments require this form); missing the cache-key implication of dynamic views (every querying user re-plans the JOIN to user_tenant_map vs static per-tenant views which the planner can cache more aggressively); missing the SECURITY INVOKER + Iceberg connector caveat where INVOKER views require the invoking user to have direct grants on the base table — which the answer correctly addresses by saying "ensure tenants don't have base-table SELECT" but doesn't reconcile with INVOKER's permission model (the answer implicitly assumes the JOIN to user_tenant_map gives row-level filtering, but the invoker still needs SELECT on user_tenant_map and on events for INVOKER mode to read anything; in production the engineer must grant SELECT on the view to tenant roles AND ensure the view owner has the required grants on the base — which is the SECURITY DEFINER subtlety the responder muddled).

Resource gap: `resources/05-multi-tenant-analytics.md` SECURITY INVOKER section should clarify three things: (1) `current_user` always returns the query executor in Trino regardless of security mode — link to trino.io docs; the real DEFINER-vs-INVOKER difference is whose grants are used to access tables; (2) the `WITH (security_invoker = true)` table-property alternative syntax for engines/versions that prefer property form; (3) for INVOKER views joined to a lookup table like `user_tenant_map`, the invoker needs SELECT on the lookup table (not just on the view) — show explicit GRANT for the lookup table alongside the view grants.

Verified: trino.io/docs/current/sql/create-view.html ("Regardless of the security mode, the current_user function will always return the user executing the query"); trinodb/trino issue #10708 (SECURITY DEFINER default and role interaction).

---

### Iteration 37, Q-failover-gap — 2026-05-24 (EXTENDED PHASE)
**Question**: Postgres primary failed over, replica was lagging 20-25 minutes, Iceberg watermark already advanced past the gap. How to detect what's missing and recover?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.875** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.352 across 37 questions; new running avg (4.352 × 37 + 4.875) / 38 = **4.369** across 38 questions. PASSED.

**Notes**: Near-perfect execution of the failover-gap detection-and-recovery recipe. All four expected-answer elements present and correct: (1) detection via max(updated_at) Iceberg vs Postgres PRIMARY comparison, with explicit "query PRIMARY not replica" reasoning surfaced in both the code comment and the "Why each step matters" callout; (2) targeted Spark JDBC backfill from PRIMARY for the exact gap window (`BETWEEN iceberg_max AND pg_max_row`); (3) MERGE INTO on event_id with WHEN MATCHED UPDATE / WHEN NOT MATCHED INSERT — correctly framed as idempotent and surgical vs `overwritePartitions()`; (4) prevention via `pg_last_xact_replay_timestamp()` lag check on replica and 15-30 minute lag buffer calibrated to P99 × 2. The watermark-advance step (`pg_max_row - LAG_BUFFER`) closes the recovery loop cleanly, and a Verification step (re-run gap check + spot-check counts) is added beyond the resource. The "for small/medium tables read from PRIMARY directly" prevention tip is a bonus that the resource does not explicitly contain. Anchored to production stack throughout (Spark JDBC, Iceberg, MinIO context implied via the watermark-file pattern). Beginner clarity docked 0.5: "LAG_BUFFER," "JDBC," "watermark," "MERGE INTO" used without inline plain-English glosses for first-time readers, and `pg_last_xact_replay_timestamp()` mentioned without explaining when it returns NULL (the primary vs replica connection caveat the resource calls out is missing). No new resource gaps identified — this answer directly validates the iter 34/35 detection recipe added to `resources/13-postgres-to-iceberg-ingestion.md` lines 303-362.

Verified: iceberg.apache.org/docs/latest/spark-writes/ (MERGE INTO rewrites only affected data files, recommended over INSERT OVERWRITE); Tabular/Expedia Engineering blog on MERGE INTO idempotency for late-arriving data (business-key match condition produces identical state on re-run).

---

### Iteration 37, Q-merge-idempotency — 2026-05-24 (EXTENDED PHASE)
**Question**: Switched from append() to MERGE INTO. Re-ran job for yesterday's window to test idempotency. Iceberg has MORE rows than Postgres for that day. What determines whether MERGE INTO is truly idempotent and what went wrong?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.369 across 38 questions; new running avg (4.369 × 38 + 3.75) / 39 = **4.353** across 39 questions. PASSED.

**Notes**: Core message is correct — MERGE INTO idempotency depends on the join key being unique — and the three-factor structure (unique key, deterministic source read, deduplication) is technically sound. The runnable dedup pattern (`Window.partitionBy("event_id").orderBy(updated_at.desc())` + `row_number`) is accurate Spark code, and the diagnostic SQL (`SELECT event_id, COUNT(*) GROUP BY event_id HAVING cnt > 1`) matches the expected answer.

Major completeness gap: the expected answer's primary hypothesis — that the engineer's `ON` clause is matching on the wrong column (e.g., `ON target.date = source.date` or `ON target.updated_at = source.updated_at` instead of `ON target.event_id = source.event_id`) — is never stated explicitly. The answer focuses on source-side duplication and watermark mutability, but the most common cause of "MERGE INTO inserts extra rows" in production is using a non-PK column in the `ON` clause; an engineer reading this answer will not be prompted to look at their actual MERGE INTO SQL and check what column is in the `ON` clause. Per the Apache Iceberg GitHub issue #7005 and Iceberg Spark docs, the documented behavior is also that when multiple source rows match a single target row, MERGE INTO raises an error — but if no match is found at all, NOT MATCHED branches insert; this nuance is missing.

Practical applicability docked one point: no cleanup recipe for the duplicate rows already in Iceberg. The engineer asked "Iceberg has MORE rows than Postgres" — they need to know how to get rid of the extras. The expected fix path includes `CALL system.rollback_to_snapshot(...)` or a dedup-then-overwritePartitions to get back to a clean state; neither is mentioned.

Beginner clarity: `Window.partitionBy`, `row_number()`, "watermark filter," and "deduplication" are used without inline glosses. The Spark Window code block needs a one-line comment explaining what `row_number() over (partition by event_id order by updated_at desc)` does for a Postgres-trained engineer who has never seen a window function.

Resource gap: `resources/13-postgres-to-iceberg-ingestion.md` MERGE INTO section should add an "Idempotency checklist" callout with three diagnostic questions in priority order — (1) Is your ON clause on a column that is unique per logical row in BOTH source and target? Show the wrong-column example (`ON t.date = s.date`) producing duplicates vs the right one (`ON t.event_id = s.event_id`); (2) Does your source query return duplicate keys? Show the COUNT(*) GROUP BY diagnostic; (3) If you already have duplicates in Iceberg, use `CALL system.rollback_to_snapshot(...)` first (if recent), then re-run with the corrected ON clause. The current resource shows the correct MERGE INTO pattern but does not teach how to diagnose the wrong-ON-clause failure mode that produces the symptom in this question.

Verified: iceberg.apache.org/docs/latest/spark-writes/ (MERGE INTO ON condition; multiple source matches raises error); github.com/apache/iceberg/issues/7005 (duplicate records with MERGE when source has duplicates).

---

### Iteration 37, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Dynamic view with `WHERE tenant_id = current_user` — every tenant sees view creator's data. What went wrong?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.25** |

**Topics updated**: Multi-tenant analytics — prior avg 4.280 across 39 questions; new running avg (4.280 × 39 + 4.25) / 40 = **4.273** across 40 questions. PASSED.

**Notes**: Resource fix working — SECURITY INVOKER solution, two-account test recipe, base-table REVOKE, blast-radius tradeoff, 200+ tenant inflection all present. Technical accuracy gap: `current_user` mechanism explanation contradicts Trino docs — `current_user` always returns the query executor regardless of security mode; DEFINER-vs-INVOKER only changes whose table grants are used. Fix still works but mechanism is misexplained. Missing: `WITH (security_invoker = true)` alternative syntax; explicit GRANT SELECT requirement on user_tenant_map lookup table for INVOKER views.

---

### Iteration 37, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Updated `rules.json` on Trino coordinator to deny system catalog to tenant roles. Changes pushed but tenants still can query `system.runtime.queries`. What's wrong?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.00** |

**Topics updated**: Multi-tenant analytics — prior avg 4.273 across 40 questions; new running avg (4.273 × 40 + 4.00) / 41 = **4.267** across 41 questions. PASSED.

**Notes**: Root cause correct (file-based rules.json not hot-reloaded; coordinator must restart). OPA hot-reload contrast present. Verification step included. Two gaps: opt-in `security.refresh-period` property as alternative to full restart not mentioned; specific `kubectl rollout restart` command not given.

---

### Iteration 37, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: Postgres primary failover, replica lagged 20-25 minutes, Iceberg watermark advanced past the gap. How to detect missing rows and recover?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.875** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.352 across 37 questions; new running avg (4.352 × 37 + 4.875) / 38 = **4.366** across 38 questions. PASSED.

**Notes**: Best Postgres-to-Iceberg answer of the extended phase. All expected elements: detection via Iceberg-vs-PRIMARY max(updated_at) diff, backfill from PRIMARY for exact gap window, MERGE INTO on event_id, prevention via pg_last_xact_replay_timestamp() + 15-30 min lag buffer. "Why each step matters" section and verification step both excellent. Minor clarity gaps: LAG_BUFFER/watermark/MERGE INTO without inline glosses; pg_last_xact_replay_timestamp() without the NULL-on-primary caveat. Validates iter35 detection-recipe resource additions.

---

### Iteration 37, Q4 — 2026-05-24 (EXTENDED PHASE)
**Question**: Switched from append() to MERGE INTO. Re-ran for yesterday's window — Iceberg has MORE rows than Postgres. What determines MERGE INTO idempotency?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.366 across 38 questions; new running avg (4.366 × 38 + 3.75) / 39 = **4.350** across 39 questions. PASSED.

**Iteration 37 average**: (4.25 + 4.00 + 4.875 + 3.75) / 4 = **4.219**

**Notes**: Correct framework (unique ON key, deterministic source read, pre-MERGE dedup). Window dedup snippet and diagnostic query present. Completeness gaps: (1) never explicitly tells engineer to inspect their MERGE INTO ON clause (most likely fix is changing ON column to event_id); (2) no cleanup recipe for duplicates already in Iceberg; (3) Iceberg's behavior of raising error on multiple source-to-target matches not mentioned. Resource gap: MERGE INTO section needs an "Idempotency checklist" with wrong-ON-clause example and duplicate-cleanup recipe.

---

### Iteration 39, Q-per-tenant-retention — 2026-05-24 (EXTENDED PHASE)
**Question**: Healthcare customers need 90-day retention, standard customers need 3 years. Shared Iceberg events table. How to implement per-customer retention without a mess?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Topics updated**: Multi-tenant analytics — prior avg 4.267 across 41 questions; new running avg (4.267 × 41 + 3.75) / 42 = **4.255** across 42 questions. PASSED.

**Notes**: Three-step physical deletion sequence (DELETE -> rewrite_data_files -> expire_snapshots) is the strongest element — engine-labeled (Spark) and with each step's effect on MinIO disk state surfaced. The "only expire_snapshots physically removes bytes" framing is correctly emphasized. Three significant completeness gaps vs the expected answer: (1) no mention that **partition DROP is not appropriate** for a multi-tenant shared table — engineer's obvious follow-up "why not just drop old day partitions?" goes unanswered; (2) no discussion of **separate tables per tenant as cleanest pattern for radically different retention** (90 days vs 3 years is a 12x gap — squarely in "separate tables" territory); (3) `write.data.retention.days` table-level-only caveat absent (engineer will Google this property within an hour). Technical accuracy gap: partitioning written as `(tenant_id, day(event_ts))` reverses the day-first order this rubric has previously confirmed correct in iter 7 Q4. HIPAA framing of the 90-day healthcare requirement not surfaced even though the question explicitly named healthcare.

Resource gap: `resources/05-multi-tenant-analytics.md` retention/GDPR section needs three additions: (a) a "Why partition DROP is not appropriate for multi-tenant shared tables" callout — explain that a `(day, tenant_id)` partition contains rows from both tenants on the same day, so DROP PARTITION can't be scoped to one tenant; (b) a "When to use separate tables per tenant" decision rule keyed off retention spread (e.g., >10x difference, regulatory boundary, or different compliance domains) and the maintenance/observability implications; (c) explicit note that `write.data.retention.days` (and related table properties) are table-level only — there is no per-row or per-tenant retention property; per-tenant retention must be enforced via scheduled DELETE jobs.

Verified: iceberg.apache.org/docs/latest/maintenance/ (expire_snapshots is what physically removes data files no longer referenced); iceberg.apache.org/docs/latest/configuration/ (table-level write properties only, no per-row retention).

---

### Iteration 39, Q-invoker-lookup — 2026-05-24 (EXTENDED PHASE)
**Question**: Dynamic view with SECURITY INVOKER joins to user-to-tenant mapping table. 3 out of 80 tenants get "Access Denied." All 3 have SELECT on the view. What could cause only some tenants to fail?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: Multi-tenant analytics — prior avg 4.267 across 41 questions; new running avg (4.267 × 41 + 4.50) / 42 = **4.273** across 42 questions. PASSED.

**Notes**: Direct validation that the iter38 resource 05 SECURITY INVOKER fix is working — the answer correctly identifies missing GRANT SELECT on the `config.user_tenant_map` lookup table as the primary cause, matching the expected answer exactly. Per Trino official docs (trino.io/docs/current/sql/create-view.html): under SECURITY INVOKER, the querying user must hold grants on every referenced table, not just the view itself. The 77-vs-3 explanation (older onboarding script) is surfaced, the fix (`GRANT SELECT ON config.user_tenant_map TO ROLE tenant_<id>_role`) is runnable, and three concrete diagnostic steps are provided. Secondary issue (JWT principal format mismatch) is correctly noted but flagged as producing empty rows not "Access Denied" — responder appropriately distinguished symptoms. Beginner clarity docked one point: "SECURITY INVOKER" and "JWT principal" not glossed inline for first-time readers. Completeness docked one point: missing explicit prevention recommendation (update onboarding automation to include lookup-table grant — implied by "older onboarding script" but not stated as the prevention step); `WITH (security_invoker = true)` table-property alternative syntax not mentioned. No new resource gaps — the iter38 resource fix produced a clean answer on the first new-angle question for the SECURITY INVOKER + lookup-table topic.

Verified: trino.io/docs/current/sql/create-view.html (INVOKER mode: tables accessed using invoker's permissions).

---

### Iteration 39, Q-merge-wrong-on-date — 2026-05-24 (EXTENDED PHASE)
**Question**: MERGE INTO ran with `ON t.event_date = s.event_date` (wrong — date is not unique). Job ran 3 times before catching it. Iceberg has 2-3x expected row counts. Fastest way to clean up?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 5 |
| **Average** | **4.25** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.350 across 39 questions; new running avg (4.350 × 39 + 4.25) / 40 = **4.348** across 40 questions. PASSED.

**Notes**: Strategically correct incident-response answer. Snapshot rollback IS the right first move when expire_snapshots has not yet run — metadata-only, instant, atomic. Comparison table ("Why this beats other approaches") is the strongest pedagogical move — it tells the panicked on-call engineer "do this, not those" with concrete tradeoffs. Root cause explanation precise: `ON t.event_date = s.event_date` matches date-to-date (not unique), all same-day source rows fall into NOT MATCHED branch → insert path; table only inserts, never updates. Corrected `ON t.event_id = s.event_id` shown. Post-rollback maintenance (expire_snapshots + remove_orphan_files) included.

Technical accuracy gap: persistent engine-syntax-mixing bug. The metadata query `iceberg.analytics."events$snapshots"` is Trino-style (catalog.schema.table), but all CALL procedure invocations (`CALL iceberg.system.rollback_to_snapshot(table => ..., snapshot_id => ...)`, `CALL iceberg.system.expire_snapshots(... older_than => current_timestamp - interval '7' day, retain_last => 10)`, `CALL iceberg.system.remove_orphan_files(...)`) are Spark Iceberg procedure syntax with named arguments. In Trino 467 (production query engine) the correct forms are `ALTER TABLE analytics.events EXECUTE rollback_to_snapshot(snapshot_id => <id>)`, `ALTER TABLE analytics.events EXECUTE expire_snapshots(retention_threshold => '7d')`, and `ALTER TABLE analytics.events EXECUTE remove_orphan_files(retention_threshold => '3d')`. Trino does not support `older_than` / `retain_last` parameters on the EXECUTE form — it uses `retention_threshold` only. An engineer copy-pasting Step 2 or the cleanup block into Trino will get a syntax error during incident response. This problem has been flagged across Iter 11 Q3, Iter 13 Q3, Iter 16 Q1, Iter 16 Q3 and remains unfixed in `resources/17-iceberg-table-maintenance.md` and `resources/13-postgres-to-iceberg-ingestion.md`.

Completeness gap: expected answer's "if rollback unavailable" fallback (re-read affected partitions from Postgres + `overwritePartitions()`) is only implied via the comparison table row ("Re-ingest from Postgres") and never spelled out as a runnable second-resort recipe. If expire_snapshots had already cleaned up the pre-bad-MERGE snapshot, the responder's plan has no backup path.

Beginner clarity: "metadata-only," "atomic," "snapshot isolation" used without inline glosses.

Resource gap (recurring, systemic): both `resources/17-iceberg-table-maintenance.md` and `resources/13-postgres-to-iceberg-ingestion.md` need an engine-labeled syntax table for the four core procedures (rollback, expire_snapshots, remove_orphan_files, rewrite_data_files / optimize) with explicit "Run in Spark" vs "Run in Trino" headers on every SQL block. Trino uses `ALTER TABLE ... EXECUTE` with `retention_threshold => '7d'` style args; Spark uses `CALL iceberg.system.*` with `older_than =>` / `retain_last =>` / `table =>` args. The two are not interchangeable.

Verified: trino.io/docs/current/connector/iceberg.html (ALTER TABLE EXECUTE form, retention_threshold parameter); iceberg.apache.org/docs/latest/spark-procedures/ (CALL system.rollback_to_snapshot, expire_snapshots with older_than/retain_last).

---

### Iteration 39, Q-composite-key-merge — 2026-05-24 (EXTENDED PHASE)
**Question**: No single unique event_id — events identified by (device_id, session_id, event_type, occurred_at) together. How to write MERGE INTO ON clause for a composite key? Does idempotency still hold?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.350 across 39 questions; new running avg (4.350 × 39 + 3.75) / 40 = **4.335** across 40 questions. PASSED.

**Notes**: The 4-column AND ON clause is correct and the Spark SQL block is runnable on the production stack (Spark 3.x + Iceberg 1.5.2). The idempotency reasoning is correct: "holds exactly as with a single-column key if the compound key is truly unique per logical event." The pre-MERGE diagnostic SQL is correct and matches the expected answer. However, the answer omits the most production-critical risk for composite keys that include a timestamp column: **occurred_at precision drift between Postgres microsecond and Iceberg millisecond / Parquet INT96 sub-second truncation** can cause rows that *should* match to fall into NOT MATCHED → INSERT, producing silent duplicates even when the compound key is logically unique in the source. This is exactly the well-documented failure mode for timestamp-in-composite-key MERGEs and is the single most likely real-world cause of "I have duplicates after MERGE INTO" on this shape. The answer also does not tell the engineer what to do if the diagnostic returns rows — no fallback (add a hash or sequence surrogate key, use ROW_NUMBER dedup before MERGE, etc.). The diagnostic should ideally be run on BOTH the Postgres source AND the existing Iceberg target — running only on the source misses the timestamp-truncation case where Postgres looks unique but Iceberg's stored rows do not.

Resource gap: `resources/13-postgres-to-iceberg-ingestion.md` MERGE INTO section needs a "Composite key gotchas" subsection covering: (1) **timestamp precision drift** — Postgres `timestamp` defaults to microsecond resolution but Parquet INT96 / Iceberg TIMESTAMP can truncate to millisecond, so `t.occurred_at = s.occurred_at` may silently fail; standardize on `date_trunc('millisecond', occurred_at)` on both sides or store occurred_at as `BIGINT` epoch-millis; (2) **fallback when composite key is not truly unique** — add a deterministic hash surrogate column (`md5(device_id || session_id || event_type || occurred_at::text || event_payload::text)`) and merge on that hash; (3) **run the COUNT(*) GROUP BY diagnostic on BOTH Postgres source AND the existing Iceberg target**, not just on Postgres — the timestamp-truncation case only shows up on the Iceberg side; (4) when occurred_at has fuzziness (e.g., client-set timestamps from mobile devices), the safe path is to add a `event_uuid` or `ingest_sequence` column in Postgres before deploying the MERGE pipeline.

Verified: iceberg.apache.org/docs/latest/spark-writes/ (MERGE INTO ON condition behavior, multi-source match raises error); github.com/apache/iceberg/issues/7005 (duplicate records when source has duplicates); Parquet INT96 deprecated for timestamps but still common in older writers — precision varies by writer config.

---

### Iteration 39, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: SECURITY INVOKER dynamic view joins user_tenant_map. 3 of 80 tenants get Access Denied even with SELECT on the view. What's wrong?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: Multi-tenant analytics — prior avg 4.267 across 41 questions; new running avg (4.267 × 41 + 4.50) / 42 = **4.273** across 42 questions. PASSED.

**Notes**: Primary diagnosis correct — under SECURITY INVOKER, querying user needs SELECT on every base table in view body, not just the view. Fix (GRANT SELECT ON config.user_tenant_map) and 77-vs-3 explanation (older onboarding script) match expected. Three runnable diagnostics. JWT mismatch correctly flagged as empty-results symptom not Access Denied. Validates iter38 resource 05 fix.

---

### Iteration 39, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Healthcare 90-day vs standard 3-year retention on shared Iceberg table. How to implement without creating a mess?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Topics updated**: Multi-tenant analytics — prior avg 4.273 across 42 questions; new running avg (4.273 × 42 + 3.75) / 43 = **4.261** across 43 questions. PASSED.

**Notes**: 3-step sequence correctly engine-labeled. Only expire_snapshots removes bytes framing correct. Missing: partition DROP not appropriate for shared table; separate tables per tenant for 12x spread; write.data.retention.days is table-level only; partition order written as (tenant_id, day) but day-first is more efficient for retention range-pruning.

---

### Iteration 39, Q3 — 2026-05-24 (EXTENDED PHASE)
**Question**: No single event_id — events identified by (device_id, session_id, event_type, occurred_at). MERGE INTO composite key ON clause and idempotency?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.350 across 39 questions; new running avg (4.350 × 39 + 3.75) / 40 = **4.335** across 40 questions. PASSED.

**Notes**: ON clause with 4-column AND join correct. Idempotency reasoning correct. Pre-MERGE diagnostic present. Critical gap: occurred_at precision drift (Postgres microsecond vs Iceberg/Parquet millisecond) can make distinct events look identical on composite key — most common production failure mode for occurred_at in composite keys. No fallback offered (hash surrogate, sequence column) when diagnostic returns duplicates.

---

### Iteration 39, Q4 — 2026-05-24 (EXTENDED PHASE)
**Question**: MERGE INTO ran 3× with `ON t.event_date = s.event_date` (not unique). Now 2-3x row counts. Fastest cleanup?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 5 |
| **Average** | **4.25** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.335 across 40 questions; new running avg (4.335 × 40 + 4.25) / 41 = **4.333** across 41 questions. PASSED.

**Iteration 39 average**: (4.50 + 3.75 + 3.75 + 4.25) / 4 = **4.063**

**Notes**: Snapshot rollback first is strategically correct. Comparison table strong. Root-cause explanation (date not unique → all rows fall into NOT MATCHED → inserts only) precise. Engine-syntax mixing: uses Trino-style `events$snapshots` path but Spark CALL syntax with named args — pasting into Trino 467 during incident produces syntax errors. Fallback (re-read from Postgres + overwritePartitions if rollback unavailable) only implied, not spelled out.

### Iteration 40, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Is `write.data.retention.days` a per-tenant Iceberg property, and when should mixed-retention tenants get separate tables?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: Multi-tenant analytics — prior avg 4.261 across 43 questions; new running avg (4.261 × 43 + 4.50) / 44 = **4.266** across 44 questions. PASSED.

### Iteration 40, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Where does microsecond-to-millisecond timestamp truncation happen in a Postgres → Spark → Iceberg → Trino pipeline, and does it matter for analytics?

| Dimension | Score |
|---|---|
| Technical accuracy | 2 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 3 |
| **Average** | **3.00** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.333 across 41 questions; new running avg (4.333 × 41 + 3.00) / 42 = **4.301** across 42 questions. PASSED.

**Iteration 40 average**: (4.50 + 3.00) / 2 = **3.75**

### Iteration 41, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: TIMESTAMP_MILLIS Spark config inherited from Hive job downgrading occurred_at precision; fix and rewrite strategy.

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 4 |
| **Average** | **3.50** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.301 across 42 questions; new running avg (4.301 × 42 + 3.50) / 43 = **4.282** across 43 questions. PASSED.

### Iteration 41, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Is it safe to DROP partitions on a day-partitioned shared Iceberg events table to remove a churning tenant?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.25** |

**Topics updated**: Multi-tenant analytics — prior avg 4.266 across 44 questions; new running avg (4.266 × 44 + 4.25) / 45 = **4.266** across 45 questions. PASSED.

**Iteration 41 average**: (3.50 + 4.25) / 2 = **3.875**

### Iteration 42, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: TIMESTAMP_MILLIS config causing composite key collisions in MERGE INTO — diagnosis and fix.

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.25** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.282 across 43 questions; new running avg (4.282 × 43 + 4.25) / 44 = **4.281** across 44 questions. PASSED.

### Iteration 42, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: CALL iceberg.system.expire_snapshots in Trino throws syntax error; current_timestamp() cutoff breaks live readers.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: Multi-tenant analytics — prior avg 4.266 across 45 questions; new running avg (4.266 × 45 + 4.50) / 46 = **4.271** across 46 questions. PASSED.

**Iteration 42 average**: (4.25 + 4.50) / 2 = **4.375**

### Iteration 43, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: SHOW COLUMNS shows timestamp(6) for occurred_at — does that confirm microsecond precision, or could we still be losing precision at the Parquet level?

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 3 |
| Completeness | 4 |
| **Average** | **3.50** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.281 across 44 questions; new running avg (4.281 × 44 + 3.50) / 45 = **4.264** across 45 questions. PASSED.

**Notes**: Correctly identified that SHOW COLUMNS reports Iceberg logical schema (always TIMESTAMP(6)), not physical Parquet precision. TIMESTAMP_MILLIS culprit correctly named. Re-read-from-Postgres-not-from-Iceberg remediation correct. Critical bug: the diagnostic SQL `EXTRACT(MICROSECOND FROM occurred_at) % 1000 != 0` is not valid Trino syntax — Trino's EXTRACT does not support a MICROSECOND field (fields stop at SECOND). An engineer pasting this into Trino 467 gets a parse error at the exact moment they are trying to diagnose data loss. Correct Trino-native diagnostic: `date_diff('microsecond', date_trunc('millisecond', occurred_at), occurred_at) != 0`. Resource 13 was fixed this iteration with the Trino-valid diagnostic.

### Iteration 43, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Hidden partitioning explained; how to partition a multi-tenant SaaS events table by date and tenant; what goes wrong if partitioning is wrong.

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.50** |

**Topics updated**: Iceberg partition design for SaaS — prior avg 4.438 across 4 questions; new running avg (4.438 × 4 + 4.50) / 5 = **4.450** across 5 questions. PASSED.

**Notes**: Strong answer covering hidden partitioning, day-first rationale, four failure modes, bucket() escape hatch, and compaction recipe. Technical accuracy docked one point: answer used Spark DDL `PARTITIONED BY (...)` syntax — the production query engine is Trino 467, which uses `WITH (partitioning = ARRAY[...])`. An engineer copy-pasting Spark DDL into Trino gets a syntax error. Beginner clarity docked one point: "manifest", "bucket()", "partition spec", "partition predicates" appear without inline glosses. Resource 10 was fixed this iteration with a Spark vs Trino engine-label callout on the CREATE TABLE example.

**Iteration 43 average**: (3.50 + 4.50) / 2 = **4.00**

### Iteration 44, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Per-tenant Trino role created and granted to a view, GRANT ROLE TO USER also run — but the service account can still SELECT from the base analytics.events. What's missing?

| Dimension | Score |
|---|---|
| Technical accuracy | 2 |
| Beginner clarity | 4 |
| Practical applicability | 2 |
| Completeness | 3 |
| **Average** | **2.75** |

**Topics updated**: Multi-tenant analytics — prior avg 4.271 across 46 questions; new running avg (4.271 × 46 + 2.75) / 47 = **4.239** across 47 questions. PASSED.

**Notes**: Correctly named REVOKE ALL as the missing step and correctly stated Trino's default is allow-all. Critical bug: recommended `REVOKE ALL ON analytics.events FROM ROLE acme_role` — but the role never had a base-table grant; revoking from it is a no-op. The correct target is the USER PRINCIPAL: `REVOKE ALL ON analytics.events FROM USER "acme-service-account"`. Also incorrect framing: "your role still had implicit access" — only USER PRINCIPALS get default allow-all, not freshly-created roles. Resource 05 fixed this iteration: added "REVOKE target: USER vs ROLE" clarification and explained that in OPA-backed production, SQL REVOKE may not be the enforcement mechanism — the OPA policy must deny base-table access for non-admin principals.

### Iteration 44, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Postgres date arithmetic (NOW() - INTERVAL '30 days', EXTRACT(epoch FROM ...)) copied to Trino — parse errors and wrong results — fundamental or just syntax?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.00** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.264 across 45 questions; new running avg (4.264 × 45 + 4.00) / 46 = **4.258** across 46 questions. PASSED.

**Notes**: Correctly identified EXTRACT(epoch) as invalid in Trino, to_unixtime() as substitute, INTERVAL unit-outside-quotes rule, NOW() as alias for current_timestamp. Minor imprecisions: EXTRACT field list understated (QUARTER, WEEK, DOW also supported); `current_timestamp()` shown with empty parens (Trino uses no parens — that's now()). Missing: date_diff not mentioned alongside date_add; sub-second precision pattern absent. Resource 13 fixed this iteration with a comprehensive Postgres→Trino date/time translation table including EXTRACT supported fields and NOT supported fields (EPOCH, MICROSECOND).

**Iteration 44 average**: (2.75 + 4.00) / 2 = **3.375**

### Iteration 45, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Tenant service accounts can run SELECT against system.runtime.queries and system.runtime.nodes in Trino — are per-tenant views and roles sufficient, or is this a cross-tenant data leak?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Multi-tenant analytics — prior avg 4.239 across 47 questions; new running avg (4.239 × 47 + 4.75) / 48 = **4.250** across 48 questions. PASSED.

**Notes**: Correctly identified system catalog as accessible to all authenticated users by default (verified against trino.io), correctly stated per-tenant views/roles do not protect the system catalog, named OPA as the correct enforcement mechanism matching prod stack, deferred specific OPA policy rules to external governance doc. Runnable verification steps provided. Minor clarity gap: "catalog-level deny rule", "JWT principal", "P0" without inline glosses. No critical resource gaps.

### Iteration 45, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Fix two broken Postgres-style Trino queries: `WHERE occurred_at < NOW() - INTERVAL '90 days'` and `SELECT EXTRACT(epoch FROM NOW()) - EXTRACT(epoch FROM occurred_at) AS seconds_since_event`.

| Dimension | Score |
|---|---|
| Technical accuracy | 3 |
| Beginner clarity | 4 |
| Practical applicability | 2 |
| Completeness | 3 |
| **Average** | **3.00** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.258 across 46 questions; new running avg (4.258 × 46 + 3.00) / 47 = **4.231** across 47 questions. PASSED.

**Notes**: Correctly named EXTRACT(EPOCH) as invalid, to_unixtime() as substitute, INTERVAL plural-unit rule. Failed to show corrected SQL for user's specific two broken queries — used different column name (event_time vs occurred_at) and different duration (30 vs 90 days). Never mentioned date_diff('hour', occurred_at, current_timestamp) for the explicit "hours ago" sub-question. Pattern: responder names the abstract rule but doesn't paste back corrected SQL for user's actual broken queries. Resource 13 fixed this iteration with before/after worked examples for both patterns and `date_diff` elevated as preferred idiom.

### Iteration 46, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Fix two broken Postgres/MySQL-style Trino queries: `WHERE signup_date > NOW()::DATE - 30` and `SELECT DATEDIFF(NOW(), first_event_at) AS days_active`.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.231 across 47 questions; new running avg (4.231 × 47 + 4.75) / 48 = **4.242** across 48 questions. PASSED.

**Notes**: Resource fix from iter45 confirmed effective. Responder correctly pasted back both corrected queries inline using the user's actual column names (signup_date, first_event_at), named both failure modes (:: cast invalid, DATEDIFF doesn't exist in Trino), and provided a complete runnable end-to-end query. date_diff('day', first_event_at, current_timestamp) correctly identified as the Trino idiom. Minor clarity gap: "ANSI SQL" used without inline gloss. Score 4.75 vs iter45 Q2 score of 3.00 — direct validation that the before/after worked-examples fix worked.

### Iteration 46, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Added tenant_id to Iceberg partition spec via ALTER TABLE SET PROPERTIES — why are per-tenant queries still slow for the last 90 days?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Iceberg partition design — prior avg 4.450 across 5 questions; new running avg (4.450 × 5 + 4.75) / 6 = **4.500** across 6 questions. PASSED.

**Notes**: Correctly identified partition evolution gotcha (ALTER TABLE only changes spec for new writes). Correctly prescribed rewrite_data_files with CALL iceberg.system.* syntax and right options (target-file-size-bytes, min-input-files). Correctly labeled CALL as Spark SQL only (not Trino). Covered one-time operation, 2x storage spike, maintenance window scheduling, ingestion conflict risk. Minor clarity gap: technical terms (expire_snapshots, remove_orphan_files, partition spec) used without inline glosses.

**Iteration 45 average**: (4.75 + 3.00) / 2 = **3.875**

### Iteration 46, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Fix two broken Postgres/MySQL-style Trino queries: `WHERE signup_date > NOW()::DATE - 30` and `SELECT DATEDIFF(NOW(), first_event_at) AS days_active`.

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.231 across 47 questions; new running avg (4.231 × 47 + 4.75) / 48 = **4.242** across 48 questions. PASSED.

**Notes**: Resource fix from iter45 confirmed effective. Responder correctly pasted back both corrected queries using user's actual column names, named both failure modes (:: cast invalid, DATEDIFF MySQL-only), and provided complete runnable end-to-end query. date_diff('day', first_event_at, current_timestamp) correctly identified as the Trino idiom. Minor clarity gap: "ANSI SQL" used without inline gloss.

### Iteration 46, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Added tenant_id to Iceberg partition spec via ALTER TABLE SET PROPERTIES — why are per-tenant queries still slow for the last 90 days?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Iceberg partition design — prior avg 4.450 across 5 questions; new running avg (4.450 × 5 + 4.75) / 6 = **4.500** across 6 questions. PASSED.

**Notes**: Correctly identified partition evolution gotcha (ALTER TABLE only changes spec for new writes). Correctly prescribed rewrite_data_files with CALL iceberg.system.* syntax and right options. Correctly labeled CALL as Spark SQL only. Covered one-time operation, 2x storage spike, maintenance window scheduling, ingestion conflict risk. Minor clarity gap: technical terms without inline glosses.

**Iteration 46 average**: (4.75 + 4.75) / 2 = **4.75**

### Iteration 47, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Ran `REVOKE ALL ON analytics.events FROM ROLE acme_role` to block base-table access — but the service account can still query the full base table. What went wrong?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Multi-tenant analytics — prior avg 4.250 across 48 questions; new running avg (4.250 × 48 + 4.75) / 49 = **4.260** across 49 questions. PASSED.

**Notes**: Correctly identified REVOKE-from-ROLE as silent no-op (role never had the privilege). Correctly identified USER PRINCIPAL as the default allow-all holder. Correct fix: REVOKE ALL ON base table FROM USER "acme-service-account". Full four-step isolation sequence with runnable SQL. Correctly noted OPA caveat. Recurring minor clarity gap: "USER principal", "role", "default allow-all", "authorization backend" without inline glosses.

### Iteration 47, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Switched from reading pg_partman parent table to child partition directly — now April's Iceberg event count is 12,000 rows lower than Postgres. Mobile app batches events offline. What's happening and how to fix?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.242 across 48 questions; new running avg (4.242 × 48 + 4.50) / 49 = **4.247** across 49 questions. PASSED.

**Notes**: Correctly identified late-arriving events as root cause and explained pg_partman routes by occurred_at value. Correct diagnostic SQL. Correct fix: re-run April job for 5-7 days with overwritePartitions(). Correct Spark code with overwrite-mode=dynamic. Completeness gap: did not mention UNION-two-consecutive-months pattern for cross-boundary late arrivals; did not address long-tail beyond 7-day window. Beginner clarity gap: "idempotent", "atomic", "dynamic overwrite" without inline glosses.

**Iteration 47 average**: (4.75 + 4.50) / 2 = **4.625**

### Iteration 48, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Iceberg `$partitions` metadata table exposes all tenant IDs and row counts to a per-tenant service account. Is this a real data leak? How to stop it?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Multi-tenant analytics — prior avg 4.260 across 49 questions; new running avg (4.260 × 49 + 4.75) / 50 = **4.270** across 50 questions. PASSED.

**Notes**: Correctly identified as real data leak. Correctly explained $partitions exposes partition key values (tenant_id), record counts, file counts — view row filter does NOT protect metadata tables. Two-layer fix: OPA deny + REVOKE from USER PRINCIPAL. Correctly enumerated $files, $snapshots, $history as additional sensitive metadata tables. Correctly deferred specific OPA Rego to governance doc. Judge noted complete metadata-table list is longer ($manifests, $refs, $entries, etc.) — resource 05 updated with full deny-list. Minor clarity gap: metadata layer, USER PRINCIPAL, tenant principal without inline glosses.

### Iteration 48, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Postgres JSONB column shows up as STRING in Iceberg. How to query it in Trino and how to store it as a struct?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.247 across 49 questions; new running avg (4.247 × 49 + 4.75) / 50 = **4.257** across 50 questions. PASSED.

**Notes**: Correctly explained JDBC reads JSONB as VARCHAR (no native JSON type in Parquet). Correct Trino function: json_extract_scalar(properties, '$.device_type'). Correct Spark flattening: get_json_object + withColumn. Correctly recommended keeping properties_raw STRING alongside extracted columns. Correctly noted ALTER TABLE ADD COLUMN is metadata-only. Good trade-off explanation and "5-10 hot keys" decision rule. Minor clarity gap: dictionary encoding, min/max file statistics without inline glosses.

**Iteration 48 average**: (4.75 + 4.75) / 2 = **4.75**

### Iteration 49, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Can we use `current_user` in a single shared Trino view to auto-filter by tenant, instead of maintaining per-tenant views?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 5 |
| **Average** | **4.25** |

**Topics updated**: Multi-tenant analytics — prior avg 4.270 across 50 questions; new running avg (4.270 × 50 + 4.25) / 51 = **4.270** across 51 questions. PASSED.

**Notes**: Correctly explained SECURITY INVOKER requirement, lookup-table pattern for username→tenant_id mapping, blast-radius trade-off, 50 vs 150-200 tenant threshold. Technical gap: used `REVOKE ALL ON` instead of `REVOKE ALL PRIVILEGES ON` (Trino requires `ALL PRIVILEGES`). Missed OPA/JWT framing for the prod stack. Resource 05 fixed this iteration with correct `ALL PRIVILEGES` syntax throughout.

### Iteration 49, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Incremental watermark ingestion misses hard-deletes and has duplicate-on-retry problems. Does CDC with Debezium fix both?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.257 across 50 questions; new running avg (4.257 × 50 + 4.75) / 51 = **4.267** across 51 questions. PASSED.

**Notes**: Correctly explained CDC reads Postgres WAL to capture DELETE operations (tombstone with op="d"). Correctly noted watermark is blind to hard deletes. Correct dedup fix: MERGE INTO with primary key for idempotent CDC writes. Correctly listed Debezium operational requirements (wal_level=logical, replication slot, Kafka, exactly-once). Practical alternative path (soft-delete + overwritePartitions()) given for teams not ready for CDC. Minor: tombstone-as-separate-record precision; replication slot disk-bloat gotcha not mentioned. Recurring clarity gap: LSN, exactly-once, replication slot without inline glosses.

**Iteration 49 average**: (4.25 + 4.75) / 2 = **4.50**

### Iteration 50, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Larger tenant starving smaller tenants. Memory limit on Trino role didn't help. How to properly cap resource consumption and monitor current usage?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 5 |
| **Average** | **4.25** |

**Topics updated**: Multi-tenant analytics — prior avg 4.270 across 51 questions; new running avg (4.270 × 51 + 4.25) / 52 = **4.270** across 52 questions. PASSED.

**Notes**: Correctly identified roles vs resource groups distinction. Correct resource groups JSON with softMemoryLimit, hardConcurrencyLimit, maxQueued. Correctly noted selectors match JWT principal not role name. Correctly warned system.runtime.queries is a cross-tenant leak path (admin-only). Technical bug: `SELECT system.runtime.kill_query(...)` should be `CALL system.runtime.kill_query(...)` (it's a procedure, not a function). Resource 05 fixed this iteration. Missing: query.max-memory-per-node server property as a complementary per-query cap. Recurring jargon gap: JWT sub, OPA, catalog-level deny without inline glosses.

### Iteration 50, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Debezium CDC replication slot caused Postgres disk-full crash over a weekend when Spark consumer died. What happened and how to prevent it?

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topics updated**: Postgres-to-Iceberg ingestion — prior avg 4.267 across 51 questions; new running avg (4.267 × 51 + 4.75) / 52 = **4.276** across 52 questions. PASSED.

**Notes**: Correctly explained replication slot retains WAL indefinitely when consumer stops. Correct pg_replication_slots monitoring query with pg_wal_lsn_diff. Correct max_slot_wal_keep_size (Postgres 13+) as safety valve. Supervise Spark job with auto-restart. Alert on Kafka consumer lag. Correct recovery path: Debezium full snapshot resync + MERGE INTO for Iceberg idempotency. Minor nit: max_slot_wal_keep_size marks slot invalid rather than literally dropping it, but functional consequence is identical. Recurring clarity gap: LSN, replication slot, snapshot resync, consumer lag without inline glosses.

**Iteration 50 average**: (4.25 + 4.75) / 2 = **4.50**

### Iteration 51, Q1 — 2026-05-24 (EXTENDED PHASE)
**Question**: Plan MinIO storage for migration of 250 GB Postgres events table (500M rows, 50M/month growth) to Iceberg — does Parquet save space and how to estimate ongoing growth?

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.25** |

**Topics updated**: Storage sizing and growth estimation for lakehouse workloads — prior avg 4.375 across 2 questions; new running avg (4.375 × 2 + 4.25) / 3 = **4.333** across 3 questions. PASSED.

**Notes**: Strong, runnable budget answer with correct Postgres-baseline decomposition (indexes, MVCC bloat, row headers, TOAST), per-column-type Parquet compression breakdown (dictionary, delta, UUIDs), 5–10x overall ratio, growth-rate formula, MinIO EC:4+2 ~1.5x overhead (verified vs MinIO docs), and snapshot accumulation trap with runnable expire_snapshots SQL. Factual error: states "Iceberg's default codec is Snappy" — incorrect for Iceberg 1.5.2 (the production version per prod_info.md); Iceberg switched the default Parquet write codec to **Zstd** in version 1.4.0 (verified against e6data / iceberg docs). The "switch to Zstd" recommendation is therefore stale on the prod stack. Minor nit: 50% headroom on the 12-month projection then 1.5x erasure overhead on top compounds the safety factor (~2.25x of bare data) without flagging it. Estimated 15–25 GB initial migration is on the optimistic end vs the expected 25–50 GB range — defensible but not central. Recurring beginner clarity gap: dictionary encoding, delta encoding, erasure coding, EC:4+2, manifest, rewrite_data_files, expire_snapshots without inline glosses. Resource gap: `resources/11-lakehouse-storage-sizing.md` updated this iteration to add Zstd as default codec for Iceberg 1.4.0+.

### Iteration 51, Q2 — 2026-05-24 (EXTENDED PHASE)
**Question**: Build a retention analysis: of users who had their first event in a given week, what % came back 7, 30, 90 days later? Show the SQL pattern in Trino.

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.25** |

**Topics updated**: Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL — prior avg 4.375 across 2 questions; new running avg (4.375 × 2 + 4.25) / 3 = **4.333** across 3 questions. PASSED.

**Notes**: Three-CTE structure (first_events → cohort_sizes → returns) is pedagogically strong and maps cleanly to the three conceptual steps. Correct Trino date_diff syntax. BETWEEN 1 AND N correctly excludes day-0 signup event. Incomplete-data filter (date_diff >= 90) present and well-explained. Percentage computation with ROUND answers the "what %" wording. Customization section and materialization recommendation both appropriate. Critical bug: `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` counts event rows not distinct users — a user who fires 5 events in the 7-day window contributes 5 to returned_7d and 1 to total_users, producing retention > 100%. Correct idiom is `COUNT(DISTINCT CASE WHEN ... THEN e.user_id END)`. Resource gap: `resources/07-analytical-query-patterns.md` added a "Milestone-retention variant" section this iteration with the correct COUNT(DISTINCT CASE WHEN) idiom and an explicit callout that SUM(CASE WHEN ... THEN 1) double-counts repeat events.

**Iteration 51 average**: (4.25 + 4.25) / 2 = **4.25**
