# Judge Feedback — Iter 377 (EXTENDED PHASE)

**Iteration average: 3.25 — FAIL**

| Question | Topic | TA | BC | PA | Comp | Avg | Result |
|---|---|---|---|---|---|---|---|
| Q1 | Window functions running totals in Trino | 4.0 | 3.5 | 2.0 | 2.0 | **2.875** | FAIL |
| Q2 | Iceberg table properties at CREATE TABLE | 3.0 | 4.0 | 3.5 | 4.0 | **3.625** | FAIL |

---

## Q1 — Window functions running totals in Trino

**What was given:** Responder admitted resources do not contain enough window-function content; confirmed Trino supports window functions; recommended testing with EXPLAIN ANALYZE; suggested pre-aggregated rollup tables as alternative for large datasets. **Did NOT provide a working `SUM(...) OVER()` example** — the deliverable the engineer asked for.

**What worked:**
- Honest acknowledgement of the resource gap (correct behavior when content is missing)
- All affirmative claims are accurate (Trino supports window functions, EXPLAIN ANALYZE is useful, pre-aggregated rollup is a valid alternative pattern)
- No misleading or incorrect technical claims

**Gaps:**
- **TA (−1.0)**: No factual errors in what was stated, but absence of canonical SQL example is a content-coverage failure.
- **BC (−1.5)**: A beginner asking "how do I compute a running total" needs to SEE the SQL syntax. Telling them "we support it, go test with EXPLAIN ANALYZE" gives them nothing to test.
- **PA (−3.0)**: Engineer cannot act on this. The CORE deliverable (`SUM(amount) OVER (PARTITION BY tenant_id ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`) is missing.
- **Comp (−3.0)**: Did not answer the question. Missing canonical Trino window function syntax (documented at https://trino.io/docs/current/functions/window.html), frame specification (ROWS vs RANGE), per-tenant PARTITION BY for multi-tenant SaaS, performance note that window functions execute after FROM/WHERE so partition pruning still works.

Judge verified via WebSearch:
- [Window functions — Trino 481 Documentation](https://trino.io/docs/current/functions/window.html) confirms SUM() OVER (PARTITION BY ... ORDER BY ... [frame_clause]) is the standard syntax pattern.

---

## Q2 — Iceberg table properties at CREATE TABLE

**What was given:** Detailed checklist table with: `partitioning=ARRAY['day(occurred_at)', 'tenant_id']`, `format='PARQUET'`, `write.distribution-mode='hash'` (claimed CRITICAL for bucket partitioning, prevents file explosion), `sorted_by` for non-partition pruning, **bloom filters for LOW-cardinality equality predicates**, `history.expire.min-snapshots-to-keep` as safety net, `write.target-file-size-bytes` "belongs in compaction not creation."

**What worked:**
- Checklist table format is helpful for an engineer scanning a CREATE TABLE template
- partitioning=ARRAY['day(occurred_at)', 'tenant_id'] is VALID per Trino 481 Iceberg connector docs
- format='PARQUET' is VALID
- sorted_by for non-partition column pruning is VALID
- history.expire.min-snapshots-to-keep as safety net is VALID

**Gaps (two factual errors — see verification below):**
- **TA (−2.0)**: TWO factual issues:
  1. **Bloom filter LOW-CARDINALITY recommendation is BACKWARDS.** Per [Iceberg Bloom Filters with Spark — Cazpian](https://cazpian.ai/blog/iceberg-bloom-filters-with-spark-configuration-validation-and-performance-guide) and [Bloom Filter — Apache Parquet](https://parquet.apache.org/docs/file-format/bloomfilter/), bloom filters are valuable for HIGH-cardinality columns (UUIDs, user IDs, session IDs, trace IDs) where min/max stats are useless because every file's range covers the lookup value. For LOW-cardinality columns, min/max + dictionary encoding already prune well — bloom filter adds overhead with little benefit. This would steer the engineer to add bloom-filter overhead on wrong columns.
  2. **`write.distribution-mode='hash'` "critical, prevents file explosion" is overstated.** Per [Trino issue #12966](https://github.com/trinodb/trino/issues/12966) and [Spark Writes — Apache Iceberg](https://iceberg.apache.org/docs/latest/spark-writes/): it is primarily a Spark write hint; on bucket transforms hash distribution can produce SKEW, not always fix small-files. Should be framed as "Spark-side hint, helps in some patterns, can cause skew in others."
  3. **`write.target-file-size-bytes` "belongs in compaction not creation"** is MISLEADING — per [Configuration — Apache Iceberg](https://iceberg.apache.org/docs/latest/configuration/) it IS a creation-time table property (1GB default), but per [Trino issue #28250](https://github.com/trinodb/trino/issues/28250) Trino does NOT currently honor the table-level property at write time; only session-level `target_max_file_size` is honored. Correct framing is "Trino does not honor table-level; use session property `target_max_file_size`."
- **BC (−1.0)**: Checklist helpful; "bucket partitioning", "distribution-mode", "non-partition column pruning" used without inline glosses but minor.
- **PA (−1.5)**: Detailed checklist gives a starting CREATE TABLE template, but bloom-filter advice would steer engineer wrong, and distribution-mode might be set unnecessarily on Trino-write workloads. Engineer needs production-stack-specific guidance (Iceberg 1.5.2 + Trino 467 + HMS): Trino session property `target_max_file_size`, not table-level write.target-file-size-bytes.
- **Comp (−1.0)**: Missed: (a) production caveat that Trino 467 does not honor all Iceberg standard write.* table properties — Spark-vs-Trino split; (b) `parquet_bloom_filter_columns` as the Trino-Iceberg property name (vs Spark's `write.parquet.bloom-filter-enabled.column.<col>`); (c) `format_version = 2` recommendation (needed for row-level delete files / position deletes); (d) `location` property for explicit MinIO path control.

Judge verified via WebSearch:
- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html) — partitioning, format, sorted_by, location confirmed
- [Trino issue #12966 — partitioned writes with transform columns have poor distribution](https://github.com/trinodb/trino/issues/12966) — hash distribution on bucket transforms can cause skew
- [Spark Writes — Apache Iceberg](https://iceberg.apache.org/docs/latest/spark-writes/) — write.distribution-mode primarily Spark write hint
- [Iceberg Bloom Filters with Spark — Cazpian](https://cazpian.ai/blog/iceberg-bloom-filters-with-spark-configuration-validation-and-performance-guide) — bloom filters for HIGH-cardinality (NOT low-cardinality)
- [Bloom Filter — Apache Parquet](https://parquet.apache.org/docs/file-format/bloomfilter/) — bloom filter use case for high-cardinality point lookups
- [Trino issue #28250 — Support Iceberg table properties for write configuration](https://github.com/trinodb/trino/issues/28250) — Trino does not honor table-level write.target-file-size-bytes
- [Configuration — Apache Iceberg](https://iceberg.apache.org/docs/latest/configuration/) — write.target-file-size-bytes is a standard creation-time table property

---

## ITER378 TEACHER ACTIONS (PRIORITY-ORDERED)

1. **CRITICAL (TA, factual error in Q2)** — **Fix bloom filter cardinality guidance.** Audit all `resources/` files mentioning bloom filters. Must clearly state bloom filters are for HIGH-CARDINALITY columns (UUIDs, user IDs, session IDs, trace IDs) where min/max stats are useless. For LOW-CARDINALITY columns, min/max + dictionary encoding already prune well and bloom filters add overhead without benefit. Add explicit "when to use / when NOT to use bloom filters" section. **This is critical — the answer would actively harm an engineer following it.**

2. **CRITICAL (PA gap in Q1)** — **Add window function content to `resources/`.** Worked SQL example for running total:
   ```sql
   SELECT
     day,
     tenant_id,
     amount,
     SUM(amount) OVER (
       PARTITION BY tenant_id
       ORDER BY day
       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
     ) AS running_total
   FROM fact_events
   WHERE day >= DATE '2026-01-01'
     AND tenant_id = ?
   ```
   Explain: (a) PARTITION BY for per-tenant isolation in multi-tenant SaaS, (b) ORDER BY for cumulative ordering, (c) frame clause `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` for running total semantics, (d) note that window function executes AFTER FROM/WHERE so partition pruning on the base scan still works, (e) when to switch to pre-aggregated rollup table (very large fact tables, per-tenant windowing memory pressure).

3. **HIGH (TA in Q2)** — **Reframe `write.distribution-mode` guidance.** State plainly: primarily Spark write hint; Trino writers follow their own distribution rules; on bucket transforms hash distribution can cause skew per Trino issue #12966. Do NOT call it "critical, prevents file explosion."

4. **HIGH (TA in Q2)** — **Surface Spark-vs-Trino write property split for `write.target-file-size-bytes`.** Trino 467/481 does NOT honor the table-level property (Trino issue #28250 open). Engineers must use Trino session property `target_max_file_size`. Spark ingestion DOES honor the table-level property. This is exactly the kind of cross-engine inconsistency the on-prem Iceberg 1.5.2 + Spark + Trino 467 + HMS production stack will encounter.

5. **MEDIUM (Comp in Q2)** — Add to `resources/` Iceberg table properties section: `format_version = 2` recommendation (needed for row-level deletes / position deletes), `location` property for explicit MinIO path control, `parquet_bloom_filter_columns` as the Trino-Iceberg-specific property name (vs Spark's `write.parquet.bloom-filter-enabled.column.<col>`).

6. **LOW CARRY-FORWARD (BC, iter376 systemic)** — Inline glossary at first mention for: Trino UI vocab (Queued, Scheduled, Physical Input, Blocked, Spilled, EXPLAIN ANALYZE, TYPE DISTRIBUTED), lakehouse tx vocab (atomic, idempotent, destructive operation, partial commit), federation vocab (CBO, BROADCAST, PARTITIONED, build/probe side, left-deep join tree). HyperLogLog gloss open since iter372. MinIO TCO open since iter374.

---

## ITER378 JUDGE PROBE TARGETS

1. **Window function durability re-probe**: "How do I compute a 7-day rolling average of events per tenant in Trino?" — tests action #2 from a different angle (sliding frame `RANGE BETWEEN INTERVAL '7' DAY PRECEDING AND CURRENT ROW` vs cumulative UNBOUNDED PRECEDING).

2. **Bloom filter cardinality re-probe**: "I have a `country_code` column with 200 distinct values used in WHERE clauses — should I add a bloom filter on it?" — tests action #1 (correct answer: NO, low cardinality means min/max + dictionary already prunes; bloom filter would add overhead).

3. **Iceberg table property production-stack-fit**: "I set `write.target-file-size-bytes = 512MB` on my Iceberg table via Spark DDL but Trino is still writing 200MB files. Why?" — tests action #4 (Trino does not honor table-level write.target-file-size-bytes; session property `target_max_file_size` needed).

4. **Distribution mode probe**: "Should I set `write.distribution-mode='hash'` on my bucket-partitioned Iceberg table?" — tests action #3 (Spark vs Trino split + skew caveat).

5. **Carry-forward iter376 EXPLAIN ANALYZE warning probe** (it actually executes — do not run casually on already-slow queries; use EXPLAIN TYPE DISTRIBUTED instead).

6. **Carry-forward iter370+ federation glossary** open since iter360.

---

## PATTERN OBSERVATIONS

- **Iter 377 ends 3.25 — FAIL**, breaking the iter370-376 stabilizing band (4.0-4.75). First sub-4.0 iteration since iter370 (3.98 FAIL).
- Two distinct failure modes this iteration:
  - **Q1 = content-coverage gap**: window function SQL absent from `resources/`. Responder honestly admitted the gap (correct behavior) but cannot answer the question. Teacher must close this content gap before next iteration.
  - **Q2 = factual errors**: bloom filter cardinality is BACKWARDS (low vs high), distribution-mode framing overstated, write.target-file-size-bytes framing misleading. The answer LOOKS authoritative (detailed checklist) which makes the errors harder to catch — exactly the kind of failure that hurts engineers in production.
- Q2 production-stack-fit was mixed: used appropriate `format='PARQUET'` and `day()` transforms for Iceberg 1.5.2 + Trino 467 + HMS, but missed the Trino-vs-Spark write property split — a known issue for this on-prem stack.
- BC was not the primary drag this iteration (TA and PA dominate). The systemic gloss-cascade gap from iter360+ remains open but is secondary to the content/factual errors this iteration.
- "Analytical query patterns on Iceberg+Trino" topic running avg 4.625/6 → 4.375/7 — still PASSED but the 2.875 single-question drop is the largest negative since iter300+. Topic durability concern if next probe on similar SQL pattern questions also fails.
- "Iceberg partition design for SaaS" topic 4.573/19 → 4.526/20 — small drag but still PASSED.
- Training loop remains in extended phase with `passed: true` overall, but iter377 shows the bar is fragile: content gaps and embedded factual errors in `resources/` surface as soon as the question hits an unprobed angle.

---

## SOURCES VERIFIED

- [Window functions — Trino 481 Documentation](https://trino.io/docs/current/functions/window.html)
- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html)
- [Trino issue #12966 — Iceberg partitioned writes with transform columns have poor distribution](https://github.com/trinodb/trino/issues/12966)
- [Spark Writes — Apache Iceberg](https://iceberg.apache.org/docs/latest/spark-writes/)
- [Iceberg Bloom Filters with Spark — Cazpian](https://cazpian.ai/blog/iceberg-bloom-filters-with-spark-configuration-validation-and-performance-guide)
- [Bloom Filter — Apache Parquet](https://parquet.apache.org/docs/file-format/bloomfilter/)
- [Trino issue #28250 — Support Iceberg table properties for write configuration](https://github.com/trinodb/trino/issues/28250)
- [Configuration — Apache Iceberg](https://iceberg.apache.org/docs/latest/configuration/)
