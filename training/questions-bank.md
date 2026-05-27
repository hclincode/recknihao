# Questions Bank

This file is a curated pool of real-world questions sourced from Stack Overflow, Hacker News, Reddit, and developer blogs. Each question reflects how a working SaaS application engineer (with no OLAP / data warehousing background) would actually ask about big data, lakehouse, and analytical systems topics — using their own vocabulary, with their own misconceptions, and grounded in concrete production scenarios.

The questions are tagged with the rubric topics they exercise so the training loop can target gaps in `resources/` coverage.

## How to use (for the `saas-engineer` agent)

1. **Pick a question** from the bank that aligns with the rubric topics currently below threshold (see `training/rubric.md`). Prefer questions whose `Used in iteration` field is still `—` so coverage broadens over time.
2. **Ask the question verbatim** (or with light paraphrasing to stay in character as a SaaS engineer). Do not rewrite it into "data engineer" vocabulary — the wording, confusion, and assumptions are intentional and part of the test.
3. **Stay in character** if the `weak-ai-responder` asks clarifying questions: respond as the SaaS engineer described in the question would, not as a data expert. Keep follow-ups grounded in the original production scenario.
4. **Record usage**: after a question is used, update its `Used in iteration` field with the iteration number (e.g., `Used in iteration: 7`). If a question is reused later, append additional iteration numbers (e.g., `Used in iteration: 7, 14`).
5. **Rotate topics**: avoid asking two questions from the same rubric topic back-to-back unless the judge explicitly flagged that topic as still weak.
6. **Add new questions** to the bottom of the file (continue numbering) when you encounter realistic gaps not covered here. Keep the same entry format.

---

### Q1: Schema — foreign keys / normalization
We have a Postgres schema that's been carefully normalized for years — users, accounts, subscriptions, events, all linked by foreign keys. Someone told me that when we move this to a data warehouse we should "denormalize" it. Doesn't that just mean duplicating data everywhere and making it easy to introduce inconsistencies? Why would you deliberately design something that would fail your university database course?
**Source**: Matillion 3NF vs dimensional modeling blog; HN "We built our customer data warehouse all on Postgres" https://news.ycombinator.com/item?id=39213309
**Rubric topics**: Schema design for analytics: denormalization, star schema basics; Lakehouse schema design: fact tables, dimension tables, denormalization
**Used in iteration**: —

### Q2: Schema — fact vs dimension concept
I keep seeing the terms "fact table" and "dimension table" in data warehouse tutorials. In Postgres I just have tables — there's no such concept. Is a fact table literally just the biggest table, or does it mean something specific? If I have an events table and a users table, which one is the fact table?
**Source**: Monte Carlo "Fact vs. Dimension Tables Explained"; dev.to beginner posts
**Rubric topics**: Schema design for analytics; Lakehouse schema design: fact tables, dimension tables, denormalization
**Used in iteration**: 14

### Q3: Partition gotcha — query still slow
I added a date partition to my Iceberg table on event_date and my queries are still slow. I'm filtering by WHERE event_date >= '2024-01-01' so shouldn't it skip all the old data? I ran EXPLAIN and it still shows millions of rows being scanned. What am I doing wrong?
**Source**: Starburst "Iceberg Partitioning and Performance Optimizations in Trino"; Trino episode 5
**Rubric topics**: Query performance basics: partitioning, indexing strategy for analytics; Iceberg partition design for SaaS
**Used in iteration**: 8

### Q4: Partition gotcha — wrong column
We partitioned our events table by tenant_id because we thought that would make per-customer queries faster. But we have 80 tenants and some have 1,000 events and some have 50 million. The big customers' queries are actually slower now. Did we partition wrong?
**Source**: HN "Ask HN: How did you scale your analytics workloads (Postgres)?" https://news.ycombinator.com/item?id=42291569
**Rubric topics**: Iceberg partition design for SaaS; Query performance basics
**Used in iteration**: 7

### Q5: Multi-tenant — proof for security team
Our security team is asking me to prove that customer A can never see customer B's rows in our analytics layer. I wrote a Trino view that filters by WHERE tenant_id = :current_tenant but they want a test that demonstrates the isolation holds even if someone writes a bad query. How do I actually verify this works?
**Source**: WorkOS "Tenant isolation in multi-tenant systems"
**Rubric topics**: Multi-tenant analytics: isolating customer data in SaaS
**Used in iteration**: 4

