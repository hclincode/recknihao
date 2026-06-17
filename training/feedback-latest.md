# iter975 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 3.94 PASS** (Q1 3.81 / Q2 2.63 / Q3 4.81 / Q4 4.50 = 15.75/4 = 3.9375; margin +0.44 THIN; OVERALL AVERAGE governs, NO per-Q veto).

All claims verified BOTH directions vs trino.io/docs/467 + WebSearch 2026-06-17 (Trino IN-subquery SemiJoin blog/wiki; functions/datetime.html year()/current_date; sql/select.html GROUP BY non-grouped-column rule) — NOT against resources/. Q1 alternative + Q2 fan-out + Q4 YoY TRACED on concrete examples (JOIN cardinality + column scope). Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO) — answers fit; no env-incompatibility.

---

## Per-question scores

### Q1 — single-item orders, cleanest query — 3.81 (Acc 3.5 / Clar 4.0 / App 3.75 / Comp 4.0)
**LEAD CORRECT.** `SELECT o.* FROM orders o WHERE o.order_id IN (SELECT order_id FROM order_items GROUP BY order_id HAVING COUNT(*)=1)` — single-item orders = order_ids appearing exactly once in order_items; the HAVING COUNT(*)=1 subquery is exactly right.

**"IN (SELECT...) is a SemiJoin in Trino" = LEGITIMATE / ACCURATE label — VERIFIED.** WebSearch confirms Trino plans IN/NOT-IN-over-subquery via a **SemiJoin** plan node (trino.io blog 2019 + trinodb/trino Plan-nodes wiki: `... where custkey in (select custkey from customer)` shows a SemiJoin node in EXPLAIN; the semi-join itself dedups the subquery values, returns each left row at most once). This is the **CORRECT** semi-join label describing a REAL Trino mechanism — **NOT** the iter960/963 false-mechanism mislabel. No ding for the SemiJoin claim.

