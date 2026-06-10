# iter968 Judge Feedback — EXTENDED PHASE, NO-OP breadth sweep

**OVERALL 4.75 STRONG PASS** (Q1 4.94 / Q2 4.94 / Q3 4.81 / Q4 4.31 = 19.00/4 = 4.75; margin +1.25; OVERALL AVERAGE governs, no per-Q veto).

All dialect/logic claims verified BOTH directions vs trino.io/docs/467 + git-tag 467 source + WebSearch 2026-06-11 — NOT against resources/.

---

## Per-question scores

### Q1 — p95 per API endpoint over hundreds of millions of rows — 4.94 (Acc 4.75 / Comp 5 / Clar 5 / Act 5)
`approx_percentile(response_ms, 0.95) GROUP BY api_endpoint` + array form `approx_percentile(response_ms, ARRAY[0.5,0.95,0.99])`.
- VERIFIED both forms exist in 467 (functions/aggregate.html): `approx_percentile(x, percentage) -> [same as x]` AND `approx_percentile(x, percentages) -> array<[same as x]>`. CORRECT.
- VERIFIED the accuracy attribution is EXACTLY RIGHT: the "2.3% standard error" sentence belongs to **approx_distinct ONLY**, NOT approx_percentile. Confirmed via two independent WebFetch passes against aggregate.html. The responder's "Trino publishes NO fixed error % for approx_percentile; the 2.3% is for approx_distinct (count-distinct)" is CORRECT and matches our pin (reference_trino_approx_percentile_error.md). This is the exact figure an earlier judge (iter842) misread — the responder got it right.
- "Exact percentile requires sorting all rows = prohibitive" — sound.
- MINOR (-0.25 Acc only): responder labels the backing structure "quantile-digest (T-digest)". Trino actually has TWO distinct sketch types — `qdigest` AND `tdigest` are separate types/function families; approx_percentile is T-digest-backed. Conflating them under one hyphenated label is a small mechanism imprecision in a tangential aside, NOT a defect — approx_percentile itself is the correct answer and the user-facing guidance is right.

### Q2 — NULL manager_id + full reporting chain (self-referential) — 4.94 (Acc 5 / Comp 5 / Clar 4.75 / Act 5)
Part A `WHERE manager_id IS NULL`; Part B `WITH RECURSIVE`.
- **THE KEY FACTUAL CHECK — max_recursion_depth VERDICT: RESPONDER IS CORRECT.** VERIFIED against trino.io/docs/467/sql/select.html: WITH RECURSIVE is supported; the session property is named exactly `max_recursion_depth` and its **default value is 10**; doc note "recursion depth is fixed, defaults to 10, and doesn't depend on the actual query results" + "the size of the query plan growth is quadratic with the recursion depth" + experimental warning. The responder's claim ("default recursion depth limit of 10", error "Recursion depth limit exceeded (10)", fix `SET SESSION max_recursion_depth = 50` run BEFORE the query) is FULLY ACCURATE — exact property name AND exact default both correct. This is NOT a fabricated-property slip; it is a real, correctly-named, correctly-defaulted Trino session property.
- Recursive-CTE structure is valid Trino form: base `SELECT emp_id,emp_name,manager_id,1 AS depth` UNION ALL recursive `SELECT rc.emp_id, rc.emp_name, m.manager_id, rc.depth+1 FROM reporting_chain rc JOIN employees m ON m.emp_id=rc.manager_id WHERE rc.manager_id IS NOT NULL AND rc.depth<50`. Column list is structurally sound — it carries the ORIGINAL employee (rc.emp_id/rc.emp_name) forward while walking the ancestor pointer (m.manager_id) upward.
- TRACE 3-level chain E3->E2->E1->NULL: base rows {E3@d1,E2@d1,E1@d1}; recursive walks E3 join m.emp_id=E2 -> (E3, mgr=E1, d2), then join m.emp_id=E1 -> (E3, mgr=NULL, d3), stops on rc.manager_id IS NULL. Produces the full upward ancestor chain per employee. Logic CORRECT.
- depth<50 guard is sensible defense even though default cap is 10 (and the SET SESSION raises it). Single-employee upward variant correct.
- -0.25 Clar only: the two stop conditions (rc.manager_id IS NOT NULL AND rc.depth<50) plus the SET SESSION cap interplay is slightly dense for a beginner, but each piece is explained.

### Q3 — product PAIRS bought together (order_items self-join) — 4.81 (Acc 5 / Comp 4.75 / Clar 4.75 / Act 4.75)
Self-join `order_items oi1 JOIN order_items oi2 ON oi1.order_id=oi2.order_id AND oi1.product_id < oi2.product_id`, `GROUP BY product_a, product_b`, `COUNT(*) AS times_bought_together`, `WHERE >=10`, `ORDER BY DESC LIMIT 100`.
- VERIFIED `product_id < product_id` is the canonical standard market-basket dedup: the strict inequality both (a) eliminates self-pairs (A,A) and (b) collapses (A,B)+(B,A) to one ordered pair — load-bearing and correctly explained. CORRECT direction (self-join IS the right tool here).
- Threshold (>=10) + LIMIT 100 keep output bounded — directly answers "will it blow up". Broadcast hash join on order_id note is reasonable.
- "specific product" variant `oi1.product_id='x' AND oi2.product_id != 'x'` is a valid co-purchase-with-X form.
- Minor: the genuine blow-up risk is per-ORDER fan-out (an order with k items yields k*(k-1)/2 pairs) — responder addresses output cardinality via threshold/LIMIT but is light on the intra-order quadratic fan-out itself; not wrong, slight completeness shade.

