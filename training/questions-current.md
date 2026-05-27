# Iter 325 Questions

Date: 2026-05-27
Topics: Iceberg manifest cleanup / optimize_manifests version gate on Trino 467 (Q1) + STRUCT vs flat columns for stable-schema JSONB (Q2)

## Q1 — Iceberg maintenance: manifest cleanup and slow query planning on Trino 467

Our Trino queries on one of our larger Iceberg event tables are getting slow at the planning phase — before any data is actually read, there's a multi-second delay that gets worse the longer we go without maintenance. I went looking for a fix and found several references suggesting we should run something called `optimize_manifests` or `rewrite_manifests` to clean up "manifest files." I tried running `ALTER TABLE iceberg.analytics.events EXECUTE optimize_manifests` against our Trino cluster (we're on version 467) and got an error saying the procedure doesn't exist. Can you explain what manifest files actually are and why they slow down query planning rather than data reading, and tell me what I should actually run on Trino 467 to fix this — whether that's a different Trino command or something I need to run from Spark instead?

## Q2 — Postgres-to-Iceberg ingestion: is a "struct" type better than individual columns when you control the JSONB schema?

We have a `metadata` JSONB column in one of our core Postgres tables that we own completely — it is not user-generated, we wrote the schema, and it always has exactly the same eight fields: `account_tier`, `region`, `feature_flags`, `contract_start`, `contract_end`, `seat_count`, `billing_cycle`, and `support_tier`. None of these fields are ever missing or added at runtime. Previously I was told the right move for JSONB in Iceberg is to flatten the hot fields into individual columns and store the raw JSON as a fallback string. But a colleague mentioned that Iceberg has a "struct" or "nested record" type that can hold all eight fields in a typed format without creating eight separate top-level columns — and that this might be cleaner when you know the schema upfront. Is that a real thing? If we go with individual flat columns versus a struct type versus just leaving it as a plain JSON string column, what are the actual trade-offs in terms of query performance, schema evolution, and operational overhead on our Trino 467 + Iceberg setup?
