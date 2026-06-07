# Judge Feedback — iter627 (EXTENDED PHASE)

**Trino pinned: 467.** Docs verified live today (2026-06-07) at trino.io/docs/467 and quoted below. Federation NOT probed this iteration — the 4.49944/310 row is UNCHANGED.

**OVERALL: ~4.97 STRONG PASS** (margin +1.47 above the 3.5 floor). All four answers are docs-verbatim correct with zero defects. Recommend iter628 = **durability NO-OP**.

---

## Q1 — Percent change guarded against zero last-month

**Answer**: `ROUND(100.0 * (this_month_sales - last_month_sales) / NULLIF(last_month_sales, 0), 2) AS pct_change` (+ a `CASE WHEN last_month_sales = 0 THEN NULL` variant).

**Scores — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS**

- VERIFIED trino.io/docs/467/functions/conditional.html: `NULLIF(value1, value2)` "Returns null if `value1` equals `value2`, otherwise returns `value1`." So `NULLIF(last_month_sales, 0)` → NULL when last-month is 0; dividing by NULL yields NULL (SQL propagation), NOT a division-by-zero error. Zero-guard CORRECT.
- `100.0 *` forces decimal/double arithmetic, so the division is NOT integer-truncated (no INTEGER-DIVISION loss). CORRECT.
- The `CASE WHEN last_month_sales = 0 THEN NULL` variant is an equivalent, more explicit guard. Both honest and correct.
- `ROUND(..., 2)` is a sensible 2-dp presentation. Clean.

No defects.

## Q2 — RANK vs DENSE_RANK within category (CRITICAL)

**Answer**: `RANK()` ties share a rank then the next rank SKIPS (1,2,2,4 — "two get rank 1, next gets rank 3"); `DENSE_RANK()` no gap (next gets rank 2). Both `PARTITION BY category ORDER BY units_sold DESC`. Recommended RANK for leaderboards.

**Scores — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS**

- VERIFIED trino.io/docs/467/functions/window.html: `rank()` — "The rank is one plus the number of rows preceding the row that are not peer with the row. **Thus, tie values in the ordering will produce gaps in the sequence.**" → 1,2,2,**4**. `dense_rank()` — "similar to rank(), except that **tie values do not produce gaps in the sequence.**" → 1,2,2,**3**.
- The responder's explanation is **CORRECT and NOT SWAPPED**: RANK leaves gaps (skips), DENSE_RANK does not. The worked phrasing ("two get rank 1, next gets rank 3" for a single top-tie = gap behavior) matches the docs.
- `PARTITION BY category ORDER BY units_sold DESC` correctly ranks within each category, highest units first. Leaderboard recommendation (RANK so a 2-way tie for 1st makes the next product 3rd) is reasonable and conventional.

**Q2 VERDICT (CRITICAL): CORRECT — RANK leaves gaps, DENSE_RANK does not; distinction is NOT swapped.**

## Q3 — Boolean true only on each customer's earliest order

**Answer (PRIMARY)**: `CASE WHEN ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date ASC) = 1 THEN true ELSE false END AS is_first_order` (window fn in SELECT CASE, keeps all rows). **SECONDARY**: subquery with `rn` + outer `WHERE rn = 1`, labeled "optional: only show first orders".

**Scores — Acc 5 / Comp 5 / Clar 5 / Act 4.5 = 4.875 STRONG PASS**

- VERIFIED window.html: `row_number()` "Returns a unique, sequential number for each row, starting with one, according to the ordering of rows within the window partition." With `ORDER BY order_date ASC`, the earliest order per customer gets 1.
- WINDOW-FN-IN-CASE placement: window functions ARE allowed in the SELECT list, including inside a CASE expression in SELECT (window functions run after HAVING / before ORDER BY; they are only disallowed in WHERE/GROUP BY/HAVING). The PRIMARY query is VALID Trino 467 and correctly flags ALL rows — `true` on the first order, `false` on every later order. On-target for the "flag all rows" ask.
- SECONDARY `WHERE rn = 1` filters to only-first-orders (the CASE would then always be true) — slightly off-target for "flag ALL rows," but explicitly LABELED "optional: only show first orders," so it is a minor completeness nuance, NOT an error. Act dinged a hair (4.5) only because a reader skimming to the second block could grab the filtering form; the primary block is unambiguous and correct.

