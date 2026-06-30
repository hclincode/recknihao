# Judge Feedback — Iteration 1296

**Overall: 4.578 — PASS. Pure breadth round. Q2 (dynamic-filter + bare-ANALYZE + RemoteExchange[REPLICATE]/[REPARTITION] + SET SESSION join_distribution_type='BROADCAST') 4.8125 STRONG; Q4 (NVL-chain → COALESCE + type-strict CAST + Oracle-vs-Trino empty-string + NULLIF wrap) 4.75 STRONG; Q1 main UNNEST+COUNT(DISTINCT)+MAX(CASE) CORRECT 4.375 with a per-instance broken-secondary-alternative slip (the secondary `SELECT customer_id, CONTAINS(arr,'x') FROM events ... GROUP BY customer_id` is malformed — CONTAINS is per-row scalar, neither grouped nor aggregated, requires `bool_or(CONTAINS(...))` or no GROUP BY; ~10th instance of this responder padding pattern); Q3 expression_is_true + custom generic test BOTH CORRECT 4.375 with a minor completeness gap (omitted the textbook singular-test option — plain .sql in tests/ returning failing rows, no {% test %} wrapper, no dbt-utils dep — which is the idiomatic answer for a ONE-OFF model-specific rule). No FAILs. No FIX-A — both peripheral slips are per-instance behavior, not resource defects. Continuous PASS-loop holds (iter1295 4.4375 → iter1296 4.578, +0.14). All required topics REMAIN PASSED.**

| Q | Score | Acc | Clar | Prac | Compl | Topic | Result |
|---|---|---|---|---|---|---|---|
| 1 | 4.375 | 4.0 | 4.5 | 4.5 | 4.5 | Analytical query patterns on Iceberg+Trino | PASS (broken-secondary slip) |
| 2 | 4.8125 | 5.0 | 4.5 | 5.0 | 4.75 | Query performance basics | STRONG PASS |
| 3 | 4.375 | 4.75 | 4.5 | 4.25 | 4.0 | Improving complex SQL performance on Trino with dbt | PASS (singular-test omitted) |
| 4 | 4.75 | 5.0 | 4.5 | 4.75 | 4.75 | Oracle PL/SQL → dbt + Trino SQL migration | STRONG PASS |

---

## Q1 (array column UNNEST + DISTINCT count + 'api_access' flag) — 4.375 PASS

**Main query CORRECT.** `SELECT customer_id, COUNT(DISTINCT feature), MAX(CASE WHEN feature='api_access' THEN 1 ELSE 0 END) FROM events CROSS JOIN UNNEST(enabled_features) AS t(feature) WHERE DATE_TRUNC('month',event_ts)=DATE_TRUNC('month',CURRENT_DATE) GROUP BY customer_id` — canonical Trino 467 form. `COUNT(DISTINCT feature)` correctly dedupes both across rows AND within each row's array (UNNEST makes each array element a separate row, DISTINCT collapses repeats per customer). `MAX(CASE WHEN ... 1 ELSE 0 END)` correctly produces a 0/1 flag per customer. `CROSS JOIN UNNEST` vs `LEFT JOIN UNNEST(...) ON TRUE` distinction (latter preserves rows with empty/NULL arrays as a single NULL-extended row) is accurate. `contains(array(T), T) -> boolean` is a real Trino 467 function (verified [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html)).

**Secondary "membership without unnest" query is MALFORMED — broken-secondary-alternative slip.** Responder wrote `SELECT customer_id, CONTAINS(enabled_features,'api_access') FROM events ... GROUP BY customer_id`. `CONTAINS(enabled_features,'api_access')` is a per-row scalar expression that is neither in the GROUP BY clause nor wrapped in an aggregate — Trino's analyzer rejects with the standard "must appear in GROUP BY clause or be used in an aggregation expression" error. Correct rewrites: (a) `bool_or(CONTAINS(enabled_features,'api_access')) AS has_api_access ... GROUP BY customer_id`, or (b) drop GROUP BY entirely.

**Classification: per-instance broken-secondary-alternative slip, NO FIX-A.** Matches pinned `feedback_responder_broken_secondary_alternative.md` family — the LEAD is correct and copy-pasteable, an appended "for completeness" alternative is broken. ~10th instance (window-in-GROUP-BY / PERCENTILE_CONT / price-suffix menu / nested-aggregate max_by / TO_CHAR-wrong-codes / ORDER-BY-ungrouped / TABLESAMPLE-after-WHERE / regexp_extract-comma / FIRST_VALUE-no-DISTINCT / CONTAINS+GROUP-BY-no-bool_or). NO single resource fix exists for responder-padding behavior. Engineer who copies the MAIN query gets correct output; engineer who copies the SECONDARY hits an analyzer error and recovers in session.

No imported-prior, no fabrication, no over-warning, no resource-source defect (lead is sourced cleanly from r07/r28 UNNEST canonicals).

