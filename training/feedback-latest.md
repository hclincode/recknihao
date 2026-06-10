# Judge Feedback — iter921 (NO-OP durability sweep: 4 fresh adjacents; approx_distinct/LAG/ROW_NUMBER/FILTER coverage)

**Overall: 4.84 PASS** (Q1 5.00 / Q2 5.00 / Q3 4.375 / Q4 5.00 = 19.375 / 4 = 4.844; margin +1.344). OVERALL AVERAGE governs — no per-Q veto.

All dialect claims verified vs trino.io/docs/467 (functions/aggregate.html, functions/window.html, sql/select.html, language/types.html) + git-tag/issue WebSearch, 2026-06-10. Trino 467 PINNED. Teacher made ZERO edits expected — pure durability sweep.

**iter921 = DEFAULT NO-OP — no source-verified findable-but-missing gap; no dialect defect.**

## ★ DIRECTED VERIFICATIONS (both explicitly settled) ★

**(1) Q2 approx_distinct ~2.3% standard error = DOC-CORRECT (NOT a fabrication).** VERIFIED verbatim against trino.io/docs/467 functions/aggregate.html: approx_distinct "should produce a standard error of 2.3%, which is the standard deviation of the (approximately normal) error distribution over all possible sets." The 2.3% figure is documented for **approx_distinct specifically** (consistent with the standing pin: it is NOT an approx_percentile figure). The responder's note is accurate. The 10x–50x speedup framing is a reasonable order-of-magnitude perf claim for HyperLogLog vs exact COUNT(DISTINCT) on high-cardinality columns. CONFIRMED CORRECT.

**(2) Q3 LAG technique CORRECT, but the COUNT(DISTINCT customer_id) aggregation shape is a PARTIAL INTERPRETATION MISMATCH (completeness nuance, NOT a dialect defect).** VERIFIED functions/window.html: LAG(status) OVER (PARTITION BY customer_id ORDER BY payment_date) is valid; it returns the prior payment's status per customer, and the outer `WHERE status='failed' AND prev_status='failed'` correctly flags adjacent failed→failed pairs. The LAG-based consecutive-failure DETECTION is the right tool and dialect-clean. HOWEVER the question asked "for each customer, HOW MANY TIMES they had 2+ consecutive failed payments" (a PER-CUSTOMER count of occurrences), and the responder returned `COUNT(DISTINCT customer_id)` = a SINGLE TOTAL of customers with at least one back-to-back failure — not a per-customer breakdown. "Count customers with consecutive failures" is a defensible reading, and the core technique is correct, so this is a proportional completeness deduction, NOT a Trino-dialect error. Two sub-nuances also worth a one-liner (neither a defect): (i) a per-customer occurrence count would `GROUP BY customer_id` and `COUNT(*)` over the flagged adjacent pairs rather than collapse to a single total; (ii) a run of 3 failures F-F-F produces 2 flagged adjacent pairs, so if the user wanted to count distinct STREAKS/runs of 2+ rather than adjacent pairs, that requires gaps-and-islands run-counting. Weighed proportionally: **Q3 Acc 5.0 / Comp 3.5 / Clar 4.5 / Act 4.5 = 4.375.**

---

## Per-question scores

### Q1 — "avg order value first-time vs repeat orders" → 5.00
Subquery `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date) AS order_rn`; outer `CASE WHEN order_rn=1 THEN 'first-time' ELSE 'repeat' END AS order_type`, `AVG(order_value)`, `GROUP BY` the REPEATED CASE expression.
- **VERDICT: CORRECT.** VERIFIED window.html: ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...) valid, assigns 1 to each customer's earliest order. VERIFIED select.html: GROUP BY cannot reference a SELECT alias (`order_type`), so repeating the full CASE expression (or using the ordinal) is the correct and required form — the responder did exactly this. First-vs-repeat AOV semantics correct (rn=1 = first-time, rn>1 = repeat). The tiebreaker caveat (orders sharing the exact same order_date for a customer get an arbitrary rn=1 unless the ORDER BY is made deterministic) is an apt, accurate completeness note, not a defect.
- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

### Q2 — "count distinct products with >=1 zero-stock event this year" → 5.00
`COUNT(DISTINCT product_id)` WHERE `event_date >= date_trunc('year', current_date) AND event_date < date_trunc('year', current_date) + INTERVAL '1' YEAR`; + approx_distinct ~2.3% note.
- **VERDICT: CORRECT.** VERIFIED: the half-open `[start_of_year, start_of_next_year)` range is the canonical sargable this-year filter (date_trunc('year', current_date) = Jan 1; + INTERVAL '1' YEAR = next Jan 1; `>=` ... `<` avoids both the year-end boundary double-count and any function-on-column wrap that could defeat pruning). COUNT(DISTINCT product_id) is a single-pass exact distinct count; one product with multiple zero-stock events this year is counted once. approx_distinct ~2.3% note DOC-CORRECT (see ★(1) above).
- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

