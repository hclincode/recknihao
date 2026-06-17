# iter979 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.5625 STRONG PASS** (Q1 4.75 / Q2 4.75 / Q3 4.0625 / Q4 4.75 = 18.25/4 = 4.5625; margin +1.0625; OVERALL AVERAGE governs, no per-Q veto).

Verification: all claims checked BOTH directions vs trino.io/docs/467 (functions/aggregate.html count(x) vs count(*); sql/select.html HAVING + correlated-subquery support) + WebSearch Trino decorrelation 2026-06-17 — NOT against resources/. Q2 LEFT-JOIN-COUNT and Q3 relational-division TRACED on concrete examples. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — answers fit.

---

## Q1 — Products where current_qty < reorder_point (just a WHERE clause?) — 4.75 CLEAN

`SELECT product_id, product_name, current_qty, reorder_point FROM stock_levels WHERE current_qty < reorder_point ORDER BY current_qty` — correct, no Trino-specific gotcha for a plain comparison; "works same as Postgres" accurate for this construct; "WHERE runs before GROUP BY" correct (there is no GROUP BY here but the ordering note is harmless context). **NULL 3VL caveat VERIFIED CORRECT and a genuine value-add:** `NULL < 5` -> UNKNOWN -> row excluded by WHERE; if a missing `current_qty` should count as below-reorder, add `OR current_qty IS NULL` — correctly framed as a data-design decision, not a Trino quirk. No tics. Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q2 — Direct reports per manager INCLUDING zero-report managers — 4.75 CLEAN (KEY CHECK: semi-join mislabel did NOT recur)

`SELECT m.manager_id, m.manager_name, COUNT(e.employee_id) AS direct_report_count FROM managers m LEFT JOIN employees e ON m.manager_id=e.manager_id GROUP BY m.manager_id, m.manager_name ORDER BY direct_report_count DESC`. **VERIFIED the textbook LEFT-JOIN-COUNT pattern (aggregate.html count(x)="number of non-null input values" vs count(*)="number of input rows"):** for a manager with no reports, the LEFT JOIN emits one NULL-padded row -> `COUNT(*)` would count it as 1 (the trap) but `COUNT(e.employee_id)` ignores the NULL child key -> 0 (correct). The responder EXPLICITLY explained this distinction and prescribed `COUNT(child_key)` — exactly right. TRACE (manager M, no reports): NULL-padded row -> COUNT(*)=1, COUNT(employee_id)=0 -> kept with 0. CORRECT.

**SEMI-JOIN MISLABEL DID NOT RECUR (decisive):** the iter978 Q3 false-mechanism slip (calling a LEFT JOIN / IS NULL anti-join a "SemiJoin node") did NOT repeat here. The responder described the LEFT JOIN and COUNT semantics plainly and accurately, with no spurious plan-node naming. This confirms the iter978 SemiJoin mislabel as INTERMITTENT, not a structural defect — NO FIX-A warranted on recurrence grounds. Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q3 — Products in EVERY one of a customer's orders (relational division) — 4.0625 (single-customer correct+complete; all-customers self-flagged-incomplete)

**SINGLE-CUSTOMER LEAD CORRECT + COMPLETE:** `SELECT product_id FROM order_items WHERE customer_id=42 GROUP BY product_id HAVING COUNT(DISTINCT order_id) = (SELECT COUNT(DISTINCT order_id) FROM order_items WHERE customer_id=42) ORDER BY product_id`. **TRACE (customer 42 has 3 distinct orders O1/O2/O3):** product in all 3 -> COUNT(DISTINCT order_id)=3 = total 3 -> kept (in ALL); product in only O1,O2 -> COUNT=2 != 3 -> dropped (in SOME not all). Relational-division logic CORRECT. The subquery is NON-CORRELATED (literal `customer_id=42`) -> unambiguously valid Trino 467 (HAVING + scalar subquery comparison is standard; COUNT(DISTINCT) confirmed valid).