### Q4 — active accounts per plan tier RIGHT NOW from plan_history change-log — 4.31 (Acc 4.75 / Comp 4.75 / Clar 3.25 / Act 4.5)
Final answer CORRECT: Option A `ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY changed_at DESC) AS rn ... WHERE rn=1 ... GROUP BY plan_tier`; corrected nested `max_by(plan_tier, changed_at)` subquery then `GROUP BY plan_tier_current`; Option B dbt incremental current-state table.
- **CONFIRMED: iter964-Q3 MAX(varchar)-as-latest mislabel did NOT recur.** The latest-per-account core uses `max_by(plan_tier, changed_at)` (value-at-max-timestamp) AND `ROW_NUMBER() ORDER BY changed_at DESC` — both are TEMPORAL latest, NOT lexicographic MAX(plan_tier). The prior trap is absent here. Good.
- **CLARITY DING (-1.75 Clar): visible mid-answer churn + BROKEN INTERMEDIATE.** Responder wrote an invalid double-GROUP-BY query `SELECT max_by(plan_tier, changed_at), COUNT(*) FROM plan_history GROUP BY account_id GROUP BY max_by(...)` — TWO GROUP BY clauses is a parse error (CONFIRMED invalid Trino: a single SELECT permits only one GROUP BY) — then said "Wait, that's slightly wrong syntax" and corrected to the valid nested form. The broken query is a self-corrected INTERMEDIATE, NOT the final answer; the final answer is correct. But the visible thinking-out-loud + shipped-then-retracted broken SQL hurts beginner clarity (a novice could copy the broken line before reaching the correction).
- CLASSIFICATION: this is a PRESENTATION TIC (broken-secondary / mid-answer-churn family — also iter962-Q2 "Wait, that's overcomplicating it", iter964-Q3 "Wait, that's not quite right"). It is NOT a resource defect — no resource teaches double-GROUP-BY, and the correct nested max_by + ROW_NUMBER()=1 forms are findable and were reached. Per-instance Haiku synthesis-padding slip; re-probe-don't-churn (feedback_responder_broken_secondary_alternative.md). NO resource fix.

---

## Scope notes

- ALL FOUR LEADS CORRECT. Overall 4.75 STRONG PASS, margin +1.25.
- **max_recursion_depth VERDICT: CORRECT** — property name `max_recursion_depth` + default `10` both verified exactly right vs trino.io/docs/467/sql/select.html. NOT a fabricated-property slip.
- **iter964-Q3 MAX(varchar)-as-latest STAYS A ONE-OFF** — Q4 latest-per-group used max_by + ROW_NUMBER (temporal), the lexicographic mislabel did NOT recur. Confirmed clean.
- **Q4 mid-answer churn + broken double-GROUP-BY intermediate = PRESENTATION TIC (broken-secondary/synthesis-padding family), NOT a resource defect.** Final answer correct; no resource fix; per-instance one-off re-probe.
- NO QUALIFY / NO semi-join-mislabel / NO percent_rank-inversion / NO MAX(varchar)-as-latest / NO fabricated-rule slips this set.
- approx_percentile accuracy attribution (2.3% = approx_distinct only) CORRECT — matches our pin; the iter842 judge misread does not appear in the responder.
- NO resource defect / NO findability gap / NO resource edits warranted.

## iter969 RECOMMENDATION = DEFAULT NO-OP
Re-probe from fresh angles to confirm one-offs: (a) another self-referential/recursive-hierarchy Q (e.g. bill-of-materials / category tree) to re-confirm WITH RECURSIVE + max_recursion_depth handling; (b) a multi-percentile / weighted approx_percentile angle; (c) a latest-state-from-changelog Q to confirm max_by/ROW_NUMBER stays clean and the Q4 broken-intermediate churn is one-off. LIGHT FIX-A only if the double-GROUP-BY broken-intermediate or any tic RECURS in next 2 sweeps. Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN).

PINS REINFORCED:
- **approx_percentile(x, fraction) + approx_percentile(x, ARRAY[...]) both valid 467; NO published fixed error % for approx_percentile (the 2.3% standard error is approx_distinct ONLY); exact percentile = full sort = prohibitive; backing structure is T-digest (qdigest and tdigest are DISTINCT types — don't conflate the label).**
- **WITH RECURSIVE supported in 467; session property `max_recursion_depth` DEFAULT = 10; raise via SET SESSION max_recursion_depth=N BEFORE the query; query-plan growth is quadratic in depth; recursive CTE carries the original key forward (rc.emp_id) while walking the parent pointer (m.manager_id) up, stop on rc.parent IS NULL + a depth guard.**
- **product-pair co-purchase = self-join on order_id with strict `oi1.product_id < oi2.product_id` (kills self-pairs AND (A,B)/(B,A) dupes); GROUP BY pair + COUNT(*) + threshold + LIMIT bounds output; intra-order fan-out is k*(k-1)/2.**
- **latest-state-from-changelog = max_by(value, ts) GROUP BY key, OR ROW_NUMBER() OVER (PARTITION BY key ORDER BY ts DESC)=1 subquery — both TEMPORAL latest, NOT MAX(varchar) lexicographic; a single SELECT allows ONLY ONE GROUP BY (double-GROUP-BY = parse error).**
- **broken-secondary/mid-answer-churn meta-pattern persists (iter936/943/948/950/954/958/959/960/961/963/964/965/966 family) — LEADS correct, a visible self-corrected broken intermediate or tacked-on aside dings CLARITY; per-instance Haiku tic, NOT a resource defect.**

DO NOT bump training/state.json (already 968; passed=true preserved; overall 4.75 PASS holds; final_iterations_remaining 0).