No errors.

## Q4 — Weekend boolean flag (Saturday/Sunday)

**Answer**: `day_of_week(order_date) IN (6, 7) AS is_weekend` (ISO 6=Sat, 7=Sun); also a CASE form.

**Scores — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS**

- VERIFIED trino.io/docs/467/functions/datetime.html: `day_of_week(x)` "Returns the ISO day of the week from `x`. The value ranges from `1` (Monday) to `7` (Sunday)." Return type `bigint`. So 6=Saturday, 7=Sunday → `IN (6, 7)` correctly flags the weekend, no OFF-BY-ONE.
- `<bigint> IN (6, 7)` evaluates to a real boolean, so `... AS is_weekend` is a genuine boolean column. CORRECT.
- CASE form is an equivalent explicit alternative. Clean.

No defects.

---

## Overall computation

- Dimension averages: Acc (5+5+5+5)/4 = 5.00; Comp (5+5+5+5)/4 = 5.00; Clar (5+5+5+5)/4 = 5.00; Act (5+5+4.5+5)/4 = 4.875.
- Overall = (5.00 + 5.00 + 5.00 + 4.875)/4 = **4.96875 ≈ 4.97**.
- Per-Q cross-check: (5.00 + 5.00 + 4.875 + 5.00)/4 = 4.96875 — agrees.
- **Overall avg GOVERNS the label = STRONG PASS** (~4.97). No per-Q gate applied; the only sub-5 was Q3 Act 4.5 (labeled-optional nuance), flagged but not gating.

## Fabrication / slip scan

NONE. No `::`-cast, no QUALIFY, no fabricated function/absence, no invalid-clause-placement, no off-by-one, no type-mismatch, no wrong-function-choice, no integer-division, no RANK/DENSE_RANK swap. NULLIF, RANK, DENSE_RANK, ROW_NUMBER, day_of_week all real Trino 467 functions used correctly. Decimal-forcing `100.0` and ISO day_of_week mapping both correct.

## iter628 directive: DURABILITY NO-OP

All four canonicals routed clean on first probe:
- percent-change NULLIF zero-guard + `100.0` decimal forcing (r07 percent-change block) — clean.
- RANK-vs-DENSE_RANK gaps/no-gaps semantics (r07 §3.1G ROW_NUMBER/RANK/DENSE_RANK lines) — clean, NOT swapped.
- first/earliest-order flag via ROW_NUMBER()=1 inside CASE in SELECT, all-rows form (r23 §3.1G / first-event keyword anchors) — clean.
- weekend boolean via day_of_week IN (6,7) (r07 day_of_week ISO mapping) — clean.

**DO NOT** (preserve locks): touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe this iter); re-edit the NULLIF-guard / RANK-DENSE_RANK / ROW_NUMBER-first-order / day_of_week-weekend landing points (all clean — durable); add `::`-casts (iter571 PIN); EXTRACT(EPOCH) (iter562 ban); QUALIFY; PERCENTILE_CONT (iter611 ban); fabricate dayname()/initcap; touch iter534-626 locks; bump training/state.json (already 627); git commit/push. Push fresh breadth instead of re-probing these four.

**Docs WebFetched/verified today (2026-06-07)**: functions/window.html (rank "tie values ... will produce gaps in the sequence"; dense_rank "tie values do not produce gaps"; row_number "starting with one ... within the window partition"), functions/datetime.html (day_of_week "ISO day of the week ... 1 (Monday) to 7 (Sunday)", bigint), functions/conditional.html (NULLIF "Returns null if value1 equals value2, otherwise returns value1").
