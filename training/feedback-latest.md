# Iter 702 — Judge Feedback

**Verdict**: PASS (overall 4.21875 ≥ 3.5; margin +0.72 above floor; two genuine defects flagged — one findable-but-missing gap in Q2, one CONFIRMED Trino 467 dialect parse-error in Q4)

**Overall average**: 4.21875 (sub-score sum 67.5/16; per-Q-avg cross-check (4.875+3.75+4.875+3.375)/4 = 4.21875 — agrees)

**Dim avgs**: Acc (5+3.5+5+2.5)/4 = 4.00 / Comp (4.5+3.5+4.5+3.5)/4 = 4.00 / Clar (5+4.5+5+4.5)/4 = 4.75 / Act (5+3.5+5+3)/4 = 4.125 → grand-avg (4.00+4.00+4.75+4.125)/4 = 4.21875 — agrees.

---

## Per-Question Scores

### Q1 — Anti-join (signups with no payment) — 4.875

- **Accuracy 5** / **Completeness 4.5** / **Clarity 5** / **Actionability 5**
- Form: `LEFT JOIN ... WHERE p.customer_id IS NULL` is the canonical Trino 467 anti-join idiom. NOT IN + NULL gotcha is correctly stated (any NULL in IN list → predicate yields UNKNOWN, never TRUE → no rows match). Verified against trino.io/docs/467/sql/select.html (LEFT JOIN grammar) and standard three-valued-logic semantics.
- **Minor completeness nit**: did not mention NOT EXISTS (the other safe form, NULL-immune) or EXCEPT (set-difference alternate). Both are equally correct and are mentioned in `resources/07` per the prompt's docs-correct list. Half-point completeness shave only — NOT a defect, NOT a FIX-A.

### Q2 — Revenue bucketing (small/medium/large) — 3.75

- **Accuracy 3.5** / **Completeness 3.5** / **Clarity 4.5** / **Actionability 3.5**
- CASE WHEN dialect is correct Trino 467. `width_bucket(x, bound1, bound2, n)` signature verified at trino.io/docs/467/functions/math.html.
- **PRIMARY DEFECT — outer GROUP BY granularity mismatch**: The user explicitly said "GROUP BY those labels directly" — i.e. they want a per-SEGMENT rollup (small=N customers / $X total, medium=M customers / $Y total, large=K customers / $Z total). The responder's outer query is:
  ```sql
  SELECT customer_id, CASE ... AS revenue_segment, COUNT(*) AS customer_count, SUM(total_revenue) AS segment_revenue
  FROM (per-customer-revenue subquery)
  GROUP BY customer_id, revenue_segment
  ```
  Because the outer GROUP BY includes `customer_id`, each output row is a single customer, so `COUNT(*)` is always 1 and `SUM(total_revenue)` is just that customer's own revenue. The labels `customer_count`/`segment_revenue` make those aggregates look like segment rollups but they are not.
- The fix is either (a) drop the aggregate columns and emit `SELECT customer_id, revenue_segment FROM (...)` for per-customer labels, OR (b) drop `customer_id` from outer GROUP BY: `SELECT revenue_segment, COUNT(*) AS customer_count, SUM(total_revenue) AS segment_revenue FROM (...) GROUP BY revenue_segment`.
- **FINDABLE-BUT-MISSING-GAP ASSESSMENT**: Likely findable in `resources/07` Pattern C4 (CASE/width_bucket section) — but the canonical there may show per-customer labeling only and not include a clean "CASE bucket then GROUP BY segment for rollup" sibling block. **Candidate FIX-A for iter703**: add a 2-block companion in `resources/07` Pattern C4: (Block A) per-customer-label `SELECT customer_id, CASE ... AS segment FROM ...`; (Block B) per-segment-rollup `SELECT segment, COUNT(*) AS customers_in_band, SUM(revenue) AS band_revenue FROM (label_subquery) GROUP BY segment ORDER BY segment_sort_key`. Make the decision-routing explicit at the top: "Do you want one row per customer (label them) or one row per band (count/sum customers in each)?" The responder's slip suggests the canonical didn't disambiguate granularity strongly enough, or had a Frankenstein form where both shapes were mashed.

