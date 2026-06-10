# Judge Feedback — iter918 (NO-OP durability sweep)

**Overall: 4.84 PASS** (Q1 5.00 / Q2 5.00 / Q3 4.375 / Q4 5.00 = 19.375 / 4 = 4.84; margin +1.34). OVERALL AVERAGE governs — no per-Q veto.

All dialect claims verified vs trino.io/docs/467 (datetime.html, select.html) + Trino 467 git-tag source (DateTimeFunctions/timestamp DateDiff) + standing pins (`reference_trino_datediff_dayaware`), multi-source WebSearch/WebFetch, 2026-06-10. Trino 467 PINNED. Teacher made ZERO edits — pure durability re-confirm sweep. **iter919 = re-probe-don't-churn (DEFAULT NO-OP on the Q3 alternative — RESPONDER SYNTHESIS SLIP on CLEAN resources, correct lead form delivered; NOT a resource gap).**

---

## Per-question scores

### Q1 — count customers with total spend > average customer total — **5.00 CLEAN**
`SELECT customer_id, SUM(order_value) AS total_spent FROM orders GROUP BY customer_id HAVING SUM(order_value) > (SELECT AVG(total) FROM (SELECT SUM(order_value) AS total FROM orders GROUP BY customer_id))`.

VERIFIED CORRECT, both directions:
- **Scalar subquery in HAVING is VALID in 467** (standing pin; select.html scalar-subquery = non-correlated, returns ≤1 row; the inner `AVG(total)` over the per-customer-total derived table yields exactly one scalar). `SUM(order_value) > <scalar>` is a legal HAVING comparison.
- **Inner derived table needs NO alias** — Trino's grammar treats the FROM-relation alias as OPTIONAL (`aliasedRelation : relationPrimary (AS? identifier ...)?`); standing iter882 pin "FROM-subquery alias optional in Trino." (Note: the select.html prose shows aliased examples and a doc-extracted reading could *suggest* an alias is required — that is a doc-vs-grammar discrepancy; the grammar/pin governs, alias is optional. Did NOT flag this as a defect.)
- Semantics: inner-most groups per customer → per-customer totals; AVG over those = average customer total; outer HAVING keeps customers whose own total exceeds it = above-average spenders. Correct. Acc/Comp/Clar/Act 5.0.

### Q2 — distinct shipping countries per customer — **5.00 CLEAN**
`SELECT customer_id, COUNT(DISTINCT shipping_country) FROM orders GROUP BY customer_id`.

VERIFIED aggregate.html: `COUNT(DISTINCT x)` supported in 467; per-customer GROUP BY yields one row per customer with the distinct-country count. Correct shape, no dialect concern. Acc/Comp/Clar/Act 5.0.

### Q3 — count orders with >5 line items in last 30 days — **4.375 (Acc 4.0 / Comp 5.0 / Clar 4.0 / Act 4.5)**
The responder gave TWO forms. SHAPE CHECK resolved:

**(1) FIRST form is CORRECT and LEADS:**
`SELECT COUNT(*) AS complex_orders FROM (SELECT order_id, COUNT(*) AS line_count FROM line_items GROUP BY order_id HAVING COUNT(*) > 5) subquery JOIN orders o ON subquery.order_id = o.order_id WHERE o.order_date >= current_date - INTERVAL '30' DAY`.
- Inner = orders with >5 line items, ONE row per such order (GROUP BY order_id + HAVING COUNT(*)>5).
- JOIN orders to bring in `order_date`; `current_date - INTERVAL '30' DAY` is a VALID 467 date expression (standing pin) and a query-constant, so the date filter is sargable.
- Outer `COUNT(*)` collapses the surviving qualifying-order rows to a **single total** = how many complex orders in the last 30 days. Correct answer to the question.

**(2) SECOND "alternative" (labeled "slightly simpler") is WRONG-SHAPE:**
`SELECT COUNT(DISTINCT li.order_id) AS complex_orders FROM line_items li JOIN orders o ON li.order_id = o.order_id WHERE o.order_date >= current_date - INTERVAL '30' DAY GROUP BY li.order_id HAVING COUNT(*) > 5`.
- `GROUP BY li.order_id` makes each group exactly one order ⇒ `COUNT(DISTINCT li.order_id)` = **1 per group**.
- `HAVING COUNT(*) > 5` keeps qualifying orders, so the query returns **ONE ROW PER qualifying order, each value = 1** — a list of 1's, NOT a single total count. It does NOT answer "how many orders." Same family as the recurring muddled-middle slip (iter913 Q1, iter909 Q1): grouping by the key then COUNT(DISTINCT key) per group yields per-row 1's instead of a wrapped total.
- It is mislabeled "slightly simpler" (it is not simpler AND it is wrong-shape). To return a single total it would need to drop the GROUP BY and wrap, e.g. `SELECT COUNT(*) FROM (SELECT li.order_id FROM line_items li JOIN orders o ON ... WHERE ... GROUP BY li.order_id HAVING COUNT(*) > 5)`.

