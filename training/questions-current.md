# Iter 272 Questions

## Q1 — Stale schema after altering a Postgres table

We added a column to one of our Postgres tables last week, and when I query it through Trino I still get an error saying the column doesn't exist. I double-checked: the column is definitely there in Postgres, I can query it directly in psql just fine. But Trino keeps acting like the old schema is the real one.

Is Trino caching the table structure somewhere? If so, how do I get it to pick up the new column? I'm worried about this becoming a bigger problem — we do schema migrations regularly as we ship new features, and I don't want our analytics queries to break silently every time we alter a table.

## Q2 — Cross-catalog join between Iceberg and Postgres is way slower than expected

We have an Iceberg table with about 200 million event rows, partitioned by tenant and date. We also have a small Postgres lookup table with maybe 5,000 rows that maps user IDs to account metadata. I want to join them so the dashboard can show events enriched with account info.

The Iceberg filter is really tight — after applying tenant and date filters, I'm pulling maybe 50,000 rows. But the join with the Postgres table still feels way slower than I'd expect. It's almost like Trino is reading the entire Postgres table regardless of what I'm filtering on the Iceberg side. Is that what's happening? Is there a way to make Trino push the filter down so it only fetches the relevant rows from Postgres?