**ALL-CUSTOMERS GENERALIZATION — HONESTLY SELF-FLAGGED INCOMPLETE (good behavior, NOT a fabrication slip):** `GROUP BY customer_id, product_id HAVING COUNT(DISTINCT order_id) = (SELECT COUNT(DISTINCT order_id) FROM order_items t2 WHERE t2.customer_id=t1.customer_id)` references `t1.customer_id` but the outer `FROM order_items` lacks the `t1` alias. The responder explicitly noted "(This syntax needs a correlation alias — see the resources for the full pattern)" — i.e. it self-identified the missing alias rather than shipping a confidently-broken query. **VERIFIED the generalization WOULD work once the `t1` alias is added:** Trino DOES support correlated subqueries and decorrelates them (WebSearch: decorrelation of correlated subqueries is a core optimizer capability; the correlated COUNT-in-HAVING relational-division pattern decorrelates into an aggregation + join). This is the missing-column-in-CTE family by surface, but SELF-FLAGGED -> minor completeness ding ONLY, NOT a false-confidence / fabrication slip. The self-flag-plus-defer is the desired behavior. Acc 4.25 / Clar 4.0 / App 4.0 / Comp 4.0.

## Q4 — Count sessions with zero clicks (zeros-vs-NULLs trap?) — 4.75 CLEAN

`SELECT COUNT(*) AS sessions_with_zero_clicks FROM sessions WHERE click_count = 0` — correct. **VERIFIED the 3VL explanation:** `click_count = 0` matches only explicit 0; `NULL = 0` evaluates to UNKNOWN -> NULL rows excluded; if "loaded and left" is stored as NULL, this query misses them. Diagnostic query (`COUNT(*)`, `COUNT(click_count)`, `SUM(CASE WHEN click_count=0...)`, `SUM(CASE WHEN click_count IS NULL...)`) is correct and genuinely useful for understanding the data shape — `COUNT(click_count)` ignoring NULLs is confirmed (aggregate.html). Remediation `WHERE click_count = 0 OR click_count IS NULL` correct if NULL means zero. No tics. Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

---

## SCOPE NOTES

- **Q2 LEFT-JOIN-COUNT CORRECT + semi-join-mislabel did NOT recur** — `COUNT(e.employee_id)` (child key, ignores NULL -> 0) vs `COUNT(*)` (counts the null-padded row -> 1) is the right pattern, explained explicitly; no spurious "SemiJoin node" naming. iter978 Q3 mislabel = CONFIRMED INTERMITTENT/one-off, NO FIX-A.
- **Q3 single-customer CORRECT + all-customers generalization SELF-FLAGGED INCOMPLETE** — single-customer lead complete + valid (non-correlated subquery); all-customers form is missing the `t1` alias but the responder self-flagged it and deferred to resources rather than shipping it broken -> minor comp ding, NOT a fabrication/false-confidence slip (self-flag is good behavior; the form would work with the alias since Trino decorrelates correlated subqueries).
- **Q1 / Q4 CLEAN** — both nail the 3VL NULL semantics (NULL comparison -> UNKNOWN -> excluded; OR IS NULL to include) and frame the NULL handling as a data-design decision.

## TICS — CLEAN

No QUALIFY; no false-mechanism semi-join mislabel (Q2 did NOT mislabel — confirmed); no MAX(varchar)-as-latest; no percent_rank inversion; no fabricated functions/rule-names/issue-numbers; no PARTITIONED-BY foreign DDL; no broken-secondary / false-justification; no mid-churn; the Q3 missing-`t1`-alias was SELF-FLAGGED (not a silent slip); no JOIN fan-out; no ts-minus-ts.

## RECOMMENDATION = DEFAULT NO-OP

Margin +1.0625; lone non-clean item (Q3 all-customers generalization) is an honestly-self-flagged incomplete generalization, NOT a resource defect or findability gap. Re-probe next sweep: (a) another relational-division "appears in ALL / every" Q — does the responder reach the full correlated form WITH the alias, or keep deferring (deferring is acceptable); (b) another LEFT-JOIN-COUNT "include zero-X entities" Q — confirm COUNT(child_key) stays correct and the SemiJoin mislabel stays absent (3-clean would fully retire the iter978 concern). Federation r22 §13.x hard-locked NOT probed (OVERRIDDEN). NO resource edits. DO NOT bump training/state.json (already 979; passed=true preserved; final_iterations_remaining 0).
