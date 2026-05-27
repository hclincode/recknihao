# Iter 3 Q1 — Lakehouse schema design / fact tables

## Scores
- Technical accuracy: 5
- Beginner clarity: 4
- Practical applicability: 4
- Completeness: 4
- Average: 4.25

## Topic updated
- Topic name: "Lakehouse schema design: fact tables, dimension tables, denormalization"
- Questions asked so far for this topic: 0 -> 1
- New running avg: 4.25

## Key finding
Strong answer that directly addresses both halves of the CTO question ("just copy the table?" -> no, denormalize) and gives the engineer a concrete starting point: three named fact tables with column lists, a before/after SQL contrast, the "old plan_type stays old" insight framed as a feature not a bug, SCD Type 2 for the dimension side, and a migration path (Spark reads Postgres -> writes Iceberg). It correctly anchors to the production stack (Spark + Iceberg) and pulls the right material from `09-lakehouse-schema-design.md`. The grain concept is implicit but not named, and `tenant_id` — present in the engineer's own Postgres schema — is barely discussed as a partition/isolation lever even though that is the exact bridge to the multi-tenant topic the engineer will hit next.

## Resource gap for next iteration
The answer mentions "Spark job reads Postgres, flattens and writes to Iceberg" but no resource explains the ingestion mechanics — full-refresh vs CDC vs append-only snapshot, scheduling, and the JSONB-properties-to-`MAP<VARCHAR,VARCHAR>` flattening step that the engineer literally asked about (their Postgres table has a `properties` JSONB blob). A `resources/12-postgres-to-iceberg-ingestion.md` (or an "Ingestion" section appended to `09-lakehouse-schema-design.md`) covering: (a) Spark JDBC read of Postgres, (b) handling the JSONB column — promote known keys, keep the rest in `MAP`, (c) initial backfill vs incremental, (d) idempotency / dedup on `event_id`, (e) writing partitioned Iceberg via Hive Metastore on MinIO — would close the loop between "design the model" and "actually populate it." This was also the gap flagged in Iteration 2 Q5 and has now surfaced again; it should be prioritized.
