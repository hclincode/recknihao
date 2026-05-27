# Iter 287 Questions

## Q1 — Postgres column completely missing when I query through Trino

We have a Postgres table with a column that stores some custom status values — it's defined as a custom type (an enum we created in Postgres years ago, something like `CREATE TYPE order_status AS ENUM ('pending', 'fulfilled', 'cancelled')`). The column is definitely there, I can SELECT it directly in Postgres no problem.

But when I query that same table through Trino — either with `DESCRIBE` or just `SELECT *` — the column is completely gone. It's not null, it's not throwing an error, it literally does not appear in the result at all. No warning either. I double-checked the catalog config and the table name is definitely correct, it's reading other columns from the same table fine.

Is this a known thing where Trino quietly drops columns it doesn't understand? How do I get that column to show up, even if it comes back as a plain string?

## Q2 — Postgres array column not showing up in Trino, or maybe it does but I can't query it right

We store a list of tags per customer in Postgres as a `TEXT[]` column — just a plain Postgres array. When I try to access it through Trino it either doesn't show up at all, or when it does show up I'm not sure how to actually filter on it (like "give me all customers where tags contains 'enterprise'").

Can Trino even work with Postgres array columns? Is there a setting I need to flip to make the column visible, and if so does it come back as something I can actually search inside, or just a raw string I'd have to parse myself?
