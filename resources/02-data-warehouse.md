# What a Data Warehouse Is and When Your SaaS Product Needs One

> **Note:** The production environment in `prod_info.md` is not yet filled in. This resource gives advice for a generic SaaS setup. Once your stack is described, re-read this with your specific tools in mind.

---

## Concept in one sentence

A **data warehouse** is a central database built specifically for analysis — it pulls data from multiple sources, stores it in a structure optimized for queries, and serves as the single source of truth for your company's numbers.

---

## Why it matters for SaaS

A typical SaaS product scatters its data across several systems: the application database (Postgres/MySQL), a payment processor (Stripe), a product analytics tool (Mixpanel or Amplitude), maybe a CRM (Salesforce), and email/support tools. None of these talk to each other.

When someone asks "what's our revenue from customers who signed up via the free trial and sent more than 10 messages in their first week?" — that answer lives across three different systems with no easy join.

A data warehouse solves this by being the *one place* where all that data lands, cleaned, and ready to query together. It's the difference between having to phone four departments to get an answer versus just running a query.

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

**Early signals that you're ready:**
- Your BI/analytics queries are slow on production and you can't afford to keep a read replica just for analytics
- You need to join data from more than one source (app DB + payments + events + CRM)
- Multiple people (data analysts, CS, finance, PMs) need to query data independently
- You want to track metrics over time that don't live in your app DB (e.g., Stripe MRR trends joined with user behavior)
- Your data team spends most of their time exporting CSVs and wrangling spreadsheets

**You probably don't need one yet if:**
- You're pre-PMF and your team is fewer than ~10 people
- All the data you care about lives in one database and fits on a read replica
- Your analytics needs are met by a tool like Metabase or Redash pointed at a read replica

**A common growth path:** Postgres read replica → Postgres replica + dbt → BigQuery/Snowflake/ClickHouse with a proper pipeline.

---

## Popular warehouse options (brief overview)

| Tool | Best for | Pricing model |
|---|---|---|
| **BigQuery** (Google) | Serverless, pay-per-query, integrates well with GCP | Per TB scanned |
| **Snowflake** | Multi-cloud, large enterprise, flexible scaling | Per credit (compute time) |
| **ClickHouse** | Extremely fast on time-series and event data; self-hosted or cloud | Per resource used |
| **DuckDB** | Local/embedded analytics; great for small-to-medium data or development | Free / open-source |
| **Redshift** (AWS) | AWS-native, good for existing AWS shops | Per node-hour |

A dedicated resource covers each of these in depth. The right choice depends heavily on your cloud provider and data scale — see `prod_info.md` for constraints.

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
