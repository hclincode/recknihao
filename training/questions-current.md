# Iter 276 Questions

## Q1 — Search filter not getting pushed to Postgres

We added a search bar in our dashboard where customers can type partial strings to filter their data — something like finding all accounts whose name contains "corp" case-insensitively. In our old direct-Postgres setup we used `ILIKE` for this and it was fast. Now that the same query goes through Trino (which federates to Postgres), it feels noticeably slower, and when I look at the row counts in the query plan it seems like a lot more rows are flowing through than I'd expect. My question is: does Trino actually push `ILIKE` down to Postgres, or does it pull all the rows into Trino and do the filtering there? Is there a way to check, and is there anything we can configure to make it push down?

## Q2 — Running a Postgres-specific function through Trino

We rely on a Postgres function called `similarity()` from the pg_trgm extension to do fuzzy matching on customer names — it's been working great in our app queries. Now we're trying to use that same matching logic in a Trino query that joins our Postgres customer table to an Iceberg events table, and Trino just errors out saying it doesn't know the function. Is there a way to tell Trino "for this part of the query, just run it directly in Postgres and give me the results"? I don't need Trino to understand the function, I just need the output so I can join it to my Iceberg data. What's the right way to handle something like this?
