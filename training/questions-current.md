# Iter 283 Questions

## Q1 — Writes to Postgres and Iceberg at the same time — are they safe together?

We have a workflow where, when a customer's billing event comes in, we need to write a record to our main Postgres database (so the app can see it immediately) and also write the same event into our Iceberg tables (so it shows up in their usage dashboard). Right now we're doing these as two separate writes in our backend code, which feels fragile — if one succeeds and the other fails we end up with inconsistent data.

I saw that Trino supports some kind of transaction syntax. My question is: if I wrap both writes in a `START TRANSACTION` in Trino, does that actually guarantee both the Postgres write and the Iceberg write either both succeed or both roll back together? Or is that wishful thinking and they're still separate underneath? I want to understand how much I can trust Trino to keep these two systems in sync.

## Q2 — Should we copy a big Postgres table into Iceberg or just keep joining across them?

We have a table in Postgres called `accounts` — it's about 20 million rows and it changes slowly (maybe a few hundred updates a day, things like plan changes or account renames). Almost every analytics query we run in Trino ends up joining against this table to attach account-level context to the event data sitting in Iceberg.

Right now we just let Trino reach across and query Postgres directly when it needs that data. It works, but some of our heavier queries feel sluggish and I'm wondering if we're paying a cost every time Trino has to go fetch from Postgres mid-query. Would we be better off copying that `accounts` table into Iceberg and keeping it in sync ourselves? Or is the live federation approach fine and we're just not tuning something right?
