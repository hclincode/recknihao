# Judge Feedback — Iter 938 (EXTENDED PHASE, DEFAULT NO-OP durability sweep)

**Overall: 4.9375 PASS** (per-Q 5.00 / 5.00 / 4.875 / 4.875 = 19.75/4 = 4.9375; margin +1.4375 above 3.5 threshold; OVERALL AVERAGE governs, no per-Q veto)

FEDERATION NOT PROBED (4.49944/310 row UNCHANGED). All dialect verified vs trino.io/docs/467 (functions/window.html, functions/aggregate.html, functions/datetime.html, functions/comparison.html, sql/select.html) + WebSearch 2026-06-10 — NOT against resources/; iter882 verify-BOTH-directions applied throughout.

Teacher made ZERO resource edits this iteration (durability sweep). All four answers are dialect-clean.

---

## Per-question scores

### Q1 (oldest unfulfilled order per warehouse): 5.00
Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0

`SELECT warehouse_id, order_id, created_at FROM (SELECT ..., ROW_NUMBER() OVER (PARTITION BY warehouse_id ORDER BY created_at ASC NULLS LAST) AS rn FROM orders WHERE fulfilled_at IS NULL) WHERE rn=1` — fully correct top-1-per-group idiom in Trino 467.

- **ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ... ASC NULLS LAST)** valid (window.html confirms row_number + PARTITION/ORDER syntax; NULLS LAST is the documented Trino 467 default for ORDER BY regardless of direction per standing pin, so explicit `NULLS LAST` is harmless/redundant but not wrong — pedagogically useful to be explicit).
- **Subquery + outer `WHERE rn=1`** is the canonical workaround for "no QUALIFY in 467" (confirmed: SELECT spec has no QUALIFY clause, window fn not allowed in WHERE) — responder explicitly explains this.
- **`WHERE fulfilled_at IS NULL` pre-window** correctly restricts the partition before ranking — earliest unshipped order per warehouse semantics exactly.
- One row per warehouse guaranteed by ROW_NUMBER ties=1 (the tiebreaker nuance for equal created_at is mentioned implicitly via "earliest").

No defect.

---

### Q2 (% orders returned in last 90 days): 5.00
Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0

`SELECT ROUND(100.0 * COUNT(DISTINCT o.order_id) FILTER (WHERE r.order_id IS NOT NULL) / COUNT(DISTINCT o.order_id), 2) ... FROM orders o LEFT JOIN returns r ON o.order_id=r.order_id WHERE o.created_at >= current_date - INTERVAL '90' DAY` — fully correct.

- **`COUNT(DISTINCT x) FILTER (WHERE ...)`** valid per aggregate.html verbatim "FILTER ... supported for all aggregate functions" (covers COUNT(DISTINCT) variant).
- **LEFT JOIN fan-out** correctly handled: a returned order can have multiple `returns` rows, which would inflate `COUNT(*)`, but `COUNT(DISTINCT o.order_id)` collapses to one-per-order on both denominator and FILTER numerator.
- **`current_date - INTERVAL '90' DAY`** valid (DAY is a documented INTERVAL qualifier per types.html: YEAR/MONTH/DAY/HOUR/MINUTE/SECOND — pin from iter932/933).
- **`100.0 *`** load-bearing decimal promotion (avoids BIGINT/BIGINT integer truncation; standing Division pin).
- **CTE-alt** `COUNT(DISTINCT o.order_id) AS total, COUNT(DISTINCT r.order_id) AS returned, ROUND(100.0 * returned/total, 2)` is logically equivalent (r.order_id is NULL for unmatched outer rows → COUNT(DISTINCT) skips NULL → same numerator); responder correctly notes both forms are sound.
- Responder explicitly warns "after LEFT JOIN use COUNT(right_col) not COUNT(*)" — that's the canonical anti-fan-out trap and is correctly framed.

No defect.

---

### Q3 (products with declining MoM sales): 4.875
Acc 5.0 / Comp 4.5 / Clar 5.0 / Act 5.0

CTE-1 monthly_revenue (`DATE_TRUNC('month', order_date)` + `SUM(quantity)` GROUP BY product_id+month), CTE-2 with `LAG(total_qty) OVER (PARTITION BY product_id ORDER BY month)`, final filter `WHERE prev_month_qty IS NOT NULL AND total_qty < prev_month_qty` — fully dialect-correct.

- **DATE_TRUNC('month', order_date)** valid (datetime.html; pin).
- **LAG(total_qty) OVER (PARTITION BY product_id ORDER BY month)** valid (window.html: default offset=1 returns prior row in partition, NULL when no prior row exists).
- **Filtering on LAG alias `prev_month_qty`** correctly requires the CTE/subquery wrap (window fn output not allowed in WHERE of same level) — responder structures this correctly.
- **`WHERE prev_month_qty IS NOT NULL`** excludes the first month per product (no prior month).
- **`total_qty < prev_month_qty`** is the decline test; the `<prev*0.95` variant for "decline by >=5%" is a useful adjacent.

