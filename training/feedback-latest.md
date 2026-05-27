# Feedback — Iter 296 (Extended phase)

Date: 2026-05-27
Topics: TABLESAMPLE BERNOULLI for exploration + CDC vs nightly batch

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | TABLESAMPLE BERNOULLI for prototyping; approx functions; partition filter + sample workflow | **4.75** | PASS |
| Q2 | CDC architecture; batch vs CDC decision criteria; stepwise recommendation | **4.625** | PASS |

**Iter 296 average: 4.69 — PASS** ✓

**Topic updates**:
- SQL query best practices for OLAP: 4.613/10 → **4.626/11 questions** (PASSED — improved)
- Postgres-to-Iceberg ingestion: 4.474/99 → **4.476/100 questions** (PASSED — stable)
- Real-time vs batch: 4.812/4 → **4.775/5 questions** (PASSED — stable)

---

## What worked

### Q1 — TABLESAMPLE BERNOULLI (4.75)
1. "LIMIT doesn't help you" opening — corrects the engineer's likely first instinct
2. Partition filter + TABLESAMPLE combo — exactly the right pattern, shown with before/after SQL
3. Approx functions (approx_distinct HyperLogLog, approx_percentile T-Digest) — named the algorithms, practical error bound (~2%)
4. Three-phase iteration workflow (design → validate → production rollup) — concrete and immediately actionable
5. Rollup table as the production solution — addresses the underlying problem, not just the prototyping question

### Q2 — CDC vs batch (4.625)
1. Freshness-tier table ("each jump is ~10x harder") — excellent mental model for a PM conversation
2. Concrete CDC architecture walk-through (WAL → Debezium → Kafka → Spark Streaming → Iceberg) — right level for a SaaS engineer
3. Hard DELETE capture as a key CDC differentiator — engineers often miss this
4. Ops burden enumerated honestly (Postgres WAL setup, Kafka maintenance, on-call) — prevents surprises
5. Stepwise recommendation (hourly batch → tiered dashboards → CDC on one small table) — pragmatic path

---

## Resource fix applied (iter 296)

**Bug (Q1)**: Answer framed `TABLESAMPLE BERNOULLI` as scanning 400M→1M rows, implying I/O reduction. In fact, BERNOULLI reads all physical Parquet blocks from matched partitions, then randomly drops rows post-read. The actual I/O savings come from the partition filter, not BERNOULLI. `TABLESAMPLE SYSTEM` (split-level skipping) is what actually reduces I/O.

**Fix applied** to `resources/23-sql-best-practices-olap.md` section 7:
- Added complete TABLESAMPLE BERNOULLI example with percentage clarification
- Added BERNOULLI vs SYSTEM scan-cost nuance: BERNOULLI reduces post-scan work but not I/O; SYSTEM skips whole splits
- Added guidance: pair BERNOULLI with a tight partition filter for representative samples; use SYSTEM for genuine I/O reduction

---

## Suggested iter297 angles

1. **Multi-tenant analytics** — harder angles: row-level security (Apache Ranger policies), or cross-tenant SLA metrics (p99 query latency per tenant over time)
2. **Iceberg maintenance** — snapshot expiry + orphan file cleanup workflow; or compaction tuning (when to use sort vs bin-pack strategy)
3. **Trino federation** — cross-catalog joins (Iceberg + Postgres connector in one query), predicate pushdown to JDBC, when federation beats ingestion
4. **SQL OLAP best practices** — EXPLAIN ANALYZE workflow for diagnosing a slow query step-by-step (TABLESAMPLE and approx functions covered; EXPLAIN workflow has been touched but could use a systematic angle)
