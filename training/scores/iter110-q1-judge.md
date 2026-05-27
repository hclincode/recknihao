# Iter 110 Q1 — Judge Verdict

**Topic**: Postgres-to-Iceberg ingestion (CDC with Debezium)
**Question**: Clean handoff between Spark bootstrap load and Debezium CDC for a live 200M-row Postgres table — avoiding gaps/duplicates.
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter110-q1.md`

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 3 | Several core claims correct, but one significant correctness bug in the MERGE pattern and a meaningful oversimplification of the handoff procedure |
| Beginner clarity | 4.5 | Strong structure, concrete timeline, clear table comparing snapshot.mode values — accessible to a SaaS engineer |
| Practical applicability | 3.5 | Fits the on-prem stack (Debezium 2.x, Spark, Iceberg 1.5.2). However the recommended pause-and-create-slot sequence is operationally fragile and the MERGE bug would cause silent data corruption in production |
| Completeness | 3.5 | Hits the major beats (snapshot.mode, slot creation, idempotent MERGE, verification) but misses the *correct* canonical pattern: create the slot FIRST, then snapshot, then start streaming — which eliminates the need to pause writes |

**Weighted average (simple mean)**: (3 + 4.5 + 3.5 + 3.5) / 4 = **3.625 / 5** → PASS (just over threshold)

---

## Technical verification (via WebSearch)

1. **`snapshot.mode: no_data` valid for Postgres** — CONFIRMED. It is a valid option in Debezium 2.x and is the recommended modern replacement for the deprecated `never` mode. The answer's table characterization is accurate.

2. **`pg_create_logical_replication_slot('name', 'pgoutput')` syntax** — CONFIRMED. Function signature is `pg_create_logical_replication_slot(slot_name, plugin)`, and `pgoutput` is the built-in PostgreSQL logical decoding plugin (no install needed). Answer is correct.

3. **`snapshot.mode: recovery` not valid for Postgres** — CONFIRMED. `recovery` is only available for MySQL, MariaDB, and SQL Server (connectors that use a schema history topic). Postgres and MongoDB do not support it. Answer's table is correct.

4. **MERGE INTO pattern with op IN ('u','d') / op IN ('c','r')** — **INCORRECT / BUG**. Debezium op codes are: `c`=create, `u`=update, `d`=delete, `r`=read (snapshot). The answer's pattern:
   ```sql
   WHEN MATCHED AND s.op IN ('u', 'd') THEN UPDATE SET * = s.*
   ```
   This treats a DELETE (`op='d'`) as an UPDATE. For a Debezium delete event, the "after" image is null/empty — applying `UPDATE SET *` from a delete event will either fail or, worse, silently null out the row's columns instead of removing the row. The correct pattern requires two separate WHEN MATCHED branches:
   ```sql
   WHEN MATCHED AND s.op = 'd' THEN DELETE
   WHEN MATCHED AND s.op IN ('u','c','r') THEN UPDATE SET *
   WHEN NOT MATCHED AND s.op IN ('c','r','u') THEN INSERT *
   ```
   (Plus deduping the staging set to the latest event per key before MERGE, to avoid `MERGE` non-determinism when the same key appears in multiple events in one batch.)

---

## Additional issues

### A. The "pause writes for 30 seconds" pattern is the wrong canonical approach
The standard production pattern is the **opposite order**:
1. Create the replication slot FIRST (slot starts retaining WAL immediately).
2. Snapshot the table (Spark JDBC read or `pg_dump --snapshot=<slot_snapshot_name>` for consistency with the slot's LSN).
3. Start Debezium with `snapshot.mode: no_data` — it begins streaming from the slot's start LSN, replaying every change committed after the slot was created.

Because the slot exists before the snapshot starts, no writes are missed and there's no need to pause application writes. The MERGE-based consumer's idempotency naturally absorbs the overlap (events that touch rows already in the bootstrap snapshot just re-apply the same final state).

The answer's "pause writes for 30 seconds" suggestion is operationally hostile — most production OLTP systems cannot pause writes even briefly, and the procedure leaves a race window if any step takes longer than expected.

The Debezium docs themselves call this out: *"you might miss/lose data that were created in related tables before the replication slot was created"* — which is exactly why the slot-first pattern is preferred.

### B. Missing mention of slot-exported snapshot
PostgreSQL replication slots expose a consistent snapshot (`pg_export_snapshot()` / the slot's `snapshot_name`) that Spark can use via `SET TRANSACTION SNAPSHOT '...'` to read at exactly the slot's start LSN. This is the gold-standard pattern for gap-free handoff and is not mentioned.

### C. Schema considerations missing
No mention of:
- How the bootstrap rows acquire an `op` value (typically backfilled as `op='r'`) so the MERGE consumer can treat them uniformly.
- Whether bootstrap and CDC paths produce the same target schema (e.g., flattened payload, `__deleted` flag, transaction metadata).
- Handling of `op='r'` in the MERGE — the answer correctly groups it with `'c'` in the INSERT branch but only because bootstrap is via Spark (not Debezium snapshot), so `'r'` events would never appear. Worth a brief clarification.

### D. Verification query is weak
The `COUNT(*) + MAX(updated_at)` check assumes the table has an `updated_at` column (not stated) and only catches gross gaps. A stronger check is comparing per-day row counts between Postgres and Iceberg for the bootstrap window, plus monitoring `pg_replication_slots.confirmed_flush_lsn` lag.

---

## What the answer got right

- Correctly identifies `no_data` as the right snapshot mode.
- Correctly notes `never` is the deprecated alias.
- Correctly flags `recovery` as not valid for Postgres.
- Correct `pg_create_logical_replication_slot` SQL.
- Correct `pgoutput` plugin choice (matches Debezium 2.x default).
- Good explicit timeline showing how the handoff fits together.
- Calls out the silent-data-loss failure mode (most important point for a SaaS engineer).
- MERGE INTO idempotency framing is correct in spirit.

---

## Resource fix recommendations

1. **HIGH — Fix the MERGE pattern in the CDC resource(s)**. Any code example that does `WHEN MATCHED AND op IN ('u','d') THEN UPDATE SET *` is a silent-corruption bug. Replace with the three-branch pattern (`WHEN MATCHED AND op='d' THEN DELETE` / `WHEN MATCHED AND op IN ('u','c','r') THEN UPDATE SET *` / `WHEN NOT MATCHED ...INSERT`). Also add a note about deduping the source batch to the latest event per key before MERGE.

2. **HIGH — Document the slot-first handoff pattern** as the canonical approach. The current "pause writes for 30s" pattern, while it appears in the answer, is not the production-grade pattern. Add a subsection covering:
   - Create replication slot (returns `consistent_point` LSN and `snapshot_name`).
   - Spark JDBC bootstrap uses the slot's exported snapshot for transactional consistency (or accepts overlap and relies on idempotent MERGE).
   - Start Debezium with `snapshot.mode: no_data` — it replays from the slot's LSN.
   - No application pause required.

3. **MEDIUM — Add bootstrap-row `op` convention**. When bootstrapping via Spark, backfill `op='r'` (or `'c'`) so downstream MERGE logic is uniform across bootstrap and CDC paths.

4. **MEDIUM — Strengthen verification guidance**. Replace `COUNT(*) + MAX(updated_at)` with: (a) per-day row-count diff between Postgres and Iceberg over the bootstrap window; (b) monitoring `pg_replication_slots.confirmed_flush_lsn` lag; (c) sampling-based row-hash compare.

5. **LOW — Note the `never` deprecation explicitly**. The answer table says "Alias; `no_data` is preferred in Debezium 2.x" — accurate, but the docs are stronger: `never` is officially deprecated in favor of `no_data`. Worth stating outright.

---

## Running average update

- Prior: 4.474 across 94 questions
- This score: 3.625
- New average: (4.474 × 94 + 3.625) / 95 = (420.556 + 3.625) / 95 = 424.181 / 95 = **4.465 across 95 questions**

Status: still PASSED, but a regression from 4.474 → 4.465. The MERGE bug is the dominant scoring driver — without that the answer would have been ~4.0.

---

## Sources consulted

- [Debezium connector for PostgreSQL :: Debezium Documentation](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- [Debezium Snapshot Modes Explained — Conduktor](https://kafka-options-explorer.conduktor.io/debezium/snapshot-modes/)
- [pg_create_logical_replication_slot() — pgPedia](https://pgpedia.info/p/pg_create_logical_replication_slot.html)
- [Debezium Operation Codes explained — NamiLink (Medium)](https://medium.com/namilink/debezium-postgresql-connector-understanding-data-change-events-d1c252fa1c72)
- [CDC to Iceberg: 4 Major Challenges — Upsolver](https://www.upsolver.com/blog/cdc-to-iceberg-4-major-challenges-and-how-we-solved-them)
- [Mastering Postgres Replication Slots — Gunnar Morling](https://www.morling.dev/blog/mastering-postgres-replication-slots/)
