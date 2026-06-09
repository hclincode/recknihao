# Judge Feedback — Iter 864 (EXTENDED PHASE)

**Overall: 4.66 STRONG PASS** (per-Q 5.00 / 4.875 / 4.875 / 4.875 = 19.625/4 = 4.65625; margin +1.16 over 3.5 threshold; overall average governs, no per-Q veto). All 4 forms verified clean against trino.io/docs/467 + WebFetch on 2026-06-10. **iter865 recommendation: DEFAULT NO-OP — teacher ZERO edits.**

Theme this iteration: core SQL-shape patterns for SaaS engineers (top-1-per-group, array explode, CASE bucketing, array merge). No federation probe. All dialect facts held.

---

## Q1 — Latest row per user without a self-join (millions of events) — **5.00**

Responder: `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC) AS rn` in a subquery, outer `WHERE rn=1` (single pass; correctly noted window functions cannot go in WHERE directly — must be subquery/CTE filtered in outer query). Plus one-pass aggregate alternative `max_by(order_id, order_date)` / `MAX(order_date)` GROUP BY customer_id for the few-columns case.

VERIFIED:
- window.html: `row_number()` is a ranking window function ("unique, sequential number ... according to the ordering of rows within the window partition"). Window functions run after HAVING, before ORDER BY → cannot be referenced in WHERE; subquery/CTE + outer filter is the canonical top-1-per-group pattern. CORRECT.
- aggregate.html: `max_by(x, y)` "Returns the value of x associated with the maximum value of y over all input values." So `max_by(order_id, order_date)` returns the order_id at the latest order_date. CORRECT.

Sub-scores: Accuracy 5, Completeness 5, Clarity 5, Actionability 5. Both forms correct; the two-path framing (ROW_NUMBER for full row vs max_by for a few columns) is exactly the right engineer guidance.

## Q2 — Explode array column into one row per tag, then count — **4.875**

Responder: `CROSS JOIN UNNEST(e.tags) AS t(tag)` + `GROUP BY tag COUNT(*)`. Nuances: (1) CROSS JOIN UNNEST drops rows whose array is NULL/empty (inner-join semantics) — use `LEFT JOIN UNNEST(...) ON TRUE` to keep them with tag=NULL; (2) if tags is a varchar JSON string not native ARRAY, parse first with `CAST(json_parse(tags) AS ARRAY(VARCHAR))`.

VERIFIED:
- sql/select.html: "UNNEST returns zero entries when the array/map is empty" and "... when the array/map is null" → CROSS JOIN UNNEST drop nuance CORRECT. `LEFT JOIN UNNEST(...) ON TRUE` supported ("the only condition supported by the current implementation is ON TRUE") → CORRECT.
- json.html: `json_parse(string)` returns deserialized JSON value; CAST to ARRAY(VARCHAR) supported when element types are uniform strings. CORRECT for the homogeneous-string-tags case.

Sub-scores: Accuracy 5, Completeness 5, Clarity 4.5, Actionability 5. The empty/NULL-array-drop is a frequently-missed correctness trap and the responder volunteered it unprompted — excellent. Minor clarity ding only: for mixed-type JSON arrays the direct ARRAY(VARCHAR) cast can fail (needs ARRAY(JSON) intermediate), unmentioned — edge nuance, not an error for the asked case.

## Q3 — Label numeric score 0-100 into low/mid/high by fixed cutoffs (not nested IF) — **4.875**

Responder: `CASE WHEN score<=50 THEN 'low' WHEN score<=80 THEN 'mid' ELSE 'high' END`; GROUP BY must repeat the CASE expression or use a subquery; IF for 2 outcomes, CASE for 3+.

VERIFIED:
- conditional.html: searched CASE "evaluates each boolean condition from left to right until one is true and returns the matching result" → first-match-wins, so `<=50` before `<=80` ordering is CORRECT (a score of 40 matches the first branch, never reaching `<=80`). IF(cond, true, false) confirmed; IF-for-2/CASE-for-3+ guidance CORRECT.
- sql/select.html: GROUP BY supports input column names, ordinal positions, and expressions — but NOT output aliases. So "repeat the CASE expression (or subquery)" is CORRECT and SAFE.

Sub-scores: Accuracy 5, Completeness 4.5, Clarity 5, Actionability 5. The CASE-ordering logic is right and the GROUP-BY advice is safe. Minor completeness nit only: Trino also allows `GROUP BY <ordinal>` (e.g. `GROUP BY 2`) as a shortcut to avoid repeating the CASE — the responder omitted this valid alternative. Omission, not an error; the advice given is fully correct.

## Q4 — Merge two array columns into one per user — **4.875**

Responder: `concat(trial_features, paid_features)` OR `trial_features || paid_features`; `array_distinct(concat(...))` to dedupe; advised against UNNEST + re-aggregate unless a GROUP BY is required.

VERIFIED on array.html:
- `concat(array1, ..., arrayN) → array` — concatenates arrays, "same functionality as the SQL-standard concatenation operator (||)". CORRECT.
- `||` operator joins arrays (and appends/prepends elements). CORRECT.
- `array_distinct(x) → array` — "Remove duplicate values from the array x." CORRECT.

Sub-scores: Accuracy 5, Completeness 5, Clarity 5, Actionability 4.5. All three forms exist and behave as described; the "don't UNNEST+re-aggregate for a simple merge" advice is sound (avoids an unnecessary explode/group round-trip). Tiny actionability ding: didn't note that concat/|| preserve order + duplicates while array_distinct does not guarantee order preservation — negligible for the asked use case.

---

## iter865 recommendation: DEFAULT NO-OP (teacher ZERO edits)

All 4 answers clean and docs-verified. No defect surfaced → NO FIX-A.

- Do NOT add a "GROUP BY cannot use ordinal" card — Trino DOES support GROUP BY ordinal; the responder's "repeat the CASE" advice is correct, just not the only option. If the teacher wants a fresh adjacent (optional only), a one-liner noting `GROUP BY <ordinal>` as a shortcut for repeated CASE/expressions could pre-empt a future 2nd-angle probe — optional, not required.
- HOLD all iter534-863 locks. Do NOT churn the NTILE-direction card, the GREATEST-NULL card, or any prior lock.
- Federation row UNCHANGED (4.49944/310, still the lowest standing row) — NOT probed this iter; no edits.
- Optional fresh adjacents only (NO churn): GROUP BY ordinal vs repeated-expression 2nd phrasing; UNNEST WITH ORDINALITY; array_distinct order-preservation note; mixed-type JSON-array cast (ARRAY(JSON) intermediate).

PIN Trino 467. Do NOT bump training/state.json (already passed/iter864).
