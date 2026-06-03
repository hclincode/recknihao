# Judge Feedback — Iter 424 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.6563 PASS** (Q1 4.1875 + Q2 4.8125 + Q3 4.8125 + Q4 4.8125) — **+0.125 step-UP from iter423 4.5313**, twenty-third consecutive overall PASS in extended phase. **ITER423 Q3 AGGREGATION-PUSHDOWN SELF-CONTRADICTION RESOLVED — NINTH consecutive recovery-within-one-iteration via structural-fix pattern.** **TWO NEW TOPICS MARKED PASSED — Oracle PL/SQL → dbt+Trino migration 4.78125/2 STRONG, complex SQL perf 4.71875/2 STRONG, both satisfy rubric ≥2-angles ≥3.5 rule.** **BUT NEW CONFIDENT-INACCURACY DATAPOINT in Q1 — fabricated Trino optimizer rule names + "partition filter" mislabel for a Postgres column.** **FEDERATION TOPIC REGRESSES 4.4933 → 4.4922 (-0.0011) — 24th consecutive iter below 4.5 threshold.**

---

## Headline

1. **ITER423 Q3 SELF-CONTRADICTION RESOLVED IN ONE ITERATION.** The iter424 r22 AGGREGATION-PUSHDOWN GUARDRAIL landed: Q1 opens with conditional rule "Whether aggregation pushes depends on the WHERE clause. status='paid' pushes. The aggregation ALSO pushes if Postgres can execute it after the WHERE filter" — no longer with the iter423 absolute "Trino DOES NOT push the GROUP BY and SUM/COUNT down" framing. EXPLAIN signature (Aggregate INSIDE remote fragment after RemoteExchange = success; Aggregate above TableScan = failure) is accurate. NINTH consecutive recovery-within-one-iteration following iter407→408, iter411→412, iter413→414, iter414→415, iter417→418, iter419→420, iter420→421, iter421→422.

2. **TWO NEW TOPICS MARKED PASSED — rubric rule satisfied (≥2 angles, all ≥3.5).**
   - **Oracle PL/SQL → dbt+Trino migration: 4.78125/2 STRONG PASS** (Q1 iter423 4.75 + Q2 iter424 4.8125). CONNECT BY → WITH RECURSIVE / SYS_CONNECT_BY_PATH → CONCAT / closure-table fallback / max_recursion_depth=10 default / experimental warning / Jinja loop unroll — all canonical and accurate.
   - **Improving complex SQL perf on Trino+dbt: 4.71875/2 STRONG PASS** (Q2 iter423 4.625 + Q3 iter424 4.8125). Star-join broadcast/partitioned tuning + EXPLAIN ANALYZE diagnostic workflow + join_distribution_type/join_max_broadcast_table_size session knobs + dbt partitioning+sorted_by+EXECUTE optimize — all canonical.

3. **NEW CONFIDENT-INACCURACY in Q1 — fabricated Trino optimizer rule names + "partition filter" mislabel.**
   - **"PushDownFilteredProjectionBelowProjection" and "PushDownLimitBelowProjection" are FABRICATED.** Verified via WebFetch on trino.io/docs/current/optimizer/pushdown.html and github.com/trinodb/trino/blob/master/docs/src/main/sphinx/optimizer/pushdown.md — the Trino pushdown documentation describes CATEGORIES (predicate pushdown, projection pushdown, dereference pushdown, aggregation pushdown, join pushdown, limit pushdown, top-N pushdown) NOT named rules. Real Trino optimizer rule names follow Push*IntoTableScan naming (PushFilterIntoTableScan, PushAggregationIntoTableScan, PushProjectionIntoTableScan, PushLimitIntoTableScan, PushTopNIntoTableScan). The "FilteredProjectionBelowProjection" compound naming pattern is not a real Trino rule.
   - **Calling `status='paid'` a "partition filter" is misleading terminology.** Postgres tables accessed via the PostgreSQL connector are NOT Iceberg-partitioned. `status` is just a regular VARCHAR column. "Partition filter" implies Iceberg/Hive partition pruning semantics. A SaaS engineer reading this could conclude they need to partition the Postgres table or that this filter benefits from partition pruning — neither is true. The correct term is "WHERE predicate" or "filter predicate".

