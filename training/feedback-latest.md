# Judge Feedback — iter914 (EXTENDED PHASE, NO-OP durability sweep)

**Overall: 4.875 PASS** (per-Q 4.5 / 5.0 / 5.0 / 5.0 = 19.5/4 = 4.875; margin +1.375; overall average governs, no per-Q veto)
**FEDERATION NOT PROBED** — the 4.49944/310 row is UNCHANGED this iteration.
**Verdict: NO-OP CONFIRMED — all 4 answers dialect-clean. Teacher ZERO edits.**

All facts VERIFIED vs trino.io/docs/467 (datetime / select / aggregate .html) + WebSearch 2026-06-10 (LEFT-JOIN/anti-join predicate placement). iter882 verify-first applied in BOTH directions: no doc-CORRECT claim flagged as a defect; no doc-WRONG claim blessed.

---

## Q1 — avg days signup→first purchase — 4.5

`SELECT AVG(date_diff('day', s.created_at, fo.order_date)) FROM signups s JOIN (SELECT user_id, MIN(order_date) AS order_date FROM orders GROUP BY user_id) fo ON s.user_id = fo.user_id`

CORRECT and runnable.
- VERIFIED datetime.html: `date_diff('day', ts1, ts2)` = `ts2 - ts1` as a **bigint** day count; arg order (unit, from, to) correct so result = first_order − signup.
- Inner `MIN(order_date) GROUP BY user_id` = each user's FIRST order; INNER JOIN to signups keeps only users who have ordered (correct denominator for "signup→first purchase").
- `created_at` is TIMESTAMP, `order_date` is DATE: Trino coerces DATE→TIMESTAMP at **midnight**, `date_diff('day', ...)` valid across the mixed types, AVG over the resulting bigints returns DOUBLE (preserves fractional average). Single-query, no window fn needed.

Deduction = COMPLETENESS NUANCE (NOT a defect): if `created_at` carries an intra-day time component, `date_diff('day', TIMESTAMP, DATE-at-midnight)` measures whole-day calendar boundaries from the signup time to midnight of the order date, which can be off-by-one vs a "calendar-day" intent (e.g. signup 2026-01-01 23:00 → order 2026-01-02 09:00 yields 0 not 1). Reasonable either way and matches the day-aware pin; responder did not flag the time-component caveat. Acc 5.0 / Comp 4.0 / Clar 4.5 / Act 4.5 = 4.5.

## Q2 — count tickets opened+resolved same day — 5.0

`COUNT(*) ... WHERE date_trunc('day', opened_at) = date_trunc('day', resolved_at)` (+ per-day GROUP BY variant).

CORRECT.
- VERIFIED datetime.html: `date_trunc('day', timestamp)` truncates to midnight (time portion → 00:00:00.000); comparing two truncated timestamps = same calendar day test.
- `CAST(x AS date)` equality would be an equally-valid alternative — both fine; responder's date_trunc form is correct as written. Per-day GROUP BY variant valid.
Acc / Comp / Clar / Act 5.0.

## Q3 — customers whose 2025 spend ≥ 2× 2024 spend — 5.0

One-pass YoY pivot, no join:
`SUM(order_value) FILTER (WHERE year(order_date)=2024) AS revenue_2024`, `SUM(...) FILTER (WHERE year(order_date)=2025) AS revenue_2025`, ratio `SUM(...2025) * 1.0 / NULLIF(SUM(...2024), 0)`, `GROUP BY customer_id`, `HAVING (repeated full ratio expression) >= 2.0`.

CORRECT.
- VERIFIED aggregate.html: `FILTER (WHERE condition)` is "supported for all aggregate functions" — valid on both SUMs; per-aggregate scoping gives a one-query YoY pivot with no self-join/UNION.
- VERIFIED datetime.html: `year(order_date)` valid (returns bigint).
- `* 1.0` forces DECIMAL division (avoids integer truncation); `NULLIF(SUM(...2024), 0)` guards DIVISION_BY_ZERO on customers with no 2024 spend (returns NULL → HAVING comparison NULL → row excluded, correct).
- VERIFIED select.html: HAVING **cannot** reference a SELECT output alias — responder correctly **repeated the full ratio expression** in HAVING rather than referencing `yoy_ratio`. This is exactly right and a positive durability signal (the HAVING-alias trap was avoided).
Acc / Comp / Clar / Act 5.0.

## Q4 — products with zero 'West' sales, KEEP products that sold elsewhere — 5.0 (KEY CHECK)

**EXPLICIT VERDICT: the responder placed the region predicate CORRECTLY — in the ON clause (Approach A) and inside the correlated subquery (Approach B), NOT in the outer WHERE. The anti-join predicate-placement trap was AVOIDED. Positive durability signal.**

- Approach A: `LEFT JOIN order_line_items oli ON oli.product_id = p.product_id AND oli.region = 'West' WHERE oli.product_id IS NULL`. VERIFIED (select.html + WebSearch 2026-06-10): a right-side predicate (`oli.region='West'`) in the **ON** clause filters which right rows are eligible to match, but left rows that find no eligible match are **still preserved with NULLs**. So a product that sold only in other regions finds no West match → its joined row is all-NULL → kept by `WHERE oli.product_id IS NULL`. Correctly returns "products with zero West sales" while preserving other-region products.
- Approach B: `NOT EXISTS (SELECT 1 FROM order_line_items oli WHERE oli.product_id = p.product_id AND oli.region = 'West')`. Region filter scoped **inside** the correlated subquery; NOT EXISTS is true iff the product has zero West line items, regardless of sales elsewhere. Correct decorrelatable anti-join form.
- The responder explicitly AVOIDED putting `region='West'` in the outer WHERE, which would have demoted the LEFT JOIN to an effective inner join and wrongly dropped products selling only in other regions — exactly the trap the question warned about ("without accidentally filtering out products that sold in other regions").
Acc / Comp / Clar / Act 5.0 → **Q4 = 5.0**.

---

## Scope / action

- **NO defect, NO dialect error, NO findable-but-missing gap surfaced.** All four are correct Trino 467.
- **iter915 = DEFAULT NO-OP.** Teacher ZERO edits.
- Do NOT add any "wrong" card. Do NOT mark wrong: Q1 date_diff('day')+MIN-first-order INNER JOIN, Q2 date_trunc('day') same-day equality, Q3 FILTER-aggregate YoY pivot + NULLIF div-guard + HAVING-repeated-expression, Q4 ON-clause/NOT-EXISTS region-scoped anti-join — all correct.
- Q1 TIMESTAMP-vs-DATE day-boundary off-by-one = responder-side completeness nuance, NOT a resource gap (day-aware date_diff pinned). Re-probe-don't-churn; do NOT touch the date_diff / date-coercion pins.
- Optional micro re-probe (NO pin touch): "avg days signup→first order" where created_at carries a non-midnight time — confirm whether the responder reaches for `date_diff('day', CAST(created_at AS date), order_date)` when calendar-day intent matters. SKIP if it duplicates a date-window/coercion pin.
- Federation (4.49944/310) remains the only un-passed row — bulletproofed angles only.
- Do NOT touch any iter534-913 pin. PIN 467. NO federation edits. **DO NOT bump training/state.json** (already passed; overall 4.875 PASS holds).
