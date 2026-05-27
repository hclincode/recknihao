# Iter 115 Q1 — Judge Report

**Question topic**: Bootstrap an 800M-row Postgres table into Iceberg while a Debezium CDC stream is already running, with a clean handoff that loses no rows and avoids duplicates.

**Resource under test**: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter115-q1.md`

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Core slot-first sequence and `snapshot.mode=no_data` are correct (verified vs Debezium and PG docs). One concrete error in the `pg_create_logical_replication_slot` 4-arg call (see Errors). Otherwise statements are accurate. |
| Clarity | 4.5 | Excellent narrative arc, step-by-step structure with explicit "why this order matters" table, glossed `op='r'`, LSN, slot terminology in context, and a closing key-insight line. Minor jargon (`consistent_point`, `confirmed_flush_lsn`) introduced without inline definitions. |
| Practical completeness | 4.0 | Engineer can act: there is a runnable slot-creation SQL, Spark JDBC code with `numPartitions`, Strimzi CRD snippet, a MERGE template, a slot-health monitoring SQL, and a per-day verification query. Missing: the alternative Debezium incremental-snapshot signal path, and acknowledgement that `lowerBound`/`upperBound` in the Spark JDBC example are obviously placeholder values (the `800_000_000_000` upper bound is three orders of magnitude too high). |
| Completeness of coverage | 3.5 | Covers the canonical slot-first bootstrap, MERGE idempotency, slot health, and verification. Misses (a) Debezium 2.x **incremental snapshot via signal table** — the other valid solution to this exact problem and arguably the more modern recommendation since it avoids a separate Spark JDBC pipeline; (b) `publication.autocreate.mode` / `publication.name` interaction; (c) the prod-environment Strimzi/MinIO/JWT context is not woven in. |

**Average: 3.875**

**Verdict: PASS** (≥ 3.5 threshold).

---

## What was verified correct (via WebSearch)

1. **`snapshot.mode=no_data`** is a real Debezium 2.x value, and `never` is the deprecated alias. Confirmed against the Debezium PostgresConnector documentation. The answer's table description matches the official docs: "skips per-row snapshot entirely … streaming starts from the current WAL position."
2. **Slot-first sequence (slot → bootstrap → connector with `no_data`)** is the canonical pattern endorsed by Debezium docs: "Replication slots are guaranteed to retain all WAL entries that are required for Debezium even during Debezium outages." Once the slot is created, all subsequent WAL is retained until consumed.
3. **`SET TRANSACTION ISOLATION LEVEL REPEATABLE READ` + `pg_export_snapshot()`** is the correct PostgreSQL mechanism to share a consistent snapshot across sessions, per the PG docs: "For REPEATABLE READ and SERIALIZABLE transaction levels, a snapshot is created at the beginning and kept consistent throughout the transaction."
4. **`max_slot_wal_keep_size`** correctly bounds WAL retention for replication slots; PG marks the slot invalidated (not dropped) when exceeded — the answer's framing ("fills Postgres disk … set a cap") matches the documented behavior.
5. **Spark SQL `UPDATE SET *` / `INSERT *`** in MERGE INTO is real syntax supported by Iceberg's Spark extensions and is documented in the Apache Iceberg writes docs. The answer correctly scopes the MERGE to a "Spark Structured Streaming consumer," not Trino, so the wildcard form is valid in context. (Trino MERGE does NOT support `SET *` / `INSERT *` — using these in Trino would error. The answer does not make that claim, so this is fine, but borderline if a beginner copy-pastes into Trino.)
6. **`op='r'` convention for snapshot rows** matches Debezium's documented schema (`r` = read / snapshot).

---

## Errors and gaps found

### ERROR 1 — Incorrect 4-arg `pg_create_logical_replication_slot` signature (HIGH severity for technical correctness)

The answer writes:

```sql
SELECT * FROM pg_create_logical_replication_slot('debezium_slot', 'pgoutput', false, true);
SELECT pg_export_snapshot();
```

and frames the `true` fourth argument as causing snapshot export. This is **wrong**. The PostgreSQL SQL function's 4-arg signature is `(slot_name, plugin, temporary, two_phase)`. The fourth argument is `two_phase`, not `exportSnapshot`. Passing `true` enables two-phase decoding (relevant only for prepared transactions); it does NOT cause snapshot export.

What's correct is that *creating the slot inside a REPEATABLE READ transaction* causes the slot's `consistent_point` to align with the transaction's snapshot, and `pg_export_snapshot()` on the same transaction then exports a snapshot at that same point. So the resulting behavior the answer describes (cross-session snapshot consistency) is achievable — but the explanation of *which argument enables it* is incorrect. An engineer who follows this verbatim will end up with two-phase decoding enabled (a feature they probably do not want and which can cause subtle Debezium behavior changes if not also configured on the connector side).

Note: the `exportSnapshot` parameter the answer is thinking of belongs to the **streaming-replication protocol's `CREATE_REPLICATION_SLOT` command** (used by `pg_recvlogical` and Debezium internally), not to the SQL function `pg_create_logical_replication_slot`. This is a common confusion. The same error appears in the underlying resource (`resources/13-postgres-to-iceberg-ingestion.md` line 1492-1494) — see fix recommendation below.

### ERROR 2 — Placeholder `upperBound=800_000_000_000` is three orders of magnitude too high (MEDIUM)

For an 800M-row table the upperBound should be in the neighborhood of `800_000_000` (or higher, since `id` is a PK with gaps). The trailing zeroes in the answer (`800_000_000_000` = 800 *billion*) appear to be a typo. With `numPartitions=16` and `lowerBound=1`, this produces partition strides of 50B IDs each, so all 800M real IDs land in partition 0 — turning the parallel read back into a single-partition read. This is the exact failure mode resource 13 warns against in "Setting numPartitions=1 'to be conservative'." A non-OLAP engineer copy-pasting this code will get the symptom (12+ hour bootstrap) without understanding the cause.

### GAP 1 — Debezium incremental snapshot via signal table is not mentioned (MEDIUM)

Debezium 2.x supports **incremental ad-hoc snapshots** triggered by writing a row to a signal table, which is arguably the cleaner solution to this exact problem: keep the existing Debezium connector running, write a `execute-snapshot` row to the signal table, and Debezium reads the table in chunks (interleaved with WAL streaming) without any separate Spark JDBC pipeline. The Debezium blog post "Incremental Snapshots in Debezium" (2021) and the official signalling docs cover this. The answer is correct that the slot-first Spark JDBC pattern works, but in an environment that already has a healthy Debezium connector running, the incremental-snapshot signal is the lower-risk option (no separate bootstrap pipeline to operate, no MERGE-overlap reasoning needed).

### GAP 2 — Production-environment fit not explicit (LOW)

`prod_info.md` describes Strimzi/MinIO/JWT/OPA on-prem k8s. The answer mentions Strimzi KafkaConnector CRD (good) but does not call out: (a) the connector secret-injection pattern documented in resource 13 (FileConfigProvider, not plaintext `database.password`); (b) any MinIO/S3 endpoint specifics for the Iceberg writes. These are not strictly required for the question asked, but a complete answer for this prod environment would name them.

### GAP 3 — Reliance on `pg_export_snapshot()` requires keeping the transaction open (LOW)

The answer says "Keep transaction open while Spark runs; commit after Spark finishes" — correct, but does not warn the engineer that an 800M-row Spark read could take 1-6 hours, during which time the transaction holds an open snapshot on the primary. This blocks autovacuum on the affected tables for the duration and is a well-known foot-gun. Resource 13's `hot_standby_feedback` discussion covers a related issue for replicas, but the primary-side autovacuum implication is not explicit.

### GAP 4 — The `confirmed_flush_lsn` and `lag_bytes` interpretation glosses over a sharp edge (LOW)

The answer says "active must be true and lag_bytes should decrease toward zero." In practice, during the bootstrap window, the slot is **inactive** (Debezium has not connected yet) and `lag_bytes` will grow large — this is *expected* behavior, not a bug. The current wording could panic an engineer who runs the monitoring query during step 2.

---

## Resource fix recommendations

### HIGH — Fix the `pg_create_logical_replication_slot` 4-arg signature in `resources/13-postgres-to-iceberg-ingestion.md`

File: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
Lines: approximately 1485-1497

The current text frames the 4th argument as triggering snapshot export. It does not. The 4th argument is `two_phase`. Replace with the correct mechanism:

- Either: drop to the 2-arg form and rely on the surrounding `BEGIN; SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; … pg_export_snapshot();` block, explaining that the SQL function inherits the calling transaction's snapshot.
- Or: explicitly point to the streaming-replication protocol's `CREATE_REPLICATION_SLOT … EXPORT_SNAPSHOT` command for users who want the slot's own consistent_point snapshot exposed without holding a long transaction.

Add a callout: "The SQL function `pg_create_logical_replication_slot(slot_name, plugin, temporary, two_phase)` does NOT have an `exportSnapshot` parameter. Snapshot export at slot creation time is a protocol-level feature of `CREATE_REPLICATION_SLOT`, not of the SQL function."

### MEDIUM — Add Debezium incremental snapshot (signal table) as a parallel option in resource 13

File: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
Location: a new subsection adjacent to "Canonical Spark bootstrap → Debezium CDC handoff (slot-first)" (around line 1470).

Cover:
- When to prefer signal-table incremental snapshot vs. Spark JDBC bootstrap (existing healthy connector vs. greenfield).
- Required config: `signal.data.collection`, `signal.enabled.channels`, signal table DDL on Postgres.
- The `INSERT INTO debezium.signal VALUES (...)` form to trigger an `execute-snapshot` for `public.events`.
- Chunking behavior (Debezium reads in PK-ordered chunks of `incremental.snapshot.chunk.size` rows, interleaved with WAL streaming — no separate pipeline).
- Trade-offs: signal-table approach is slower wall-clock for an 800M-row table because all rows go through the connector/Kafka rather than parallel Spark workers, but operationally simpler.

### MEDIUM — Add a "placeholder values" warning to the Spark JDBC code

File: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
Lines: the Spark JDBC bootstrap example near line 1501-1514.

Add an explicit `# REPLACE with actual MAX(id) from your table` comment on the `upperBound` argument, and a sentence noting that wrong upperBound silently reduces parallelism to 1 partition without raising an error.