4. **FEDERATION TOPIC REGRESSES — 4.4933 → 4.4922 (-0.0011), 24th consecutive iter below threshold.** Q1 4.1875 was the single federation datapoint this iter and is below topic avg 4.4933, pulling the topic DOWN. Now 0.0078 below 4.5 threshold vs 0.0067 last iter — FURTHER from crossing than iter423.

---

## Critical confirmations (explicit)

### (a) Q1 self-contradiction RESOLVED, but TWO NEW IMPRECISIONS

**YES — the iter423 Q3 self-contradiction is RESOLVED.** The responder no longer opens with "Trino DOES NOT push" as an absolute statement; instead leads with the conditional rule "Whether aggregation pushes depends on the WHERE clause. status='paid' pushes. The aggregation ALSO pushes if Postgres can execute it after the WHERE filter." This is the canonical correct framing per trino.io/docs/current/optimizer/pushdown.html "If an aggregate function is successfully pushed down to the connector, the explain plan does not show that Aggregate operator." The EXPLAIN signature (Aggregate INSIDE remote fragment after RemoteExchange / no separate Aggregate above TableScan = pushed) is accurate.

**BUT TWO NEW IMPRECISIONS:**

1. **"Partition filter" terminology mislabel** — `status='paid'` is a regular VARCHAR equality predicate on a Postgres column, not a partition filter. Postgres tables via the PostgreSQL connector are not Iceberg-partitioned. The term "partition filter" should be reserved for Iceberg/Hive partition column predicates that drive partition pruning. Mislabeling could confuse a SaaS engineer who associates "partition filter" with Iceberg semantics.

2. **Fabricated Trino optimizer rule names** — "PushDownFilteredProjectionBelowProjection" and "PushDownLimitBelowProjection" do NOT appear in Trino source code or documentation. VERIFIED via WebFetch on:
   - trino.io/docs/current/optimizer/pushdown.html — describes pushdown CATEGORIES, not named rules
   - github.com/trinodb/trino/blob/master/docs/src/main/sphinx/optimizer/pushdown.md — "no specific named optimizer rules are mentioned"
   - Real Trino rule names use Push*IntoTableScan naming (PushFilterIntoTableScan, PushAggregationIntoTableScan, etc.)

   This is a confident-inaccuracy datapoint: naming rules that don't exist is a fabrication risk that could mislead an engineer who tries to look them up or set session properties controlling them. TA penalty 3.5 for the dual imprecision; overall Q1 4.1875 PASS but flagged.

### (b) Two NEW topics — can either be marked PASSED?

**YES — BOTH ARE NOW MARKED PASSED.**

**Oracle PL/SQL → dbt+Trino migration: 4.78125/2 STRONG PASS.**
- Q1 iter423 4.75 (cursor-loop→set-based, DECODE→CASE, NVL→COALESCE, SYSDATE-1, TRUNC, sequences→dbt_utils.generate_surrogate_key, MERGE→incremental_strategy='merge', empty-string-vs-NULL gotcha)
- Q2 iter424 4.8125 (CONNECT BY → WITH RECURSIVE, SYS_CONNECT_BY_PATH → CONCAT path build, closure-table dbt pattern for deep trees, max_recursion_depth=10 default, experimental warning, Jinja loop unroll)
- **2-angle average: (4.75 + 4.8125) / 2 = 4.78125, both ≥3.5, rubric rule satisfied → PASSED.**

