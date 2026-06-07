# Judge Feedback — iter628 (EXTENDED PHASE)

**Trino pinned: 467.** Docs verified live today (2026-06-07) at trino.io/docs/467 and quoted below. Federation NOT probed this iteration — the 4.49944/310 row is UNCHANGED.

**OVERALL: 5.00 STRONG PASS** (margin +1.50 above the 3.5 floor). All four answers are docs-verbatim correct with zero defects. The Q4 ROWS-vs-RANGE default-frame lock applied cleanly. Recommend iter629 = **durability NO-OP**.

---

## Q1 — Absolute difference (always-positive miss)

**Answer**: `ABS(forecasted_units - actual_units) AS forecast_miss`.

**Scores — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS**

- VERIFIED trino.io/docs/467/functions/math.html: `abs(x)` "Returns the absolute value of `x`." Accepts any numeric type, returns the same type. So `ABS(forecasted_units - actual_units)` yields the magnitude of the gap regardless of sign — exactly the "always positive miss" requirement. CORRECT.
- The subtraction inside ABS is evaluated first (standard precedence), so the sign of `forecast - actual` is discarded. No off-by-one, no type issue (both columns numeric → numeric result).

No defects.

## Q2 — Add 48 hours to a timestamp for an SLA deadline

**Answer**: `date_add('hour', 48, created_at) AS sla_deadline`. Noted the unit is a quoted string and the value sits OUTSIDE the quotes; flagged that this is NOT the Postgres `INTERVAL '48 hours'` form.

**Scores — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS**

- VERIFIED trino.io/docs/467/functions/datetime.html: `date_add(unit, value, timestamp)` "Adds an interval `value` of type `unit` to `timestamp`. Subtraction can be performed by using a negative value." So `date_add('hour', 48, created_at)` advances `created_at` by 48 hours (two days). Signature order (unit, value, ts) CORRECT; `'hour'` is a valid unit string; `48` is the integer value in the correct slot. CORRECT.
- The note about the interval form is ACCURATE: Trino's literal form is `INTERVAL '48' HOUR` — the numeric magnitude is inside the string and the **unit is a trailing keyword**, NOT the Postgres `INTERVAL '48 hours'` (unit-inside-the-string, plural). Docs confirm the operator example `time '01:00' + interval '3' hour` → `04:00:00.000` (value-in-quotes, unit-as-keyword). So `created_at + INTERVAL '48' HOUR` would also be correct; the responder's `date_add` form is the cleaner, equally-valid choice and the dialect caveat is right.

No defects.

## Q3 — Percentile rank by lifetime spend (top 5% / 90th percentile)

**Answer**: `PERCENT_RANK() OVER (ORDER BY total_lifetime_spend)` over a `GROUP BY customer_id` subquery that computes `SUM(amount) AS total_lifetime_spend`. Noted 0.0 = lowest, 1.0 = highest, multiply by 100 for a percentile number.

**Scores — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS**

- VERIFIED trino.io/docs/467/functions/window.html: `percent_rank()` "Returns the percentage ranking of a value in group of values. The result is `(r - 1) / (n - 1)`" where r is the rank. So the lowest-spend customer (r=1) → 0.0 and the highest (r=n) → 1.0. The responder's 0.0=lowest / 1.0=highest mapping is CORRECT.
- The **ascending** `ORDER BY total_lifetime_spend` means the top spender lands near 1.0, so "top 5%" = `percent_rank() >= 0.95` and "90th percentile" = `>= 0.90` — consistent with the responder's framing ("top" = near 1.0). The `*100` to read it as a 0–100 percentile is sensible presentation. Framing is adequate and internally consistent.
- The `GROUP BY customer_id` → `SUM(amount)` subquery correctly produces one lifetime-spend row per customer BEFORE the window ranks them, so each customer is ranked once (not once per order). Structure CORRECT.
- `cume_dist()` (docs: "number of rows preceding or peer with the row ... divided by total rows") is a defensible alternative for "percentile," but `percent_rank()` is a valid and standard reading of "percentile rank." No defect for the choice.

No defects.

## Q4 — Running per-customer order counter (1,2,3 in date order) — CRITICAL window-frame check

**Answer**: `COUNT(*) OVER (PARTITION BY customer_id ORDER BY order_date, order_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS order_number`. Explained that the explicit ROWS frame is critical (the default differs) and that `order_id` is a tiebreaker for determinism.

**Scores — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS**

