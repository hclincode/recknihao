# Judge Feedback — iter930 (re-probe sweep)

**Overall: 4.50 PASS** (Q1 3.00 / Q2 5.00 / Q3 5.00 / Q4 5.00 = 18.00/4). OVERALL AVERAGE governs — no per-Q veto. Trino 467 PINNED. All dialect claims verified vs trino.io/docs/467 (window.html, datetime.html, select.html) + Trino GitHub (QUALIFY = open feature request, NOT in 467) via WebFetch + multi-source WebSearch 2026-06-10. DO NOT bump training/state.json (already 930; passed=true preserved).

---

## Per-question scores

### Q1 — avg position of first answered attempt per answered ticket — **3.00** (Acc 2 / Comp 3 / Clar 4 / Act 3)

Two separate findings, exactly as the directive flagged:

**(1) STRUCTURAL re-probe — iter929 slip ONE-OFF CONFIRMED (did NOT recur).**
The responder used VALID NESTED SUBQUERIES: `ROW_NUMBER() OVER (PARTITION BY ticket_id ORDER BY attempt_at)` lives in the INNERMOST SELECT, then is filtered in an OUTER `WHERE`, then aggregated by `AVG` in the outermost SELECT. It did NOT reference a window-fn alias inside another window aggregate in the same SELECT, did NOT nest window functions, and correctly recognized QUALIFY is absent in Trino 467 (self-corrected the QUALIFY draft to nested-subquery + outer WHERE). Verified vs window.html (row_number is a documented ranking fn; aggregate window fns legal) and Trino GitHub (QUALIFY = open feature request, not shipped in 467). The iter929 two-CTE-layer / window-alias structural slip is CLOSED — no findability FIX-A needed for structure.

