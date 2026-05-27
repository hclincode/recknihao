# Iter 155 Q1 — Judge Report

**Question topic**: Postgres-to-Iceberg ingestion — CDC pipeline end-to-end (Postgres WAL → Debezium → Kafka → Spark → Iceberg), and lag/backpressure behavior during traffic spikes.

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter155-q1.md`

---

## Scores

### Technical accuracy: 4.5 / 5 (weight 2x)

Nearly all technical claims verified correct against official docs. One incorrect "requires" claim and one minor framing nit.

**Verified correct:**
- `op` field values `c` (INSERT), `u` (UPDATE), `d` (DELETE), `r` (snapshot read) — confirmed against debezium.io PostgreSQL connector docs. Answer omits `t` (TRUNCATE) and `m` (logical decoding message), but these are not relevant to the question.
- `REPLICA IDENTITY FULL` syntax (`ALTER TABLE t REPLICA IDENTITY FULL`) — correct DDL. The explanation that without it Postgres logs only the primary key in the WAL for DELETEs and Debezium's `before` image therefore contains only the PK is verified against PostgreSQL 18 publication docs and multiple secondary sources.
- "Roughly 2x WAL volume" framing for `REPLICA IDENTITY FULL` is in line with documented impact ("FULL writes every column to WAL for each update and delete... significantly more WAL volume").
- `wal_level = logical`, `max_wal_senders`, `max_replication_slots` in `postgresql.conf` plus the requirement to restart Postgres — all confirmed against postgresql.org runtime-config-wal docs.
- `pgoutput` plugin and `CREATE PUBLICATION ... FOR ALL TABLES` syntax correct.
- `pg_replication_slots` view with `restart_lsn` column and `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)` for slot lag — verified against postgresql.org pg_replication_slots docs and standard CDC monitoring patterns.
- Debezium offset tracking in the Kafka `connect-offsets` topic — confirmed against debezium.io storage docs (KafkaOffsetBackingStore, `OFFSET_STORAGE_TOPIC`).
- The three-place state tracking (Debezium source offsets in `connect-offsets`, Postgres `pg_replication_slots`, Spark checkpoint) is conceptually correct and a strong framing.
- `foreachBatch` is required for `MERGE INTO` from Structured Streaming into Iceberg — correct; the native Iceberg streaming sink supports append/complete output modes, not MERGE semantics.
- Unread replication slot can fill the WAL disk and stall the Postgres primary — correct and a real production failure mode.
- MinIO/`s3a://` checkpoint location and Hive Metastore-backed Iceberg fit the documented prod stack.

**Errors / overstatements:**

1. **(Minor) "Iceberg 1.5.2 requires a minimum 60-second trigger interval for streaming writes"** — overstated. The official Iceberg Spark Structured Streaming docs *recommend* 60 seconds as a minimum to control metadata growth and small-file churn; they do not *require* it. The answer presents an operational guideline as a hard constraint. This is misleading for an engineer who might want to experiment with shorter triggers.

2. **(Minor) `pgoutput` slot creation** — `SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput')` is technically valid, but Debezium will create the slot automatically when the connector starts (controlled by `slot.name`). Manually pre-creating it is unusual and not the recommended path; this isn't wrong, but it adds friction. Not scored down hard.

3. **(Very minor) "Debezium retries snapshots from scratch if `connect-offsets` topic is wiped"** — correct in spirit. Worth noting this depends on `snapshot.mode` (default `initial` will re-snapshot; `never` will not). The answer doesn't mention `snapshot.mode` at all, which is a small gap given the question's depth.

### Beginner clarity: 4.5 / 5

- Strong scaffolding: numbered list of the five pipeline components up front, then prerequisites, then code, then failure modes.
- "Three independent places" framing for state tracking is the kind of mental model a SaaS engineer with no CDC background can hold onto.
- The Summary table at the end is excellent — directly answers the four sub-questions in one glance.
- Jargon mostly explained inline (`op`, `before`/`after`, replication slot, LSN implied via `restart_lsn`).
- Minor: "LSN" appears in the SQL example without being spelled out as "Log Sequence Number". Trivial.
- Minor: `foreachBatch` is named as an "escape hatch" without a one-sentence definition of what `foreachBatch` does (it gives you a DataFrame per micro-batch to run arbitrary SQL/DataFrame ops against).

### Practical usefulness: 4.75 / 5

