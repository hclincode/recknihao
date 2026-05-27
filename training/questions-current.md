# Iter 288 Questions

## Q1 — Trino join with Postgres lookup table is painfully slow

We have a query that joins a huge Iceberg table (like 200 million rows of usage events) against a Postgres table we use as a lookup — it has maybe 50,000 rows, just mapping customer IDs to their plan tier and region. The join works but it takes forever, like 4-5 minutes. I was reading somewhere that when one side of a join is really small, some query engines are smarter about it — they load the small table into memory and send a copy to every machine working on the big table instead of shuffling data around. Is that something Trino can do? And if it can, is it doing it automatically, or do I have to tell it somehow? Our Postgres table has up-to-date stats, I just don't know if Trino is aware of that.

## Q2 — Should I copy a 5-million-row Postgres table into Iceberg or just keep querying it live?

We have a Postgres table that our app writes to — it holds enrichment data for accounts, roughly 5 million rows. It gets updated every few hours via a background job. We run analytical queries against it through Trino dozens of times a day, always joining it with stuff in Iceberg. Right now we're just federating live (Trino queries Postgres directly), but it feels slow and I'm worried we're putting load on our production Postgres replica. Someone on the team suggested copying the table into Iceberg and just refreshing it periodically. But I don't know if 5 million rows is even big enough to bother, and if we do copy it, how do we keep it in sync without rewriting the whole thing every time? Is there a rule of thumb for when live federation stops being worth it?
