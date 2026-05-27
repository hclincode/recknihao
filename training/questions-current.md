# Iter 324 Questions

Date: 2026-05-27
Topics: Trino 467 Iceberg maintenance — what runs where (Q1) + JSONB column ingestion into Iceberg (Q2)

## Q1 — Iceberg table maintenance: Trino 467 vs Spark

We're running Trino 467 and I'm trying to clean up our Iceberg tables — we have a bunch of old snapshots piling up and the storage costs are climbing. I looked at some docs online and found syntax like `ALTER TABLE ... EXECUTE expire_snapshots(retain_last => 10, clean_expired_metadata => true)`, but when I ran it against our Trino cluster I got an error saying those parameters don't exist. What can I actually run from Trino 467 to expire snapshots, and is there anything I just flat-out cannot do from Trino and would need a separate Spark job for?

## Q2 — Postgres-to-Iceberg ingestion: JSONB column handling

We're pulling change events from Postgres into Iceberg via Debezium and Kafka, and it's mostly working. But one of our Postgres tables has a `details` column that's stored as JSONB — it has nested fields like `plan_tier`, `feature_flags`, and `region` that our customers actually want to filter on in their dashboards. Right now those nested fields are just landing as a raw JSON string in Iceberg, which means our Trino queries can't filter on them efficiently. What's the right way to handle this — do we extract the fields during ingestion and store them as real columns, or is there a way to query into the JSON string from Trino that performs well enough?