- Engineer can copy-paste the Postgres setup, the Spark consumer code, and the monitoring SQL and have a working pipeline.
- Concrete numeric thresholds given (slot lag 10 GB, retention 30 days, retries 8–12) — these are the kind of starting-point numbers that unblock decisions.
- Failure-mode section is organized by *layer* (Debezium→Kafka, Kafka→Spark, MERGE contention) which mirrors how oncall engineers debug.
- Recommendation to "schedule compaction outside the ingestion window" and to raise `commit.retry.num-retries` to 8–12 is the kind of operational tweak that comes from real experience.
- Small gap: doesn't tell the engineer *how* to deploy Kafka and Kafka Connect on-prem (the prod env is k8s on-prem with MinIO; Kafka is not mentioned as already-running). For a "set up something that tails the WAL" question, the operational lift of standing up Kafka + Kafka Connect on the cluster is worth at least a one-line callout. Iter 18 notes flagged this same gap previously.

### Completeness: 4.75 / 5

- Both halves of the question answered: (a) end-to-end pipeline architecture, and (b) what happens under traffic spike / backpressure.
- Explicitly enumerates data-loss vs no-data-loss scenarios, which is exactly the engineer's "can it catch up on its own, or does that cause data loss?" framing.
- Pre-deletes-only motivation is acknowledged in the opening sentence.
- Minor gaps:
  - `snapshot.mode` not mentioned (relevant to "what happens on initial setup" and to the `connect-offsets` wipe scenario).
  - Doesn't address whether Kafka itself is assumed to exist in the prod environment (on-prem k8s).
  - Doesn't mention TRUNCATE handling (op=`t`) — a corner case for the deletes question (TRUNCATE is a bulk delete that behaves differently in Debezium).

---

## Weighted average

`(4.5 × 2 + 4.5 + 4.75 + 4.75) / 5 = (9.0 + 14.0) / 5 = 23.0 / 5` = **4.60**

## Verdict: **PASS** (≥ 4.5)

---

## Verified correct (with sources)

- Debezium `op` codes c/u/d/r — [Debezium PostgreSQL connector docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- `REPLICA IDENTITY FULL` behavior for DELETE before-image — [PostgreSQL 18 logical-replication-publication docs](https://www.postgresql.org/docs/current/logical-replication-publication.html), [Postgres Replica Identity guide](https://www.postgrescripts.com/post/postgresql-replica-identity-logical-replication/)
- `wal_level = logical`, `max_wal_senders`, `max_replication_slots`, restart required — [PostgreSQL 18 runtime-config-wal](https://www.postgresql.org/docs/current/runtime-config-wal.html), [wal_level parameter](https://postgresqlco.nf/doc/en/param/wal_level/)
- `connect-offsets` topic stores Debezium source offsets (LSN for Postgres) — [Debezium storage docs](https://debezium.io/documentation/reference/stable/configuration/storage.html), [Debezium offset management](https://risingwave.com/blog/debezium-offset-management-guide/)
- `pg_replication_slots` with `restart_lsn` and `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)` for slot lag — [pg_replication_slots view docs](https://www.postgresql.org/docs/current/view-pg-replication-slots.html), [Postgres replication slot monitoring](https://dev.to/philip_mcclarence_2ef9475/postgresql-replication-slots-create-monitor-troubleshoot-595g)
- Debezium `snapshot.mode` parameter (initial/never/initial_only/always/custom, default `initial`) exists — [Debezium PostgreSQL connector docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html), [Debezium snapshot modes explained](https://kafka-options-explorer.conduktor.io/debezium/snapshot-modes/)

## Errors / gaps found

1. **(Minor)** "Iceberg 1.5.2 requires a minimum 60-second trigger interval" — the Iceberg docs *recommend* 60s minimum, not *require*. — [Iceberg Spark Structured Streaming docs](https://iceberg.apache.org/docs/latest/spark-structured-streaming/)
2. **(Minor)** `snapshot.mode` not discussed despite being directly relevant to the "connect-offsets wiped" failure mode the answer raises.
3. **(Minor)** On-prem Kafka/Kafka Connect deployment burden not called out. Prod env is on-prem k8s + MinIO; the answer assumes Kafka exists without naming the operational lift.
4. **(Very minor)** Manually pre-creating the replication slot with `pg_create_logical_replication_slot` is not the recommended path — Debezium creates it from `slot.name` on first start.

## Resource fix recommendations

- **LOW** — Update `resources/13-postgres-to-iceberg-ingestion.md` (or wherever the Iceberg streaming snippet lives) to phrase the 60-second trigger as "recommended minimum to control metadata churn" rather than "required". Cite the Iceberg streaming docs.
- **LOW** — Add a one-paragraph callout on `snapshot.mode` (default `initial`) when discussing connector first-start vs restart and the `connect-offsets` wipe scenario.
- **LOW** — Add a one-line note in CDC sections that on the on-prem stack, Kafka and Kafka Connect must be provisioned on the same k8s cluster (or an adjacent one) — this is non-trivial operational scope and engineers should know it before committing to CDC.

No high-severity issues. The topic remains comfortably in PASSED state (current rubric avg ≈ 4.4 across 90+ questions).
