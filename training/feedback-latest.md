# Iter 658 Judge Feedback — 2026-06-08 (EXTENDED PHASE)

## OVERALL: 5.00 STRONG PASS

Per-Q scores: Q1=5.00 / Q2=5.00 / Q3=5.00 / Q4=5.00
Overall = (5.00+5.00+5.00+5.00)/4 = **5.00 STRONG PASS** (margin +1.50 above 3.5 floor)
Dim-avg cross-check: Acc=5.0 / Comp=5.0 / Clar=5.0 / Act=5.0 → (5+5+5+5)/4 = 5.00 — agrees.

---

## Q1 — first AND current plan tier per subscriber (FIX-A re-validation #4) — 5.00 STRONG PASS

**Answer:**
```sql
SELECT subscriber_id,
       min_by(plan_tier, changed_at) AS first_tier,
       max_by(plan_tier, changed_at) AS current_tier
FROM subscription_changes
GROUP BY subscriber_id
```

**Scores: Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00**

### *** FIX-A RE-VALIDATION (the key check) — VERDICT: LANDED ***

**(a) The iter658 dual-destination FIX-A LANDED.** The responder did NOT reproduce the iter655/iter657 invalid `first_value/last_value` window-mixed-with-GROUP-BY hybrid. The PRIMARY routing destination (r07 Pattern B3 DECISION INOCULATION block, iter658 PIN) and SECONDARY anchor (r23:652 keyword anchor broadening) jointly closed the iter655/657 regression on the "first AND current plan tier per subscriber" phrasing. Inoculation HELD on first re-probe across BOTH routing destinations.

**(b) Soft-watch is RESOLVED — min_by/max_by FINALLY SELECTED CLEANLY as the PREFERRED form.** Not the valid-but-verbose ROW_NUMBER+MAX(CASE) alternative; not the INVALID window+GROUP-BY hybrid. The responder reached the cleanest, single-pass, one-aggregate-pair-per-group canonical form on first try.

**Verified vs trino.io/docs/467/functions/aggregate.html (General aggregate functions):**
- `min_by(x, y)` "Returns the value of x associated with the minimum value of y over all input values"
- `max_by(x, y)` "Returns the value of x associated with the maximum value of y over all input values"
- Both are AGGREGATE functions → one row per GROUP BY group (no SELECT DISTINCT collapse needed).
- The query satisfies the trino.io/docs/467/sql/select.html GROUP BY rule: every SELECT expression is either the grouped column (`subscriber_id`) or an aggregate (`min_by`, `max_by`).

**Conclusion for iter659 context:** Soft-watch on min_by/max_by non-selection is now RESOLVED — the responder selected the PREFERRED form cleanly on this re-probe. Mark resolved and DO NOT continue actively probing this shape; let it ride as durability-only.

---

## Q2 — average hours to first response per priority — 5.00 STRONG PASS

**Answer:**
```sql
SELECT priority,
       ROUND(AVG(date_diff('hour', opened_at, first_response_at)), 2) AS avg_hours_to_first_response
FROM tickets
WHERE first_response_at IS NOT NULL
GROUP BY priority
```

**Scores: Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00**

**Verified vs trino.io/docs/467/functions/datetime.html:**
- `date_diff(unit, timestamp1, timestamp2) -> bigint` returns `timestamp2 - timestamp1` in the specified unit — correctly applied as `date_diff('hour', opened, first_response)` (opened first, response second).
- `AVG` of the bigint hour-deltas correctly produces a per-priority mean.
- `ROUND(x, 2)` 2-arg signature verified at trino.io/docs/467/functions/math.html.
- `WHERE first_response_at IS NOT NULL` correctly excludes tickets that never received a response.
- `GROUP BY priority` standard aggregation grain.

Clean composition — date_diff hour arithmetic + AVG + 2-arg ROUND + NULL-guard + GROUP BY all docs-canonical.

---

## Q3 — date cumulative revenue first crossed 50% of annual total — 5.00 STRONG PASS

**Answer:** subquery emits per-day `cumulative_revenue = SUM(revenue) OVER (ORDER BY revenue_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` and `total_annual_revenue = (SELECT SUM(revenue) FROM daily_revenue)`; outer takes `MIN(revenue_date) WHERE cumulative_revenue >= 0.5*total AND cumulative_revenue - revenue < 0.5*total`.

**Scores: Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00**

**Verified vs trino.io/docs/467/functions/window.html:**
- "All Aggregate functions can be used as window functions by adding the OVER clause" — `SUM(revenue) OVER (...)` valid.
- `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` is the canonical running-total frame (cumulative up to and including current row).
- Scalar subquery for grand total `(SELECT SUM(revenue) FROM daily_revenue)` runs once.
- **First-crossing predicate is correct and clever**: `cumulative_revenue >= 0.5*total AND cumulative_revenue - revenue < 0.5*total` says "today's cumulative is at or above 50% AND yesterday's cumulative (today's minus today's contribution) was below 50%" — uniquely identifies the single day where the running total first crosses the threshold. No LAG needed because `cumulative - revenue` is the previous day's running total.
- `MIN(revenue_date)` collapses to a single date row (defensive against duplicate-date input; on unique-date input the filter already yields exactly one row).