### LOW — Document the autovacuum hazard of long-running snapshot-exporting transactions

File: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
Location: in the slot-first section, after the `pg_export_snapshot()` callout.

Note: "A transaction holding an exported snapshot for hours blocks autovacuum on rows visible to that snapshot. For an 800M-row table this is usually acceptable for a one-shot bootstrap but should be coordinated with the DBA. Coordinate the bootstrap window with off-peak autovacuum scheduling."

### LOW — Clarify expected slot state during bootstrap window

File: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
Location: in or near the slot-monitoring SQL.

Note: "During step 2 (Spark bootstrap), the slot will show `active=false` and `lag_bytes` will grow — this is expected. Only after step 3 (Debezium connects with `snapshot.mode=no_data`) should `active` flip to true and `lag_bytes` begin to decrease."

---

## Topic rubric update

Topic touched: **Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling** (currently PASSED, avg 4.468 across 96 questions).

This answer scores **3.875**, which slightly drags the running average down but remains well above the 3.5 pass threshold.

## Sources

- [Debezium connector for PostgreSQL :: Debezium Documentation](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- [Incremental Snapshots in Debezium](https://debezium.io/blog/2021/10/07/incremental-snapshots/)
- [Sending signals to a Debezium connector :: Debezium Documentation](https://debezium.io/documentation/reference/stable/configuration/signalling.html)
- [pg_create_logical_replication_slot() — pgPedia](https://pgpedia.info/p/pg_create_logical_replication_slot.html)
- [PostgreSQL: Documentation: 18: 47.2. Logical Decoding Concepts](https://www.postgresql.org/docs/current/logicaldecoding-explanation.html)
- [PostgreSQL: Documentation: 18: 54.4. Streaming Replication Protocol (CREATE_REPLICATION_SLOT)](https://www.postgresql.org/docs/current/protocol-replication.html)
- [max_slot_wal_keep_size — pgPedia](https://pgpedia.info/m/max_slot_wal_keep_size.html)
- [Mastering Postgres Replication Slots — Gunnar Morling](https://www.morling.dev/blog/mastering-postgres-replication-slots/)
- [Apache Iceberg Spark Writes (MERGE INTO `UPDATE SET *` / `INSERT *`)](https://iceberg.apache.org/docs/latest/spark-writes/)
- [MERGE — Trino documentation](https://trino.io/docs/current/sql/merge.html)
- [Release 467 (6 Dec 2024) — Trino documentation](https://trino.io/docs/current/release/release-467.html)