### Q3 — MERGE INTO (upsert from Postgres) — 4.875

- **Accuracy 5** / **Completeness 4.5** / **Clarity 5** / **Actionability 5**
- Explicit-column MERGE form is valid Trino 467 syntax. VERIFIED against trino.io/docs/467/sql/merge.html grammar: `WHEN MATCHED THEN UPDATE SET (column = expression [, ...])` and `WHEN NOT MATCHED THEN INSERT [column_list] VALUES (expression, ...)`. **No star form in the grammar.**
- The responder's Spark-vs-Trino distinction is **ACCURATE**: Spark SQL supports `UPDATE SET *`/`INSERT *` star expansion; Trino 467 does NOT — explicit columns required. Verified via WebFetch of Trino 467 MERGE docs (no asterisk wildcard mentioned in grammar).
- The defanged WRONG form (`UPDATE SET *`) is shown first which is mildly risky for findability copy-attractiveness, but the responder explicitly transitions "from a Trino client you must list columns" and the canonical explicit form follows immediately — defang is intact. Per iter694 defang-style learning, the WRONG-form line could be inline-marked WRONG more aggressively for safety, but as composed here, the responder's narrative ordering plus the explicit-form follow-up adequately routes the reader to the right form. NOT a defect.
- **Minor completeness nit**: did not mention Iceberg MoR-default → MERGE writes delete+data files (merge-on-read merge). Not required by the question, half-point completeness shave only.

### Q4 — array_agg DISTINCT + ORDER BY pre-cast key (collect product IDs) — 3.375

- **Accuracy 2.5** / **Completeness 3.5** / **Clarity 4.5** / **Actionability 3**
- `array_agg(x ORDER BY y)` is valid (verified at trino.io/docs/467/functions/aggregate.html: "Ordering during aggregation"). `array_join(array, delimiter)` is valid. The CAST-to-varchar claim ("no implicit number→string coercion") is correct Trino 467 behavior.
- **CRITICAL DIALECT DEFECT — DISTINCT + ORDER BY-on-different-expr will raise an analysis error**: The exact form
  ```sql
  array_agg(DISTINCT CAST(product_id AS varchar) ORDER BY product_id)
  ```
  is **NOT valid** in Trino 467. The aggregate argument is `CAST(product_id AS varchar)` (a varchar expression). The ORDER BY key is `product_id` (an integer — the pre-cast value). When DISTINCT is combined with ORDER BY in an aggregate, Trino requires the ORDER BY expression to appear in the aggregate's argument list. This restriction yields the analyzer error:
  > "For aggregate function with DISTINCT, ORDER BY expressions must appear in arguments"
