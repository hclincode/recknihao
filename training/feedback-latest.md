# Judge Feedback — iter1049

**Phase:** extended (state.json passed=true). Overall average governs; NO per-question veto.
**Verification:** BOTH directions against RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/...) + WebSearch, NOT resources/. Federation NOT probed (hard-locked).

## Production-environment fit
prod_info.md serving-environment section is unfilled (Model/context/platform blank); SaaS stack is on-prem Trino 467 + Iceberg + Hive Metastore + MinIO. All four questions are pure Trino-467 SQL-dialect questions with no auth/authz or platform dependency, so the only applicability bar is "valid runnable Trino 467 SQL." Evaluated on that basis.

---

## Q1 — integer cents → decimal dollars (1999 → 19.99)
**Scores:** Accuracy 4.9 / Completeness 4.875 / Clarity 4.9 / Actionability 4.875 → **4.8875**

- `price_cents / 100.0` → integer / DECIMAL → exact DECIMAL result 19.99. **VERIFIED:** RAW `language/types.md` lists `1.1` as an example DECIMAL literal under the DECIMAL type section; only scientific/exponent notation (`1.03e1`) is DOUBLE. So the undecorated decimal-point literal `100.0` is DECIMAL, and integer/DECIMAL is exact. The responder's "DECIMAL result" label is CORRECT.
  - NOTE: a first-pass WebFetch summary misread types.md (quoted the sci-notation sentence and concluded `100.0`=DOUBLE). RAW-source re-read settled it as DECIMAL — consistent with the iter1048 finding and the imported-prior self-error family (GREATEST-NULL / div-by-zero / TZ-coercion). Do NOT ding the DECIMAL label.
- `CAST(price_cents AS decimal)/100` also works (CAST AS decimal defaults to DECIMAL(38,0); /100 stays exact decimal).
- Correctly flags integer/integer division: `1999/100 = 19` (truncation). Verified (toward-zero / floor for positives).
- Sound and complete.

## Q2 — sum an array of prices per order, no join/unnest
**Scores:** Accuracy 4.875 / Completeness 4.8125 / Clarity 4.875 / Actionability 4.8125 → **4.84375**

- `reduce(line_items, 0, (sum, price) -> sum + price, sum -> sum)` is the canonical array-sum. **VERIFIED:** RAW `functions/array.md` — there is NO built-in `array_sum`; `reduce(array(T), initialState S, inputFunction(S,T,S), outputFunction(S,R)) -> R` is the documented 4-arg form. Per-element accumulation, no UNNEST.
- Init `0` is integer; with double prices the accumulator coerces to double — fine. Clean.

## Q3 — accounts where EVERY flag starts with literal "beta_"
**Scores:** Accuracy 4.9375 / Completeness 4.9375 / Clarity 4.9375 / Actionability 4.9375 → **4.9375**

- `all_match(feature_flags, f -> starts_with(f, 'beta_'))`. **VERIFIED BOTH WAYS:**
  - `all_match(array(T), function(T,boolean)) -> boolean` exists (array.md), and for an empty array returns `true` (documented special case) — the responder's "empty array → TRUE vacuous" is CORRECT.
  - `starts_with(string, substring) -> boolean` exists (string.md); `ends_with` does NOT exist (not used here, correctly).
- **PROACTIVE LITERAL-PREFIX TEACHING (watch (o) durability-positive):** responder EXPLICITLY warns NOT to use `f LIKE 'beta_%'` because LIKE `_` is a single-character wildcard that would match `'betaX...'`. **VERIFIED:** `functions/comparison.md` — `_` matches any single character; `'beta_%'` would over-match `'betaX'`. Literal-underscore must use `starts_with` (or `LIKE 'beta\_%' ESCAPE '\'`). This is the exact iter1028/1029/1036 misconception, and the responder taught the correct guard unprompted across the `all_match` surface — extends the clean literal-underscore streak (bare-col / filter-lambda / any_match / all_match). Watch (o) stays CLOSED/passive, durability-positive.
- Best answer of the four. Score HIGH.

## Q4 — this month vs last month revenue, one row, % change, no two-queries/join
**Scores:** Accuracy 3.0 / Completeness 4.0 / Clarity 3.625 / Actionability 3.5 → **3.53125**

- **PRIMARY query is INVALID — nested window functions.** The lead writes `LAG(SUM(amount) OVER (PARTITION BY ...)) OVER (ORDER BY ...)` — a window function (`SUM(...) OVER`) used as the ARGUMENT to another window function (`LAG(...) OVER`). **VERIFIED:** Trino does NOT permit nesting window functions; a window function's argument may not itself contain a window function. This raises an analysis error ("Cannot nest window functions" / nested window function not allowed). The PRIMARY query will not run. (Same root cause guarded in r07 — pre-aggregate first, then apply the window.)
- **SECONDARY "Simpler form" is CORRECT and runnable.** The CTE pre-aggregates per month (`GROUP BY date_trunc('month',order_date)`), then `LAG(total_revenue) OVER (ORDER BY month)` over the already-aggregated rows, with `ROUND(100.0*(total_revenue - LAG(...))/LAG(...), 2)`. This is exactly the canonical period-comparison form and the fix for the nested-window error. Verified valid.
- Net: BROKEN lead + CORRECT clean CTE present. Accuracy dinged for the invalid primary; partial credit because the correct answer IS in the response and is the one a careful reader would adopt. A SaaS engineer copy-pasting the FIRST block hits an error; the second block works — hence the actionability/clarity drag (the broken lead is presented first and more prominently).

---

## Overall
- Q1 4.8875 + Q2 4.84375 + Q3 4.9375 + Q4 3.53125 = 18.2 / 4 = **4.55** → **PASS** (margin +1.05 over 3.5).

## Recommendation — Q4 nested-window classification
**Classify as per-instance responder slip → MONITOR / re-probe-don't-churn. NO resource edit, NO commit.**

Rationale: this is NOT a resource defect. The resource (r07) teaches the CTE-then-LAG period-comparison form correctly, and the responder DID produce that correct form — as its own "simpler form" secondary. The failure is the responder's habit of leading with an over-complicated single-statement window construction that happens to nest windows illegally, then appending the correct simpler version. That matches the documented "responder broken secondary alternative / over-engineered lead" pattern, not a missing/wrong resource. It is a 1st occurrence of the nested-SUM-OVER-as-LAG-argument shape at the LEAD position this sweep — NOT a 2-in-2 same-shape and NOT sourced from a wrong resource claim (r07 nested SUM(SUM) OVER guard + running-total pre-aggregate CTE are intact and correct).

Action:
- MONITOR. Re-probe the month-over-month / period-comparison family next sweep with a differently-phrased prompt to confirm whether the nested-window LEAD recurs.
- If it recurs 2-in-2 with the SAME nested-window shape, escalate to a LIGHT FIX-A: add an inline co-located caveat near the r07 period-comparison card — "Trino cannot nest window functions; pre-aggregate in a CTE, then LAG over the aggregated rows" — placed where the period-comparison keywords lead the responder. Do NOT churn now (margin healthy, single occurrence, correct form already produced).

## Clean-of report
`::` cast absent all 4; no QUALIFY / false-semi-join / fabricated-function / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / over-warning. Q4 IS a broken-lead instance (the nested-window primary) — logged as monitor.

DEFAULT otherwise NO-OP. NO resource edit; NO commit. MUST NOT bump state.json (already 1049).
