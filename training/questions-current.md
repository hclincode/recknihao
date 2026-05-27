# Iter 284 Questions

## Q1 — How do I tell if Trino is actually sending my WHERE clause to Postgres or doing the filtering itself?

We have a federated query that joins our Iceberg event data with a Postgres table, and I'm filtering on a Postgres column in the WHERE clause. The query is slower than I expected and I'm trying to figure out if Trino is actually passing that filter down to Postgres (so Postgres can use its indexes), or if Trino is pulling all the rows from Postgres into memory and then doing the filtering itself.

Someone mentioned I should look at the query plan with EXPLAIN ANALYZE but I've never done that for a query that touches two different systems. What am I looking for in that output to confirm the filter is actually being applied on the Postgres side? Is there a specific line or section that tells me "yes, Postgres is handling this" versus "Trino is doing this work in memory after fetching everything"?

## Q2 — We're doing JSONB filtering on a Postgres column through Trino and it's ignoring our index

We store some per-customer configuration in a Postgres column as JSONB, and we have a GIN index on it so that filtering on specific JSON keys is fast when querying Postgres directly. The problem is we're now querying this through Trino (because the rest of our analytics stack is there), and the same filter that's instant in Postgres is dog-slow through Trino.

My guess is Trino doesn't know how to push a JSONB condition down to Postgres, so it's fetching everything and filtering in Trino. Someone on my team mentioned there's a way to send a raw SQL string directly to Postgres from within Trino using something like `system.query()` so the GIN index gets used. Is that a real thing? How does it work, and are there gotchas I should know about — like can I still JOIN the result of that against my Iceberg tables, or does it have to be a standalone query?
