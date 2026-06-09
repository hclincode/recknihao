# Judge Feedback — iter787 (EXTENDED PHASE, FIX-A re-probe)

**Designation**: ADDITIVE FINDABILITY FIX-A re-probe. iter786 Q3 used a non-existent `LEFT()` and missed `rpad`; iter787 added a fixed-width-STRING-padding `rpad`/`lpad` canonical at r23 §3.1A with no-LEFT and `%-20s`-doesn't-truncate defangs + keyword anchors. Q1 re-probes the fix; Q2–Q4 fresh.

All four claims verified against trino.io/docs/467 (string.html, datetime.html, window.html, conditional.html) via WebFetch on 2026-06-09.

---

## Per-question scores

### Q1 — Fixed-width pad (THE FIX RE-PROBE): force customer_reference to EXACTLY 15 chars, right-pad with spaces if short, truncate at 15 if long, single step
- Answer: `rpad(customer_reference, 15, ' ')`
- VERIFIED trino.io/docs/467/functions/string.html: "Right pads `string` to `size` characters with `padstring`. If `size` is less than the length of `string`, the result is truncated to `size` characters." → `rpad(customer_reference, 15, ' ')` pads short values to 15 with spaces AND truncates long values at 15 — EXACTLY the single-step fixed-width-pad answer.
- THE FIX WORKED: responder LED with `rpad` (did NOT use `LEFT()`, did NOT use non-truncating `format('%-15s')`) and cited the new r23 §3.1A "pad a STRING to FIXED WIDTH" sub-canonical. The iter786 defects (non-existent LEFT, missed rpad truncation) did NOT recur.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

### Q2 — Sequential row number on a top-50-by-revenue result, in result order
- Answer: `ROW_NUMBER() OVER (ORDER BY revenue DESC) AS position`
- VERIFIED trino.io/docs/467/functions/window.html: row_number() "returns a unique, sequential number for each row, starting with one, according to the ordering of rows within the window partition." No PARTITION BY → whole result is one partition → 1,2,3 sequence. ORDER BY revenue DESC supplies deterministic ordering. Tie-break-arbitrary caveat correctly stated.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

### Q3 — Extract year, month number, hour-of-day from order_timestamp as separate columns
- Answer: `year(order_timestamp)`, `month(order_timestamp) AS month_num`, `hour(order_timestamp) AS hour_of_day`; EXTRACT(... FROM ...) noted equivalent
- VERIFIED trino.io/docs/467/functions/datetime.html: year(x), month(x), hour(x) all exist returning bigint; hour ranges 0–23; `EXTRACT(YEAR FROM ts)` SQL-standard equivalent confirmed. Scalar functions, no string parsing — correct and idiomatic.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

### Q4 — best_phone = first non-null of mobile_phone, home_phone, work_phone (priority order)
- Answer: `COALESCE(mobile_phone, home_phone, work_phone) AS best_phone`
- VERIFIED trino.io/docs/467/functions/conditional.html: COALESCE returns "the first non-null value in the argument list"; NULL if all null. Priority order preserved left-to-right. Standing COALESCE pin holds.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

---

## Overall

- Per-Q avgs: 5.00 / 5.00 / 5.00 / 5.00 = 20.00 / 4
- **Overall avg = 5.00 — STRONG PASS** (margin +1.50 above 3.5 floor; overall avg governs, no per-Q veto)
- Federation NOT probed this iteration.

## Verdicts

**(a) Is fixed-width-pad CLOSED?** YES — CLOSED. Q1 is the 1st post-fix datapoint and it is clean: responder led with `rpad(col, 15, ' ')`, correctly relied on rpad's documented truncation-when-size<length, avoided both prior failure modes (no `LEFT()`, no non-truncating `format('%-15s')`), and cited the new r23 §3.1A card. The iter787 FINDABILITY FIX-A worked on first re-probe. Recommend a 2nd-angle re-probe (e.g. left-pad a numeric ID to fixed width with zeros via `lpad(CAST(id AS varchar), 8, '0')`, or a "pad/truncate to exactly N" framing) to drive it to BULLETPROOFED.

**(b) iter788 designation:** DEFAULT NO-OP / durability-breadth. No open defect surfaced — all 4 answers clean and docs-verified. Recommended for iter788: one fixed-width-pad 2nd-angle re-probe (to bulletproof) plus 2–3 fresh adjacent picks. Do NOT churn the new r23 §3.1A card or any bulletproofed canonical (iter693 lesson). FIX-A only if a defect surfaces.

## Teacher notes
- No resource edits needed. The r23 §3.1A fixed-width-pad add is findable and was correctly used; keep its no-LEFT and `%-Ns`-doesn't-truncate defangs intact and inline-marked un-copyable.
- Standing pins all hold: rpad/lpad-fixed-width-pad-truncates / no-LEFT-use-substr-or-rpad / ROW_NUMBER-no-partition-sequential / year-month-hour-EXTRACT / COALESCE-first-non-null. Full iter534–786 inventory remains in force.

DO NOT bump training/state.json (already 787).
