# Judge Feedback — Iter 616 (EXTENDED PHASE)

**Overall: 5.00 STRONG PASS** (margin +1.50 above 3.5 floor). Federation NOT probed — **4.49944/310 row UNCHANGED**.

**HEADLINE: iter615 FIX A ($.items-on-bare-array slip) is RESOLVED.** Q1 now LEADS with `json_array_length(tags)` directly — NO `$.path` — for the bare-array column, and correctly relegates the nested-under-a-key `json_extract` form to the secondary case. The r13 reconcile-in-place reorder + disambiguator LANDED and was applied correctly first-probe. All four questions are zero-defect.

---

## Q1 — Count items in a BARE JSON array column `tags` = '["vip","trial","beta"]' (FIX A re-probe) — 5/5/5/5 = 5.00 STRONG PASS

Answer: `SELECT customer_id, json_array_length(tags) AS tag_count FROM customers WHERE tags IS NOT NULL`. LED with the bare-array no-path form. Added the secondary note: "if nested under a key like `{"tags":[...]}` extract it first: `json_array_length(json_extract(tags, '$.tags'))`."

VERIFIED trino.io/docs/467/functions/json.html: `json_array_length(json) → bigint` — "Returns the array length of `json` (a string containing a JSON array)." The function **accepts a string/varchar containing a JSON array directly, takes NO path argument**. Example `json_array_length('[1, 2, 3]')` → 3. For the stated bare-array value `'["vip","trial","beta"]'`, `json_array_length(tags)` → 3 CORRECT.

The iter615 defect was leading with `json_array_length(json_extract(metadata,'$.items'))` on a BARE array — `$.items` on a bare array yields no member → NULL → `json_array_length(NULL)` = NULL = silent wrong answer. **That slip did NOT recur.** The responder led with the no-path form for the bare-array column and correctly positioned the `json_extract` chain ONLY as the nested-under-a-key fallback (where `{"tags":[...]}` genuinely needs `$.tags`). Disambiguation is exactly right. Zero defects.

**FIX A VERDICT: RESOLVED.**

## Q2 — Each order's amount + that customer's average on the same row, flag outliers (window AVG per row) — 5/5/5/5 = 5.00 STRONG PASS

Answer: `AVG(order_amount) OVER (PARTITION BY customer_id) AS customer_avg_amount` + `CASE WHEN order_amount > 2 * AVG(order_amount) OVER (PARTITION BY customer_id) THEN 1 ELSE 0 END AS is_outlier`.

VERIFIED trino.io/docs/467/functions/window.html: "All Aggregate functions can be used as window functions by adding the `OVER` clause. The aggregate function is computed for each row over the rows within the current row's window frame." So `AVG(...) OVER (PARTITION BY customer_id)` computes the per-customer average and **repeats it on every row of that customer** — exactly the "same row" requirement. Referencing the window AVG twice (once as an output column, once inside the CASE in the SELECT list) is valid Trino 467 — window functions are permitted in the SELECT list including inside a CASE expression. The outlier flag (amount > 2× per-customer avg → 1) is a sound, correct heuristic. Zero defects.

## Q3 — Unpack `pipeline_stages` into one row per stage WITH 1-based position (UNNEST WITH ORDINALITY) — 5/5/5/5 = 5.00 STRONG PASS

Answer: `... CROSS JOIN UNNEST(pipeline_stages) WITH ORDINALITY AS t(stage, stage_position)` — element named first, ordinality second.

VERIFIED trino.io/docs/467/sql/select.html: "`UNNEST` can optionally have a `WITH ORDINALITY` clause, in which case an additional ordinality column is added to the end." Docs example: `... UNNEST (ARRAY[2, 5], ARRAY[7, 8, 9]) WITH ORDINALITY AS t(a, b, rownumber)` — element columns (a, b) FIRST, ordinality (rownumber) LAST. The responder's `t(stage, stage_position)` therefore maps element→`stage`, ordinality→`stage_position` CORRECTLY (element first, ordinality last). The ordinality column is **1-based** (docs example shows rownumber 1, 2, 3), satisfying the 1-based-position requirement. UNNEST-ORDINALITY-ORDER check PASSES — no transposition. Zero defects.

## Q4 — Per region: active / churned / trial counts as three columns (conditional aggregation) — 5/5/5/5 = 5.00 STRONG PASS

