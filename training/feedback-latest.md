# Iter 378 Feedback — 2026-05-30 (EXTENDED PHASE)

## Overall: 4.71875 — STRONG PASS (recovery from iter377 3.25 FAIL)

Both questions targeted iter377 critical teacher actions and BOTH passed cleanly. Recovery profile is the textbook outcome of mid-cycle judge feedback: content gap (Q1, window function SQL) closed with canonical syntax; factual error (Q2, bloom filter cardinality) inverted from backwards to correct.

| Question | Topic | TA | BC | PA | Comp | Avg | Result |
|---|---|---|---|---|---|---|---|
| Q1 | Window functions: cumulative sum | 5.0 | 4.5 | 5.0 | 4.5 | 4.75 | STRONG PASS |
| Q2 | Bloom filters: high-cardinality UUIDs | 5.0 | 4.5 | 4.75 | 4.5 | 4.6875 | STRONG PASS |

---

## Q1 — Cumulative sum window function in Trino

**Probe target**: Iter378 #1 — window function durability re-probe (iter377 Q1 content-coverage gap closure).

**Answer summary**: Provided canonical `SUM(revenue) OVER (PARTITION BY customer_id ORDER BY event_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_revenue` with explanations of PARTITION BY (per-customer isolation), ORDER BY (cumulative ordering), frame clause, and an example output table walking through cumulative values row by row.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Canonical Trino syntax verified vs [Window functions — Trino 480 Documentation](https://trino.io/docs/current/functions/window.html) and [Trino blog — Introducing new window features](https://trino.io/blog/2021/03/10/introducing-new-window-features.html). `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` is exactly the documented running-total frame. |
| Beginner clarity | 4.5 | Example output table walking through cumulative values row by row is a strong beginner aid. Minor: "frame clause" used without inline gloss for newcomer who has never seen window-function frame syntax. |
| Practical applicability | 5.0 | Copy-paste-ready SQL with named columns; engineer can run against Trino 467 immediately. |
| Completeness | 4.5 | Strong core. Missed: (a) `ROWS` vs `RANGE` distinction (physical row offset vs value-based offset on ORDER BY column), (b) NULL handling note (`SUM` skips NULLs but running total still progresses), (c) explicit "window functions execute after FROM/WHERE — partition pruning on scan preserved" callout for multi-tenant SaaS scale. |

**Q1 verdict: 4.75 STRONG PASS.** Closes iter377 Q1 content-coverage gap (canonical SUM() OVER() syntax now in responder output). Lifts "Analytical query patterns on Iceberg+Trino" running avg from 4.375/7 → 4.422/8.

---

## Q2 — Bloom filters on high-cardinality user_id UUID columns

**Probe target**: Iter378 #2 — bloom filter cardinality re-probe (iter377 Q2 factual error inversion).

**Answer summary**: YES for high-cardinality UUIDs/user_ids where min/max statistics are useless; NO for low-cardinality status / country / plan_type (already pruned by dictionary encoding + min/max). Provided `ALTER TABLE ... SET PROPERTIES parquet_bloom_filter_columns = ARRAY['user_id']` (correct Trino-Iceberg property name vs Spark's `write.parquet.bloom-filter-enabled.column.<col>`). Noted existing data needs Spark rewrite (Trino can't write bloom filters). Cited 10-100x speedup for point lookups.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Fully accurate — INVERTS iter377 backwards advice correctly. Verified vs [Iceberg Bloom Filters with Spark — Cazpian](https://cazpian.ai/blog/iceberg-bloom-filters-with-spark-configuration-validation-and-performance-guide), [Bloom Filter — Apache Parquet](https://parquet.apache.org/docs/file-format/bloomfilter/). High-cardinality (UUIDs, user IDs, session IDs, trace IDs) is the correct use case; low-cardinality columns already prune via min/max + dictionary encoding. 80-90% I/O reduction confirmed for point lookups → 10-100x speedup ballpark is reasonable. |
| Beginner clarity | 4.5 | Concrete examples (UUID, user_id as YES; status, country, plan_type as NO) anchor the cardinality concept well. Could gloss "cardinality" (= number of distinct values) and "dictionary encoding" (= Parquet stores repeated values once, references via integer ID) inline. |
| Practical applicability | 4.75 | ALTER TABLE syntax + Spark-rewrite caveat is actionable on the on-prem Iceberg 1.5.2 + Trino 467 + HMS stack. Minor: did not call out `parquet_bloom_filter_fpp` tunable for very-high-cardinality where the default 1MB size may produce too many false positives. |
| Completeness | 4.5 | Strong core. Missed: (a) probabilistic nature — bloom filter says "NOT in file" definitively but "yes" means "maybe in file" (engine still reads), (b) 1MB default size per column per row group, (c) explicit note that bloom filters only help equality predicates (`=`, `IN`) not range predicates (`>`, `<`, `BETWEEN`) — beginner might think they accelerate all WHERE clauses. |

**Q2 verdict: 4.6875 STRONG PASS.** Inverts iter377 backwards bloom filter cardinality recommendation. Lifts "Iceberg partition design for SaaS" running avg from 4.526/20 → 4.534/21.

---

## Iter 379 Teacher Actions (priority-ordered)

1. **MEDIUM (Comp Q1)** — Window function depth: add to running-total resource (a) `ROWS` vs `RANGE` distinction (physical row offset vs value-based offset on ORDER BY column), (b) NULL handling note (`SUM` skips NULLs, running total progresses), (c) explicit "window functions execute after FROM/WHERE — partition pruning on the scan is preserved" callout for multi-tenant SaaS scale. Add `RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW` 7-day rolling average example since iter379 probe #1 will target this.

2. **MEDIUM (Comp Q2)** — Bloom filter depth: add (a) probabilistic nature — bloom filter says "NOT in file" definitively but "yes" means "maybe in file" (engine still reads), (b) 1MB default size per column per row group, (c) explicit note bloom filters only help equality predicates (`=`, `IN`) not range predicates (`>`, `<`, `BETWEEN`), (d) `parquet_bloom_filter_fpp` tunable.

3. **LOW (BC inline glosses)** — Cascade still open: "frame clause" (window function), "cardinality" (= distinct value count), "dictionary encoding" (= Parquet stores repeated values once, references via integer ID). Plus iter376 carry-forward: Trino UI vocab (Queued, Scheduled, Physical Input, Blocked, Spilled, EXPLAIN ANALYZE, TYPE DISTRIBUTED), lakehouse tx vocab (atomic, idempotent, destructive, partial commit), federation vocab (CBO, BROADCAST, PARTITIONED, build/probe side, left-deep). HyperLogLog open since iter372. MinIO TCO open since iter374.

4. **LOW (carry-forward iter377 unprobed actions)** — `format_version = 2` for row-level deletes, `location` property for MinIO path control, Spark-vs-Trino write property split (table-level `write.target-file-size-bytes` unhonored by Trino — session property `target_max_file_size` needed per Trino issue #28250), `write.distribution-mode='hash'` Spark-vs-Trino split + skew caveat per Trino issue #12966. Did not surface this iteration because questions did not probe them.

---

## Iter 379 Judge Probe Targets

1. **Window function 3rd angle**: "How do I compute a 7-day rolling average per tenant in Trino?" — tests sliding `RANGE` frame (`RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW`) vs cumulative `UNBOUNDED PRECEDING`. Builds topic durability from 8 → 9 angles.

2. **Bloom filter 3rd angle (low-cardinality side)**: "I have a `country_code` column with 200 distinct values used in WHERE clauses — should I add a bloom filter on it?" — explicit low-cardinality probe (CORRECT: NO, dictionary encoding + min/max already prunes). Tests Q2 win durability.

3. **Iceberg table property production-stack-fit (carry-forward iter378 #3)**: "I set `write.target-file-size-bytes = 512MB` on my Iceberg table via Spark DDL but Trino is still writing 200MB files. Why?" — tests Trino-vs-Spark write property split per Trino issue #28250.

4. **Distribution mode probe (carry-forward iter378 #4)**: "Should I set `write.distribution-mode='hash'` on my bucket-partitioned Iceberg table?" — tests Spark vs Trino split + skew caveat per Trino issue #12966.

5. **EXPLAIN ANALYZE warning** (carry-forward iter376): probe whether responder warns EXPLAIN ANALYZE actually executes the query on an already-slow query.

6. **Federation glossary** (carry-forward iter370+): re-probe CBO / BROADCAST / PARTITIONED / build-vs-probe vocab inline glosses.

---

## Pattern Observations

- **Iter 378 ends 4.71875 — STRONG PASS, recovering from iter377 3.25 FAIL.** Both teacher critical actions from iter377 closed: window function canonical SQL provided (action #2), bloom filter cardinality inverted (action #1).
- Recovery profile is clean: Q1 closes content-coverage gap, Q2 inverts factual error. Both answers production-ready for SaaS engineer on the Iceberg 1.5.2 + Trino 467 + HMS + MinIO + k8s on-prem stack.
- Remaining drag is BC inline gloss cascade (cardinality, dictionary encoding, frame clause) and Comp depth (ROWS vs RANGE, false-positive nature of bloom filter) — both secondary to iter377 TA + PA failures. Drag is small (each dimension <0.5 below 5.0 across both questions).
- Production-stack-fit was good: `parquet_bloom_filter_columns` correctly used as Trino-Iceberg name (not Spark's `write.parquet.bloom-filter-enabled.column.<col>`), Spark-rewrite caveat correctly surfaces Trino-can't-write-bloom-filters constraint.
- Topic running averages all improve: "Analytical query patterns on Iceberg+Trino" 4.375/7 → 4.422/8, "Iceberg partition design for SaaS" 4.526/20 → 4.534/21, "Common analytical query patterns" 4.633/9 → 4.645/10.
- Iter370-378 trajectory restored above 4.0 pass band: 4.625 → 4.375 → 4.47 → 3.98 FAIL → 4.5625 → 4.75 → 4.1875 → 4.4375 → 4.40625 → 4.5625 → 3.25 FAIL → **4.71875 STRONG PASS**. Iter377 was a single-iteration anomaly driven by a content gap + factual error pair, both now corrected.

---

## Sources verified via WebSearch

- [Window functions — Trino 480 Documentation](https://trino.io/docs/current/functions/window.html) — `SUM() OVER (PARTITION BY ... ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` is canonical running-total syntax
- [Trino blog — Introducing new window features](https://trino.io/blog/2021/03/10/introducing-new-window-features.html) — `sum(totalprice) OVER (PARTITION BY clerk ORDER BY orderdate ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` documented pattern
- [Iceberg Bloom Filters with Spark — Cazpian](https://cazpian.ai/blog/iceberg-bloom-filters-with-spark-configuration-validation-and-performance-guide) — high-cardinality (UUIDs, user IDs, session IDs, trace IDs) is the correct bloom filter use case
- [Bloom Filter — Apache Parquet](https://parquet.apache.org/docs/file-format/bloomfilter/) — bloom filter for high-cardinality point lookups
- [Iceberg Query Performance Tuning — Cazpian](https://www.cazpian.ai/blog/iceberg-query-performance-tuning-partition-pruning-bloom-filters-and-spark-configs) — 80-90% I/O reduction confirmed
- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html) — `parquet_bloom_filter_columns` is the Trino-Iceberg property name
