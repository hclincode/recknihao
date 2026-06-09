# iter808 — Judge Feedback (DEFAULT NO-OP sweep; Q1/Q2 bulletproof re-probes, Q3 scrutiny, Q4 clean)

**Overall: 4.06 / 5 — PASS** (overall average governs; no single-Q veto)

Verification basis: every dialect claim checked against trino.io/docs/467 (aggregate.html, json.html, string.html, conversion.html) plus WebSearch on Trino concat/`||` numeric coercion. resources/ NOT treated as ground truth.

---

## Per-question scores

### Q1 — regr_slope(revenue, ad_spend), revenue dependent  →  BULLETPROOF
`regr_slope(revenue, ad_spend) AS slope`, first arg dependent (y), second independent (x); GROUP BY for per-group. Cites r05 native-stats card.

Verified: trino.io/docs/467/functions/aggregate.html — *"regr_slope(y, x) → double. Returns linear regression slope of input values. y is the dependent value. x is the independent value."* `regr_slope(revenue, ad_spend)` puts revenue=y (dependent), ad_spend=x (independent) → "revenue per dollar of spend". CORRECT (y, x) order, native function.

- Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5 → **avg 4.75**

### Q2 — count nested 'items' array  →  BULLETPROOF
`json_array_length(json_extract(order_payload, '$.items')) AS n_items` → 3; uses `json_extract` (NOT `_scalar`) for the array, notes `json_extract_scalar` returns NULL on a non-scalar. Cites r13.

Verified: trino.io/docs/467/functions/json.html — `json_extract(json, json_path)` returns the nested value as JSON (so the array comes back as JSON); `json_array_length(json)` counts a JSON array's elements; `json_extract_scalar` requires a scalar. Correct nested extract + count → 3.

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.0**

### Q3 — format decimal 0.0732 as '7.32%'  →  DEFECT (cast-less concat / wrong citation)
Responder gave `CONCAT(ROUND(100.0 * conversion_rate, 2), '%')` and `ROUND(100.0 * conversion_rate, 2) || '%'`, claimed result `'7.32%'`. Cites r07:1649.

**VERDICT: TYPE ERROR.** trino.io/docs/467 + WebSearch confirm `concat(...) → varchar` and the `||` operator are **VARCHAR-only**; Trino does **NOT** implicitly coerce double/decimal/bigint to varchar inside concat/`||`. `ROUND(100.0*x, 2)` returns a double/decimal, so both responder forms raise an "Unexpected parameters / cannot be applied to (double, varchar)" type error — they DO NOT compile without an explicit `CAST(... AS varchar)`. The responder's claimed `'7.32%'` output is wrong (the query never runs).

**Correct forms (verified):**
- Canonical: `format('%.2f%%', conversion_rate * 100)` → `'7.32%'` (docs example `format('%s%%', 123)` → `'123%'`; `%%` = literal percent, `%.2f` = 2-decimal float).
- Or, if `||` is wanted: `CAST(ROUND(100.0 * conversion_rate, 2) AS varchar) || '%'`.

**Slip vs defect — primarily a RESPONDER SLIP plus a findability gap:**
- The cited r07:1649 is the integer-division *"Why `100.0 *` and not `100 *`"* note — it is about division, NOT about percent-string formatting. The responder mis-anchored.
- The CORRECT canonical already exists in resources: **r23:574** shows `format('%.1f%%', 87.5) → '87.5%'`, and **r23:647-681 (§3.1A sub-canonical)** states verbatim that `concat`/`||` are VARCHAR-only and every numeric needs `CAST(... AS varchar)` — including a cast-before-`||` idiom-2. The responder did not find/apply it.
- Findability gap: that percent-string form is buried inside r23's general `format()` card; it is NOT surfaced under percent-string keywords (`format a decimal as a percent string`, `0.0732 → '7.32%'`, `append % sign to a number`) in r07 where the question's "% string" wording leads.

- Accuracy 1 / Completeness 3 / Clarity 4 / Actionability 2 → **avg 2.5**

### Q4 — month-resetting running total  →  CLEAN
`SUM(amount) OVER (PARTITION BY DATE_TRUNC('month', txn_date) ORDER BY txn_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`. Cites r07:2476-2493.

Verified: PARTITION BY the month bucket isolates each month (cumulative resets at each month boundary); explicit `ROWS UNBOUNDED PRECEDING → CURRENT ROW` frame gives the per-row running total. Correct and matches the standing running-total + date_trunc pins.

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.0**

---

## Overall

(4.75 + 5.0 + 2.5 + 5.0) / 4 = **4.06 → PASS**

### Bulletproof status
- **regr-native (Q1): BULLETPROOFED.** 2nd consecutive clean datapoint after iter807 fix; correct (y, x) order and native function.
- **json-array-length / nested extract (Q2): BULLETPROOFED.** 2nd consecutive clean datapoint after iter807 fix; correct `json_extract`-then-`json_array_length` nested path.

### Q3 the one weak spot
The percent-string format is a real DEFECT in the answer (cast-less concat = type error) but it is a responder findability/citation slip against an EXISTING correct canonical (r23 §3.1A), not a missing-resource gap. The fix is a light findability inoculation, not new teaching.

---

## iter809 designation — FIX-A (light findability inoculation)

The Q3 defect is real and recurrable, so this is NOT a no-op. Recommend a **light additive findability FIX-A** (no large new content):

1. **Surface the percent-string canonical under percent-string keywords in r07** (near the existing `100.0 *` percent card around line 1648-1651), as a copy-attractive 1-liner:
   - `format('%.2f%%', conversion_rate * 100)  -- 0.0732 -> '7.32%'  (%% = literal percent)`
   - Keyword anchors: *format a decimal as a percent string, 0.0732 to '7.32%', append a % sign to a number, ratio to percent display string, build a percentage label.*
2. **Defang the cast-less concat inline** (mark it un-copyable WRONG, per the defang-DO-NOT-WRITE memory — make the `format` line the copy-attractive block, not the broken concat):
   - WRONG: `ROUND(100.0*x,2) || '%'` / `CONCAT(ROUND(...), '%')` → type error: `||`/concat are VARCHAR-only, no implicit numeric cast.
   - If `||` is required: `CAST(ROUND(100.0*x, 2) AS varchar) || '%'`.
3. **Cross-link** the new r07 percent-string snippet to r23 §3.1A (the authoritative concat/format coercion guardrail) so the keyword path from r07 → r23 is explicit.

Keep it light — the underlying truth already lives in r23:574 / r23:647-681; this is purely placing the percent-string form where the question's keywords lead and defanging the broken concat the responder reached for.
