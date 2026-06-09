# Judge Feedback — Iter 880 (EXTENDED PHASE)

**Overall: 4.94 STRONG PASS** (per-Q 5.00 / 5.00 / 5.00 / 4.75 = 19.75 / 4 = 4.9375; margin +1.44; overall average governs, no per-Q veto)

Trino PINNED 467. All dialect facts WebFetch-verified against trino.io/docs/467 on 2026-06-10 (sql/select.html, functions/map.html, functions/conversion.html, functions/math.html, functions/list.html). NO federation probe this iter (4.49944/310 row UNCHANGED).

**Headline: the iter879 Q2 ROW-unpack FIX LANDED CLEAN.** This iter's Q1 re-probed it from a fresh phrasing and the responder now leads with `(properties).*` (parens-required) and explicitly REJECTS UNNEST-on-a-ROW. No regression — NO iter881 escalation.

---

## Q1 — Expand all nested fields of a ROW/struct column into top-level columns — 5.00
Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

Responder: `SELECT (properties).* FROM events` with parentheses around the column REQUIRED; `(properties).* AS (plan, region, account_tier)` for explicit names; `properties.plan` for a single field; and explicitly "Do NOT use CROSS JOIN UNNEST for this — UNNEST works on arrays/maps (turning them into rows), it does not expand a single ROW's named fields into columns."

VERIFIED sql/select.html: `(row_expression).*` — "All fields of the row define output columns to be included in the result set"; parens required; example `SELECT (CAST(ROW(1, true) AS ROW(field1 bigint, field2 boolean))).*` yields columns `field1`,`field2`; aliases "override any preexisting column or row field names." Also confirmed UNNEST expands ARRAY/MAP into a relation (rows), NOT a single ROW's fields into columns.

**FIX LANDED (a):** The iter879 Q2 defect (wrong UNNEST-on-ROW suggestion + missed `(row).*`) is GONE. Responder now leads with `(properties).*`, parens-required called out, AS-alias form given, per-field dot-notation provided, and the UNNEST-on-a-ROW misconception explicitly defanged with the correct reason. Clean, complete, exemplary. No regression.

## Q2 — Merge two MAP columns, overrides win over defaults — 5.00
Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

Responder: `map_concat(default_settings, user_overrides)` — RIGHTMOST map wins on key collision; `COALESCE(col, MAP())` to treat NULL as empty map; defanged `||` (string/array, not maps) and `transform_values`.

VERIFIED map.html: map_concat — "If a key is found in multiple given maps, that key's value in the resulting map comes from the last one of those maps." Rightmost-wins CONFIRMED, so `map_concat(defaults, overrides)` correctly gives overrides priority. `COALESCE(col, MAP())` for NULL inputs is sound. Defanging `||` (concatenates strings/arrays, not maps) is correct.

**(b) map_concat rightmost-wins CONFIRMED.** Argument order matters and the responder ordered it correctly for the stated requirement. No defect.

## Q3 — Format a number with thousands separators (1,234,567.89) — 5.00
Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

Responder: `format('%,.2f', invoice_amount)` -> '1,234,567.89'; `format('%,d', 1234567)` -> '1,234,567'; `%%` for literal percent; follows Java printf.

VERIFIED conversion.html: format() follows Java Formatter syntax. Verbatim doc example `SELECT format('%,.2f', 1234567.89);` -> `'1,234,567.89'` (the responder's example is the documented one). `%%` escapes literal percent (`SELECT format('%s%%', 123);` -> `'123%'`). The `,` grouping flag works for both `%,.2f` (float) and `%,d` (integer).

**(c) format ',' thousands-separator flag CONFIRMED.** No defect.

## Q4 — Euclidean distance sqrt(x^2 + y^2) — 4.75
Sub-scores: Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5

Responder: `sqrt(power(delta_x, 2) + power(delta_y, 2))`; also `power(power(dx,2)+power(dy,2), 0.5)`; noted power/pow alias, NO `^` operator in Trino, sqrt/ln/exp/log10 return double.

VERIFIED math.html + list.html: `sqrt(x)->double`, `power(x,p)->double`, `pow(x,p)` is a documented alias of power(); NO `^` exponent operator (documented operators: `+ - * / %`); **`hypot` does NOT appear in the 467 functions list or math.html**.

**(d) sqrt(power+power) is the CANONICAL answer and is correct.** Since Trino 467 has NO `hypot(x,y)`, there is NO one-call option the responder missed — the answer is complete on substance. Minor (-0.25 completeness only): the responder could have noted in one line "Trino has no hypot()" to preempt a user reaching for it, but this is a polish nuance, not a gap (the answer is the only correct construction). No over-cautious CAST/sargability prior surfaced; no wrong-mechanism misframe.

---

## Summary
- All four answers dialect-correct against trino.io/docs/467. Three perfect 5.00, one 4.75 (trivial polish nuance only).
- Watch-items from the run prompt: NO over-cautious CAST/sargability imported priors; NO wrong-mechanism misframes; the iter879 ROW-unpack FIX is durable under re-phrasing.

## iter881 Recommendation: **DEFAULT NO-OP**
All 4 dialect-clean; the iter879 `(row).*` FIX LANDED (clean re-probe, Q1); map_concat / format-',' / sqrt+power all correct. Teacher ZERO edits. Do NOT add any "wrong" card for Q1/Q2/Q3/Q4 (all forms correct). Do NOT touch the iter879 row-unpack card, the map functions card, the conversion/format card, or any iter534-879 pin. OPTIONAL micro-polish (not required, do NOT regress existing content): a one-line "Trino 467 has NO hypot() — use sqrt(power(a,2)+power(b,2))" anchor near the math/distance card to preempt the foreign-function reach. PIN 467. NO federation edits. DO NOT bump training/state.json.

EXPLICIT CONFIRMATIONS:
- (a) `(row).*` row-unpack FIX LANDED — parens-required called out, UNNEST-on-ROW explicitly rejected with correct reason; no regression.
- (b) map_concat rightmost-wins CONFIRMED (map.html "value ... comes from the last one of those maps").
- (c) format ',' thousands-separator flag CONFIRMED (conversion.html verbatim `format('%,.2f', 1234567.89)` -> '1,234,567.89'; `%%` escapes percent).
- (d) hypot does NOT exist in Trino 467 — sqrt(power+power) is the canonical and only correct construction; responder missed nothing material.