This is a clever, correct, single-pass first-crossing pattern. Explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` avoids the default RANGE-frame footgun. No analyzer issues.

---

## Q4 — count orders with BOTH 'gift' AND 'express' tags — 5.00 STRONG PASS

**Answer:**
```sql
SELECT COUNT(*) AS order_count
FROM orders
WHERE contains(tags, 'gift') AND contains(tags, 'express')
```

**Scores: Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00**

**Verified vs trino.io/docs/467/functions/array.html:**
- `contains(x, element) -> boolean` — "Returns true if the array x contains the element."
- AND of two `contains` predicates correctly enforces array-has-all (both tags must be present in `tags`).
- `COUNT(*)` returns the scalar order count as requested.
- No UNNEST needed (and would actually be wrong for this question — UNNEST + GROUP BY HAVING COUNT(DISTINCT tag)=2 would also work but is more complex and unnecessary).

Clean composition. The `contains(array, element) AND contains(array, element)` form is the docs-canonical array-has-all idiom.

---

## Teacher-actionable guidance for iter659

**RECOMMEND: DEFAULT NO-OP / DURABILITY-BREADTH.**

Reasoning:
- All four Q's at perfect 5.00.
- **Q1 FIX-A LANDED cleanly across both r07 Pattern B3 (PRIMARY) and r23:652 (SECONDARY) routing destinations** — the iter655/657 invalid window-mixed-with-GROUP-BY hybrid did NOT recur on the "first AND current plan tier per subscriber" probe. The dual-destination inoculation from iter658 worked.
- **The min_by/max_by soft-watch is RESOLVED** — responder selected the PREFERRED aggregate form cleanly (not ROW_NUMBER+MAX(CASE), not window+DISTINCT). Mark resolved.
- No per-Q below the 3.5 floor; no new FIX-A targets identified.

**DO NOT for iter659:**
- Touch the iter658 Pattern B3 DECISION INOCULATION block at r07 (just inserted, proven on first re-probe — HOLDS).
- Re-edit the iter656/iter658 r23:636/r23:652 first-AND-last-per-group anchors (HOLD — broadened keyword anchors routed cleanly).
- Re-edit r07 SUM OVER ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW running-total canonical (Q3 HOLDS).
- Re-edit r23/r07 date_diff('hour', earlier, later) + AVG + ROUND(x,2) canonical (Q2 HOLDS).
- Re-edit r07/r23 `contains(array, element)` AND-AND array-has-all canonical (Q4 HOLDS).
- Touch r22 §13.x federation guardrails (4.49944 row thin, ZERO probe iter645-658 streak = 14 iterations — keep stable).
- Rewrite any iter534-657 locks.
- Add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban).
- Fabricate dayname()/initcap; DISTINCT-ON Postgres-leak (iter634 ban).
- Bump training/state.json (per directive).

**Suggested iter659 probe areas (synthesizable-from-primitives; DO NOT pre-probe):**
- Confirm the FIX-A landing one more time on a different first-AND-last-per-group phrasing (e.g., "first AND latest reading per sensor" or "opening and closing reading per device") to triple-confirm dual-destination inoculation under varied keyword routing.
- Fresh composite from un-re-probed backlog (percentile composites, cohort-retention shapes, INSERT OVERWRITE partition semantics, time-travel re-probe).
- Bulletproofed federation predicate-pushdown re-probe IF opted-in (14-iter zero-probe streak now).

## Topic avg updates

- **Analytical query patterns on Iceberg+Trino / r07**: Q1 FIX-A iter658 Pattern B3 DECISION INOCULATION + min_by/max_by PREFERRED form selection LANDED cleanly (+0.5 BIG durability win — soft-watch RESOLVED); Q3 SUM OVER ROWS-UNBOUNDED-PRECEDING-AND-CURRENT-ROW running-total + first-crossing predicate (cum >= 0.5*total AND cum - revenue < 0.5*total) durability +0.5; Q4 contains(array,elem) AND contains(array,elem) array-has-all durability +0.25 → net UP STRONGLY.
- **SQL query best practices for OLAP / r23**: Q1 r23:652 keyword-anchor broadening routed cleanly via FIX-A SECONDARY destination +0.5 durability; Q2 date_diff('hour',earlier,later) + AVG + ROUND(x,2) + IS NOT NULL guard durability +0.25 → net UP.
- **Federation / r22**: NOT probed — 4.49944 row UNCHANGED (consecutive non-probe count +1 → 14-iter ZERO probe streak iter645-658).

## Trajectory note (iter651→658)

(4.9375 → 4.96875 → 4.6875 → 5.00 → 4.00 → 4.625 → 4.375 → 5.00)

iter655 trough (Q3 invalid hybrid) → iter656 partial recovery (FIX-A v1 LANDED on firmware re-probe) → iter657 partial regression (FIX-A v1 did NOT hold on login-status phrasing — routing landed at first_value/last_value lock which lacked inoculation) → iter658 dual-destination FIX-A v2 LANDED CLEANLY on plan-tier re-probe + min_by/max_by soft-watch RESOLVED → perfect 5.00.

The iter658 lesson: dual-destination inoculation (PRIMARY at the lock the responder lands at by keyword + SECONDARY at the canonical anchor) is the durable fix for the first-AND-last-per-group invalid-hybrid bug. iter659 should hold steady and probe a different first-AND-last-per-group phrasing one more time to confirm the dual-destination model holds across all routing variants.

## VERDICT

**OVERALL 5.00 STRONG PASS — perfect-score iteration; iter658 FIX-A v2 (dual-destination Pattern B3 + r23:652) LANDED CLEANLY; soft-watch on min_by/max_by non-selection RESOLVED (PREFERRED form finally selected); Q2/Q3/Q4 all clean STRONG PASS; federation row stays 4.49944 (ZERO probe 14-iter streak); iter659 recommended DEFAULT NO-OP / durability-breadth continuation.**
