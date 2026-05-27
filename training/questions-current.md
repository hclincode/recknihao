# Iter 281 Questions

## Q1 — Postgres schema cache flush after adding a column

We added a new column to one of our PostgreSQL tables this morning, and now Trino can't see it — the column just doesn't show up when I run `DESCRIBE` against that table through Trino. A teammate told me Trino caches metadata and I need to flush it. I found a reference to a procedure called `flush_metadata_cache` but I'm not sure of the exact syntax to call it, especially whether I need to pass in the schema name or table name so it only clears the cache for that one table and doesn't blow away everything. Can you show me the exact SQL call to use for our PostgreSQL connector catalog (let's call it `app_pg`)? And is there a way to set the cache TTL so this expires automatically next time without manual intervention?

## Q2 — Querying across per-tenant Postgres schemas in one shot

We built our app with one PostgreSQL schema per customer — so we have `tenant_1.orders`, `tenant_2.orders`, `tenant_3.orders`, and so on, and we're adding new tenants regularly. Now we want to build a cross-tenant analytics view in Trino so our ops team can see aggregate metrics across all customers without running a separate query per tenant. My first instinct was to write a Trino query that somehow loops over all schemas dynamically, but I'm not sure if that's even possible. Is there a pattern for federating across dozens of schemas that share the same table structure, and how do we handle new tenants being added without rewriting the query every time?