**Improving complex SQL perf on Trino+dbt: 4.71875/2 STRONG PASS.**
- Q2 iter423 4.625 (correlated subquery → LEFT JOIN+MAX+GROUP BY, date_trunc-partition reframing, CTE materialization, dbt levers, EXPLAIN diagnostic signatures)
- Q3 iter424 4.8125 (star-join broadcast/partitioned tuning, EXPLAIN ANALYZE physicalInputDataSize/RemoteExchange[REPLICATE]/dynamicFilterSplitsProcessed, SHOW STATS+ANALYZE, partition-prune-killer table, join_distribution_type='PARTITIONED' for OOM remediation, join_max_broadcast_table_size session prop)
- **2-angle average: (4.625 + 4.8125) / 2 = 4.71875, both ≥3.5, rubric rule satisfied → PASSED.**

### (c) Federation topic — does it CROSS 4.5?

**NO — federation topic REGRESSES 4.4933 → 4.4922 (-0.0011), 24th consecutive iter below threshold.**

Math:
- Prior: 4.4933 × 283 datapoints = 1271.5839 sum
- + Q1 4.1875 = +4.1875
- New sum: 1271.5839 + 4.1875 = 1275.7714
- New count: 284
- New average: 1275.7714 / 284 = **4.4922**

Topic is now 0.0078 below threshold vs 0.0067 last iter — REGRESSES from iter423's position. The 2-iter trending-UP streak (iter421 +0.0021, iter422 +0.0025) had already broken in iter423; iter424 continues the regression. Q1 4.1875 was the only federation datapoint, and 4.1875 < 4.4933 topic avg pulls the topic DOWN. Path to crossing now requires 2+ federation answers at 4.85+ per iter; the density wall at 284 datapoints means each pair must net ~+0.0025 to reach 4.5.

### (d) Any NEW confident-inaccuracy / engine-version-API confusion / self-contradiction in iter424?

**YES — ONE NEW confident-inaccuracy in Q1 with TWO sub-failures:**
1. Fabricated Trino optimizer rule names ("PushDownFilteredProjectionBelowProjection", "PushDownLimitBelowProjection") — verified not present in Trino source/docs
2. "Partition filter" terminology mislabel for a Postgres column predicate — implies Iceberg partition pruning semantics when none apply

Q2, Q3, Q4 are all clean of confident-inaccuracies. The myth-buster zero-confident-inaccuracy streak BREAKS at 0 iters again (had recovered to 2 iters at iter422, broke in iter423, briefly clean in iter424 fix-validation territory but new failure mode emerged in Q1 imprecision dimension).

---

## Per-question scoring

### Q1 — Aggregation pushdown re-probe (Trino federation / cross-source connectors)

**Scores: 3.5 / 4.25 / 4.5 / 4.5 — avg 4.1875 PASS**

What landed:
- Opens with conditional rule "Whether aggregation pushes depends on the WHERE clause" — **ITER423 SELF-CONTRADICTION RESOLVED**
- EXPLAIN signature: GOOD = Aggregate INSIDE remote fragment after RemoteExchange / no separate Aggregate above TableScan = Postgres did GROUP BY — CORRECT
- BAD = Aggregate above TableScan = Trino did it — CORRECT
- Correlated subquery in WHERE would not push — CORRECT

What broke:
- **"Partition filter" terminology for `status='paid'` mislabel** — Postgres tables aren't Iceberg-partitioned; status is just a regular column; use "WHERE predicate" or "filter predicate"
- **Fabricated optimizer rule names "PushDownFilteredProjectionBelowProjection" and "PushDownLimitBelowProjection"** — VERIFIED not in Trino source/docs; Trino pushdown docs describe CATEGORIES not named rules; real rules use Push*IntoTableScan naming

**Verdict:** PASS with new confident-inaccuracy datapoint. The iter423 self-contradiction recovery LANDED cleanly (good), but two new imprecisions were introduced that the teacher must structurally-fix in iter425.

### Q2 — CONNECT BY → WITH RECURSIVE (Oracle PL/SQL → dbt+Trino migration NEW TOPIC 2nd angle)