**(2) NEW LOGIC DEFECT — CONFIRMED (the directive's verdict holds).**
The question asks for "the average POSITION of the FIRST ANSWERED attempt across tickets that eventually got answered" — e.g. attempts `[no, no, yes]` should contribute position **3**. The responder's filter is `WHERE was_answered = true AND position = 1`.

`position` is ROW_NUMBER over ALL attempts in chronological order, so `position = 1` is the FIRST attempt overall. `was_answered = true AND position = 1` keeps ONLY tickets whose **first** attempt was answered. For `[no, no, yes]` there is NO surviving row (position 1 is `no`), so that ticket is silently EXCLUDED; every surviving row has `position = 1`, making `AVG(first_answer_position)` degenerate to **1.0** (or NULL if zero rows match). This computes "avg position among tickets answered on attempt #1" (always 1), NOT "avg position of the first answered attempt."

**Correct form** — filter to answered rows FIRST, then take MIN(position) per ticket (the first answered attempt's position), then AVG:
```sql
SELECT AVG(p) FROM (
  SELECT ticket_id, MIN(position) AS p
  FROM ( SELECT ticket_id,
                ROW_NUMBER() OVER (PARTITION BY ticket_id ORDER BY attempt_at) AS position,
                was_answered
         FROM contact_attempts ) ranked
  WHERE was_answered = true
  GROUP BY ticket_id
);
```

This is a **LOGIC / correctness error, NOT a dialect/syntax defect** — the responder's query parses, runs, and is structurally valid Trino 467; it simply returns the wrong number. Hence Accuracy weighed LOW (2 — wrong result), Clarity moderate-high (4 — query is clean and readable), Completeness/Actionability moderate (3 — the engineer would run it and silently get 1.0, mistaking it for a real metric). Not vetoed; folded into the average.

**SCOPE — RE-PROBE-DON'T-CHURN.** This is a RESPONDER REASONING SLIP, not a findable resource gap. The resources already teach the correct "first-match-per-group" pattern (filter-to-condition → MIN/ROW_NUMBER per group → aggregate); recent sweeps (iter904 first-order-per-customer, iter910 MIN(order_date) per customer, iter911 MIN OVER first-order) all show the responder applying the first-per-group idiom correctly. The slip here is conflating "first attempt overall" (position=1) with "first answered attempt" (MIN position among answered) — a synthesis error on a confusable phrasing, parallel to the iter925 multi-arg-COUNT-DISTINCT optional-alt slip. Churning resources risks New-Card/defang regressions for zero benefit. **iter931: re-probe with an explicit "first row matching a condition per group" Q (e.g. first PAID invoice position per customer, first SUCCESSFUL login attempt per user) to confirm the responder leads with the MIN(position)-among-matching / answered-then-rank pattern.** Do NOT churn.

### Q2 — count active feature flags per environment — **5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)
`SELECT environment, COUNT(*) FROM feature_flags WHERE is_active = true GROUP BY environment`. WHERE filters active flags BEFORE grouping; GROUP BY environment = one row per distinct environment; COUNT(*) tallies active flags per environment. Verified vs select.html (GROUP BY divides into groups, count(*) per group) + aggregate.html. CLEAN — correct filter-count-per-group.

### Q3 — each category's revenue share from its top product — **5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)
`SELECT category, ROUND(100.0 * top_product_revenue / category_total_revenue, 2) FROM (SELECT category, SUM(revenue) OVER (PARTITION BY category) AS category_total_revenue, MAX(revenue) OVER (PARTITION BY category) AS top_product_revenue FROM products) GROUP BY category, category_total_revenue, top_product_revenue`. Verified window.html: SUM/MAX as window functions with OVER (PARTITION BY category) — no ORDER BY needed — broadcast the per-category total and per-category max product revenue across all rows in the partition. Outer GROUP BY collapses to one row per category (total/max are constant within each partition so grouping by them is safe). `MAX(revenue)` = the single highest-revenue product (top seller by revenue); `100.0 *` decimal-promotes to avoid integer-division truncation; share = top/total. VALID + CORRECT (assumes one row per product, the natural reading). CLEAN.

### Q4 — count distinct products sold per day — **5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)
`SELECT DATE(order_date) AS day, COUNT(DISTINCT product_id) FROM orders GROUP BY DATE(order_date)`. Verified datetime.html: `date(x)` is documented as an alias for `CAST(x AS date)`, truncating a timestamp to its calendar day; COUNT(DISTINCT product_id) per group is valid 467. GROUP BY DATE(order_date) buckets orders by day; counts unique products sold each day. CLEAN.

---

## Summary

- **(1) Q1 STRUCTURAL slip ONE-OFF CONFIRMED** — valid nested subqueries, no QUALIFY (correctly self-corrected, absent in 467), no nested-window, no window-alias-in-sibling-SELECT. The iter929 structural slip did NOT recur; CLOSED.
- **(2) Q1 NEW LOGIC DEFECT CONFIRMED** — `was_answered = true AND position = 1` makes AVG degenerate to 1.0 (avg position among tickets answered on attempt #1), NOT the requested "avg position of the first answered attempt." Correct = MIN(position) among answered rows per ticket, then AVG. Query is valid+runs ⇒ logic/correctness error, not syntax/dialect.
- **SCOPE: responder reasoning slip, NOT a findable resource gap → RE-PROBE-DON'T-CHURN.** Resources already teach the first-match-per-group pattern; the responder applies it correctly in recent sweeps. iter931: re-probe "first row matching a condition per group" from a fresh angle (first PAID invoice / first SUCCESSFUL login position) to confirm the MIN-among-matching idiom; do NOT churn resources.
- **prod-env unaffected** — all four are pure SQL on on-prem Trino 467 + Iceberg + MinIO + HMS + JWT/OPA; no stack conflict.
- **iter931 = DEFAULT NO-OP / re-probe-don't-churn.** Optional fresh adjacents: first-matching-row-per-group (re-probes the Q1 slip), RANK()=1 top-per-group share variants, mixed DATE/TIMESTAMP date_trunc with explicit CAST; CONSIDER FEDERATION (thinnest passing row 4.49944/310, long un-retested). PRESERVE full iter534–929 pin inventory; NO federation edits (federation 4.49944/310, UNCHANGED — not probed). DO NOT bump training/state.json.
