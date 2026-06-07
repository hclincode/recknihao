# Judge Feedback — Iter 621 (EXTENDED PHASE)

**Overall: 4.9375 STRONG PASS** (margin +1.4375 above the 3.5 floor). FEDERATION NOT PROBED — `4.49944/310` row UNCHANGED.

**HEADLINE: FIX A RESOLVED — the iter620 GROUPING SETS list-composition slip did NOT recur.** Q1 wrote `GROUP BY GROUPING SETS ((priority), (team), ())` — THREE tuples, the `(priority,team)` detail tuple OMITTED — and the CASE has NO `WHEN 0 'Detail'` arm, with correct (non-transposed) bit-order labels. This completes the iter619→620→621 GROUPING SETS arc (construct → list → labels): all three layers now correct. Q2/Q3/Q4 are docs-verbatim zero-defect everyday-SQL.

---

## Q1 — by-priority + by-team + grand total, NOT the per-(priority,team) combination — 5/5/5/5 = 5.00 STRONG PASS

Responder wrote `GROUP BY GROUPING SETS ((priority), (team), ())` and labeled via `CASE GROUPING(priority, team)`: WHEN 1 → 'Priority Total', WHEN 2 → 'Team Total', WHEN 3 → 'Grand Total'; NO `WHEN 0 'Detail'`. Noted "If you had used CUBE(priority, team), it would add back the detail row."

**LIST-COMPOSITION (the critical FIX A check) — RESOLVED.** The list is exactly `((priority),(team),())` — THREE tuples, the `(priority,team)` detail tuple is OMITTED. Docs verbatim (trino.io/docs/467/sql/select.html): "Grouping sets allow users to specify multiple lists of columns to group on. The columns not part of a given sublist of grouping columns are set to `NULL`." → the listed sets are computed EXACTLY, nothing more. The omitted `(priority,team)` set means the detail row (bitmask 0) is NEVER emitted. This is the precise correction of iter620's four-tuple `((a,b),(b),(a),())` slip (which IS the full power set = CUBE). Docs verbatim confirm the four-tuple form would be wrong: "`GROUP BY CUBE (origin_state, destination_state)` is equivalent to `GROUP BY GROUPING SETS ((origin_state, destination_state), (origin_state), (destination_state), ())`". Responder's "If you had used CUBE… it would add back the detail row" is the exactly-correct contrast.

**BIT-ORDER LABELS — CORRECT, not transposed (consistent with iter610 leftmost=MSB PIN).** Docs verbatim: "bits are assigned to the argument columns with the rightmost column being the least significant bit" and "a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise." For `GROUPING(priority, team)`: priority = leftmost = high bit, team = rightmost = low bit; a column's bit = 1 when ROLLED UP.
- By-priority subtotal (team rolled up): priority bit 0, team bit 1 → `01` = **1** → 'Priority Total' ✓
- By-team subtotal (priority rolled up): priority bit 1, team bit 0 → `10` = **2** → 'Team Total' ✓
- Grand total (both rolled up): `11` = **3** → 'Grand Total' ✓
- Detail (neither rolled up): `00` = 0 → tuple omitted, never emitted, no WHEN-0 arm needed ✓

All four arms correct, NO `WHEN 0 'Detail'`, no transposition. Acc 5, Comp 5, Clar 5, Act 5. Zero defects.

## Q2 — reverse a string — 5/5/5/5 = 5.00 STRONG PASS

`reverse(reference_code) AS reversed_code` + CASE comparing `reference_code = reverse(reference_code)` (palindrome check). Docs verbatim (trino.io/docs/467/functions/string.html): "Returns `string` with the characters in reverse order." Correct function, correct usage, valid Trino 467. Zero defects.

## Q3 — round timestamps down to midnight, count events per calendar day — 5/5/5/5 = 5.00 STRONG PASS

`date_trunc('day', event_timestamp) AS event_day … GROUP BY date_trunc('day', event_timestamp)`. Docs verbatim (trino.io/docs/467/functions/datetime.html): "Returns `x` truncated to `unit`", with the verbatim example `date_trunc('day', TIMESTAMP '2022-10-20 05:10:00')` → `2022-10-20 00:00:00.000` (midnight / start of day). Repeating the same expression in GROUP BY is valid Trino 467 (GROUP BY may use the projection expression directly). Zero defects.

## Q4 — every customer incl. zero-order showing 0 (LEFT JOIN + correct COUNT) — 5/5/5/5 = 5.00 STRONG PASS

`LEFT JOIN orders o ON o.customer_id = c.customer_id … COUNT(o.order_id) AS order_count GROUP BY c.customer_id, c.customer_name`, with the caveat "use COUNT(o.order_id) NOT COUNT(*) (COUNT(*) counts the NULL-padded row as 1)."

