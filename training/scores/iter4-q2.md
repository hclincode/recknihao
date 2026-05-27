# Iter 4 Q2 — Postgres-to-Iceberg ingestion

## Scores
- Technical accuracy: 5
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 4
- Average: 4.50

## Topic updated
- Topic name: "Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling"
- Prior questions: 0 → 1
- New avg: 4.50
- Status: needs 2nd angle (1 question only, must be tested from at least one more angle before passing)

## Key finding
Directly closes the resource gap flagged in Iter 2 Q5 and Iter 3 Q1 — names Spark JDBC as the correct tool for on-prem (correctly rejecting Fivetran/Airbyte which are SaaS/cloud-managed and don't fit the prod stack), gives the three real patterns (full refresh / incremental watermark / Debezium-Kafka CDC) with a decision rule tying CDC to <5min freshness or hard-delete requirements, and addresses the JSONB question head-on with the two standard options (store-as-text vs flatten-hot-fields). Spark code skeleton + KubernetesCronJob/Airflow scheduling + post-ingest `rewrite_data_files` and `expire_snapshots` mean the engineer can act today. Beginner clarity docked one point because terms like "watermark", "Debezium", "Kafka", "CDC", "compaction" likely land without inline plain-English glosses; completeness docked one point because the answer (per summary) appears to miss (a) **idempotency / dedupe on event_id** — the same gap flagged in Iter 3 Q1, critical when a job retries mid-batch, (b) **JDBC parallelism** (`partitionColumn`, `numPartitions`, `lowerBound`, `upperBound`) — without this a single-threaded read of a 50M-row Postgres table will hammer the OLTP DB and take hours, (c) **MERGE INTO for upserts** on dimension tables (users, tenants change over time — append-only is wrong for those), and (d) **schema evolution** when Postgres adds a column (Iceberg supports it but the Spark job needs to handle it).

## Resource gap for next iteration
Author or extend `resources/12-postgres-to-iceberg-ingestion.md` (likely already created for this answer) with four additions: (1) **Idempotency pattern** — `MERGE INTO ... WHEN MATCHED THEN UPDATE WHEN NOT MATCHED THEN INSERT` on event_id for retry-safe ingestion, plus the Iceberg `merge-on-read` vs `copy-on-write` trade-off for 1.5.2; (2) **JDBC parallelism cookbook** — the four-knob `partitionColumn` / `numPartitions` / `lowerBound` / `upperBound` recipe with a worked example on an `events` table, plus a warning that reading from a primary Postgres can saturate OLTP and to prefer a read replica or logical-replication slot; (3) **Fact vs dimension ingestion** — append for fact tables (events), MERGE for SCD-1 dimensions (current user state), MERGE with effective_from/effective_to for SCD-2; (4) **Schema evolution playbook** — what to do when Postgres adds, renames, or drops a column, and how to make the Spark job tolerant via `mergeSchema` or explicit `ALTER TABLE` on Iceberg. Second-angle question to test the topic from a different direction: "I ran my Spark ingestion job twice by accident and now my event counts are doubled — how do I prevent this and how do I clean it up?" (forces idempotency, MERGE INTO, and Iceberg snapshot rollback / time travel).