**ALTERNATIVE IS BROKEN (won't compile) — the ding.** `SELECT DISTINCT o.* FROM orders o LEFT JOIN order_items oi ON o.order_id=oi.order_id WHERE oi.order_id IS NOT NULL GROUP BY o.order_id HAVING COUNT(*)=1` — `SELECT o.*` (ALL order columns) with `GROUP BY o.order_id` ALONE will NOT compile: VERIFIED Trino 467 has NO functional-dependency GROUP BY relaxation — every non-aggregated SELECT column must appear in GROUP BY or be wrapped in an aggregate (sql/select.html). Selecting all of o.* while grouping only by order_id throws the missing-aggregation error. Additionally `SELECT DISTINCT` + `GROUP BY` is redundant. Responder did correctly flag the IN form as "simpler" so the steer toward the lead is right; the alternative is a **broken-secondary-alternative** (responder-slip family iter936/943/948/950/954/958-969). Lead correct, secondary won't-compile → Acc/App dinged moderately, not severely.

### Q2 — % of emails OPENED by campaign (each send opened-or-not, NOT total opens) — 2.63 (Acc 2.0 / Clar 3.0 / App 2.5 / Comp 3.0) — **THE KEY DEFECT: one-to-many JOIN fan-out COUNT(*) denominator inflation**
**LEAD-LEVEL FAN-OUT BUG — CONFIRMED via TRACE.** Query: `SELECT campaign, COUNT(*) AS total_emails_sent, COUNT(DISTINCT eo.sent_email_id) AS emails_opened, 100.0*COUNT(DISTINCT eo.sent_email_id)/COUNT(*) AS open_rate_pct FROM sent_emails se LEFT JOIN email_opens eo ON se.sent_email_id=eo.sent_email_id GROUP BY se.campaign`.

sent_emails = 1-row-per-send; email_opens = MANY-rows-per-send. **TRACE** campaign with sends {A: 2 opens, B: 0 opens, C: 1 open}:
- Joined rows after LEFT JOIN: A→2 rows, B→1 row (NULL eo), C→1 row = **4 rows**.
- `COUNT(*) AS total_emails_sent` = **4** — but TRUE sends = **3** → **DENOMINATOR INFLATED by the fan-out** (counts each send once PER open).
- `emails_opened = COUNT(DISTINCT eo.sent_email_id)` = {A,C} = **2** — CORRECT (DISTINCT dedupes multiple opens of the same send).
- `open_rate = 100*2/4 = 50%` vs **TRUE 2/3 = 66.7%** → **WRONG**.

The COUNT(DISTINCT) correctly fixes the NUMERATOR, but the **denominator COUNT(*) is fan-out-inflated**. Correct denominator = `COUNT(DISTINCT se.sent_email_id)` (or pre-aggregate email_opens to one-row-per-send BEFORE joining, then the join is 1:1 and COUNT(*) is safe). The responder **half-acknowledged** the problem ("if email_opens has multiple rows per sent_email_id, the LEFT JOIN will multiply your sent_emails rows... COUNT(DISTINCT) prevents double-counting the metric, but make sure you're grouping correctly") and then **FALSELY concluded** "The query above groups by se.campaign (from the left side), which is correct." Grouping by campaign is fine; the bug is the COUNT(*) on the fanned-out join, NOT the grouping. The false-justification compounds the accuracy hit.

**RESOURCE-vs-SLIP = RESPONDER SYNTHESIS SLIP, NOT a resource defect.** Resources teach JOIN fan-out + COUNT(DISTINCT) dedupe (r23 §multi-COUNT-DISTINCT L183-222 + JOIN-fan-out diagnostic ~L933). Responder reached past the guard (even narrating the multiplication) yet kept COUNT(*) as the denominator → assembly slip.

**FAN-OUT FAMILY = INTERMITTENT, NOT 2-in-2-consecutive.** iter971 Q2 (many-to-many SUM cross-product, fall-in) → iter972 Q3-re-probe CLEAN (pre-aggregated each side) → now iter975 Q2 (one-to-many COUNT(*) denominator inflation, fall-in). iter972 was clean in between, so this is NOT a 2-in-2 consecutive recurrence → **re-probe-don't-churn, LIGHT FIX-A only if it recurs next sweep (would be 2-in-2 from here).**

### Q3 — total tax per US state, GROUP BY gotchas at scale (few hundred M rows) — 4.81 (Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75) — CLEAN
`SELECT state, SUM(tax_amount) AS total_tax FROM orders WHERE state IS NOT NULL GROUP BY state ORDER BY total_tax DESC` — correct. Perf notes all VERIFIED accurate:
- Columnar/projection: reads only state + tax_amount — correct (Iceberg/Parquet columnar).
- Partition pruning needs a BARE partition column in WHERE (no CAST/date_trunc wrapping) — correct, matches r28 DATE-literal pushdown guidance.
- Low cardinality (~50 states) → small hash table, cheap aggregation — correct.
- No secondary indexes in Trino/Iceberg — correct.
- **"HAVING COUNT(*)>N does NOT speed it up — runs AFTER groups are built, trims OUTPUT not INPUT; add WHERE on the partition column instead"** — VERIFIED CORRECT, matches the r07 L37 reconcile (HAVING runs after aggregation, only trims output, does NOT cut GROUP BY build-side memory). The "HAVING trims memory" folklore (iter941/946) did NOT recur here — responder correctly steered to WHERE-on-partition-col. Excellent at-scale answer.

### Q4 — YoY spend per customer, side-by-side + flag who spent more — 4.50 (Acc 4.75 / Clar 4.75 / App 4.5 / Comp 4.0) — strong, minor completeness gap
`SELECT customer_id, SUM(CASE WHEN year(created_at)=year(current_date) THEN order_total ELSE 0 END) AS revenue_this_year, SUM(CASE WHEN year(created_at)=year(current_date)-1 THEN order_total ELSE 0 END) AS revenue_last_year, [ratio *1.0 + NULLIF guard] AS yoy_ratio FROM orders GROUP BY customer_id HAVING revenue_this_year>0 OR revenue_last_year>0 ORDER BY yoy_ratio DESC`.

VERIFIED CORRECT: conditional-aggregation YoY is the **right pattern** — single GROUP BY pass, mutually-exclusive CASE branches, NO self-join fan-out. Responder explicitly states "not a self-join — single GROUP BY pass, no fan-out, mutually-exclusive CASE branches" = correct and exactly the fan-out-avoidance the harder Qs keep tripping on. `year(created_at)` returns bigint year, `current_date` is a date, `year(current_date)` and `year(current_date)-1` = this/prior year — all VERIFIED (datetime.html). `*1.0` decimal promotion + NULLIF div-by-zero guard correct (division pin). FILTER-syntax equivalent offered = correct secondary (clean this time, not broken).

**MINOR completeness ding:** the question asked to "flag those who spent more this year," but the query delivers side-by-side + yoy_ratio (ordered DESC) WITHOUT an explicit `revenue_this_year > revenue_last_year` flag column or filter. The side-by-side IS delivered (the bulk of the ask) and yoy_ratio>1 implies "spent more," but a `revenue_this_year > revenue_last_year AS spent_more` boolean (or a HAVING/WHERE on it) would have nailed the explicit "flag" request → Comp 4.0.

---

## Scope notes / tic audit
- **Q1**: IN-subquery=SemiJoin label = LEGITIMATE (verified, real Trino mechanism) — NOT the false-mechanism mislabel. Broken-secondary alternative (`SELECT o.*` + `GROUP BY order_id` only = won't compile; DISTINCT+GROUP BY redundant) = responder-slip, lead correct.
- **Q2 = THE defect**: one-to-many JOIN fan-out → COUNT(*) denominator inflated (50% vs true 66.7%, TRACED) + false "is correct" justification. RESPONDER SYNTHESIS SLIP (resources r23 L183-222/~L933 teach fan-out + COUNT(DISTINCT) dedupe). **Fan-out family INTERMITTENT (iter971 fall-in → iter972 clean → iter975 fall-in), NOT 2-in-2-consecutive.**
- **Q3/Q4 CLEAN.** HAVING-after-groups (Q3) matches r07 L37 reconcile. Conditional-agg YoY (Q4) correctly avoids self-join fan-out.
- TICS otherwise CLEAN: no QUALIFY; no MAX(varchar)-as-latest; no percent_rank inversion; no fabricated function; no missing-CTE-column-projection; no ts-minus-ts; no mid-churn. (Q1 broken-alt + Q2 false-justification are the two slips this set.)

## Recommendation
**iter976 = DEFAULT NO-OP.** Margin +0.44 thin but PASS; both defects are responder synthesis/assembly slips, no resource defect, no findability gap. Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN). Re-probe next sweep:
1. Another **one-to-many ratio/rate Q** where the denominator must be `COUNT(DISTINCT parent_key)` not `COUNT(*)` over a fanned-out join — confirm whether responder reaches COUNT(DISTINCT se.key) or pre-aggregates (if it falls in AGAIN, that's 2-in-2 → LIGHT FIX-A near r23 ~L933: a one-to-many "rate per parent" canonical: pre-aggregate the child OR COUNT(DISTINCT parent_key) as denominator).
2. Another **single-item / exactly-N-children Q** — confirm IN(SELECT...HAVING COUNT(*)=N) lead stays clean and the LEFT JOIN alt either gets the columns into GROUP BY or is dropped.

NO resource edits. DO NOT bump training/state.json (already 975; passed=true preserved; final_iterations_remaining 0).