**Q4 VERDICT (CRITICAL): FULLY CORRECT — ROWS-vs-RANGE default-frame lock applied.**

- VERIFIED trino.io/docs/467/functions/window.html: "All Aggregate functions can be used as window functions by adding the `OVER` clause." So `COUNT(*) OVER (...)` is valid. With the explicit frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, the frame for each row contains itself plus every preceding row in the partition's `order_date, order_id` order → COUNT(*) returns 1, 2, 3, ... row by row. CORRECT running counter.
- VERIFIED trino.io/docs/467/sql/select.html (window frames): "If the frame is not specified, it defaults to `RANGE UNBOUNDED PRECEDING`, which is the same as `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`" and "This frame contains all rows from the start of the partition up to **the last peer of the current row**." This is the lock: under the DEFAULT RANGE frame, two orders sharing the same ORDER BY key (e.g., same `order_date` with no tiebreaker) are PEERS, so both rows' frames extend to the last peer and they receive the SAME count (the max for that key) — giving e.g. 2, 2 instead of 1, 2. The responder's explanation that "the default frame differs" and that the explicit ROWS frame is critical is ACCURATE and matches the docs verbatim.
- The `order_id` tiebreaker makes the ordering total (no two rows are peers), so even under a RANGE frame the result would be deterministic; combined with the explicit ROWS frame, the 1,2,3 row-by-row counter is fully correct and deterministic. Tiebreaker reasoning CORRECT.
- ALTERNATIVE noted for completeness: `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date, order_id)` always returns 1,2,3 unique regardless of frame (frame is ignored for row_number). The responder's `COUNT(*) OVER ... ROWS` is equivalent here given the total ordering — a correct and valid choice, not a defect.

No defects.

---

## Overall

Per-dimension averages: Acc (5+5+5+5)/4 = 5.00, Comp 5.00, Clar 5.00, Act 5.00 → (5.00+5.00+5.00+5.00)/4 = **5.00**. Per-question cross-check: (5.00+5.00+5.00+5.00)/4 = 5.00 — agree. Overall-average GOVERNS the label = **STRONG PASS**; no per-Q gate triggered.

## Slip diagnosis

**No slips, no fabrications.** No `::`-cast, no QUALIFY, no fabricated function/absence, no invalid-clause-placement, no off-by-one (Q4 counter starts at 1, frame inclusive of current row), no type-mismatch, no wrong-function-choice (Q3 percent_rank valid; Q4 COUNT(*) OVER ROWS valid), no WINDOW-FRAME-MISUSE (Q4 explicit ROWS frame + tiebreaker is exactly right and the default-RANGE-difference explanation is accurate).

## iter629 directive: DURABILITY NO-OP

All four canonicals routed clean first-probe: `abs()` difference, `date_add('hour', n, ts)` + INTERVAL '48' HOUR dialect caveat, `percent_rank()` ascending-percentile, and the `COUNT(*) OVER ... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` running counter with ROWS-vs-RANGE default-frame explanation. Push fresh breadth next iter.

**DO NOT**: touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter628); re-edit the abs / date_add / percent_rank / Pattern-A-cumulative ROWS-frame landing points (all clean); add `::`-casts (iter571 PIN); EXTRACT(EPOCH) (iter562 ban); QUALIFY; PERCENTILE_CONT (iter611 ban); fabricate dayname()/initcap; touch iter534-627 locks; bump training/state.json (already 628); git commit/push.

WebFetched/verified today: functions/math.html (`abs(x)` "Returns the absolute value of x" — Q1), functions/datetime.html (`date_add(unit, value, timestamp)` "Adds an interval value of type unit" + `interval '3' hour` operator form — Q2), functions/window.html (`percent_rank()` "(r - 1) / (n - 1)" + "All Aggregate functions can be used as window functions by adding the OVER clause" — Q3/Q4), sql/select.html (default frame "RANGE UNBOUNDED PRECEDING ... up to the last peer of the current row" — Q4 ROWS-vs-RANGE lock).

**OVERALL: 5.00 STRONG PASS — Q1 ABS difference, Q2 date_add('hour',48,ts) + INTERVAL '48' HOUR dialect caveat, Q3 percent_rank ascending-percentile, Q4 COUNT(*) OVER ROWS running counter (ROWS-vs-RANGE default-frame lock applied, order_id tiebreaker correct) all docs-verbatim zero-defect; iter629 = durability NO-OP; federation row stays 4.49944/310.**
