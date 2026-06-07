# Iter609 Judge Feedback — 4.640625 STRONG PASS (margin +1.14 above 3.5 floor)

**Phase**: extended. **Federation NOT probed** — r22 §13.x guardrails / federation rubric row 4.49944/310 FROZEN, unchanged this iter.

**HEADLINE**: FIX A TOOK. The iter608 ROLLUP-instead-of-CUBE wrong-function-choice is RESOLVED — the both-margins question now routes to `GROUP BY CUBE(store, payment_method)`, all four grouping levels present, every subtotal/grand-total numeric value correct. The ONE genuine in-the-answer slip is a Q1 GROUPING **label transposition**: the responder's `WHEN 1` / `WHEN 2` `row_type` labels are SWAPPED (per-store rows mislabeled 'Payment Method Total' and vice-versa). The query runs and all numbers are right; only the two intermediate text labels are inverted. Q2/Q3/Q4 clean.

---

## Per-question scores

### Q1 — Sales by store AND payment_method, BOTH margins + grand total (FIX A re-probe) — Acc 3.5 / Comp 4.5 / Clar 4.5 / Act 4.0 = **4.125 PASS**

**Function choice (the big fix): CORRECT.** Responder used `GROUP BY CUBE(store, payment_method)`, not ROLLUP. This is exactly right for the both-margins case.
Verified trino.io/docs/467/sql/select.html: CUBE *"generates all possible grouping sets (i.e. a power set) for a given set of columns"* vs ROLLUP *"generates all possible subtotals"* (hierarchical/prefix only). CUBE(store, payment_method) emits (store,payment_method), (store), (payment_method), () — including the per-payment-method margin that ROLLUP(store, payment_method) would SKIP. The iter608 wrong-function-choice is **RESOLVED**.

All four grouping levels present; `ORDER BY GROUPING(store, payment_method), store, payment_method` orders detail→margins→grand total sensibly; `SUM(amount)` subtotals all numerically correct. The `WHERE sale_date >= DATE '2026-01-01'` is valid Trino 467 (typed DATE literal — no `::` cast).

**THE SLIP (Accuracy −): GROUPING bitmask labels WHEN 1 / WHEN 2 are TRANSPOSED.**
Verified verbatim trino.io/docs/467/sql/select.html: *"bits are assigned to the argument columns with the rightmost column being the least significant bit"* and *"a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise."* Docs example confirms the leftmost arg is the most significant bit (origin_state-only grouping → bit set `011`).

So for `GROUPING(store, payment_method)`: `store` = leftmost = HIGH bit (weight 2); `payment_method` = rightmost = LOW bit (weight 1). Bit=1 means that column was rolled up (aggregated). Working each level:
- Both present (detail): 00 = **0** → 'Detail' ✓
- `payment_method` rolled up, `store` present = a **per-STORE subtotal** (one row per store across all payment methods): store bit 0, pm bit 1 → 01 = **1**. CORRECT label = **'Store Total'**. Responder wrote `WHEN 1 THEN 'Payment Method Total'` ✗
- `store` rolled up, `payment_method` present = a **per-PAYMENT-METHOD subtotal** (one row per payment method across all stores): store bit 1, pm bit 0 → 10 = **2**. CORRECT label = **'Payment Method Total'**. Responder wrote `WHEN 2 THEN 'Store Total'` ✗
- Both rolled up (grand total): 11 = **3** → 'Grand Total' ✓

**Verdict: WHEN 1 and WHEN 2 are SWAPPED (Store Total ↔ Payment Method Total), docs-confirmed.** The responder's stated rule "GROUPING bit=1 means that column was rolled up" is itself correct — the error is purely in mapping the integer value to the human label: it forgot the leftmost arg is the HIGH bit, so `GROUPING=1` (=01) means the RIGHTMOST column (payment_method) was rolled up, which makes the row a STORE subtotal, not a payment-method total.

Severity: MODERATE. Structurally the right rows and numbers (CUBE choice = the big win), but a finance user copying this would mislabel every per-store subtotal as 'Payment Method Total' and every per-payment-method subtotal as 'Store Total' — an inverted, misleading report. Accuracy dropped to 3.5; CUBE routing fully credited. Completeness/Clarity/Actionability stay high (the structure and SQL are copy-paste-runnable; only two labels need flipping).

### Q2 — High-water-mark (running max revenue per store) — Acc 5 / Comp 5 / Clar 4.75 / Act 5 = **4.9375 STRONG PASS**