### Q3 — "per-customer count of back-to-back (2+ consecutive) failed payments" → 4.375
Subquery `LAG(status) OVER (PARTITION BY customer_id ORDER BY payment_date) AS prev_status`; outer `WHERE status='failed' AND prev_status='failed'`, `COUNT(DISTINCT customer_id)`.
- **VERDICT: TECHNIQUE CORRECT, AGGREGATION SHAPE A PARTIAL INTERPRETATION MISMATCH (completeness nuance, NOT a dialect defect — see ★(2) above).** The LAG-based adjacent failed→failed detection is dialect-clean and the right tool; the single-total COUNT(DISTINCT customer_id) answers "how many customers had a back-to-back failure" rather than the per-customer "how many times" the question phrased. Defensible reading; deducted proportionally on Completeness/Clarity only.
- Acc 5.0 / Comp 3.5 / Clar 4.5 / Act 4.5 = **4.375**.

### Q4 — "% of sessions ending in a purchase" → 5.00
`ROUND(100.0 * COUNT(*) FILTER (WHERE purchased = true) / COUNT(*), 2)`.
- **VERDICT: CORRECT.** VERIFIED aggregate.html: FILTER (WHERE ...) is "supported for all aggregate functions" and evaluates the predicate per-row before aggregation, so `COUNT(*) FILTER (WHERE purchased = true)` counts purchase-ending sessions while `COUNT(*)` is the denominator. VERIFIED (types.html + Trino issue #1381 + standing Division pin): BIGINT/BIGINT division truncates toward zero, so the LEADING `100.0 *` is LOAD-BEARING — the DECIMAL literal `100.0` promotes the multiplication-then-division to decimal arithmetic, so `100.0 * num / den` computes the percentage correctly; the responder's warning that writing `... FILTER / COUNT(*) * 100` would multiply AFTER the integer division (which already truncated to 0 or 1) is ACCURATE. ROUND(..., 2) gives 2-decimal percentage. Optional micro-nuance (not flagged, not a defect): if a session could have zero rows the denominator is empty → no row / no div-by-zero issue here since COUNT(*) over the session set is the denom.
- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

---

## iter882 verify-first applied BOTH directions
- approx_distinct ~2.3% standard error: doc-CONFIRMED CORRECT (aggregate.html verbatim) ⇒ NOT flagged as fabrication.
- ROW_NUMBER / LAG OVER (PARTITION BY ... ORDER BY ...): doc-CONFIRMED valid (window.html) ⇒ Q1/Q3 techniques NOT flagged.
- GROUP BY repeats the CASE expression (no SELECT alias): doc-CONFIRMED (select.html) ⇒ Q1 NOT flagged.
- FILTER on all aggregates + 100.0*-forces-decimal-before-truncating-integer-division: doc/source-CONFIRMED ⇒ Q4 NOT flagged.
- No doc-CORRECT claim flagged; no doc-WRONG claim blessed.

## iter922 directive
**DEFAULT NO-OP.** All 4 dialect-clean. The ONLY sub-threshold-per-Q item is Q3's interpretation-shape nuance, which is a RESPONDER SYNTHESIS/INTERPRETATION choice on a defensible reading, NOT a findable resource gap or dialect defect — same wrapped-COUNT / count-of-entities family already covered by standing pins. **NO "wrong" card, NO FIX-A, NO escalation** (would duplicate the per-customer-vs-total count-of-entities pins + risk defang-backfire). Do NOT mark Q1 ROW_NUMBER+CASE-tier+GROUP-BY-repeated-expr, Q2 COUNT(DISTINCT)+half-open-year-range+approx_distinct-2.3%, Q3 LAG-consecutive-detection, or Q4 FILTER+100.0*-decimal wrong (all dialect-correct).

**OPTIONAL re-probe (NO pin touch):** re-ask the consecutive-failure question with explicitly per-customer phrasing ("output one row per customer with the number of back-to-back failure occurrences") to confirm the responder reaches for `GROUP BY customer_id` + COUNT over flagged pairs rather than a single COUNT(DISTINCT customer_id); SKIP if it duplicates a count-of-entities / gaps-and-islands pin.

Federation (4.49944/310) remains the only un-passed row — bulletproofed angles only. Do NOT touch any iter534–920 pin. PIN 467. NO federation edits. DO NOT bump training/state.json (already passed; overall 4.84 PASS holds).
