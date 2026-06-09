# Judge Feedback — iter807 (DUAL ADDITIVE FIX-A re-check)

**Phase:** extended. **Mode:** end-of-iteration summary (state.json already at 807 — NOT bumped).
All four answers docs-verified against trino.io/docs/467 (json.html, aggregate.html, string.html) + cross-checked GitHub PR #11236 / issue #11347 for trim char-set semantics, on 2026-06-09.

---

## Per-question scores

### Q1 — Count elements in a JSON ARRAY STRING (`tags_json '["urgent","billing","vip","new"]'` → 4, no explode)
- **Accuracy 5** — `json_array_length(tags_json) AS tag_count` → 4. VERIFIED json.html: `json_array_length(json) -> bigint`, *json* = "a string containing a JSON array"; auto-coerces a VARCHAR JSON-array string, so the bare call works without `json_parse`. `json_array_length('["urgent","billing","vip","new"]') = 4`. Correctly advised AGAINST `cardinality(CAST(...))`.
- **Completeness 5** — direct count answer, no-explode rationale, the cardinality-CAST anti-pattern called out.
- **Clarity 5** — leads with the one function; clean COUNT-vs-EXPLODE framing.
- **Actionability 5** — copy-ready single expression.
- **Q1 avg = 5.00**
- **FIX CHECK:** Responder LED with `json_array_length(tags_json)` (NOT the iter806 garbled `cardinality(CAST(col AS JSON)->col)` / bare `cardinality(CAST(col AS ARRAY(JSON)))`) and cited the NEW r07 card (r07:103-113, keyword-anchored on the JSON-array-count path). **json-array-length FIX WORKED.**

### Q2 — Correlation between `session_minutes` and `purchase_total`
- **Accuracy 5** — `corr(purchase_total, session_minutes) AS correlation`. VERIFIED aggregate.html: `corr(y, x) -> double` (correlation coefficient = Pearson), native Trino aggregate; `covar_samp`/`covar_pop`/`regr_slope`/`regr_intercept` all `(y, x) -> double`, all native. `corr` is symmetric so arg order doesn't change the value, but the (y dependent, x independent) note is good practice and matters for covar/regr.
- **Completeness 5** — gives corr plus the covar/regr family; range -1..1; arg-order note.
- **Clarity 5** — plain explanation of what correlation means + the result range.
- **Actionability 5** — drop-in GROUP-BY-able expression.
- **Q2 avg = 5.00**
- **FIX CHECK:** Responder LED with NATIVE `corr(...)` — did NOT decline, did NOT call it federation-only (the iter806 Q4 honest-decline gap). Cited the NEW r05 card (r05:2267-2281), which correctly states these are native and run directly on Iceberg, with the r22 native-vs-pushdown cross-ref. **correlation-native FIX WORKED.**

### Q3 — Products priced >= 90% of the table-wide max price
- **Accuracy 5** — `MAX(price) OVER ()` computes the table-wide max on every row; window functions are illegal in `WHERE` in every SQL dialect including Trino 467, so the CTE-then-`WHERE price >= 0.9 * max_price` wrap is correct. VERIFIED against window/select semantics. (Scalar-subquery alternative `WHERE price >= 0.9 * (SELECT MAX(price) FROM products)` is equally valid; not required.)
- **Completeness 5** — covers the empty-OVER() table-wide-max meaning AND the window-not-in-WHERE constraint that forces the CTE.
- **Clarity 4.5** — clear; could note the scalar-subquery alternative, but not required.
- **Actionability 5** — full runnable CTE.
- **Q3 avg = 4.875**

### Q4 — Strip `#`/`*` off both ends of a code (`"##ABC123##"` → `"ABC123"`)
- **Accuracy 5** — `trim(BOTH '#*' FROM code)` → `'ABC123'` / `'XYZ'`. VERIFIED string.html + r27:1011 rationale: the FROM-form trim character is a **SET**, not a fixed substring — every listed char is stripped individually from the end(s) (`trim(TRAILING 'ER' FROM 'WORKER')` → `'WORK'` strips R then E-is-no-longer-trailing-so-stop, NOT a literal `'ER'` substring match). `LEADING`/`TRAILING` for one end. No 2-arg `ltrim/rtrim(string,chars)` in Trino. All consistent with the standing trim-char-SET pin.
- **Completeness 5** — char-SET semantics, both-ends vs one-end, two worked inputs.
- **Clarity 5** — explicit that `'#*'` is a SET.
- **Actionability 5** — copy-ready.
- **Q4 avg = 5.00**

---

## Overall

| Q | Avg |
|---|---|
| Q1 json-array-count | 5.00 |
| Q2 correlation-native | 5.00 |
| Q3 within-X%-of-max | 4.875 |
| Q4 trim-char-set both-ends | 5.00 |

**Overall avg = 4.969 — PASS** (threshold 3.5; no single-Q veto).

---

## Closure status

- **(a) json-array-length — CLOSED.** Q1 is the 1st post-fix datapoint: responder led with `json_array_length(col)` on the count phrasing and cited the new r07 keyword-path card. The iter806 garbled-cardinality defect did not recur. (One more phrasing — e.g. nested-under-a-key `json_array_length(json_extract(col,'$.items'))`, or a numeric-element array — would BULLETPROOF it.)
- **(b) correlation-native — CLOSED.** Q2 is the 1st post-fix datapoint: responder gave native `corr(...)` (no decline, no federation-only framing) and cited the new r05 native-stats card. The iter806 Q4 honest-decline gap did not recur. (One more phrasing — e.g. a `regr_slope`/`regr_intercept`-specific ask where arg order is load-bearing — would BULLETPROOF it.)
- **No NEW defect surfaced.** Q3 and Q4 clean against well-covered resources.

## iter808 designation — **DEFAULT NO-OP / durability-breadth sweep**

No open defect. Both iter807 fixes confirmed on 1st datapoint. Recommend teacher make ZERO edits and re-probe to bulletproof the two freshly-closed topics from a 2nd angle each, plus fresh adjacent topics:
1. **json-array-length 2nd angle** — nested-array-under-a-key (`json_array_length(json_extract(col,'$.items'))`) or numeric-element JSON-array-string count.
2. **correlation/stats 2nd angle** — `regr_slope`/`regr_intercept` where `(y, x)` arg order changes the answer (asymmetric — distinguishes from symmetric `corr`).
3-4. Two fresh adjacent probes (judge's discretion).

**PRESERVE (churn risk — drove the iter807 fixes):** r07:103-113 json_array_length COUNT card + COUNT-vs-EXPLODE disambiguator + cardinality-CAST defang; r05:2267-2281 native corr/covar/regr stats card + r22 native-vs-pushdown cross-ref; r27:992-1015 trim char-SET FROM-form card (+ the `'ER'`→`'WORK'` SET-not-substring rationale and the no-2-arg-ltrim/rtrim pin); r23 window-not-in-WHERE → CTE/subquery-wrap card.

**Standing pins all held:** json_array_length-for-count / corr-covar-regr-native-not-federation-only / MAX-OVER-empty-window-CTE-to-filter / trim-char-SET-BOTH-chars-FROM (and no 2-arg ltrim/rtrim) / window-illegal-in-WHERE.
