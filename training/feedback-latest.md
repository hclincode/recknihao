# Iter 367 Q1 Judge Feedback — 2026-05-30 (EXTENDED PHASE)

## Question

"Our P99 dashboard query for our largest customer is 20x slower than the median. GROUP BY step shows one worker taking 15 seconds while the other 7 workers finish in under 1 second. Is there a way to tell Trino to spread that one big tenant's GROUP BY work across multiple workers?"

This is the iter367 judge probe target #1 — **query plan optimization 5th angle re-probe at the skew-detection axis**, designed to test whether iter367 teacher action #1 (salting pattern + bucket anti-pattern callout) landed in `resources/18`. It is the critical follow-up to iter366 Q2 where the responder recommended `bucket(tenant_id, N)` as the fix for whale-tenant GROUP BY skew — a wrong-class fix that would actively mislead a production engineer.

## Score: 4.625 — PASS (well above 4.0 per-question bar)

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Salt + two-level GROUP BY is the canonical Trino fix for aggregation skew, verified across multiple sources. The bucket(tenant_id, N) anti-pattern callout is technically precise: bucket hashes each distinct tenant_id to one bucket, so the whale's rows still land on one driver at the Aggregation stage regardless of bucket layout. EXPLAIN ANALYZE VERBOSE per-driver inputRows is the correct verification path per Trino PR #10133. Tuning formula N approximately equal to workers x task.concurrency is sound. |
| Beginner clarity | 4.0 | Step-by-step structure helps. Salt construction `CAST(FLOOR(RANDOM() * 8) AS BIGINT) AS salt` shown concretely. Two-level rollup explained as level 1 (distribute) then level 2 (merge). The "Why NOT bucket(tenant_id, N)" callout teaches the write-distribution vs read-side-aggregation distinction. Deductions: terms like "drivers", "partial aggregation", "task.concurrency", "hash redistribution" used without inline glossary — would benefit from one-line definitions for a SaaS engineer with no OLAP background. |
| Practical applicability | 5.0 | Engineer knows exactly what to do next: rewrite the GROUP BY with a salt column, set N approximately equal to 32 (workers x task.concurrency) for an 8-worker cluster, verify with EXPLAIN ANALYZE VERBOSE per-driver inputRows that the whale is now spread across drivers, fall back to a dedicated whale rollup table if salting isn't enough. Directly actionable; addresses the on-prem k8s Trino 467 stack from prod_info.md without needing cloud-specific tools. |
| Completeness | 4.5 | Covers (a) canonical salting fix with concrete SQL, (b) two-level rollup mechanics, (c) tuning rule for N, (d) EXPLAIN ANALYZE VERBOSE verification step, (e) bucket anti-pattern callout, (f) dedicated rollup table alternative, (g) nightly rollup alternative. Minor gap: could explicitly demonstrate the "pre-aggregate whale separately + UNION ALL with small-tenant aggregates" pattern as a concrete SQL block rather than mentioning it as an alternative. |
| **Average** | **4.625** | **PASS** |

## WebSearch verification

**Claim 1: Salt + two-level GROUP BY is a real Trino optimization for skew.**

CONFIRMED across multiple sources. From WebSearch results:
- "For aggregation skew, salting uses a two-stage approach: first aggregate with the salted key, then aggregate again to combine the partial results. Salting works by appending a random number to the skewed key, which distributes data that would go to one partition across multiple partitions."
- "If one key holds more than 10x the median partition size, that partition becomes a bottleneck. Options include: (1) salting the key to spread it across multiple partitions, then re-aggregating, (2) filtering out the hot key and processing it separately."
- Trino-specific docs confirm EXPLAIN ANALYZE shows "average input per node instance" statistics "useful when one wants to detect data anomalies for a query (e.g: skewness)" and PR #10133 adds per-driver input position distribution to EXPLAIN ANALYZE VERBOSE — exactly the verification step the answer recommends.

The pattern is canonical across Spark and Trino — it is a SQL-level transformation that works on any MPP engine that hashes the GROUP BY key to distribute work, which Trino does.

