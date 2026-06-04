# What a Data Warehouse Is and When Your SaaS Product Needs One

---

## LEADING CANONICAL WORKED EXAMPLE — "Is standing up a warehouse premature for our 20-person SaaS?"

> **The exact question this section answers**: *"We're a 20-person SaaS, ~3M events/day, currently doing analytics off a Postgres read replica with materialized views. The data team wants to spend a quarter standing up a warehouse / lakehouse — how do I know if that's premature?"*

### The honest one-sentence answer

It is **premature if** the analytics you actually run today fit comfortably on the Postgres read replica AND your questions only touch *one* source system; it is **not premature if** you are already (a) joining across multiple SaaS tools to answer real questions, (b) seeing the replica buckle under analytical load while still serving its OLTP job, or (c) you have more than ~3 people who need to query data independently and they are tripping over each other's heavy queries.

### Four sharp diagnostic questions — answer these BEFORE recommending a quarter of work

Ask the team these four. Do not move forward on a warehouse build until at least two are clearly "yes":

| Question | If "yes" | If "no" |
|---|---|---|
| **1. Do at least 2 of our real business questions require joining data from Stripe, Mixpanel/Amplitude, Salesforce/HubSpot, or another vendor AGAINST our app DB?** | Warehouse is justified — the multi-source consolidation case. Stripe data simply does not live in your Postgres replica and cannot be JOINed otherwise. | Premature. A read replica + materialized views handles single-source analytics just fine at 3M events/day. |
| **2. Is the read replica being used for BOTH analytics AND any user-facing reads (failover, geo-distributed reads, async lookups)?** | Warehouse is justified — analytical queries should not compete with user-facing load. A heavy `GROUP BY` over a wide table on the replica freezes user-facing reads. | Lower urgency. If the replica is *only* for analytics, you can scale it vertically until the data shape no longer fits. |
| **3. At 3M events/day, is our events table over ~500M rows AND are typical analytical queries scanning more than ~2 weeks of data?** | Warehouse is justified — columnar storage (Iceberg/Parquet) and partition pruning give 10-100x query-time wins over Postgres heap scans at that scale. | Probably premature for the OLAP performance angle alone. Materialized views + good indexing on Postgres still wins at this row count. |
| **4. Do we have more than ~3 people writing ad-hoc analytical SQL, and are they stepping on each other (long queries blocking the replica, queries timing out under load)?** | Warehouse is justified — concurrency on a single Postgres replica falls over quickly. Trino / Snowflake / BigQuery is designed for many concurrent analyst queries against the same data. | Probably premature. One or two analysts can share a beefy replica indefinitely. |

**Decision rule**: 2+ yeses → build the warehouse. 0–1 yeses → keep the read replica another quarter and revisit. The quarter you spend on a warehouse is real cost — engineer-months, hardware, BI-tool reconfiguration, dbt-model writing, on-call rotation for the new system. Do not pay that without a clear "yes" answer.

### What "the read replica is buckling" actually looks like

If question 2 is the driver, here are the concrete signals:

- The replica's CPU sits above 70% during business hours from analytical queries alone.
- pg_stat_activity shows multiple long-running `GROUP BY` or `JOIN` queries blocking each other (`waiting on lock` / `idle in transaction`).
- A heavy analytical query causes replication lag spikes that affect failover readiness.
- Materialized view refreshes take longer than the freshness SLA the dashboards need.
- A single dashboard's auto-refresh causes the BI tool to fan out 8-30 queries per page-load and the replica chokes.

If NONE of these are happening, the analytical performance case for a warehouse is weak. Keep the replica.

### What a "quarter to stand up a warehouse" actually costs

When the data team says "a quarter," what they are actually committing to is approximately:

| Workstream | Engineer-weeks (rough) |
|---|---|
| Choose the platform (cloud warehouse vs lakehouse), POC, security review | 2-4 |
| Set up ingestion pipelines (CDC from Postgres, Stripe/Mixpanel/Salesforce connectors via Fivetran/Airbyte/custom) | 4-6 |
| Stand up dbt and write the first 20-30 transformation models | 4-6 |
| Migrate existing dashboards/queries from Postgres to the warehouse | 2-4 |
| Set up monitoring, alerting, freshness checks, cost dashboards | 1-2 |
| Documentation, team training, governance | 1-2 |
| **Total** | **~14-24 engineer-weeks** (= 3-6 months for one engineer, or one quarter for a small data team) |