### Q6: Multi-tenant — GDPR delete
One of our enterprise customers canceled and they're asking us to delete all their data under GDPR. In Postgres this was DELETE FROM events WHERE tenant_id = 'acme'. But we just moved everything to Iceberg and our data team says "deletes are complicated." Why are deletes in a lakehouse more complex than in a database?
**Source**: BryteFlow CDC from Multi-Tenant Databases; r/dataengineering GDPR discussions
**Rubric topics**: Multi-tenant analytics: isolating customer data in SaaS
**Used in iteration**: 10

### Q7: Cost — Postgres to lakehouse estimate
We have a 200 GB Postgres database. Someone said Parquet compresses 10x so our data warehouse will only be 20 GB. That seems too good to be true. How do I actually estimate how much storage we'd use in a lakehouse, and are there hidden costs like snapshots or metadata?
**Source**: Dremio "Optimizing Cloud Data Costs with Apache Iceberg"; MotherDuck data warehouse costs
**Rubric topics**: Cost considerations for analytical workloads at SaaS scale; Storage sizing and growth estimation
**Used in iteration**: 11

### Q8: Tools — BigQuery vs Snowflake vs ClickHouse
We're a 15-person startup and we need to pick between BigQuery, Snowflake, and ClickHouse for our analytics. Everyone I talk to has a different opinion. How do I actually choose? What questions should I be asking myself?
**Source**: HackerNoon "Snowflake vs BigQuery vs ClickHouse"; PostHog "ClickHouse vs Snowflake"; HN thread https://news.ycombinator.com/item?id=36064488
**Rubric topics**: Popular tools overview: BigQuery, Snowflake, ClickHouse, DuckDB, Iceberg; Cost considerations
**Used in iteration**: 4

### Q9: Tools — self-hosted lakehouse hidden costs
I've been reading about Iceberg + Trino + MinIO as a self-hosted stack. The storage cost seems really cheap compared to Snowflake. But what's the hidden cost I'm not seeing? Is this something a small team can actually run?
**Source**: Starburst "Reducing data warehouse costs using Icehouse architecture"; MotherDuck startup playbook
**Rubric topics**: Popular tools overview; Cost considerations; When to add an OLAP layer vs staying on the transactional DB
**Used in iteration**: 7

### Q10: Real-time vs batch — freshness
Our product managers want analytics that's no more than 5 minutes stale. Right now we batch-copy from Postgres to our warehouse once a day. Is "5-minute freshness" a streaming problem or a batch problem? And what does setting up streaming actually involve?
**Source**: IBM "What Is Real-Time Data?"; Estuary "Data Streaming Technologies"
**Rubric topics**: Real-time vs batch analytics trade-offs
**Used in iteration**: 4

### Q11: Real-time vs batch — late-arriving events
We have a mobile app that sometimes batches events when a user is offline and sends them 30 minutes later. Our weekly active users dashboard shows different numbers depending on whether we filter by occurred_at or ingested_at. Which timestamp should I use and why?
**Source**: Databricks structured streaming docs; Trino + Iceberg late-arriving data tutorials
**Rubric topics**: Real-time vs batch analytics trade-offs; Analytical query patterns on Iceberg+Trino
**Used in iteration**: 6

### Q12: Integration — getting Postgres data in
I want to move our analytics off Postgres into a warehouse but I have no idea how data actually gets there. Do I write a cron job that does INSERT INTO bigquery SELECT * FROM postgres? Should I use Fivetran or Airbyte? What's CDC and do I need it?
**Source**: Airbyte "ETL Postgres to BigQuery"; Definite "Best ETL Tools for PostgreSQL 2026"
**Rubric topics**: When to add an OLAP layer; Popular tools overview
**Used in iteration**: 4

### Q13: Query patterns — funnel SQL
I want to know how many users go from signing up → activating → paying within 7 days. When I try to write the SQL I get confused about how to "follow" a user through steps and enforce the order and the time window. How do you actually write this query?
**Source**: Fivetran "Funnel Analysis and Conversion Metrics in SQL"; Mitzu "Funnels with SQL"
**Rubric topics**: Common analytical query patterns: aggregations, funnels, cohort, time-series; Analytical query patterns on Iceberg+Trino
**Used in iteration**: 11

### Q14: Query patterns — cohort / retention
My investors keep asking for "cohort retention". I think I understand what it means — group users by when they signed up and see how many are still active each month. But I've never written that query. Is this something standard SQL can do?
**Source**: Medium "E-Commerce Cohort, Retention, Churn & Funnel Analysis using SQL"; r/SaaS and HN discussions
**Rubric topics**: Common analytical query patterns: aggregations, funnels, cohort, time-series
**Used in iteration**: 4

