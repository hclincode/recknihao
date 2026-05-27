# Iter 286 Questions

## Q1 — Iceberg scan seems to ignore our Postgres join filter, is there a timeout somewhere?

We have a federated query where we join a big Iceberg event table (left side, around 200 million rows) against a Postgres customers table (right side, maybe 50k rows). The whole point is that Trino reads Postgres first, figures out which customer IDs are relevant, and then only scans the matching Iceberg files instead of everything. That part seems to work sometimes, but on days when Postgres is under load and responds slowly, the query just blows up and scans the full Iceberg table like it didn't even try to filter.

My theory is that Trino gives up waiting for the Postgres side to finish and just starts scanning Iceberg anyway. Is that actually what's happening — like there's some timeout where Trino says "filter didn't arrive in time, I'll just scan everything"? If so, can I bump that timeout somewhere, either in a query hint or a session setting I can set per query? I'd rather not restart the coordinator just to test a config change.

## Q2 — Does Trino push ILIKE down to Postgres or does it pull everything into memory?

We're building a search feature where users can search customer names case-insensitively — basically a LIKE but it shouldn't care whether the name is stored as "Acme Corp" or "acme corp." In Postgres directly I'd just use ILIKE and it works fine and uses the index.

Now we're routing that query through Trino because the rest of the query joins against Iceberg data. My concern is that Trino might not know how to push ILIKE down to Postgres — so instead of Postgres doing the filtering with its index, Trino pulls the entire customers table into memory and does the case-insensitive match itself. Is that what happens? Is there a way to tell Trino it's okay to push ILIKE down, or are we stuck doing a full table transfer every time someone searches?