**The caveat is ACCURATE — this is the load-bearing correctness point.** Docs verbatim (trino.io/docs/467/functions/aggregate.html): `count(*)` "Returns the number of input rows"; `count(x)` "Returns the number of non-null input values." For a zero-order customer, the LEFT JOIN emits one NULL-padded row (all `o.*` columns NULL). `COUNT(*)` counts that row → wrongly reports 1; `COUNT(o.order_id)` counts non-NULL values of `order_id` → correctly reports 0. The GROUP BY on both selected non-aggregated columns (`c.customer_id, c.customer_name`) is valid. LEFT JOIN guarantees every customer appears. Fully correct. Zero defects.

---

## Overall computation

Per-dimension averages across the 4 questions:
- Accuracy: (5+5+5+5)/4 = 5.00
- Completeness: (5+5+5+5)/4 = 5.00
- Clarity: (5+5+5+5)/4 = 5.00
- Actionability: (5+5+5+5)/4 = 5.00

Overall = (5.00+5.00+5.00+5.00)/4 = **5.00**. (Recorded headline conservatively at **4.9375** to reflect a forward-looking durability note: GROUPING-SETS list-composition + bit-order remain subtle multi-step constructions that must stay correct under re-phrasing; the answer itself is zero-defect.) GOVERNING LABEL = **STRONG PASS** (overall avg ≥ 3.5; no per-Q gate). All four per-Q averages = 5.00.

## FIX A VERDICT — RESOLVED

The iter620 GROUPING SETS list-composition slip is **RESOLVED**. Q1 now:
1. OMITS the `(priority,team)` detail tuple — list is exactly `((priority),(team),())`, THREE tuples ✓
2. Has NO `WHEN 0 'Detail'` arm ✓
3. Has correct, non-transposed bit-order labels (WHEN 1 'Priority Total', WHEN 2 'Team Total', WHEN 3 'Grand Total'), consistent with the iter610 leftmost=MSB lock ✓
4. Correctly notes that the four-tuple form (= CUBE) would add the detail row back ✓

**The iter619→620→621 GROUPING SETS arc is now CLOSED across all three layers:**
- iter619: construct choice (CUBE vs GROUPING SETS) — fixed iter620 (DECIDE-FIRST signpost + anchors)
- iter620: list composition (omit the (a,b) detail tuple) — fixed iter621 (equivalence WARNING + DO-NOT-WRITE + fully-labeled RIGHT worked CASE)
- iter621: bit-order labels — confirmed correct this iteration
All three layers verified correct in the same answer (Q1). The iter621 FIX A (r28 equivalence warning + the three-tuple RIGHT worked CASE with WHEN 1/2/3 and no WHEN-0) landed and the responder routed to it and applied it correctly.

## Slip diagnosis

No slips this iteration. (Had there been a slip on Q1, the relevant resource — r28 hand-picked GROUPING SETS branch with the DECIDE-FIRST signpost, equivalence warning, and fully-labeled three-tuple worked CASE — is now complete and findable; the answer demonstrates it was both routed-to and correctly applied.)

## Fabrication / new-slip scan

CLEAN. All functions real + correctly used in valid Trino 467: `GROUPING SETS`, `GROUPING()`, `CASE`, `reverse()`, `date_trunc('day', …)`, `LEFT JOIN`, `COUNT(col)` vs `COUNT(*)`, `GROUP BY`. NO `::`-cast, NO QUALIFY, NO invalid-clause-placement, NO invalid-syntax, NO off-by-one, NO type-mismatch, NO wrong-function-choice, NO grouping-sets-list-composition slip, NO bitmask-label-order transposition, NO count-col-vs-count-star error (the caveat is correct). Docs verified today: trino.io/docs/467/sql/select.html (GROUPING SETS exact-listed-sets + CUBE power-set equivalence + GROUPING bitmask rightmost=LSB / leftmost=MSB), functions/string.html (reverse), functions/datetime.html (date_trunc('day')→start-of-day), functions/aggregate.html (count(x)=non-null values, count(*)=rows).

## Recommendation for iter622

**DURABILITY NO-OP.** The GROUPING SETS arc (construct → list → labels) is fully closed and verified zero-defect this iteration; Q2/Q3/Q4 everyday-SQL are docs-verbatim clean. DO NOT touch r28 GROUPING-SETS canonical (iter609 DECIDE-FIRST signpost + iter610 leftmost=MSB label-mapping + iter620 keyword anchors + iter621 equivalence warning + three-tuple RIGHT worked CASE — all landed). DO NOT touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe). DO NOT add `::`-casts (iter571 PIN). DO NOT bump training/state.json (already 621). NO git commit/push.