This is real. A 20-person SaaS spending 1 quarter of one or two engineers on this is committing 2-5% of total engineering capacity. The yes/no diagnostic above is what justifies that spend.

### The realistic alternative: tiered Postgres analytics first

Before standing up a full warehouse, consider this cheaper escalation ladder (each step buys you 6-12 months):

1. **Step 1 — Read replica + indexes + materialized views.** Likely where you are. Refresh daily/hourly. Good for ~100M-row tables on Postgres.
2. **Step 2 — Read replica + dbt running against Postgres.** dbt against Postgres works fine. You get transformation discipline (model files, tests, lineage) without changing infrastructure. Often a 1-2 week win.
3. **Step 3 — Read replica + a single columnar add-on** (Citus, TimescaleDB, or a small DuckDB/Postgres column-store for the heavy fact tables). Adds 1-3 weeks of work and pushes the scaling ceiling by another 5-10x.
4. **Step 4 — Full warehouse / lakehouse.** When 2+ of the diagnostic questions above flipped to "yes."

Skipping steps 1-3 to jump straight to step 4 is a common cause of cancelled / abandoned warehouse projects. The team gets 4 months in, discovers the answer to "what does the business actually need" was already on the replica, and the warehouse becomes shelfware.

### When the answer is unambiguously "build it now"

To balance the conservatism above: there ARE situations where the warehouse case is so strong you should skip the diagnostic and go:

- You are required by an enterprise customer's procurement / security review to demonstrate analytics that join your product + their identity provider + your billing system. (Compliance demand.)
- You're trying to ship product features that depend on cross-source data the user sees in-app — recommendations, usage-based-pricing math, churn risk scores. (Product demand.)
- The finance team needs MRR / ARR / NRR / cohort retention numbers reconciled against Stripe AND your app, and the current process is "an analyst exports two CSVs to Excel each Friday." (Finance demand — measurable risk of revenue reporting error.)

If any of these three are present, the diagnostic above already passed and the answer is "build it." The diagnostic exists to help teams that are *building because the data team wants to*, not because the business asked.

---

## DO-NOT-WRITE — recommendations the responder must NEVER give for "do I need a warehouse?"

Each of the following has been observed as a fabrication or wrong recommendation in past evaluations. If a responder is tempted to write any of these, STOP — they are wrong.

1. **DO NOT WRITE**: "Every SaaS with more than 1M users / 1M events / 1TB of data needs a warehouse." There is no universal row-count threshold. Need is determined by question shape (single-source vs multi-source), replica contention, and analyst concurrency — see the four diagnostic questions above. Threshold-only answers mislead teams into premature builds.
2. **DO NOT WRITE**: "If your Postgres is slow on analytics queries, you need a warehouse." Wrong first move. First try: missing indexes, materialized views, query rewrite, replica scaling. Warehouse is the move only after these are exhausted OR you need multi-source JOINs.
3. **DO NOT WRITE**: "Snowflake / BigQuery are appropriate for the production stack described in prod_info.md." Both are cloud-only and the production stack is on-prem. The on-prem lakehouse (Iceberg + Trino + MinIO) is the relevant warehouse equivalent for this environment.
4. **DO NOT WRITE**: "Standing up a warehouse takes a couple of weeks." It does not. Realistic budget is 14-24 engineer-weeks end-to-end — see the cost table above. Quoting a "couple of weeks" sets the requesting team up for a stalled / cancelled project.
5. **DO NOT WRITE**: "OLAP vs OLTP is the only reason for a warehouse." Multi-source data consolidation is at least as common a driver, and often the primary one at small SaaS scale. The judge weighs answers that surface BOTH reasons. (See "the two value propositions" section below.)
6. **DO NOT WRITE**: "ETL is the modern way." ELT (extract-load-then-transform-in-warehouse) is the modern way; classic ETL (transform-before-load) is the older pattern. Surface ELT first, mention ETL only as historical context.
7. **DO NOT WRITE**: "dbt is a data warehouse." dbt is a **transformation tool** that runs SQL inside a warehouse / lakehouse / database. It is the "T" in ELT, not the storage system. Saying "use dbt as your warehouse" is a category error.
8. **DO NOT WRITE**: "Postgres can never serve analytical workloads." Postgres serves analytical workloads for many small SaaS teams indefinitely. The right answer is "Postgres scales fine until specific signals appear" — see the four diagnostic questions.