**Scores: 5.0 / 4.75 / 4.75 / 4.75 — avg 4.8125 STRONG PASS**

What landed:
- CONNECT BY doesn't exist in Trino — CORRECT
- WITH RECURSIVE standard ANSI SQL + experimental in Trino + max_recursion_depth default 10 — VERIFIED against trino.io/docs/current/sql/select.html
- Base case parent_id IS NULL + recursive UNION ALL JOIN on c.parent_id=t.category_id — CORRECT
- level+1 counter (Oracle LEVEL pseudo-col) — CORRECT
- SYS_CONNECT_BY_PATH → CONCAT(t.full_path,'/',c.name) — CORRECT (verified)
- max_recursion_depth>=8 via pre_hook for 8-level deep trees — CORRECT
- Experimental warning — CORRECT
- Closure-table dbt pattern (materialize ancestor/descendant/distance/path once, JOIN at read) with Jinja loop unroll as RECOMMENDED production pattern for deep trees — CORRECT
- Downstream models ref() the closure table — CORRECT

**Verdict:** STRONG PASS — comprehensive coverage with appropriate closure-table fallback recommendation.

### Q3 — Star-join broadcast/partition tuning (Improving complex SQL perf NEW TOPIC 2nd angle)

**Scores: 5.0 / 4.5 / 5.0 / 4.75 — avg 4.8125 STRONG PASS**

What landed:
- Root cause taxonomy: join order / missing stats / partition-predicate-wrapped — CORRECT
- EXPLAIN ANALYZE on 1-day slice with physicalInputDataSize, CorrelatedJoin, RemoteExchange[REPLICATE]=broadcast >100MB risk, dynamicFilterSplitsProcessed — CORRECT
- SHOW STATS then ANALYZE all tables — CORRECT
- Verify partition prune via constraint= on TableScan — CORRECT
- Partition-prune-killer table (CAST/arithmetic/non-literal RHS → naked literal or Jinja date) — CORRECT
- dbt config partitioning + sorted_by + EXECUTE optimize — CORRECT
- SET SESSION join_distribution_type='PARTITIONED' to avoid broadcast OOM — VERIFIED CORRECT
- join_max_broadcast_table_size='500MB' override — VERIFIED CORRECT (default 100MB)

**Verdict:** STRONG PASS — comprehensive diagnostic workflow + remediation knobs + session-prop names all accurate.

### Q4 — NOT IN vs NOT EXISTS NULL trap (SQL query best practices for OLAP)

**Scores: 5.0 / 4.75 / 4.75 / 4.75 — avg 4.8125 STRONG PASS**

What landed:
- Three-valued logic, one NULL in subquery → NOT IN evaluates UNKNOWN for all rows → zero rows — CORRECT
- NOT EXISTS rewrite NULL-safe — CORRECT
- SemiJoin FilterMode=ANTI in Trino plan — CORRECT
- LEFT JOIN (SELECT DISTINCT...) ... WHERE IS NULL with DISTINCT critical — CORRECT
- Diagnose by SELECT COUNT(*) WHERE col IS NULL — CORRECT
- dbt not_null + unique tests + WHERE IS NOT NULL guard — CORRECT

**Verdict:** STRONG PASS — clean canonical OLAP SQL best-practice answer with full dbt integration.

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.1875 | Trino federation (aggregation pushdown re-probe) | PASS — iter423 self-contradiction RESOLVED but new confident-inaccuracy (fabricated rule names + "partition filter" mislabel) |
| Q2 | 4.8125 | Oracle PL/SQL → dbt+Trino migration (NEW, 2nd angle) | STRONG PASS — CONNECT BY → WITH RECURSIVE / closure-table fallback comprehensive |
| Q3 | 4.8125 | Complex SQL perf on Trino+dbt (NEW, 2nd angle) | STRONG PASS — star-join broadcast/partitioned tuning + session knobs all accurate |
| Q4 | 4.8125 | SQL query best practices for OLAP (NOT IN NULL trap) | STRONG PASS — three-valued logic + NOT EXISTS rewrite + dbt tests canonical |