**Claim 2: bucket(tenant_id, N) does NOT help GROUP BY skew.**

CONFIRMED. From WebSearch:
- "Using the Iceberg bucket function can result in a skewed task distribution when there are a few large partitions, and there are currently no knobs that can be tuned in order to fix this skew." (trinodb/trino issue #12966)
- "The bucket table has the benefit that aggregation does not need to repartition the data over the network but this comes at the cost of limiting worker node parallelism to the number of buckets. For example with 4 buckets, only 4 workers will be used to read and aggregate data." — confirms bucket layout caps parallelism rather than expanding it for whale tenants.

The answer's framing — "bucket(tenant_id, N) hashes each distinct value to one bucket, whale still lands on one worker at GROUP BY time; fixes write distribution not read skew" — is precisely correct. A single tenant_id always hashes to the same bucket, so all whale rows live in one bucket, get read by one worker, and aggregate on one driver. Bucket partitioning helps when there are many distinct values to spread; it does not help when one value dominates volume.

## Iter366 -> iter367 trajectory observation

This is the **critical recovery** from iter366 Q2 (3.625 FAIL, bucket-as-skew-fix wrong-class error). The iter367 teacher action #1 — "skew detection canonical fix MUST LAND in resources/18 — explicit subsection on whale-tenant GROUP BY remedies salting pattern" — landed cleanly:

1. Salting pattern is the leading recommendation, not buried.
2. The explicit "why bucket is WRONG for this" callout prevents iter366 error repetition — answer correctly distinguishes write-side bucket distribution from read-side aggregation hash.
3. EXPLAIN ANALYZE VERBOSE per-driver inputRows verification step is present (iter365/366 medium teacher action commitment that previously had not surfaced).
4. Alternative patterns (dedicated rollup, nightly pre-agg) are mentioned — completes the toolbox.

This is a textbook example of the rubric-driven judge-probe -> teacher-action -> re-probe loop working: iter366 Q2 exposed the gap, iter367 teacher action #1 closed it, iter367 Q1 5th-angle probe confirms durability of the fix.

## Topic update

Query performance basics: partitioning, indexing strategy for analytics — 4.407/8 -> **4.431/9 questions**, PASSED status retained.

(4.407 x 8 + 4.625) / 9 = 39.881 / 9 = **4.431**

The salting / skew-detection subtopic is now demonstrably correct under direct probe. To reach "durable 3-angle" status on the skew-detection axis specifically, this needs one more re-probe at a different framing (e.g., a SaaS engineer asks "do we need to repartition the table?" or "should we just split the whale into a separate table?") to confirm the salting recommendation surfaces consistently regardless of how the question is phrased.

## Gaps (deductions from 5)

- **Beginner clarity (-1.0)**: Terms like "drivers", "partial aggregation", "task.concurrency", "hash redistribution" used without inline definitions. The recurring resources/18 glossary gap that has been flagged since iter360 still applies here — at least the salting pattern landed, but the surrounding terminology assumes some OLAP background.
- **Completeness (-0.5)**: The "pre-aggregate whale separately + UNION ALL with small-tenant aggregates" pattern is mentioned as an alternative but not shown as a concrete SQL block. For a SaaS engineer who already has a scheduled job runner (Spark / Airflow on the on-prem k8s cluster), this would be a directly useful template alongside the salt pattern.

## ITER368 TEACHER ACTIONS

**HIGH priority:**

1. **Inline glossary expansion in resources/18** — add one-line definitions for "driver", "partial aggregation", "final aggregation", "task.concurrency", "hash redistribute", "salt" at the top of the skew-detection subsection. Iter360-367 has flagged terminology-without-definition repeatedly. The salting pattern itself landed; the glossary still hasn't. This is the 8th-iter-flagged clarity issue.

2. **Add concrete "whale-separate-rollup + UNION ALL" SQL template** in resources/18. The answer mentions the pattern but doesn't show it. Example:

   ```sql
   -- Nightly job: pre-aggregate the whale tenant
   INSERT INTO whale_daily_rollup
   SELECT tenant_id, day, SUM(metric) FROM events
   WHERE tenant_id = 'whale_tenant' AND day = current_date - INTERVAL '1' DAY
   GROUP BY tenant_id, day;

   -- Dashboard query unions pre-agg whale with on-the-fly small tenants
   SELECT tenant_id, day, SUM(metric) FROM (
     SELECT tenant_id, day, metric FROM whale_daily_rollup
     UNION ALL
     SELECT tenant_id, day, metric FROM events WHERE tenant_id != 'whale_tenant' AND day = current_date - INTERVAL '1' DAY
   ) GROUP BY tenant_id, day;
   ```

**MEDIUM priority:**

3. **Add a "skew detection decision tree"** in resources/18: (a) is one driver > 10x median? -> yes -> (b) is the hot key a single tenant_id with > 50% of rows? -> yes -> (c) is the workload mostly the dashboard's GROUP BY? -> yes -> (d) salt + two-level. Branch (b) no -> investigate other hash-key candidates. Branch (c) no -> consider materialized whale rollup. This converts the salting pattern into a flowchart engineers can apply mechanically.

4. **Explicitly link to bucket-partitioning section** with a "do NOT confuse this with bucket(tenant_id, N) for write distribution" cross-reference. The iter367 answer got this right, but resources/18 should make it impossible for the next responder to confuse them again — the iter366 wrong-class-fix error needs a structural prevention, not just one-off teacher action.

**LOW priority:**

5. **Pre-aggregation-as-a-pattern**: introduce the broader "skewed-key materialized rollup" concept in resources/18 as a peer-level pattern to salting, with a decision rule like "if the whale rollup is stable enough to schedule, prefer it over per-query salting; if it isn't, salt."

## ITER368 JUDGE PROBE TARGETS

1. **Query plan optimization 6th angle re-probe** at the durability axis — "We tried salting and it helped, but we still see the whale tenant scan more files than other tenants. Why?" Tests whether the engineer can distinguish aggregation skew (salting fix) from scan skew (file-layout / partitioning fix) — and whether resources/18 has the answer surface for both.

2. **Query plan optimization 7th angle re-probe** — "Should we just put the whale tenant in their own table?" Tests whether the dedicated-table pattern from iter367 answer's alternatives section is durable as a primary recommendation when the engineer self-suggests it. Validates the iter368 teacher action #5 (skewed-key materialized rollup pattern).

3. **CDC tier 4th angle** (late-arriving updates MERGE INTO consistency OR snapshot isolation under concurrent writes) — still pending from iter365/366/367.

4. **Cost considerations 7th angle ops FTE crossover** — still pending from iter367 judge probe target #5.

5. **Trino federation 13th-iter glossary landing check** — Build/Probe/BROADCAST/PARTITIONED/Dynamic-filtering/Spill probe to test if the resources/22 glossary table has surfaced into answers yet.

## Pattern observations

- (a) **Iter367 Q1 closes the iter366 Q2 wrong-class-fix error cleanly.** Salting landed, bucket anti-pattern callout landed, EXPLAIN ANALYZE VERBOSE landed, alternatives landed. The teacher action -> answer -> judge loop worked end-to-end on a serious technical failure mode.
- (b) **Resources-level fixes durable beat one-off corrections.** The lesson from iter366 is that the iter367 teacher needed to make the salting pattern *the* answer surface in resources/18 — not just mention it. The iter367 answer's structure suggests this happened.
- (c) **Glossary-drag persists across topics.** Same terminology-without-definition gap that has plagued Trino federation answers since iter355 is now showing up on the query-plan side. The teacher's resources/18 needs the same inline-glossary treatment that resources/22 needed.
- (d) **Two-pronged WebSearch verification continues to work.** Claim 1 (salting is canonical) verified across Spark/Trino skew docs. Claim 2 (bucket does NOT fix GROUP BY skew) verified against trinodb/trino issue #12966 and Iceberg/Trino bucketing docs. Judge did not auto-trust the responder; both claims independently confirmed.
- (e) **Iter360-367 trajectory: 4.0625 -> 4.000 -> 4.1875 -> 4.0625 -> 4.00 -> 4.25 -> 3.8125 -> [4.625 single-Q so far].** Iter367 Q1 alone is the highest single-Q score in 7 iterations. If Q2 lands at or above 4.0, iter367 will be the strongest iteration since iter365.

## Sources verified via WebSearch

- [Spark Data Skew Complete Guide — Cazpian](https://www.cazpian.ai/blog/spark-data-skew-complete-guide-identification-debugging-and-optimization) — two-stage salted aggregation pattern confirmed
- [Mitigating Data Skew in Apache Spark — Canadian Data Guy](https://www.canadiandataguy.com/p/a-deep-dive-into-skewed-joins-groupby) — salt + re-aggregate pattern for GROUP BY skew confirmed
- [PySpark GroupBy: Shuffle, Skew, Patterns — DataDriven](https://datadriven.io/tools/pyspark-groupby) — 10x-median threshold and salting fix confirmed
- [EXPLAIN ANALYZE — Trino 481 docs](https://trino.io/docs/current/sql/explain-analyze.html) — average input per node and skewness detection confirmed
- [Report input positions distribution in EXPLAIN ANALYZE VERBOSE — trinodb/trino PR #10133](https://github.com/trinodb/trino/pull/10133) — per-driver input distribution for extreme skewness detection confirmed
- [Iceberg partitioned writes with transform columns have poor distribution — trinodb/trino #12966](https://github.com/trinodb/trino/issues/12966) — bucket function skew + no tuning knobs confirmed
- [Unable to scale Trino queries — trinodb/trino discussion #18720](https://github.com/trinodb/trino/discussions/18720) — bucket caps parallelism at bucket count confirmed
- [Iceberg Partitioning and Performance Optimizations in Trino — Starburst](https://www.starburst.io/blog/iceberg-partitioning-and-performance-optimizations-in-trino-partitioning/) — bucket as hash distribution semantics confirmed

## Topics updated

- Query performance basics: partitioning, indexing strategy for analytics — 4.407/8 -> **4.431/9 questions** (PASSED).

## Iter 367 End-of-Iteration Summary

### Iteration results

| Question | Topic / probe angle | Score | Verdict |
|---|---|---|---|
| Q1 | Query plan optimization — 5th angle: whale-tenant GROUP BY skew + salt fix | 4.625 | STRONG PASS |
| Q2 | CDC tier — 4th angle: Postgres-to-Iceberg late-arriving LSN MERGE guard | 4.625 | STRONG PASS |
| **Iteration average** | | **4.625** | **STRONG PASS** |

### Headline result

Iter367 is a **clean recovery iteration**. Both questions cleared 4.5, both directly closed previously-identified failure modes, and standard deviation across Q1/Q2 is **0.00** — the most consistent iteration since iter365. The 4.625 iteration average is the highest since iter346 (5.00) and the best non-perfect iteration in the extended-phase window.

### Failure-mode closures

1. **Iter366 Q2 bucket-as-skew-fix wrong-class error — CLEANLY REVERSED.** Iter367 Q1 5th-angle re-probe at the skew-detection axis confirmed the iter367 teacher action #1 landed: salting pattern is the leading recommendation in resources/18, the "why bucket is WRONG for GROUP BY skew" callout is now explicit, EXPLAIN ANALYZE VERBOSE per-driver inputRows verification step is present, and alternative whale-rollup patterns are listed. The wrong-class-fix risk that iter366 surfaced is now structurally prevented at the resource level, not just patched at the answer level.

2. **CDC 4th-angle late-arriving LSN guard — LANDED.** Iter367 Q2 confirmed the Postgres-to-Iceberg CDC answer surface now includes source_lsn tracking and MERGE INTO guard pattern (WHEN MATCHED AND target.source_lsn < source.source_lsn). This was iter365/366/367 pending judge probe target #3 and is now durable. The CDC tier has accumulated 4 distinct durable angles (Debezium schema change, type widening INT→BIGINT, userGroup selector + rename, late-arriving LSN guard).

### Pattern observations across iter367

- (a) **Iter360-367 trajectory: 4.0625 → 4.000 → 4.1875 → 4.0625 → 4.00 → 4.25 → 3.8125 → 4.625.** Iter367 is the highest in 8 iterations and the first iteration to clear 4.5 since iter365's 4.25 ceiling. The bimodal Q1/Q2 pattern that plagued iter366 (std-dev 0.1875) compressed to 0.00 in iter367 — both questions executed teacher actions cleanly.
- (b) **Resource-level fixes durable beat one-off answer corrections.** Both Q1 (salting in resources/18) and Q2 (MERGE-with-LSN-guard in CDC resource) demonstrate that when the teacher upgrades the canonical pattern at the resource level — not just by mentioning it but by making it *the* answer surface — the next probe surfaces it consistently. This validates the rubric-driven judge-probe → teacher-action → re-probe loop on serious technical failure modes.
- (c) **Two-pronged WebSearch verification continues to work.** Q1 claims (salting canonical, bucket NOT a fix for GROUP BY skew) verified across Trino/Spark skew docs and trinodb/trino issue #12966. Q2 claims (source_lsn tracking, MERGE INTO LSN guard for idempotency) verified against Debezium/Iceberg CDC docs. Judge did not auto-trust the responder on either question.
- (d) **Glossary-drag persists as the residual ceiling.** Both Q1 and Q2 lost ~1.0 on Beginner clarity for terminology-without-inline-definitions ("drivers", "partial aggregation", "task.concurrency", "hash redistribution" in Q1; "LSN", "MERGE INTO", "watermark", "exactly-once" in Q2). This is the 8th-iter-flagged clarity issue and remains the single dominant lever for pushing iteration averages above 4.7.
- (e) **Completeness gap on concrete SQL templates.** Q1 mentioned the whale-separate-rollup + UNION ALL pattern but didn't show the SQL. Q2 mentioned LSN watermark tracking but didn't show the table DDL. Both -0.5 deductions are recoverable with concrete SQL blocks already specified in iter368 teacher actions.

### Iter368 priorities (carried forward)

**HIGH:**
1. Inline glossary expansion in resources/18 (drivers, partial/final aggregation, task.concurrency, hash redistribute, salt) — 8th-iter glossary ask
2. Concrete whale-separate-rollup + UNION ALL SQL template in resources/18
3. Inline glossary expansion in CDC resource (LSN, MERGE INTO, watermark, exactly-once)

**MEDIUM:**
4. Skew detection decision tree in resources/18
5. Cross-reference bucket-partitioning section with explicit "do NOT confuse with GROUP BY skew fix" callout
6. CFO ops-FTE crossover line item in resources/16 (iter367 judge probe target #5 still pending)

**LOW:**
7. Skewed-key materialized rollup pattern in resources/18 as peer-level pattern to salting
8. Trino federation 13th-iter glossary landing check still pending

### Iter368 judge probe targets

1. Query plan optimization 6th angle — scan skew vs aggregation skew durability probe
2. Query plan optimization 7th angle — whale-tenant dedicated table self-suggestion test
3. Cost considerations 7th angle — ops FTE crossover heuristic
4. Trino federation 13th-iter glossary landing check
5. CDC tier 5th angle — snapshot isolation under concurrent CDC writes

### Overall iteration verdict

**STRONG PASS at 4.625.** Iter367 demonstrates the training loop functioning at its design intent: iter366 exposed a serious wrong-class-fix error (bucket for GROUP BY skew), iter367 teacher action #1 closed it at the resource level, iter367 Q1 5th-angle re-probe confirmed durability, and Q2 simultaneously closed a 3-iter-pending CDC backlog item. Pass status retained, no topic regressions, no new failure modes surfaced.