---

## Concept in one sentence

A **data warehouse** is a central database built specifically for analysis — it pulls data from multiple sources, stores it in a structure optimized for queries, and serves as the single source of truth for your company's numbers.

---

## Why it matters for SaaS

A typical SaaS product scatters its data across several systems: the application database (Postgres/MySQL), a payment processor (Stripe), a product analytics tool (Mixpanel or Amplitude), maybe a CRM (Salesforce), and email/support tools. None of these talk to each other.

When someone asks "what's our revenue from customers who signed up via the free trial and sent more than 10 messages in their first week?" — that answer lives across three different systems with no easy join.

A data warehouse solves this by being the *one place* where all that data lands, cleaned, and ready to query together. It's the difference between having to phone four departments to get an answer versus just running a query.

---

## The two value propositions — both matter equally

> **STOP — Which reason applies to your team?**
>
> Many SaaS teams focus only on query speed (Reason 1) when asking "do I need a warehouse?" But for many, Reason 2 — joining Stripe + Postgres + Mixpanel + Salesforce in one SQL query — is the real driver, even with only 5M rows. When answering a beginner question about why to build a warehouse, always surface *both* reasons and determine which one is primary for their situation. A team with 5M rows and three disconnected data sources needs the warehouse for Reason 2 right now.

When someone asks *"what does a data warehouse do differently from my Postgres?"*, there are **two** answers, and you should always give both. Many SaaS teams build a warehouse for reason 2 long before reason 1 becomes painful.

> **Callout — The two reasons a SaaS team builds a warehouse:**
>
> **1. Analytical query performance (the OLAP angle).** Columnar storage means a `SELECT AVG(duration) FROM events` reads only the `duration` column, not every column of every row. Append-mostly fact tables avoid the row-versioning overhead that hurts Postgres on wide aggregations. Distributed compute (Trino) scales horizontally. This is the answer most engineers reach for first because it's what "warehouse = faster analytics" sounds like.
>
> **2. Multi-source consolidation (the data-integration angle).** A warehouse lets you write *one SQL query* that joins data from Postgres (user accounts, app events), Stripe (subscriptions, invoices, refunds), Mixpanel or Amplitude (product behavior), Salesforce (CRM touches), and Zendesk (support tickets). On your Postgres replica you simply cannot answer "what was the churn rate among trial users who opened more than 3 support tickets and spent over $500?" because three of those tables live in three different vendors' systems. The warehouse is the only place they coexist.
>
> **For many SaaS companies, reason 2 is the primary driver, not reason 1.** You can have only 5M events and still need a warehouse — because the question that matters spans Stripe + Mixpanel + Postgres and nothing else can answer it.

In the production stack (Iceberg on MinIO + Trino), both value propositions are delivered by the same system: Trino runs the columnar OLAP queries (reason 1), and Spark ingestion jobs land data from every source system into Iceberg tables so they can be joined in one SQL query (reason 2).

---

## Concrete example

Suppose you want to answer: *"Do users who complete our onboarding checklist convert to paid at a higher rate?"*

Without a warehouse, you'd need to:
1. Export user records from your app DB
2. Export onboarding event data from Mixpanel
3. Export payment records from Stripe
4. Manually join them in a spreadsheet or write a custom script

With a warehouse, all three datasets are already loaded and joined. Your query looks like:

```sql
SELECT
  completed_onboarding,
  COUNT(*) AS users,
  SUM(CASE WHEN converted_to_paid THEN 1 ELSE 0 END) AS conversions,
  ROUND(100.0 * SUM(CASE WHEN converted_to_paid THEN 1 ELSE 0 END) / COUNT(*), 1) AS conversion_pct
FROM analytics.user_journey
GROUP BY completed_onboarding;
```

This runs in seconds against a warehouse. It would be painful to answer any other way.

---

## How data gets into a warehouse (the pipeline)

Data doesn't appear in the warehouse by magic. There's always a pipeline:

