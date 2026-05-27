# Iter120 Q1 — Judge Score

**Question topic**: One-time backfill of 18 months of Postgres history into Iceberg without overloading Postgres or corrupting existing partitions.

**Production stack**: On-prem K8s, Trino 467, Iceberg 1.5.2, Spark, MinIO, Hive Metastore, Debezium 2.x, JWT, OPA.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | `writeTo(table).overwritePartitions()` correctly described — overwrites all partitions for which the DataFrame contains rows, atomic, snapshot-isolated. Dynamic-overwrite semantics implicit and correct for per-day batching where each batch's DataFrame holds rows for exactly one partition. JDBC subquery pattern `(SELECT ... WHERE date(occurred_at) = '...') t` is the canonical Spark JDBC dbtable subquery shape. `fetchsize=10000` is a sane default. `iceberg.system.rewrite_data_files`, `expire_snapshots(older_than, retain_last)`, `rewrite_manifests(table)` signatures match Iceberg 1.5.x procedure docs (named-argument calling, correct param names). `pg_last_xact_replay_timestamp()` for replica-lag check is correct PG function. Iceberg snapshot isolation + automatic retry for concurrent commits is accurate. No incorrect claims. |
| Beginner clarity | 5 | Opens by framing what makes backfill different from incremental ingestion. Lists three concrete failure modes for naive CSV dump (partition mismatch, double-counting, primary-DB overload) before showing the solution. Each step is numbered and titled with the WHY. The bullet list under `overwritePartitions()` ("Idempotent / Atomic / Partition-scoped") is exactly the vocabulary a beginner needs. Closing concern-to-mitigation table is a clean recap. Zero unexplained jargon. |
| Practical applicability | 5 | Every code block is runnable: PySpark JDBC read with replica URL, fetchsize, single-day predicate; the orchestration loop with parallel batch hint (5–10 days at once); replica-lag probe; post-backfill Spark SQL `CALL iceberg.system.*` maintenance trio. Fits stack: Spark on K8s submitting per-day jobs, writing through Iceberg 1.5.2 catalog backed by Hive Metastore, files landing in MinIO — no public-cloud assumptions. Maintenance procedures correctly tagged as Spark (CALL syntax). Watermark coordination snippet shows exact cutoff logic to prevent overlap. An engineer can copy this and run it. |
| Completeness | 5 | Covers all five required angles: (1) read replica explicitly mandated, (2) per-day JDBC batching with subquery predicate, (3) idempotency via `overwritePartitions()` keyed on fixed BATCH_DATE, (4) incremental-overlap handling via watermark cutoff (`BACKFILL_CUTOFF = CURRENT_WATERMARK - 1 day`), (5) post-backfill maintenance trio (rewrite_data_files → expire_snapshots → rewrite_manifests). Bonus: replica-lag handling via `pg_last_xact_replay_timestamp()`, parallel submission guidance, restartability framing, snapshot-isolation explanation of why concurrent commits don't corrupt. Nothing material missing. |
| **Average** | **5.0** | |

---

## Topic coverage

- **Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling** — directly tested (one-time backfill flavor with overlap-prevention against running incremental).
- **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup** — touched via the post-backfill maintenance section (rewrite_data_files / expire_snapshots / rewrite_manifests).

---

## Verification notes (WebSearch)

- `overwritePartitions()` behavior confirmed against Iceberg `spark-writes` docs (1.5.1 / latest): overwrites all partitions for which the input DataFrame contains at least one row; recommended Spark mode for Iceberg is dynamic; atomic per snapshot.
- `rewrite_data_files`, `expire_snapshots(older_than, retain_last)`, `rewrite_manifests` signatures confirmed against Iceberg `spark-procedures` 1.5.1 docs. Named-argument calling convention used in the answer is the recommended style.
- Spark JDBC dbtable subquery `(SELECT ... ) t` is the documented pattern for predicate-pushdown / batch-scoped reads. `fetchsize` semantics match Spark JDBC docs.
- `pg_last_xact_replay_timestamp()` is the standard PostgreSQL replication lag introspection function.

No technical claims in the answer contradict official documentation for the production stack.

---

## Verdict

**PASS** (5.0 average; well above 3.5 threshold). One of the strongest end-to-end procedure answers in the topic so far — combines correct API usage, fit-for-stack guidance, explicit overload mitigation (replica + per-day + parallelism cap implied), explicit duplication mitigation (idempotent partition overwrite + watermark cutoff), and the maintenance follow-through that most backfill answers omit.
