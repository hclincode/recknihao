# Judge Feedback — iter912 (NO-OP durability sweep)

**Overall: 4.94 STRONG PASS** (Q1 5.00 / Q2 4.94 / Q3 5.00 / Q4 4.81). Overall-average governs; no per-Q override. **VERDICT: NO-OP / durability-breadth — no defect, no FIX-A needed.**

Teacher made ZERO edits this iteration. Four fresh GROUP BY + aggregate + CURRENT_DATE adjacents. Every dialect claim verified vs trino.io/docs/467 (datetime/select/types .html + admin/properties-optimizer.html) + WebSearch on Trino git-tag 467 distinct-aggregations / TIMESTAMP-WITH-TIME-ZONE source, Trino 467 PINNED, multi-source, 2026-06-10.

## Per-question

**Q1 — unique customers per sales channel — 5.00 CLEAN**
`SELECT sales_channel, COUNT(DISTINCT customer_id) AS unique_customers FROM orders GROUP BY sales_channel`. Counts unique customers per channel (NOT orders); correctly warns `COUNT(*)` would count order rows not distinct customers. Multiple `COUNT(DISTINCT ...)` in one SELECT is valid in 467 (confirmed).
**`distinct_aggregations_strategy` EXISTENCE VERDICT: EXISTS in Trino 467.** Verified directly against trino.io/docs/467/admin/properties-optimizer.html — session property `distinct_aggregations_strategy` (config `optimizer.distinct-aggregations-strategy`), default `AUTOMATIC`, allowed values `AUTOMATIC | MARK_DISTINCT | SINGLE_STEP | PRE_AGGREGATE | SPLIT_TO_SUBQUERIES`. It replaced the older boolean `optimize_distinct_aggregations` (which does NOT exist on the 467 page). The responder's tuning aside is therefore **CORRECT (bonus), NOT a defect**. The COUNT(DISTINCT) SQL is fully correct regardless.

**Q2 — count overdue unpaid invoices — 4.94 CLEAN**
`SELECT COUNT(*) FROM invoices WHERE due_date < CURRENT_DATE AND paid_at IS NULL`. Correct. Verified `CURRENT_DATE` = "the current date as of the start of the query" (datetime.html); `CURRENT_TIMESTAMP` = timestamp-with-tz at query start (instant precision) — accurate. `IS NULL` (not `= NULL`) correct. Timezone discussion accurate: TIMESTAMP WITH TIME ZONE is an absolute instant (Iceberg/Trino normalize to UTC — confirmed via 467 types.html "instant in time" + git-tag/Iceberg UTC-normalization source); `CURRENT_TIMESTAMP` for instant-precision is the right pointer. Tiny clarity ding only: the instant-precision/tz tangent slightly over-elaborates a query whose own comparison is pure DATE (no tz hazard) — informative, not wrong.

**Q3 — distinct prices per product — 5.00 CLEAN**
`SELECT product_id, COUNT(DISTINCT price) AS distinct_price_count FROM product_prices GROUP BY product_id`. Exactly right: per product = number of distinct price values. Crisp, no muddle.

**Q4 — highest order value per customer — 4.81 CLEAN**
`SELECT customer_id, MAX(order_value) FROM orders GROUP BY customer_id`. Correct.
**POSITIVE DURABILITY SIGNAL:** responder correctly STATES the GROUP-BY rule that the iter909 responder VIOLATED — "you can't `SELECT customer_id, order_id, MAX(order_value)`: a column not in GROUP BY and not in an aggregate is forbidden (analysis error)." Verified vs select.html: "all output expressions must be either aggregate functions or columns present in the GROUP BY clause." For the max-ROW (returning order_id of the top order) responder gives the ROW_NUMBER()-in-subquery workaround — correct, since QUALIFY does NOT exist in Trino 467 (confirmed: select.html lists no QUALIFY). Minor ding: the max-VALUE vs max-ROW distinction is right but could be stated a touch more crisply up front.

## Findings
- **(a) `distinct_aggregations_strategy` EXISTS in 467** — Q1 aside is a correct bonus, not a nick.
- **(b) Q4 correctly STATES the iter909-violated GROUP-BY rule** + correct ROW_NUMBER workaround (no QUALIFY in 467). Durability signal: the slip stays a one-off, did not recur.
- **(c) NO DEFECT** — no fabrication, wrong-signature, crossed-family, findability-slip, GROUP-BY-muddle, or prod-env conflict. Pure SQL; on-prem Trino 467 + Iceberg + MinIO + HMS + JWT/OPA unaffected.
- **(d) iter913 = DEFAULT NO-OP / durability-breadth.** No LIGHT FIX-A warranted. Optional fresh adjacents: COUNT(DISTINCT) with FILTER (WHERE ...), multi-column COUNT(DISTINCT (a,b)) / row-distinct, `approx_distinct` vs COUNT(DISTINCT) trade-off, HAVING COUNT(DISTINCT)>1 dup-detection, max-row tie handling via RANK()=1 vs ROW_NUMBER()=1.

**PRESERVE** full iter534–911 pin inventory (COUNT(DISTINCT) multi-in-SELECT, CURRENT_DATE=query-start, IS NULL, GROUP-BY output-expr rule, no-QUALIFY ROW_NUMBER workaround, window-fn subquery+outer-filter pattern). NO federation edits (federation 4.49944/310, raised 4.5 bar). DO NOT bump training/state.json (already 912).
