# Iter 277 Questions

## Q1 — Search filter timing out on Postgres

We have a customer-facing search feature where users type partial company names to filter their analytics dashboard — something like finding all activity for companies matching "global" or "corp" anywhere in the name. I'm running this query through Trino against our PostgreSQL catalog, and it's noticeably slower than I'd expect, especially compared to queries that filter by exact ID. Someone on my team said Trino might not be "pushing" the text search down to Postgres the way it does for other filters, so Postgres ends up doing less work and Trino has to pull more rows and filter them itself. Is that true, and is there any way to tell from the query plan whether Trino is actually handing the text filter off to Postgres versus doing the filtering in-memory on the Trino side? Are there settings we can flip to improve this?

## Q2 — Should we copy our Postgres table into the data lake or keep joining across both

We have about 50 million rows in a Postgres table that maps customer accounts to metadata like plan tier, region, and signup date. Almost every analytics query we run in Trino ends up joining this table against our Iceberg event data on S3. Right now we're federating — Trino reaches into Postgres, pulls what it needs, and joins. But as query volume grows I'm worried we're hammering Postgres with analytical read load on top of the transactional writes it's already handling. At what point does it make more sense to copy that Postgres table into Iceberg so Trino can just read it locally, and what does that process actually look like? Is there a way to keep it reasonably fresh without manually moving data around all the time?
