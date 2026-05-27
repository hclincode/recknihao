# Iter 300 Questions

## Q1 — Do we actually need Iceberg and Trino, or can Postgres still handle this?

We are a B2B SaaS with around 15,000 customers. Most of them are small — their dashboards only query the last 90 days of data, maybe 5-10 million rows per customer at most. Right now our analytics queries run directly on Postgres and they are slow, but we are wondering if we are jumping to a complicated solution too fast. Someone on the team said we should just add read replicas and better indexes before we invest months in setting up Iceberg and Trino. Another person said once you are doing aggregations across many customers at once — like for our internal "platform health" reports — Postgres will always struggle no matter how many indexes you add. How do we actually decide whether our problem is solvable in Postgres, versus whether we genuinely need a separate analytics system? Are there specific signs or thresholds that tell you it is time to move?

## Q2 — Why does everyone say to avoid SELECT * in a system like Trino? It works fine in Postgres.

When I write queries against our Iceberg tables in Trino, I have been doing `SELECT *` during development because it is easier to explore the data. A coworker told me this is really bad for performance in a system like Trino and I should always list out only the columns I need. In Postgres I understand that `SELECT *` fetches more data, but it is not usually a big deal if the index is there. Why is `SELECT *` so much worse in Trino specifically? Is it something about how the files are stored on disk? And how significant is the difference in practice — are we talking 10% slower, or like 10x slower?