### Q15: When to move — still fast enough?
Our analytics queries take 3–8 seconds in Postgres. A friend told me ClickHouse would do the same queries in 50ms. But we only have 5 million rows. Is it actually worth the operational complexity of a whole new system for queries that are slow but not broken?
**Source**: HN "Ask HN: How did you scale your analytics workloads?" https://news.ycombinator.com/item?id=42291569; Rill Data "Scaling Beyond Postgres"
**Rubric topics**: When to add an OLAP layer vs staying on the transactional DB; OLAP vs OLTP
**Used in iteration**: 14

### Q16: Columnar storage — SIMD / hardware
I get that columnar databases read less data because they only load the columns you query. But I keep hearing they're also faster at math — like summing a billion numbers faster than Postgres could. Is that true? What's actually happening at the hardware level?
**Source**: DataCamp "Apache Parquet Explained"; CelerData/Alluxio Trino optimization guides on vectorized execution
**Rubric topics**: Column-oriented storage — what it is and why it's faster for analytics
**Used in iteration**: 14

### Q17: Lakehouse — why Iceberg over raw Parquet
I set up an Iceberg table on S3 and I can query it with Trino. But someone asked me why I'm using Iceberg instead of just raw Parquet files, and I didn't have a good answer. What does Iceberg actually add on top of Parquet files that I couldn't get from just organizing Parquet files in folders myself?
**Source**: AWS "What is Apache Iceberg?"; Starburst Iceberg performance blog
**Rubric topics**: What a data lakehouse is and how it differs from a warehouse; Popular tools overview
**Used in iteration**: 8

### Q18: Query performance — funnel is slow
I wrote a funnel query in Trino that checks signup → activation → payment within 7 days. It works correctly but takes 8 minutes on our events table (about 500 million rows). My data team says "add partitioning" but the table is already partitioned by day. What else can I do?
**Source**: CelerData "Trino Query Optimization Best Practices"; e6data "Trino Query Performance Optimization Guide"
**Rubric topics**: Query performance basics: partitioning, indexing strategy for analytics; Analytical query patterns on Iceberg+Trino
**Used in iteration**: 7

### Q19: Schema — slowly changing dimensions
We have a users table with a plan_type column — free, pro, or enterprise. If I join this to our events table in the warehouse, I'll see the user's current plan, not the plan they were on when the event happened. So if they upgraded last month, all their old events will look like they happened on the pro plan. How do analytics systems handle the fact that dimensions change over time?
**Source**: Microsoft Learn "Star Schema and Power BI"; Databricks star schema glossary
**Rubric topics**: Schema design for analytics: denormalization, star schema basics; Lakehouse schema design
**Used in iteration**: 8

### Q20: Tools — DuckDB for small data
I've heard DuckDB can run analytical queries really fast directly on Parquet files on my laptop. If my data is only a few GB, do I even need Trino or Snowflake? Can I just use DuckDB as my "data warehouse" and if so, when would I need to graduate to something bigger?
**Source**: MotherDuck "Best Data Warehouse for Startups 2026"; HN discussions https://news.ycombinator.com/item?id=41272854
**Rubric topics**: Popular tools overview: BigQuery, Snowflake, ClickHouse, DuckDB, Iceberg; When to add an OLAP layer
**Used in iteration**: 8

### Q21: Iceberg maintenance — compaction never ran
I inherited a Trino + Iceberg setup and queries have been getting slower every week for the past two months. My predecessor set up the ingestion job but I don't see any maintenance scheduled. What maintenance does Iceberg need, and what happens if I've been skipping it for two months?
**Source**: Apache Iceberg docs — "Maintenance" section; Starburst "Iceberg Performance Tuning"
**Rubric topics**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup; Iceberg partition design for SaaS
**Used in iteration**: 8

### Q22: Iceberg maintenance — snapshot explosion
Our MinIO storage has been growing even though we haven't added much new data. I noticed the Iceberg metadata folder has thousands of files in it. What are these snapshot files, why do they keep accumulating, and how do I clean them up safely without losing data?
**Source**: Apache Iceberg docs — "Maintenance" section; Dremio "Apache Iceberg Maintenance Best Practices"
**Rubric topics**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup; Storage sizing and growth estimation
**Used in iteration**: 14

### Q23: Iceberg maintenance — safe compaction window
We run a Spark compaction job on our events table every night. Last night the compaction was still running when the morning ingestion job started and we got file conflicts. How should I sequence compaction and ingestion, and is it safe to run compaction while analysts are querying?
**Source**: Apache Iceberg docs — "Maintenance" section; Trino + Iceberg concurrency documentation
**Rubric topics**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup; Iceberg partition design for SaaS
**Used in iteration**: 11