## Q2 (join filter pushdown, 50K filtered to ~5% but events still full-scan) — 4.8125 STRONG PASS

Two-pronged answer covers the actual Trino mechanism:

1. **Dynamic filtering diagnostic.** DF takes join-key values from the small build side after the dim filter resolves, sends a probe-side predicate to the large TableScan before reading row-groups. Verify via `EXPLAIN ANALYZE VERBOSE` and ctrl-F `dynamicFilters=` on the events TableScan (annotation present + nonzero `dynamicFilterSplitsProcessed` = DF fired; absent / 0 = DF didn't fire). Matches pinned iter1239/iter1256 canonical, verified verbatim at [trino.io/docs/467/admin/dynamic-filtering.html](https://trino.io/docs/467/admin/dynamic-filtering.html).

2. **Join distribution lever.** `SET SESSION join_distribution_type='BROADCAST'` (no `/*+ */` hint syntax in Trino — silently ignored as block comment, verified [trinodb/trino#9498](https://github.com/trinodb/trino/issues/9498)). EXPLAIN distinguishes via `RemoteExchange[REPLICATE]` (broadcast) vs `RemoteExchange[REPARTITION]` (partitioned). Permanent fix: `ANALYZE iceberg.analytics.events` and `ANALYZE iceberg.analytics.customers` (bare `ANALYZE`, no `TABLE` keyword — verified [trino.io/docs/467/sql/analyze.html](https://trino.io/docs/467/sql/analyze.html) grammar `ANALYZE table_name [WITH(...)]`). Fresh row counts + NDVs let CBO pick BROADCAST automatically for the 50K-row dim.

Consistent with iter1203/iter1238/iter1295 canonical answers. No imported-prior, no fabrication, no over-warning.

**Minor recall ceilings (not load-bearing):** `iceberg.dynamic-filtering.wait-timeout` (default 1s) not surfaced; `join_distribution_type` values list `AUTOMATIC|BROADCAST|PARTITIONED` not enumerated. Engineer reaches the fix without these.

## Q3 (custom business rule dbt test: net_revenue >= 0 for enterprise) — 4.375 PASS

Two paths offered, both technically correct:

1. **`dbt_utils.expression_is_true`** with `expression: "CASE WHEN plan_tier='enterprise' THEN net_revenue >= 0 ELSE TRUE END"` in `schema.yml` under `data_tests`. The CASE-guard pattern is standard for "rule applies only to a subset". Severity (`error`/`warn`) and `store_failures: true` correctly described. Test compiles to `SELECT * FROM <model> WHERE NOT(<expr>)` — any non-matching row = failure. Picked up by `dbt build` / `dbt test --select`. Verified [docs.getdbt.com/reference/resource-properties/data-tests](https://docs.getdbt.com/reference/resource-properties/data-tests).

2. **Custom generic test** in `tests/generic/enterprise_revenue_nonnegative.sql` with the `{% test %}...{% endtest %}` wrapper, then referenced in `schema.yml`. Generic tests in `tests/generic/` are auto-discovered. Verified [docs.getdbt.com/best-practices/writing-custom-generic-tests](https://docs.getdbt.com/best-practices/writing-custom-generic-tests).

**Completeness gap: SINGULAR test omitted.** The engineer asked "where do I put this kind of test" for a ONE-OFF, single-model business rule. The IDIOMATIC dbt answer for one-off model-specific rules is a **singular test** — a plain `.sql` file in `tests/` (NOT `tests/generic/`) returning failing rows, with NO `{% test %}` wrapper:

```sql
-- tests/daily_revenue_enterprise_nonnegative.sql
SELECT *
FROM {{ ref('daily_revenue_summary') }}
WHERE plan_tier = 'enterprise' AND net_revenue < 0
```

dbt auto-discovers via `dbt test`; failing rows = test fail. Verified at [docs.getdbt.com/docs/build/data-tests](https://docs.getdbt.com/docs/build/data-tests). Both responder options WORK, but the generic-test wrapper is over-engineered for a rule that only applies to one model, and `expression_is_true` requires the dbt-utils package (engineer may not have it). A singular test needs nothing extra.

Classification: minor completeness gap, NOT a defect. Given answers are correct; engineer reaches a passing test; may over-engineer the implementation. **NO FIX-A on first occurrence; SOFT WATCH for re-probe.** Per pinned `feedback_new_card_over_attracts_adjacent.md` — adding a singular-test card near the existing dbt-test keyword zone risks over-attracting one-off questions away from the generic form before establishing the recurrence pattern.

No imported-prior, no fabrication, no over-warning. dbt_utils.expression_is_true verified to exist + CASE-guard pattern is standard.

## Q4 (Oracle NVL chain → Trino COALESCE + edge cases) — 4.75 STRONG PASS

`COALESCE(arg1, ..., argN)` correctly identified as the flat n-ary first-non-NULL equivalent of any nested NVL chain (Oracle NVL is strictly 2-arg → nested; Trino COALESCE is unlimited args → flat). Migration mapping `NVL(NVL(NVL(col_a,col_b),col_c),'unknown')` → `COALESCE(col_a, col_b, col_c, 'unknown')` is exact.

**Edge cases correctly surfaced:**
1. **Type strictness** — Trino errors at analyze on mixed types (DATE/VARCHAR/BIGINT in one COALESCE); CAST to common type. Oracle's implicit conversion is more permissive. Correct.
2. **Empty string vs NULL** — Oracle `''=NULL` so `NVL(col,'default')` returns `'default'` if col is `''`; Trino `''` is a non-NULL empty string so `COALESCE(col,'default')` returns `''` not `'default'`. Wrap with `NULLIF(col,'')` if Oracle empty-is-NULL semantics matter. Verified accurate.
3. NULL propagation behaves same in both for first-non-NULL case.

Consistent with iter1295/iter1294/iter1289 Oracle→Trino canonicals (r27 dialect-rewrite). No imported-prior, no fabrication, no over-warning, no broken secondary.

**Minor shave:** Could note COALESCE short-circuits left-to-right (matches NVL chain); could surface that Oracle's `NVL2(expr, when_not_null, when_null)` has no direct Trino equivalent (`CASE WHEN expr IS NOT NULL THEN ... ELSE ... END`).

---

## Explicit answers to asked checkpoints

1. **Q1 secondary CONTAINS+GROUP BY malformed → broken-secondary-alternative slip, NO FIX-A.** Confirmed per-instance responder padding (10th+ instance of this exact pattern). Lead is correct; alternative parse-broken because `CONTAINS(enabled_features,'api_access')` is per-row scalar neither grouped nor aggregated under `GROUP BY customer_id`. Correct rewrites: `bool_or(CONTAINS(...))` aggregation, or drop GROUP BY. Pinned `feedback_responder_broken_secondary_alternative.md` family rule — no resource fix exists for responder padding, accept per-instance ding, don't churn.

2. **Q2/Q4 accuracy: SOLID.** Q2 dynamic-filter + RemoteExchange + bare-ANALYZE + join_distribution_type all verified against trino.io/docs/467. Q4 COALESCE n-ary + type-strict CAST + empty-string Oracle-vs-Trino + NULLIF wrap all accurate.

3. **Q3 expression_is_true + custom generic test BOTH CORRECT; omitting singular test is a real minor completeness gap.** Textbook dbt answer for one-off model-specific rule is a SINGULAR test (plain `.sql` in `tests/`, returns failing rows, no `{% test %}` wrapper, no dbt-utils dep). Verified [docs.getdbt.com/docs/build/data-tests](https://docs.getdbt.com/docs/build/data-tests). Both responder options work; engineer arrives at passing test; this is clarity-of-recommendation, not a defect. NO FIX-A on first occurrence; SOFT WATCH for re-probe.

4. **New watches / FIX-A this iter: NONE BEYOND PER-INSTANCE.**
   - **NEW SOFT WATCH `iter1296-Q1 CONTAINS+GROUP-BY-no-bool_or secondary slip`**: another instance in broken-secondary-alternative family; re-probe under array-membership-aggregation framings 4-8 iters; no FIX-A unless a NEW pattern emerges (this is established responder padding).
   - **NEW SOFT WATCH `iter1296-Q3 singular-test-omitted-when-question-is-one-off-rule`**: re-probe under "where do I put a one-off model-specific test" framings 4-8 iters; if recurs with both occurrences omitting the singular-test option, escalate to LIGHT FIX-A (additive card in r28 dbt-tests section: "ONE-OFF MODEL RULE → singular test in tests/ no wrapper" with generic + expression_is_true forms as secondary).
   - **CARRY forward:** iter1295-Q2 FIRST_VALUE-priming-overrides-min_by/max_by (re-probe 4-8); iter1294-Q4 ROWNUM-per-group; iter1290-Q3 small-files-routing; iter1289-Q2 position-delete-Spark-vs-Trino; iter1289-Q4 LPAD-RPAD-false-divergence.
   - **All required topics REMAIN PASSED.**

### Topic routing for rubric

- Q1 → "Analytical query patterns on Iceberg+Trino" (row 122) — UNNEST + COUNT(DISTINCT) + aggregation
- Q2 → "Query performance basics: partitioning, indexing strategy for analytics" (row 49) — dynamic filtering + join distribution + EXPLAIN diagnostic family (precedent iter1203/iter1239/iter1256/iter1258/iter1273/iter1276/iter1278)
- Q3 → "Improving complex SQL performance on Trino with dbt" (row 711) — dbt-test infra (precedent iter1191/iter1233)
- Q4 → "Oracle PL/SQL → dbt + Trino SQL migration" (row 526) — Oracle function rewrite