- **VERIFIED** via WebSearch + WebFetch of GitHub issue [trinodb/trino#20725](https://github.com/trinodb/trino/issues/20725) (opened 2024-02-15, still OPEN as enhancement). Documented behavior:
  - `array_agg(DISTINCT concat(value, value))` — works
  - `array_agg(concat(value, value) ORDER BY value)` — works
  - `array_agg(DISTINCT concat(value, value) ORDER BY value)` — FAILS with the above error
- The responder's form is identical-shape: DISTINCT on a CAST/derived expression, ORDER BY on the pre-cast underlying column. **Will raise in Trino 467 at analyze time.**
- **CORRECT FORMS**:
  ```sql
  -- match ORDER BY to the aggregate argument expression:
  array_agg(DISTINCT CAST(product_id AS varchar) ORDER BY CAST(product_id AS varchar))

  -- OR drop the CAST and order on the integer (if downstream tolerates int array):
  array_agg(DISTINCT product_id ORDER BY product_id)

  -- OR cast in an inner subquery and aggregate over the cast value:
  SELECT customer_id, array_agg(DISTINCT pid_str ORDER BY pid_str)
  FROM (SELECT customer_id, CAST(product_id AS varchar) AS pid_str FROM iceberg.analytics.purchases)
  GROUP BY customer_id;
  ```
- **FINDABLE-BUT-MISSING-GAP ASSESSMENT**: Likely findable in `resources/07` §1a.2A array_agg canonical — but the canonical evidently shows the exact form the responder reproduced (DISTINCT + CAST + ORDER BY pre-cast key). **HIGH-PRIORITY FIX-A for iter703**: in `resources/07` §1a.2A array_agg canonical, rewrite the DISTINCT+ORDER BY example to use `ORDER BY CAST(product_id AS varchar)` (matching the aggregate argument), and add a one-line inoculation note: "When DISTINCT is present in an aggregate, ORDER BY expression MUST appear in the aggregate's argument list — otherwise Trino raises 'For aggregate function with DISTINCT, ORDER BY expressions must appear in arguments'. If you need to cast for output formatting, push the cast into a subquery OR match ORDER BY exactly to the aggregate-arg expression." Add a defanged DO-NOT-WRITE row with the wrong-shape inline-marked WRONG per iter694 defang lesson. Cross-link from r23 string/varchar section keyword anchor on "comma-separated" / "collect into one column" so the keyword route lands on the fixed canonical.

---

## FIX-A Candidates for iter703

**Two genuine defects surfaced this iter; ONE high-priority dialect parse-error fix:**

1. **HIGH-PRIORITY FIX-A (Q4 dialect defect)**: `resources/07` §1a.2A array_agg canonical — the DISTINCT+ORDER BY-on-pre-cast-key form will raise an analysis error in Trino 467. Rewrite the canonical to `ORDER BY CAST(product_id AS varchar)` (match aggregate-arg expression), add a one-line inoculation explaining the DISTINCT+ORDER BY argument-list restriction, and add a defanged DO-NOT-WRITE row with the wrong-shape inline-marked WRONG. Verified via [trinodb/trino#20725](https://github.com/trinodb/trino/issues/20725) — restriction still present.

2. **MEDIUM-PRIORITY FIX-A (Q2 findable-but-missing companion block)**: `resources/07` Pattern C4 (CASE/width_bucket bucketing) — add a clean "CASE-label-then-GROUP-BY-segment-for-rollup" companion block alongside the per-customer-label block, and prepend a "Do you want per-customer labels OR a per-segment rollup?" decision routing line at the top of the Pattern C4 header. Responder's outer-GROUP-BY-includes-customer-id slip suggests the canonical didn't disambiguate granularity strongly enough.

**HOLD INVENTORY** (no regression observed this iter):
- iter698 MoM card r07:2486-2587 — not probed this iter, 4-iter durability stamped at iter701, HOLD.
- iter697 approx_percentile mirror r07:589 + r23:2463-2464 — not probed this iter, 5-iter durability stamped at iter701, HOLD.
- iter695 QUALIFY canonical r23:744 + r23:1014-1071 — not probed this iter, 7-iter durability stamped at iter701, HOLD.
- r22 federation guardrails (HARD LOCK, 58-iter ZERO probe streak; topic avg 4.49944 vs 4.5 thin) — not probed this iter, HOLD.
- All iter534-701 locks (~260 across 17 resource files) — PRESERVED.

**iter703 directive**: Apply the HIGH-PRIORITY Q4 array_agg fix (dialect parse-error blocker — the responder reproduced a form that will actually error in Trino 467). Apply the MEDIUM-PRIORITY Q2 Pattern C4 companion-block fix. Do NOT touch held inoculations or r22 federation lock.

---

## Topic Avg Updates (rubric.md)

- Common analytical query patterns (Q2 CASE bucketing per-customer vs per-segment granularity mismatch −0.30 on completeness; Q4 array_agg DISTINCT+ORDER BY dialect parse-error −0.40 on accuracy)
- SQL query best practices for OLAP (Q1 anti-join LEFT JOIN+WHERE IS NULL + NOT IN+NULL gotcha canonical durability +0.30; Q3 MERGE INTO explicit-column Trino-vs-Spark-star distinction canonical docs-perfect +0.40)
- Postgres→Iceberg ingest / dbt-incremental upsert (Q3 MERGE INTO durability +0.30)
