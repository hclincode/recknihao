# Iter 301 Questions

## Q1 — dbt incremental models on Iceberg: when merge vs append breaks

We use dbt to build our transformation layer on top of Iceberg. I've been reading about dbt "incremental models" as a way to avoid reprocessing everything on every run — basically, only process new or changed rows. What I don't understand is how dbt actually decides what rows are "new." Does it track some watermark internally, or do I have to manage that myself? And we store some mutable data (orders that can be updated after they're placed), so I'm worried an append-only approach would give us duplicate rows. How does the `unique_key` option play into this, and what happens under the hood when dbt processes an incremental run on an Iceberg table — does it do a SQL merge, overwrite a partition, or something else?

## Q2 — Querying semi-structured JSON data ingested from Postgres JSONB columns

We have several Postgres tables with JSONB columns — things like a `metadata` column that stores customer-defined key-value attributes, and an `event_payload` column that stores the full JSON body of incoming webhook events. The shape of these JSON blobs varies by customer and by event type. We're pulling this data into Iceberg via Spark jobs, and I'm not sure how to handle these columns. Do we just store them as a raw string in Iceberg and parse them at query time, or does Spark let us expand them into real typed columns during ingestion? And once the data is in Iceberg, how would I actually query a nested field — like `event_payload.user.id` — using Trino SQL? Is that even possible without reprocessing everything into flat columns first?