**Verdict:** correct form LEADS and is delivered, so partial deduction only — NOT a hard fail. Acc 4.0 (a wrong-shape secondary query presented as an equivalent alternative) / Comp 5.0 (question fully answered by the lead) / Clar 4.0 (the mislabeled "simpler" alternative could mislead a non-expert who copies the second) / Act 4.5 (copying the LEAD works; copying the alternative returns a column of 1's). = 4.375.

### Q4 — complete months subscribed (2mo3wk → 2) — **5.00 CLEAN**
`SELECT customer_id, date_diff('month', signup_date, current_date) AS complete_months_subscribed FROM subscribers`.

VERIFIED against the pinned fact (`reference_trino_datediff_dayaware`, git-tag 467 DateDiff): `date_diff('month', a, b)` is **DAY-AWARE / complete-units** — it counts whole month-units and DROPS the fractional remainder (Jan15→Feb14 = 0, Jan15→Feb15 = 1, Jan15→Mar20 = 2). The responder's worked example `date_diff('month', DATE '2026-01-15', DATE '2026-03-20') = 2` is CORRECT (Jan15→Feb15=1, Feb15→Mar15=2, Mar15→Mar20 incomplete → dropped), and "2 months 3 weeks → 2" holds. `current_date` valid, DATE−DATE inputs fine.
- The responder's wording "complete month boundaries crossed" is slightly loose versus the precise day-aware complete-units mechanism, but the function call + result are correct ⇒ weighed as at most a tiny clarity nuance, NOT a defect. Acc/Comp/Clar/Act 5.0.

---

## Verdict

- **(1) Q3 FIRST form is CORRECT and LEADS** (wrapped `COUNT(*)` over the >5-line-item subquery JOIN orders WHERE last-30-days = single total). **The SECOND "alternative" is WRONG-SHAPE** — `GROUP BY li.order_id` + `COUNT(DISTINCT li.order_id)` returns one row per qualifying order (each = 1), per-order rows NOT a single count, and is mislabeled "slightly simpler." Partial deduction (Q3 = 4.375), not a hard fail, because the correct answer leads.
- **(2) Q4 `date_diff('month')` complete-months result is CORRECT** — day-aware/complete-units, Jan15→Mar20 = 2 verified against the pinned git-tag fact; "2mo3wk → 2" holds.
- **Q1 (scalar subquery in HAVING + unaliased inner FROM-subquery) and Q2 (COUNT(DISTINCT) per customer) are fully correct.** No doc-CORRECT claim flagged; no doc-WRONG claim blessed (iter882 verify-first applied both directions).
- **SCOPE CHECK on the Q3 wrong-shape alternative: RESPONDER SYNTHESIS SLIP on CLEAN resources, NOT a resource gap.** The responder produced the correct wrapped-COUNT lead and endorsed it; the defect is an unnecessary mislabeled wrong-shape alternative synthesized on top (same family as iter913-Q1 / iter909-Q1 muddled-middle, which the lead form correctly avoided). A "wrong card" would only duplicate the existing wrapped-COUNT / GROUP-BY-output / muddled-middle pins and risk defang-backfire ⇒ **NO resource edit. Re-probe-don't-churn:** re-probe "count orders satisfying a per-group HAVING threshold" fresh next sweep to confirm the responder reliably wraps to a single total and does NOT offer a per-group-COUNT(DISTINCT-key) alternative.
- **iter919 = DEFAULT NO-OP.** No FIX-A, no escalation; teacher ZERO edits. PRESERVE full iter534-917 pin inventory. Federation (4.49944 / 310) is the only un-passed row — NOT probed this sweep, row UNCHANGED; bulletproofed angles only. PIN 467. NO federation edits.

DO NOT bump training/state.json (already passed at iter918; overall 4.84 PASS holds).
