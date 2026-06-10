# Judge Feedback — iter900 (NO-OP durability sweep)

**Overall: 4.98 STRONG PASS** (per-Q 5.00 / 5.00 / 4.9375 / 5.00 = 19.9375 / 4 = 4.984; margin +1.48; overall average governs — no per-Q veto). All 4 answers dialect-clean. **FEDERATION NOT PROBED** — the 4.49944/310 row is UNCHANGED.

**Verdict: DEFAULT NO-OP.** Zero defects, zero findable-but-missing gaps. Teacher makes ZERO edits. Do NOT bump training/state.json (already passed).

All dialect facts VERIFIED vs trino.io/docs/467 (aggregate.html, datetime.html, types.html, comparison.html) + git-tag 467 source (RowType orderability) + my pinned date_diff day-aware reference, on 2026-06-10. iter882 verify-first applied: every structurally-suspicious claim (Q1 ROW ordering key, Q3 day-aware semantics) was VERIFIED CORRECT before judgment — none flagged.

---

## Per-question

**Q1 — 5.00. Most expensive product NAME per category (MAX + companion name), with tie-break.**
`MAX(price) AS max_price, max_by(product_name, price) AS product_at_max_price ... GROUP BY category`; tie-break `max_by(product_name, ROW(price, product_name))`.
- VERIFIED aggregate.html: `max_by(x, y)` "Returns the value of `x` associated with the maximum value of `y` over all input values." So `max_by(product_name, price)` returns the name at the max price — exactly the companion-value idiom MAX(price) alone cannot give. CORRECT.
- Tie-break `max_by(product_name, ROW(price, product_name))`: VERIFIED a ROW IS orderable in Trino 467 when all its fields are orderable (confirmed vs git-tag 467 RowType — ROW comparison is field-by-field lexicographic; the only caveat is ROW comparison errors on NULL fields, irrelevant here with non-NULL price/name). So the ordering key breaks ties by price first, then product_name — a valid, idiomatic deterministic tie-break. CORRECT.
- Docs show only scalar `y` examples and do NOT explicitly state ROW-as-ordering-key, but the orderability rule makes it valid. This is a (correct) advanced flourish, not a defect.

**Q2 — 5.00. Last-30-days vs prior-30-days order counts side by side, one query.**
`count_if(order_date >= CURRENT_DATE - INTERVAL '30' DAY) AS orders_last_30_days, count_if(order_date < CURRENT_DATE - INTERVAL '30' DAY AND order_date >= CURRENT_DATE - INTERVAL '60' DAY) AS orders_prior_30_days FROM orders` + SUM(CASE...) equivalent.
- VERIFIED aggregate.html: `count_if(x) -> bigint` "Returns the number of TRUE input values… equivalent to `count(CASE WHEN x THEN 1 END)`." Two `count_if` expressions in one SELECT with no GROUP BY produce two scalar counts side by side in one row. CORRECT.
- VERIFIED datetime.html: `date '2012-08-08' - interval '2' day` is valid date arithmetic, so `CURRENT_DATE - INTERVAL '30' DAY` is valid. The prior-30 window is correctly bounded `[CURRENT_DATE-60, CURRENT_DATE-30)` (half-open, no overlap with last-30). CORRECT.
- SUM(CASE WHEN cond THEN 1 ELSE 0 END) equivalent is a correct, more-portable alternative. Good completeness.

**Q3 — 4.9375 (Completeness ~4.75). Days a subscription was active (start to end).**
`date_diff('day', start_date, end_date) AS days_active`; explained day-aware/complete-units, `date_diff('day', same, same)=0`, +1 day → 1.
- VERIFIED datetime.html: `date_diff(unit, timestamp1, timestamp2) -> bigint` "Returns timestamp2 - timestamp1 expressed in terms of unit" (doc example `date_diff('second', 2020-03-01, 2020-03-02)=86400`, `date_diff('day', DATE '2020-03-01', DATE '2020-03-02')=1`). Argument order `(unit, from, to)` = to − from. CORRECT.
- Day-aware/complete-units for the 'day' unit (drops fractional) is consistent with my pinned 467 reference (date_diff month/year/day = complete-units, day-boundary aware). The responder's "Jan 15 2am → Feb 14 3pm = 30 (complete days)" is consistent: Jan 15 → Feb 14 is 30 calendar days, and the +13h intra-day gain neither adds nor subtracts a complete day. For pure DATE args it's the exact calendar-day difference. CORRECT.
- **Minor completeness nuance (NOT a defect, weighed proportionally):** "days active" is ambiguous between exclusive (end − start, what date_diff gives) and inclusive (+1, counting both endpoints). The responder used the exclusive form without flagging the inclusive alternative. This is a single unstated nuance on an otherwise fully-correct answer → Completeness ~4.75, no accuracy deduction. Not findability-actionable; do NOT churn.

**Q4 — 5.00. Total quantity per product counting only line items > $10.**
`SUM(quantity) FILTER (WHERE line_value > 10) AS total_quantity_above_10 ... GROUP BY product_id` + SUM(CASE WHEN line_value>10 THEN quantity ELSE 0 END) + multiple FILTER aggregates.
- VERIFIED aggregate.html: "The FILTER keyword can be used to remove rows from aggregation processing with a condition expressed using a WHERE clause. This is evaluated for each row before it is used in the aggregation and is supported for all aggregate functions." So `SUM(quantity) FILTER (WHERE line_value > 10)` is valid and applies PER-aggregate. CORRECT.
- SUM(CASE ... ELSE 0 END) equivalent correct. Multiple FILTER aggregates with the same/different conditions in one SELECT is a correct, idiomatic showcase (each FILTER scoped to its own aggregate). Excellent completeness.

---

## Teacher directives for iter901

- **DEFAULT NO-OP.** Do NOT add any "wrong" card for Q1–Q4. Every form is dialect-correct.
- Do NOT mark `max_by(v, ROW(k1, k2))` wrong — Trino 467 ROW IS orderable (lexicographic, all-fields-orderable), so it is a valid tie-break key.
- Do NOT churn the max_by companion-value, count_if-rate-window, date_diff day-aware, or FILTER-aggregate cards (all confirmed correct).
- OPTIONAL micro-anchor ONLY if it touches NO pin: a 1-line "days active: date_diff gives exclusive end−start; +1 for inclusive both-endpoints" note near a date_diff day-count card. SKIP if it churns/duplicates a date_diff pin. This is the only (tiny) completeness seam observed.
- Re-probe fresh adjacents next sweep. **Federation (4.49944/310) is the only un-passed row** — probe only bulletproofed federation angles when probed at all.
- Do NOT touch any iter534–899 pin. PIN Trino 467. NO federation edits.
- **DO NOT bump training/state.json** (already passed; overall 4.98 PASS holds).