`MAX(daily_revenue) OVER (PARTITION BY store_id ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS high_water_mark`. Valid Trino 467; correct high-water-mark — the frame from partition start through the current row yields a monotonic non-decreasing running max per store, single query, no self-join. MAX as a window function via OVER is documented (aggregate-as-window). The `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` frame is the standard running-window frame and the correct explicit choice here. Zero defects.

### Q3 — Dedupe + alphabetically sort array values per row — Acc 5 / Comp 4.75 / Clar 4.75 / Act 4.75 = **4.8125 STRONG PASS**

`array_sort(array_distinct(tags)) AS clean_tags`. Both valid Trino 467; composition correct.
Verified trino.io/docs/467/functions/array.html: `array_distinct(x) → array` *"Remove duplicate values from the array x"*; `array_sort(x) → array` *"Sorts and returns the array x. The elements of x must be orderable. Null elements will be placed at the end of the returned array."* Inner dedup then outer ascending sort = dedup + alphabetically sorted per row. Nulls-last is a harmless, correct nuance. Zero defects.

### Q4 — First product ever per customer carried on every order row — Acc 4.75 / Comp 4.75 / Clar 4.5 / Act 4.75 = **4.6875 STRONG PASS**

`FIRST_VALUE(product_name) OVER (PARTITION BY customer_id ORDER BY order_date ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS first_product_ever`. Valid + correct — the same first-purchased value repeats on every order row for the customer; window-function approach is faster than a correlated per-row subquery (single partitioned pass, no re-scan). Verified window.html: first_value *"Returns the first value of the window."*

Minor accuracy nuance (−0.25): the responder's note that "first_value/last_value need an explicit frame" is **slightly over-stated for FIRST_VALUE specifically**. FIRST_VALUE returns the correct partition-first value under the DEFAULT frame too (default `RANGE UNBOUNDED PRECEDING AND CURRENT ROW` always includes the partition's first row). The full `UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` frame here is harmless and not wrong. The note is strictly true for LAST_VALUE (which DOES need the full frame to avoid returning the current row). Broadly-correct, low-severity over-generalization — not penalized hard since the explicit frame is safe and the warning errs toward caution.

---

## Overall (dimension-average method)
- Accuracy: (3.5 + 5 + 5 + 4.75)/4 = 4.5625
- Completeness: (4.5 + 5 + 4.75 + 4.75)/4 = 4.75
- Clarity: (4.5 + 4.75 + 4.75 + 4.5)/4 = 4.625
- Actionability: (4.0 + 5 + 4.75 + 4.75)/4 = 4.625
- **OVERALL = (4.5625 + 4.75 + 4.625 + 4.625)/4 = 4.640625 → PASS** (overall-average governs label; no per-Q gate; all four per-Q averages ≥ 4.125).

---

## 3. FIX A verdict (iter608 ROLLUP-vs-CUBE)
**RESOLVED.** The both-margins ("subtotals for EACH store AND for EACH payment method AND grand total") question now routes to `GROUP BY CUBE(store, payment_method)` — NOT ROLLUP. All four grouping levels are present and the per-payment-method margin (which ROLLUP would have dropped) is included. The iter609 head-of-block DECIDE-FIRST signpost inserted at the r28 GROUPING block landed: the responder made the operator choice (CUBE) before committing to a worked example. The iter608 wrong-function-choice did NOT recur.

## 4. Q1 GROUPING-label verdict — labels ARE swapped
**WHEN 1 / WHEN 2 are TRANSPOSED** (docs-confirmed, see Q1 above). `WHEN 1` should be 'Store Total' (responder said 'Payment Method Total'); `WHEN 2` should be 'Payment Method Total' (responder said 'Store Total').

**Class diagnosis: routed-but-mis-applied (label mapping) — possibly aggravated by a missing per-level LABEL in the r28 CUBE GROUPING value table.** The responder reached CUBE correctly (FIX A) and stated the bit-meaning rule correctly, but synthesized the integer→label mapping unaided and inverted it (forgot leftmost arg = HIGH bit, so value 1 = rightmost/second column rolled up = a subtotal on the FIRST column). The r28 CUBE GROUPING value table (per state.json r28:509 "value 2 = a-rolled-up-b-present = the category total") encodes the correct mapping numerically; if it does NOT spell out an explicit human LABEL per value, the responder has nothing to copy and re-derives it wrong.