**Average 4.6563 PASS — twenty-third consecutive overall PASS, +0.125 step-UP from iter423 4.5313.**

**Headline outcomes:**
- ITER423 Q3 aggregation-pushdown SELF-CONTRADICTION RESOLVED — NINTH consecutive recovery-within-one-iteration via structural-fix pattern.
- TWO NEW TOPICS MARKED PASSED: Oracle PL/SQL → dbt+Trino migration 4.78125/2 STRONG, complex SQL perf 4.71875/2 STRONG — both satisfy rubric ≥2-angles-≥3.5 rule.
- NEW CONFIDENT-INACCURACY in Q1: fabricated optimizer rule names + "partition filter" mislabel.
- FEDERATION TOPIC REGRESSES 4.4933 → 4.4922 (-0.0011) — 24th consecutive iter below 4.5 threshold.

**Failure-mode count: 7 of prior 20 iterations** (unchanged; iter424 is a PASS but with a new confident-inaccuracy datapoint in Q1).

---

## Teacher actions next (iter 425)

1. **HIGH — Q1 FABRICATED-RULE-NAMES + PARTITION-FILTER-TERMINOLOGY GUARDRAIL.** Install in r22 aggregation-pushdown section following the proven iter418/420/421/422/424 structural-fix pattern:
   - **DO-NOT-WRITE table** banning fabricated Trino optimizer rule names like "PushDownFilteredProjectionBelowProjection", "PushDownLimitBelowProjection", or any compound rule name not actually in Trino source. Instead reference pushdown CATEGORIES (predicate pushdown, aggregation pushdown, limit pushdown, top-N pushdown) per trino.io/docs/current/optimizer/pushdown.html, OR use the real Push*IntoTableScan rule names if naming is essential.
   - **DO-NOT-WRITE callout** banning "partition filter" terminology for predicates on non-partitioned tables. Postgres tables via the PostgreSQL connector are NOT Iceberg-partitioned. Reserve "partition filter" / "partition pruning" exclusively for Iceberg/Hive partition column predicates. Predicates on Postgres columns are "WHERE predicates" or "filter predicates".
   - **Name iter424 Q1 failure modes explicitly** in the DO-NOT-WRITE callouts.
   - **Cite source URLs verbatim**: trino.io/docs/current/optimizer/pushdown.html + github.com/trinodb/trino/blob/master/docs/src/main/sphinx/optimizer/pushdown.md.

2. **LOW — Q2/Q3/Q4 content sustained STRONG.** No structural changes needed. The two new topics are now PASSED.

3. **LOW — Federation topic** at 4.4922 / 0.0078 below threshold; 24th consecutive iter below. Path to crossing requires 2+ federation answers at 4.85+ per iter; the density wall at 284 datapoints means each pair must net ~+0.0025 to reach 4.5.

4. **LOW — Carry-forward backlog**: HMS->Nessie write-freeze; Snapshot vs serializable phantom-row 3rd-angle; Window NULL 2nd-angle; Iceberg concurrency 4th-angle commit.retry exhaustion; OPA-override timeout; schema registry compat; JWT+OPA concurrency.

---

## Judge probe targets next (iter 425)

1. **HIGH — Aggregation-pushdown 3rd-angle RE-PROBE** (validate iter425 fabricated-rule-names + partition-filter-mislabel fix lands): "Does `SELECT product_id, MAX(price), MIN(price) FROM postgres.public.products WHERE category IN ('A','B','C') GROUP BY product_id` push aggregate? What EXPLAIN signature confirms it? Walk me through how the EXPLAIN should look without naming any specific Trino optimizer rule." (Forces canonical pushdown-category framing without inventing rule names; tests whether the responder still mislabels regular column predicates as "partition filters".)

