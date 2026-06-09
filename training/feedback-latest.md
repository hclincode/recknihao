# Judge Feedback — iter820 (DEFAULT NO-OP durability sweep)

Phase: extended. Teacher made zero resource edits this iteration. All 4 Q&A pairs scored on merits; every dialect claim verified against trino.io/docs/467.

## Per-question scores

### Q1 — last element of an array
- **Accuracy 5** — `element_at(arr, -1)` = last element CONFIRMED (Trino docs: "If `index` < 0, `element_at` accesses elements from the last to the first"). NULL-safe on out-of-range/empty CONFIRMED ("returns NULL when accessing an index larger than array length, whereas the subscript operator would fail"). Subscript `arr[n]` is 1-based and ERRORS on out-of-range CONFIRMED. The claim `arr[cardinality(arr)]` errors on empty arrays is correct (cardinality()=0 → subscript [0] out of range → fail).
- **Completeness 5** — gives the recommended idiom plus the verbose erroring alternative with the empty-array caveat.
- **Clarity 5** — direct, no assumed knowledge.
- **Actionability 5** — engineer can paste `element_at(array_col, -1)` immediately.
- Citation r07:610/618 verified exact. **Q1 avg = 5.00**

### Q2 — case-insensitive match
- **Accuracy 5** — `lower(plan_tier)='starter'`, `lower(plan_tier) LIKE '%starter%'`, and `regexp_like(plan_tier, '(?i)starter')` all valid. Trino docs confirm regexp functions use Java pattern syntax and the `(?i)` inline flag is supported ("Case-insensitive matching (enabled via the `(?i)` flag)"). Trino 467 has NO `ILIKE` operator; responder correctly did not invent one and offered the canonical `lower()`/regex idioms. Responder's "Java regex" phrasing is accurate (Trino uses java.util.regex Pattern syntax).
- **Completeness 5** — three distinct correct idioms (exact, substring, regex) for the Postgres-migrant asker.
- **Clarity 5** — names the "normalize one side" mental model.
- **Actionability 5** — directly usable WHERE clauses.
- Citation r23:1989/2781. **Q2 avg = 5.00**

### Q3 — pivot rows to columns
- **Accuracy 5** — `SUM(CASE WHEN channel='web' THEN amount ELSE 0 END)` conditional aggregation valid; `SUM(amount) FILTER (WHERE channel='web')` valid (Trino docs: FILTER "is supported for all aggregate functions"). Trino has no native PIVOT keyword — manual conditional aggregation is the correct idiom. ELSE 0 → 0 for absent channel; FILTER → NULL for absent — both acceptable, responder's SQL is valid.
- **Completeness 5** — both idioms shown, correct GROUP BY.
- **Clarity 5** — full runnable query.
- **Actionability 5** — copy-paste ready.
- Citation r07:1227-1246. **Q3 avg = 5.00**

### Q4 — build a JSON object from columns
- **Accuracy 5** — `CAST(MAP(ARRAY[keys], ARRAY[vals]) AS JSON)` produces a JSON object (docs example confirms). `CAST(CAST(ROW(...) AS ROW(name type,...)) AS JSON)` uses FIELD NAMES as keys CONFIRMED (docs: `ROW(v1,v2,v3)` → `{"v1":...,"v2":...,"v3":...}`). `json_format()` returns VARCHAR CONFIRMED. Critical warning correct: casting a MAP directly to VARCHAR yields `{k=v}` debug rendering, NOT valid JSON — verified via docs/search. MAP value array must be one common type, so casting `user_id` to VARCHAR to unify the values array is necessary and correct; MAP keys must be non-null VARCHAR.
- **Completeness 5** — two construction methods + the anti-pattern warning + json_format serialization step.
- **Clarity 5** — shows expected output shape.
- **Actionability 5** — full expressions ready for an API-response query.
- Citation r09:757-786. **Q4 avg = 5.00**

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = 5.00 — PASS** (threshold 3.5; overall average governs, no per-Q veto)

## Defects / gaps
None. All four answers are technically bulletproof against Trino 467, all citations verified exact, all SQL is valid Trino 467 dialect. No findability slip — responder answered all four fully and routed to correct resources. Pure-SQL questions; no prod-env (on-prem Trino 467 / OPA / JWT) conflict.

## iter821 directive
**DEFAULT NO-OP / durability sweep.** No defect surfaced — do not open a FIX-A. Continue probing fresh adjacent angles to keep coverage broad. Suggested fresh probes for iter821: (1) array flatten — `flatten(array(array))` vs `array_agg` over UNNEST; (2) `try_cast` vs `cast` on dirty numeric strings; (3) running/cumulative SUM window frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`; (4) `date_diff(unit, ts1, ts2)` unit-string form on timestamps. Keep federation (r22) untouched unless a federation question lands — margin remains thin there.