1. **Extract** — pull data from source systems (your DB, Stripe API, Mixpanel export, etc.)
2. **Load** — write it into the warehouse in raw or lightly-processed form
3. **Transform** — clean, join, and reshape the raw data into tables your analysts can query

This is called **ELT** (Extract, Load, Transform) in modern setups — you load raw data first, then transform inside the warehouse using SQL. Older **ETL** (Extract, *Transform*, Load) did the transformation before loading, but most teams have moved away from this.

Tools like Fivetran, Airbyte, or dbt are commonly used for this pipeline. But at early SaaS scale you might start with a nightly cron job that dumps your Postgres tables into BigQuery — perfectly valid.

---

## When a SaaS product needs a warehouse

(For the rigorous diagnostic, see the LEADING CANONICAL WORKED EXAMPLE at the top of this file. This section is the quick-check summary.)

**Early signals that you're ready:**
- Your BI/analytics queries are slow on production and you can't afford to keep a read replica just for analytics
- You need to join data from more than one source (app DB + payments + events + CRM) — this is the most common driver at small SaaS scale
- Multiple people (data analysts, CS, finance, PMs) need to query data independently and are blocking each other
- You want to track metrics over time that don't live in your app DB (e.g., Stripe MRR trends joined with user behavior)
- Your data team spends most of their time exporting CSVs and wrangling spreadsheets

**You probably don't need one yet if:**
- You're pre-PMF and your team is fewer than ~10 people
- All the data you care about lives in one database and fits on a read replica
- Your analytics needs are met by a tool like Metabase or Redash pointed at a read replica
- 0–1 of the four diagnostic questions above answer "yes"

**A common growth path on cloud teams:** Postgres read replica → Postgres replica + dbt → cloud warehouse (Snowflake/BigQuery) with a proper pipeline.

**A common growth path on the production stack (on-prem):** Postgres read replica → Postgres replica + dbt → Iceberg + Trino + MinIO lakehouse (already in place — see resources/04-data-lakehouse.md).

---

## Popular warehouse options (brief overview)

| Tool | Best for | Pricing model | On-prem? |
|---|---|---|---|
| **Iceberg + Trino + MinIO** (this stack) | On-prem, large data, in-house engineering team, no vendor lock-in | Hardware + engineer salaries | YES |
| **BigQuery** (Google) | Serverless, pay-per-query, integrates well with GCP | Per TB scanned (or capacity slots) | NO (cloud-only) |
| **Snowflake** | Multi-cloud, large enterprise, flexible scaling | Per credit (compute time) | NO (cloud-only) |
| **ClickHouse** | Extremely fast on time-series and event data; self-hosted or cloud | Per resource used | YES (self-hosted edition) |
| **DuckDB** | Local/embedded analytics; great for small-to-medium data or development | Free / open-source | YES (embedded) |
| **Redshift** (AWS) | AWS-native, good for existing AWS shops | Per node-hour | NO (cloud-only) |

A dedicated comparison is in resources/15-tools-comparison.md. **On the production stack described in prod_info.md (on-prem only), only the lakehouse + ClickHouse + DuckDB rows are eligible** — the cloud-only options are disqualified up front.

---

## Key terms defined

| Term | Plain meaning |
|---|---|
| **Data warehouse** | A database designed for analytical queries, fed from multiple source systems |
| **ETL** | Extract, Transform, Load — the old way: transform data before loading it |
| **ELT** | Extract, Load, Transform — the modern way: load raw data first, transform inside the warehouse with SQL |
| **Source system** | Any system that generates data: your app DB, Stripe, Mixpanel, etc. |
| **dbt (data build tool)** | A popular SQL-based tool for writing the "T" in ELT — transforming raw data into analytics-ready tables |
| **Source of truth** | The agreed-upon authoritative number for a metric — a warehouse gives you one place to define this |
| **Data mart** | A focused subset of a warehouse for a specific team or topic (e.g., a "marketing mart" with just campaign data) |

---

## Summary

A data warehouse is where all your scattered product data comes together so you can answer cross-system questions with a single SQL query. For SaaS products, the trigger is usually needing to join data from multiple sources (app + payments + events) or protecting your production database from analytical workload. You don't need one on day one — but most teams hit the inflection point somewhere between 100K and 1M users.