2. **HIGH — Federation HAVING pushdown 2nd-angle**: "Does `HAVING SUM(amount) > 1000` after a GROUP BY push to Postgres? When does Trino keep HAVING in the engine vs send it to the source?" (Federation least-explored angle; needed to push topic toward 4.5 threshold.)

3. **MEDIUM — Federation OR-with-mixed-types** carry-forward: "Does `WHERE (user_id = 123 OR email = 'a@b.com')` push when one side is numeric and the other is VARCHAR?"

4. **MEDIUM — Federation 3-way cross-catalog JOIN execution location** carry-forward: "3-way join Postgres dim + Iceberg fact + Iceberg dim, which side dominates execution and how do I read EXPLAIN?"

5. **MEDIUM — Iceberg branches-vs-expire-then-drop-tag 4th-angle** for durability: "What happens to data files when I tag a snapshot, then run expire_snapshots, then drop the tag?"

6. **MEDIUM — Iceberg concurrency 4th-angle commit.retry exhaustion** carry-forward.

7. **MEDIUM — Oracle PL/SQL migration 3rd-angle** (now PASSED but explore): EXCEPTION/temp tables/analytic-functions QUALIFY rewrite.

8. **MEDIUM — Complex SQL perf 3rd-angle** (now PASSED but explore): nested-view chain refactor or incremental-lookback-window.

---

## Critical message to teacher for iter 425: fabricated-rule-names + partition-filter-mislabel recovery

The iter424 result is a **MIXED PASS** — the iter423 Q3 self-contradiction recovery LANDED cleanly (ninth consecutive structural-fix recovery), but Q1 introduced a NEW failure mode: confident-inaccuracy via fabricated Trino optimizer rule names and "partition filter" terminology mislabel for a non-partitioned Postgres column.

**The proven structural-fix recipe applies again** (leading canonical example + DO-NOT-WRITE callouts + disambiguation tables + cite source URLs verbatim + name the iter424 failure modes explicitly). The fix has been durable across all prior failure modes:
- iter418 ENGINE-CONFUSION GUARDRAIL
- iter420 API-CONFUSION GUARDRAIL
- iter421 TopN-CONFUSION GUARDRAIL
- iter422 LIKE-CONFUSION GUARDRAIL
- iter424 AGGREGATION-PUSHDOWN GUARDRAIL
- iter425 **FABRICATED-RULE-NAMES + PARTITION-FILTER-TERMINOLOGY GUARDRAIL** (this iteration's needed fix)

**Federation topic regressed 4.4933 → 4.4922 — now 0.0078 below threshold.** The 24-iter below-threshold streak continues. Path to crossing: 2+ federation answers at 4.85+ per iter for sustained iters. The density wall at 284 datapoints is unforgiving.

**Both NEW TOPICS are now MARKED PASSED** — Oracle PL/SQL → dbt+Trino migration 4.78125/2 STRONG, complex SQL perf 4.71875/2 STRONG. Iter425 can shift probe weight back to federation threshold-push + Iceberg least-explored angles + 3rd-angle exploration of the two newly-PASSED topics for durability checks.

**The pattern across iter402-424:**
- Bulletproofed content delivers 4.75+ on the targeted angle (Q2/Q3/Q4 all 4.8125 this iter validate this)
- Recovery within one iteration via structural fix is the durable strategy (ninth recovery in iter424; iter425 is the tenth opportunity)
- New failure modes appear in unexplored angles (Q1 fabricated rule names + partition-filter mislabel this iter)
- Federation topic remains 0.0050-0.0078 below the 4.5 threshold; the density wall is real at 280+ datapoints

**Probe in iter425 should validate the iter424 Q1 fabricated-rule-names + partition-filter-mislabel fix lands cleanly while also pushing 2+ federation answers above 4.85+ to advance toward the 4.5 threshold.**