**Minor completeness nuance (-0.5 on Comp):** LAG default offset=1 returns the prior ROW in the partition — which is the prior calendar month ONLY if every month is present. If a product skips a month (no sales in February, sales return in March), LAG of March yields January, not February-NULL. That's a defensible MoM interpretation (comparing adjacent NON-EMPTY months) but the answer doesn't flag the gap-month nuance for the engineer. For strict "compare to the literal previous calendar month even when absent" semantics, a calendar-spine LEFT JOIN or a `LAG ... ON month = prev_month + INTERVAL '1' MONTH` join would be needed. Not a dialect error — a teaching nuance worth a small Comp ding.

---

### Q4 (avg days from signup to first purchase): 4.875
Acc 5.0 / Comp 5.0 / Clar 4.5 / Act 5.0

CTE `customer_first_purchase` with `DATE_DIFF('day', c.created_at, MIN(o.order_date))` + `GROUP BY c.customer_id, c.created_at` + INNER JOIN, outer `AVG(days_to_first_purchase)` — fully dialect-correct.

**Verified BOTH directions:**

- **(a) `date_diff('day', GROUP-BY-col, MIN(aggregate-col))` mixing GROUP BY column and aggregate in ONE scalar expression is VALID** in Trino 467. The select.html rule "all output expressions must be either aggregate functions or columns present in the GROUP BY clause" permits GROUP BY column REFERENCES nested inside scalar functions alongside aggregates (both resolve at aggregate level). Confirmed by docs WebFetch 2026-06-10. Not an error.
- **(b) date_diff arg order**: signature is `date_diff(unit, x1, x2) -> x2 - x1`, so `date_diff('day', signup, MIN(order_date))` is positive when order >= signup (correct semantics; responder explicitly explains the arg order).
- **(c) Mixed TIMESTAMP / DATE types in date_diff**: Trino 467 HAS implicit DATE->TIMESTAMP coercion (standing pin `reference_trino_timestamp_tz_coercion.md` — TypeCoercion.java in 467 source confirms; comparison.html shows `DATE '...' < TIMESTAMP '...'` works without CAST). So `date_diff('day', timestamp_col, date_col)` runs without explicit CAST. The responder's "CAST if needed" caveat is **unnecessary** — slight clarity imprecision (-0.5 on Clar) but **NOT a dialect error** (the CAST is harmless / would not break the query; the responder didn't say "this fails without CAST"). The caveat hedges rather than misleads.
- **(d) AVG over derived column + APPROX_PERCENTILE(...,0.5) median variant**: both valid (aggregate.html confirms AVG ignores NULL, approx_percentile scalar form documented; no median() builtin in 467 — variant is the right tool, standing pin).
- **INNER JOIN keeps only converters** — responder correctly contrasts this with LEFT JOIN for conversion-rate-style questions; useful guidance.

Minor: responder's framing "date_diff MUST be computed inside the CTE — column-scope discipline rule" is loose (you COULD compute MIN in the CTE and date_diff outside; both are valid) but not wrong as a recommended pattern. Folded into the Clar ding above.

---

## Scope verdict

- **NO RESOURCE DEFECT.** All four answers use canonical patterns already taught.
- **NO RESPONDER SLIP** on taught content. The only sub-perfect items are (Q3) a defensible MoM-with-gap-months interpretation nuance and (Q4) an unnecessary CAST caveat — neither breaks the query.
- **NO FINDABLE GAP.** Q3 gap-month nuance is a teaching subtlety not a missing card; Q4 mixed-type-coercion is taught via the TIMESTAMP-TZ + comparison pins.

---

## iter939 plan

**DEFAULT NO-OP** — all 4 dialect-clean, zero new defects. Teacher should make ZERO resource edits.

Optional re-probes (NO pin touch, SKIP if duplicative):
- MoM with explicit gap months (Feb missing, Jan->Mar) to test whether responder reaches for calendar-spine join vs LAG-on-adjacent-present-rows.
- date_diff with TIMESTAMP-vs-DATE crossover to confirm responder doesn't introduce a spurious "must CAST" hard-error claim.
- Per-warehouse oldest unfulfilled with deterministic tiebreaker (warehouse_id, created_at, order_id) — does responder add the tiebreaker?

Federation (4.49944/310) only un-passed row — bulletproofed angles only if probed.

PRESERVE full iter534-937 pin inventory; NO federation edits. PIN 467. DO NOT bump training/state.json (already 938; passed=true preserved; overall 4.9375 PASS holds).
