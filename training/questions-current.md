# Iter 282 Questions

## Q1 — Connecting Trino to a read replica instead of primary Postgres

We recently set up a Postgres read replica for our primary app database. The idea was to offload our analytics queries so they don't hammer the primary. Now we want to point Trino at the replica instead of the primary — that way our OLTP writes never compete with whatever Trino is doing. My question is: is this actually straightforward? Is it just a matter of changing the connection URL in the Trino catalog config to point at the replica host, or is there more to it? And I'm a little worried about stale data — if replication is lagging by a few seconds or even a minute, does Trino have any way to know that, or does it just silently return stale rows without warning?

## Q2 — Postgres UUID and JSON columns coming through Trino weirdly

We store a lot of data in Postgres with UUID primary keys and some JSONB columns for flexible metadata. When I query those tables through Trino, the UUIDs seem fine, but the JSONB fields look like they're coming back as plain strings — I can't do anything useful with them, like pull out a nested key. For example, I have a column called `settings` that in Postgres is JSONB with keys like `{"plan": "pro", "seats": 10}`, but when I try to do something like extract the `plan` value in a Trino query, I'm not sure what the right syntax is. Is Trino doing some kind of conversion on these types, and if so, what's the correct way to work with UUID and JSON data that originated in Postgres?
