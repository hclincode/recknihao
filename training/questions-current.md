# Iter 280 Questions

## Q1 — Strange Trino errors after adding a jsonb column to Postgres

We have a `users` table in Postgres with a `preferences` column that's of type `jsonb`. When I try to query that table through Trino, the query errors out or sometimes that column just silently doesn't show up in the results. I'm not even sure if Trino supports jsonb — it's not a standard SQL type. Is there a way to make this work, or do we need to change how we store that data? And if some column types just aren't supported, how would I even know which ones are being dropped versus which ones cause an outright error?

## Q2 — Trino not seeing a new column we added to Postgres

We added a column to one of our Postgres tables with `ALTER TABLE ... ADD COLUMN` and deployed it. Our app can read and write to it fine through the normal Postgres connection, but when we query the same table through Trino, the column doesn't exist — Trino just says it's not there or returns without it. We restarted nothing on the Trino side. Is Trino caching the table structure somewhere? If so, is there a way to force it to refresh without restarting the whole cluster?
