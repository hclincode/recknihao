# Iter 326 Questions

Date: 2026-05-27
Topics: Postgres-to-Iceberg ingestion / STRUCT schema evolution — adding a new field to an existing struct column (Q1) + Multi-tenant analytics / OPA row-level security — why batched-uri didn't improve query performance (Q2)

## Q1 — Adding a new field to an existing struct column in Iceberg

A few weeks ago we set up our `metadata` column in the Iceberg `events` table as a struct type with eight fields. Now we're rolling out SSO and need to add a new boolean field called `sso_enabled` to that same struct. In Postgres I'd do `ALTER TABLE events ADD COLUMN sso_enabled BOOLEAN` or modify the column definition, but I'm not sure how Iceberg handles this when the field lives inside a struct rather than at the top level of the table. I tried `ALTER TABLE iceberg.analytics.events ALTER COLUMN metadata ADD sso_enabled BOOLEAN` and got a syntax error. What's the correct DDL to add a new field to an existing struct column in Iceberg on Trino 467, and do I need to worry about what happens to rows that were written before the new field existed?

## Q2 — OPA row-level security set up but batched-uri config isn't helping query latency

We have OPA integrated with Trino for row-level security — every query against our `events` table gets a filter injected that limits rows to only the requesting tenant's data. It works correctly, but we're seeing added latency on every query because Trino is making HTTP calls to OPA at query time. I read in the Trino OPA plugin docs that there's a `opa.policy.batched-uri` config option that "batches OPA authorization calls," so I set it up pointing at our batch policy endpoint. But our query latency hasn't changed at all — we're still seeing the same per-query HTTP round-trips to OPA. Did I configure something wrong, or does `batched-uri` not actually apply to the row-filtering part of OPA? What does it actually batch, and is there any way to reduce the OPA overhead for row-level filtering specifically?