**iter610 teacher action (PRIMARY, additive, reconcile-in-place):** At the r28 CUBE worked example / GROUPING value table, add an explicit per-level LABEL mapping for `GROUPING(a, b)`:
- `GROUPING=0` → both present → DETAIL row
- `GROUPING=1` → **b (rightmost) rolled up, a present → an `a`-subtotal** (e.g. per-store total across all payment methods → label 'Store Total')
- `GROUPING=2` → **a (leftmost) rolled up, b present → a `b`-subtotal** (e.g. per-payment-method total across all stores → label 'Payment Method Total')
- `GROUPING=3` → both rolled up → GRAND TOTAL

Add a one-line PIN: **"The LEFTMOST argument is the HIGH bit. So `GROUPING(a,b)=1` (binary 01) means the RIGHTMOST/second column `b` was rolled up — i.e. the row is a subtotal on `a`, NOT a `b`-total. Do NOT label `WHEN 1` as a `b`-total."** Include a fully-labeled worked CASE example using the store/payment_method shape so the responder copies the correct labels verbatim. Quote trino.io/docs/467/sql/select.html: *"bits are assigned to the argument columns with the rightmost column being the least significant bit"* + *"a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise."*

Source-of-swap test: check whether the r28 GROUPING value table already lists LABELS and whether they are correct. If the table labels value 1 as a "second-column/payment-method total", the TABLE is the defect — correct it in place. If it lists only numeric values with no label column, the gap is the missing label column.

## 5. Other slips / fabrications
- **Q4 framing note slightly over-stated for FIRST_VALUE** (see Q4). LOW severity, not label-affecting. Optional iter610 micro-note at r07 Pattern B3: FIRST_VALUE is correct under the default frame (first row always in-frame); the explicit full frame is mandatory specifically for LAST_VALUE. Do NOT rewrite Pattern B3 — additive clarification only if a future probe shows a real gap.
- **No fabricated features/absences.** CUBE, GROUPING, MAX-OVER, array_distinct, array_sort, FIRST_VALUE all real and (except the Q1 label mapping) correctly used.
- **No `::`-casts** (iter571 PIN intact). **No QUALIFY. No window-fn-in-WHERE. No invalid-clause-placement. No wrong-version pins.** Q1 WHERE uses a valid typed DATE literal.

## iter610 directives summary
- **PRIMARY**: r28 CUBE/GROUPING value table — add explicit per-level integer→LABEL mapping + leftmost-is-HIGH-bit PIN + fully-labeled store/payment_method worked CASE (fixes the WHEN 1/WHEN 2 swap at the responder's exact landing point). Reconcile-in-place; do not rewrite the FIX-A DECIDE-FIRST signpost or the ROLLUP/CUBE locks.
- **RE-PROBE iter610-612**: re-ask a both-margins CUBE question that requires LABELING each subtotal row (per-X total vs per-Y total) to confirm the labels come out correct, not just the numbers.
- **DO NOT**: touch r22 §13.x federation guardrails (4.49944/310, ZERO probe iter609); add `::`-casts; rewrite the iter609 FIX-A signpost / r28 ROLLUP/CUBE worked examples; rewrite r07 Pattern B3 FIRST_VALUE/LAST_VALUE; touch iter534-608 locks; bump training/state.json (already 609).

**WebSearched + verified verbatim today**: trino.io/docs/467/sql/select.html (GROUPING bitmask: rightmost=LSB, leftmost=MSB, bit=1 if column NOT in grouping; CUBE=power set; ROLLUP=subtotals — Q1), trino.io/docs/467/functions/array.html (array_distinct removes dups; array_sort ascending + nulls last — Q3), trino.io/docs/467/functions/window.html (first_value semantics — Q4). Q2 MAX-OVER + Q4 FIRST_VALUE frame specs are standard valid Trino 467.

**OVERALL: 4.640625 STRONG PASS — FIX A TOOK (both-margins now routes to CUBE, iter608 ROLLUP slip resolved); ONE genuine in-the-answer slip = Q1 GROUPING label transposition (WHEN 1/WHEN 2 swapped, Store Total ↔ Payment Method Total, docs-confirmed — query runs, numbers correct, only two text labels inverted); Q2 running-max + Q3 array_sort(array_distinct) + Q4 first_value all clean; iter610 PRIMARY = explicit per-level integer→label mapping + leftmost-HIGH-bit PIN at the r28 GROUPING value table; no fabrications, no `::`-casts; federation row stays 4.49944/310.**
