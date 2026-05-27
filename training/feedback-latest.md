# Feedback — Iter 275 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — cross-catalog atomicity (Q1 PASS) + Trino Web UI federation debugging (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Cross-catalog writes: no atomic cross-catalog transactions, partial failure patterns, three remediation patterns | **4.75** | PASS |
| Q2 | Trino Web UI for federation debugging: Stages tab Input/Output rows, EXPLAIN as authoritative tool, combined diagnostic workflow | **4.88** | PASS |

**Iter 275 average: 4.815 — PASS** ✓ Both passed!

**Topic update**: Trino federation: 4.487/223 → **4.490/225** (NEEDS WORK, gap 0.010 — improving steadily)

---

## What worked

### Q1 — Cross-catalog atomicity (4.75)
1. Correctly stated Trino has no cross-catalog transactions — correct
2. Each catalog commits independently — correct
3. Partial failure scenario (Postgres succeeds, Iceberg fails) explained clearly — correct
4. Three remediation patterns: app-level coordination, CDC (Debezium+Kafka), batch MERGE INTO — correct and complete
5. Python idempotent retry example with `enqueue_retry` — practical
6. CDC pattern: Kafka buffers retries if Iceberg unavailable — correct key insight
7. `MERGE INTO` batch sync as simplest fallback — correct

### Q2 — Trino Web UI debugging (4.88)
1. Web UI Stages tab shows Input/Output rows per stage — correct
2. JDBC source stage vs Iceberg source stage distinction — correct
3. "Input: 5M rows, Output: 312 rows" pattern as red flag for pushdown failure — concrete and accurate
4. Critical limitation: Web UI shows how many rows returned, NOT whether WHERE clause ran server-side — correct nuance
5. EXPLAIN (TYPE DISTRIBUTED) as free diagnostic (no re-execution) — correct
6. EXPLAIN ANALYZE for runtime row counts — correct
7. Combined workflow table (Web UI → plain EXPLAIN → EXPLAIN ANALYZE → Postgres slow-query log) — excellent structure
8. Fix note: remove implicit casts that block pushdown — actionable

---

## Errors / gaps to fix before iter276

### Q1 (important addition)
- **START TRANSACTION caveat missing**: Answer should note that `START TRANSACTION` in Trino does NOT give cross-catalog atomicity — it only controls autocommit behavior within a single connector. Engineers sometimes try `START TRANSACTION; INSERT INTO iceberg...; UPDATE postgres...; COMMIT;` expecting atomicity but Trino does not coordinate across catalogs within a transaction block. Should be called out explicitly.
- **JDBC stages are single-task**: Minor — when explaining Trino internals, should note that JDBC source stages run as a single task (no parallelism) because JDBC connectors don't support splits by default; this is a factor in why Postgres scans appear as one serialized operation.

### Q2 (minor)
- No significant errors. High-quality answer.

---

## Resource fixes before iter276

### Important

1. **START TRANSACTION and cross-catalog atomicity** (resource 22, cross-catalog section):
   - Add explicit callout: `START TRANSACTION` in Trino does NOT give cross-catalog atomicity
   - Clarify that START TRANSACTION / COMMIT controls autocommit within a single connector only
   - Note: `BEGIN; INSERT INTO iceberg...; UPDATE postgres...; COMMIT;` is NOT atomic — each DML commits to its own catalog independently regardless of the transaction block

2. **JDBC parallelism / single-task note** (resource 22, JDBC connector section):
   - Add note: JDBC source stages run as a single task by default (JDBC connectors do not support splits)
   - Contrast with Iceberg which supports parallel file splits
   - This explains why large Postgres scans serialize in Trino and appear as a bottleneck

---

## Suggested iter276 angles (MUST target Trino federation, gap 0.010)

Topic at 4.490/225. Need ~4-5 more questions at 4.875+ to cross 4.500 threshold.

1. **Re-test: ILIKE pushdown nuanced behavior** — engineer asks if Trino can push LIKE/ILIKE through to Postgres; correct answer: conditional on `enable_string_pushdown_with_collate` and column collation; always verify with EXPLAIN; not a categorical "never"

2. **Trino resource groups under federation load** — engineer asks how to limit how many concurrent Postgres queries Trino runs; resource groups + PgBouncer pattern; `hardConcurrencyLimit`, `maxQueued`; source selector caveat

3. **Federate vs ingest decision at scale** — engineer has 50M-row Postgres table that joins to Iceberg frequently; answer: above 10M threshold → prefer ingestion; nightly MERGE INTO pattern; when to hybrid materialize

4. **metadata.cache-ttl and stale reads** — engineer sees Trino return old Iceberg data after a Spark job adds files; answer: cache-ttl, flush_metadata_cache (coordinator-only), CREATE OR REPLACE VIEW workaround

5. **system.query() passthrough** — engineer wants to run a native Postgres function not supported by Trino connector; TABLE(catalog.system.query(query => '...')) syntax; no outer pushdown; single-quote doubling
