# Score: Iter 336 Q2 — Hard Deletes in Incremental Pipeline

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Core claims about `updated_at`/`created_at`/`xmin` not catching hard deletes are correct; Debezium/WAL claim is correct; reconciliation pattern with EXCEPT is a valid approach. Minor caveats around `xmin` framing (it's not exactly a "watermark"; deletes leave xmax not xmin trace) but the practical takeaway ("can't catch hard deletes") is right. CDC tradeoff framing is accurate. |
| Beginner clarity | 4.5 | Plain language throughout; uses a clear table; defines what each watermark does; uses concrete SQL examples; ramps from simple (soft delete) to more complex (CDC). Minimal jargon and no assumed OLAP knowledge. |
| Practical applicability | 4.5 | Gives three clear options with explicit "when to use" guidance. Provides actionable next steps (audit, switch with trigger, weekly reconcile). Fits the production stack (Spark + Iceberg + Trino on-prem) — Debezium/Kafka and Spark are all installable on the on-prem k8s cluster. The Trino-style `EXCEPT` query for reconciliation works in Trino 467 with the postgresql + iceberg connectors. |
| Completeness | 4.0 | Covers the three main industry-standard approaches (soft delete, reconciliation, CDC). Could have mentioned: (a) implementation detail for option 2 — using `MERGE INTO ... WHEN NOT MATCHED BY SOURCE` or a NOT EXISTS pattern to actually do the delete after detection (only shows the SELECT, not the DELETE); (b) Iceberg V2 equality/positional delete files briefly; (c) the operational note that wal_level=logical is required for Debezium and adds primary-side cost (replication slot xmin horizon retention); (d) a note that the production env runs Spark/Trino on-prem so a Debezium → Kafka → Spark Structured Streaming consumer is a feasible on-prem build (no managed-service assumption). The answer covers the question's core, just doesn't go deeper. |
| **Average** | **4.375** | **PASS (near STRONG PASS)** |

## What Worked
- Clear framing that the limitation is architectural, not a bug — sets correct expectations.
- Table form comparing watermarks is digestible at a glance.
- Three-option structure mirrors how senior data engineers actually think about this trade space (do nothing different / reconcile periodically / true CDC).
- The "audit which tables actually do hard deletes" first step is exactly the right pragmatic move — it acknowledges most SaaS apps only have a handful of hard-delete tables.
- Recommendation ordering (soft delete → reconciliation → CDC) matches the operational-complexity gradient.
- Fits production env: no cloud-only tools recommended; Debezium + Kafka + Spark all run on the described on-prem k8s stack.

## What Missed
- The reconciliation SQL only shows the **detect** half (SELECT ... EXCEPT). The companion DELETE / MERGE statement that actually removes the orphaned rows from Iceberg is omitted. A beginner copying this would need to figure out the second half. Example missing follow-up: `DELETE FROM iceberg.analytics.dim_users WHERE user_id IN (<orphan list>)` or a MERGE-INTO with WHEN NOT MATCHED BY SOURCE THEN DELETE.
- No mention of `wal_level = logical` configuration prerequisite for Debezium, or the replication-slot xmin-horizon trap (an inactive slot indefinitely retains dead tuples on the primary — a known production foot-gun).
- No mention of Iceberg V2 delete file mechanics (positional vs. equality deletes) or copy-on-write vs. merge-on-read trade-offs when handling the actual DELETE in Iceberg.
- Could have explicitly named the existing reconciliation guidance in resources/13-postgres-to-iceberg-ingestion.md (the resource has a "Recurring safety net" section with the correct full pattern).
- Doesn't mention scale considerations for the EXCEPT pattern — reading the full PK set from both sides is fine for 1M-row tables but expensive for 500M-row tables.

## Technical Accuracy Verification
- **`updated_at`/`created_at`/`xmin` cannot catch hard deletes** — Correct. Per Postgres MVCC docs, a DELETE marks the row's `xmax` and the row becomes a dead tuple awaiting VACUUM; no surviving row carries a value that a `> watermark` filter could match. Verified against Postgres MVCC documentation and resources/13 line 135-139.
- **Soft-delete pattern (`UPDATE ... SET deleted_at = now()`)** — Correct and is the industry-standard approach; the resource file recommends this same pattern (line 128).
- **Reconciliation via SET DIFFERENCE / EXCEPT** — Valid pattern. Trino supports `EXCEPT` per Trino 481 SELECT docs; works with the postgresql + iceberg connectors federated in a single query. Standard "anti-join" reconciliation technique. Verified against Iceberg/Trino reconciliation pattern docs.
- **Debezium streams Postgres WAL DELETE events** — Correct. Per Debezium PostgreSQL connector docs, Debezium uses Postgres logical replication (`wal_level=logical`) and decodes WAL to emit INSERT/UPDATE/DELETE events, including tombstones for deletions. Verified against debezium.io and Red Hat Integration docs.
- **CDC operational tradeoff (Debezium + Kafka + streaming consumer)** — Correct characterization. The complexity claim ("exactly-once semantics, connector, Kafka topic, streaming consumer") is accurate; these are real operational concerns in production CDC deployments.
- **"Sub-5-minute freshness" framing for CDC** — Reasonable rule of thumb. Watermark-based incremental pipelines typically run on minutes-to-hours cadence; sub-minute latency genuinely does push toward streaming CDC.
- **Minor nit**: The answer says "Debezium streams actual DELETE events from Postgres's write-ahead log to Kafka" — technically Debezium reads via the logical replication protocol (pgoutput / wal2json decoder plugin), not the raw WAL files. The user-facing summary is correct in spirit.