Answer form A: `SUM(CASE WHEN status='active' THEN 1 ELSE 0 END) AS active_count, ...`; form B: `COUNT(*) FILTER (WHERE status='active') AS active_count, ...`. Both `GROUP BY region`.

VERIFIED trino.io/docs/467/functions/aggregate.html: FILTER — "The `FILTER` keyword can be used to remove rows from aggregation processing with a condition expressed using a `WHERE` clause." And the null-handling rule: "Except for `count()`, `count_if()`, `max_by()`, `min_by()` and `approx_distinct()`, all of these aggregate functions ignore null values and return null for no input rows" — `count()` is explicitly in the EXCEPTION list, so `COUNT(*) FILTER (WHERE ...)` returns **0 (not NULL)** when no rows match. `SUM(CASE ... THEN 1 ELSE 0 END)` also returns 0 for a region with no matching status (every row contributes 0). Both forms produce three correct per-region columns with 0 (not NULL) for empty buckets. Both valid Trino 467, semantically equivalent for this counting task. Zero defects.

---

## Overall computation

dim-avg method: Acc (5+5+5+5)/4 = 5.00, Comp 5.00, Clar 5.00, Act 5.00 → **(5.00+5.00+5.00+5.00)/4 = 5.00**
per-Q cross-check: (5.00+5.00+5.00+5.00)/4 = 5.00 — agree.

**GOVERNING LABEL = STRONG PASS** (overall ≥ 3.5; no per-Q gate applied; all four per-Q averages = 5.00).

## FIX A verdict (explicit)

**iter615 $.items-on-bare-array slip: RESOLVED.** Q1 now leads with `json_array_length(tags)` directly (no `$.path`); the `json_extract` chain appears only as the correctly-labeled nested-under-a-key secondary case. The r13 reconcile-in-place reorder + bare-vs-nested disambiguator ROUTED CLEANLY and was applied correctly first-probe. FIX A took.

## Slip diagnosis

No slips this iteration. All four answers are docs-verbatim zero-defect. No fabricated features/absences, no `::`-cast, no QUALIFY, no invalid-clause-placement, no off-by-one (Q3 ordinality 1-based + column-order correct), no type-mismatch, no wrong-function-choice, no JSONPATH-mismatch (Q1 bare-array path correctly omitted), no UNNEST-ordinality-order error.

## iter617 directive: NO-OP (durability)

All canonicals routed clean first-probe. Recommend a durability NO-OP for iter617. Optional only: a symmetric re-probe of Q1 with the column metadata being a NESTED object `{"tags":[...]}` to confirm the responder correctly SWITCHES to the `json_extract(tags,'$.tags')` form for that case (locking the other branch of the bare-vs-nested disambiguator).

**DO NOT**: touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter616); re-edit the r13 json_array_length bare-vs-nested disambiguator (VALIDATED this iter — durable); re-edit the window-AVG / UNNEST WITH ORDINALITY / conditional-aggregation canonicals (all clean); add `::`-casts (iter571 PIN); EXTRACT(EPOCH) (iter562 ban); QUALIFY; touch iter534–615 locks; bump training/state.json (already 616); git commit/push.

WebFetched/verified today: trino.io/docs/467/functions/json.html (`json_array_length(json) → bigint` "a string containing a JSON array", no path — Q1), trino.io/docs/467/functions/window.html ("All Aggregate functions can be used as window functions by adding the OVER clause" — Q2), trino.io/docs/467/sql/select.html (WITH ORDINALITY "an additional ordinality column is added to the end" + t(a,b,rownumber) 1-based — Q3), trino.io/docs/467/functions/aggregate.html (FILTER WHERE clause + count() in the exception list returning 0 not null — Q4).

**OVERALL: 5.00 STRONG PASS — iter615 $.items-on-bare-array slip RESOLVED (Q1 LEADS with json_array_length(tags), FIX A validated first-probe); Q2 window-AVG-per-row + outlier CASE, Q3 UNNEST WITH ORDINALITY (element-first/ordinality-last, 1-based), Q4 SUM(CASE) + COUNT FILTER (both 0 not NULL) all docs-verbatim zero-defect; iter617 = durability NO-OP; federation row stays 4.49944/310.**
