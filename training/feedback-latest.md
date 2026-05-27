# Feedback — Iter 283 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — Cross-catalog atomicity (Q1 PASS) + Federate vs ingest 20M-row table (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Cross-catalog atomicity: START TRANSACTION does not coordinate across Postgres+Iceberg; no XA/2PC; three remediation patterns (outbox, CDC, batch MERGE) | **4.70** | PASS |
| Q2 | Federate vs ingest 20M-row accounts table: JDBC bottlenecks, DF tuning first, CTAS+MERGE INTO sync, hybrid UNION ALL view | **4.70** | PASS |

**Iter 283 average: 4.70 — PASS** ✓ Both passed!

**Topic update**: Trino federation: 4.496/239 → **4.498/241** (NEEDS WORK, gap 0.002 — EXTREMELY CLOSE to 4.500 threshold!)

---

## What worked

### Q1 — Cross-catalog atomicity (4.70)
1. Correct and immediate "no" — START TRANSACTION does NOT coordinate across catalogs
2. Trino has no XA/2PC coordinator — verified against Trino docs
3. Each connector commits independently at DML completion — correct
4. Three remediation patterns with code: outbox+idempotent retry (Python), CDC (Debezium+Kafka concept), batch MERGE INTO with watermark overlap
5. Explicit warning: Iceberg rows committed before Postgres failure = no auto-rollback
6. Watermark upper bound in MERGE INTO pattern (2-hour overlap) — correct

### Q2 — Federate vs ingest (4.70)
1. Three structural JDBC costs correctly identified: row-by-row, single-split/connection, no pre-computation
2. Tuning-first approach: DF wait timeout to 15s, selective WHERE predicate, EXPLAIN ANALYZE
3. `dynamicFilterSplitsProcessed > 0` as the correct DF verification metric — verified
4. Domain compaction threshold 256 — verified correct
5. CTAS initial load + MERGE INTO incremental sync with 2-hour overlap watermark — sound
6. Hybrid UNION ALL view (Iceberg historical + Postgres live tail) — correct freshness pattern
7. Broadcast join benefit at 150-300MB Parquet — realistic sizing
8. Decision summary table with measurable threshold (>2s after tuning)

---

## Errors / gaps (did not block pass)

### Q1 (minor)
- Slight overstatement: "Iceberg commits are immutable — no rollback once written" understates `CALL iceberg.system.rollback_to_snapshot()`. Should clarify that manual snapshot rollback is possible but is NOT triggered automatically on transaction failure. The practical conclusion (no auto-rollback) is correct.

### Q2 (minor)
- "Single-task" should more precisely be "single split / single JDBC connection" — the constraint is at the split/connection layer, not the task layer
- Session property `iceberg.dynamic_filtering_wait_timeout` should note the prefix is the catalog name — could cause confusion if catalog is named differently
- Hard-delete handling not mentioned: MERGE INTO with watermark catches inserts/updates but not deletes; periodic full reconciliation needed for true SCD with deletes
- `domain_compaction_threshold` is configurable as a session property — not mentioned

---

## Resource fixes before iter284

None urgent. Resource 22 is in good shape.

### Nice-to-have
1. **Clarify "single-split / single JDBC connection" phrasing** in JDBC parallelism section — current "single task" language is slightly imprecise
2. **Add `domain_compaction_threshold` configurability note**: `SET SESSION domain_compaction_threshold = 512` for cases where IN-list precision matters

---

## Suggested iter284 angles (MUST target Trino federation, gap 0.002)

Topic at 4.498/241. Need ~1 more question at 4.875+ to cross 4.500 threshold!

1. **EXPLAIN ANALYZE on federated queries — reading the plan** — how to interpret ScanFilterProject vs TableScan; constraint annotation for predicate pushdown; dynamicFilters in plan output

2. **Trino resource groups for federated workloads** — hardConcurrencyLimit, maxQueued, source selectors with X-Trino-Source header; file-based config requires coordinator restart

3. **Dynamic filtering with high-cardinality keys — domain compaction** — DF IN-list ≥256 values compacted to a range; session property `domain_compaction_threshold` to raise the limit; when DF stops being effective

4. **Re-test: JSONB system.query() passthrough** — sending native Postgres SQL verbatim; no outer predicate pushdown on the result; single-quote doubling; ORDER BY not preserved

5. **ILIKE pushdown conditions** — conditional on `enable_string_pushdown_with_collate=true` and compatible column collation; COLLATE "C" warning for ICU columns
