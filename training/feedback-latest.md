# Iter 655 — Judge Feedback

**Overall: 4.00 PASS** (margin +0.50 above 3.5 floor; -1.00 swing DOWN from iter654's 5.00 perfect; governing label = PASS because overall avg >= 3.5; Q3 individual per-Q FAIL flagged separately as FIX-A target — per directive, do NOT apply per-Q gate override)

---

## Per-question scores

### Q1 — per-customer running order-sequence number 1,2,3 by date — **5.00 STRONG PASS**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date ASC) AS order_sequence` — exact canonical form. Verified trino.io/docs/current/functions/window.html: "Returns a unique, sequential number for each row, starting with one, according to the ordering of rows within the window partition." 1, 2, 3, ... strictly increasing per partition; ASC numbers oldest→newest. Matches r27:1626 + r23:996 + r07:2042 verbatim. |
| Completeness | 5 | Single-step compose, full SQL, partition + order specified, ASC explicit. |
| Clarity | 5 | Clean one-liner, plain-English semantics. |
| Actionability | 5 | Engineer pastes and ships. |

### Q2 — each payment method's count as percent of all transactions — **5.00 STRONG PASS**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | `SUM(COUNT(*)) OVER ()` is the docs-canonical share-of-bucket-counts idiom. Verified trino.io/docs/current/functions/window.html: "All Aggregate functions can be used as window functions by adding the OVER clause." `100.0 *` (decimal literal) correctly avoids integer-division trap. ROUND(..., 1) for clean display. GROUP BY payment_method + SELECT only grouped + aggregated columns — GROUP-BY rule satisfied. Matches r07:1263 LEADING CANONICAL decision-row exactly. |
| Completeness | 5 | Full query with count + percent + ORDER BY pct DESC. |
| Clarity | 5 | One natural query, no nested CTEs needed. |
| Actionability | 5 | Drop-in production-ready. |

### Q3 — first AND last status per ticket in one row — **1.75 PER-Q FAIL**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 1 | **CRITICAL VALIDITY BUG: the query DOES NOT EXECUTE.** The responder wrote `SELECT ticket_id, first_value(status) OVER (PARTITION BY ticket_id ORDER BY changed_at ASC) AS first_status, last_value(status) OVER (PARTITION BY ticket_id ORDER BY changed_at ASC ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_status FROM ticket_events GROUP BY ticket_id`. Trino's GROUP BY rule (verified trino.io/docs/current/sql/select.html + analyzer behavior): every column referenced in SELECT — INCLUDING inside a window function's arguments and its OVER clause's PARTITION BY / ORDER BY — must be either in GROUP BY or aggregated. Here `status` and `changed_at` are referenced inside `first_value(status)` / `last_value(status)` / `ORDER BY changed_at` but are NEITHER grouped (only `ticket_id` is) NOR aggregated. Trino's analyzer rejects with: `'status' must be an aggregate expression or appear in GROUP BY clause`. The query is broken. The CORRECT one-row-per-ticket form is the aggregate `min_by`/`max_by` pattern: `SELECT ticket_id, min_by(status, changed_at) AS first_status, max_by(status, changed_at) AS last_status FROM ticket_events GROUP BY ticket_id` — which IS aggregated, collapses to one row per ticket, and picks the status at earliest/latest changed_at. This canonical IS in resources at r23:636 (iter638 PIN explicitly mentions "the status at the earliest update and the status at the latest update per order — min_by(status, updated_at) AS first_status, max_by(status, updated_at) AS latest_status") and r23:643-644 verbatim, but the responder did NOT reach it. Alternative valid window form: drop GROUP BY entirely (gives one row per event) and wrap in SELECT DISTINCT to collapse — but the responder did neither. |
| Completeness | 2 | Intent (first + last per ticket in one row) is right; execution path is broken. Missed the canonical min_by/max_by route that resources HAVE. |
| Clarity | 3 | Looks readable to a beginner, which is part of the danger — they paste it and get an analyzer error with no idea why. |
| Actionability | 1 | Engineer copies, runs, fails. Worse than no answer because it looks plausible. |

### Q4 — ROUND vs TRUNCATE to 2dp (e.g. 1.235) — **4.25 PASS**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 4 | `ROUND(1.235, 2) → 1.24` HALF_UP is correct (verified r23:558 source-quoted DecimalConversions.java + DecimalCasts.java both use `setScale(..., HALF_UP)`; trino.io/docs/current/functions/math.html publishes `round(x, d)` signature; mode source-verified HALF_UP). The truncation form `FLOOR(1.235 * 100) / 100 → 1.23` is correct FOR POSITIVE values, but `FLOOR` is toward NEGATIVE INFINITY, not toward zero — these DIFFER on negatives (`FLOOR(-1.235*100)/100 = -1.24`, while true truncate-toward-zero gives `-1.23`). The Trino-canonical truncation idiom is `truncate(x*100)/100` (verified trino.io/docs/current/functions/math.html: "truncate(x) — returns x rounded to integer by dropping digits after decimal point" = toward-zero; r27:1143-1145 + r27:1300-1301 + r27:1335 verbatim). For the stated positive-revenue use case the two are equivalent and the answer is functionally correct; for the GENERAL case the responder's FLOOR substitute is wrong-on-negatives. Minor accuracy nuance — not a fatal error. Also missed: Trino `truncate(x)` is 1-arg ONLY (no 2-arg `truncate(x, d)` overload). |
| Completeness | 4 | Covered both functions, tie-case worked example, plain explanation; missed (a) `truncate(x*100)/100` as the docs-canonical toward-zero form, (b) the FLOOR-vs-truncate divergence on negatives, (c) the 1-arg-only constraint on Trino `truncate`. |
| Clarity | 5 | Clean half-up vs drop-digits framing with the concrete 1.235 → 1.24 vs 1.23 example. |
| Actionability | 4 | Works for positive revenue figures; small risk if engineer later applies the FLOOR pattern to a column that can go negative. |

---

## Overall computation

Per-Q averages: (5.00 + 5.00 + 1.75 + 4.25) / 4 = 16.00 / 4 = **4.00**

Dim-avg cross-check:
- Accuracy: (5+5+1+4)/4 = 3.75
- Completeness: (5+5+2+4)/4 = 4.0
- Clarity: (5+5+3+5)/4 = 4.5
- Actionability: (5+5+1+4)/4 = 3.75
- Overall: (3.75 + 4.0 + 4.5 + 3.75)/4 = 16.0/4 = **4.00** — agrees.

**Governing label = PASS** (overall avg 4.00 >= 3.5 by margin +0.50). Per directive: overall average governs PASS/FAIL — do NOT apply per-Q gate override. Q3 individual per-Q score of 1.75 is below floor and is flagged as the FIX-A target but does NOT flip the iteration label.

---

## iter656 FIX-A — first AND last value per group → min_by/max_by GROUP BY DECISION CANONICAL (NOT first_value/last_value mixed with GROUP BY)

**Bug surface (Q3)**: Responder produced `SELECT ticket_id, first_value(status) OVER (PARTITION BY ticket_id ORDER BY changed_at) ..., last_value(status) OVER (... ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) ... FROM ticket_events GROUP BY ticket_id`. Trino's GROUP BY rule rejects this — `status` and `changed_at` are inside window functions but are neither grouped (only `ticket_id` is) nor aggregated. Analyzer error: `'status' must be an aggregate expression or appear in GROUP BY clause`. Query does not execute.

**Root cause**: Responder conflated two valid strategies into an invalid hybrid:
1. **Aggregate form**: `SELECT ticket_id, min_by(status, changed_at), max_by(status, changed_at) FROM ticket_events GROUP BY ticket_id` — uses AGGREGATES + GROUP BY, collapses to 1 row per ticket.
2. **Window form (no GROUP BY)**: `SELECT DISTINCT ticket_id, first_value(status) OVER (PARTITION BY ticket_id ORDER BY changed_at ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING), last_value(status) OVER (...) FROM ticket_events` — uses WINDOW functions WITHOUT GROUP BY, plus SELECT DISTINCT to collapse.

The responder mixed (1)'s GROUP BY with (2)'s window functions — Trino rejects because window arguments aren't satisfying the GROUP BY rule.

**Canonical resource state**: r23:636 (iter638 PIN) explicitly anchors `min_by(status, updated_at) AS first_status, max_by(status, updated_at) AS latest_status` for "the status at the earliest update and the status at the latest update per order" — exact Q3 shape with order→ticket. r23:643-644 worked example verbatim. The canonical EXISTS but the responder did not route to it.

**Recommended iter656 edit**: Add a 1-card DECISION CANONICAL / LANDING-POINT REINFORCEMENT at r23:636 area (titled something like "first AND last value of column X per group, one row per group → min_by/max_by aggregate GROUP BY (NOT first_value/last_value mixed with GROUP BY)"). Cross-anchor:
- Keywords: `first and last`, `earliest and latest`, `status at first and last event`, `first AND last status per ticket`, `window function with GROUP BY`, `first_value last_value with GROUP BY`, `must be aggregate or in GROUP BY`.
- Cross-link from any existing first_value/last_value canonical card so a responder searching either keyword family lands on the DECISION before writing the broken hybrid.
- Add explicit DO-NOT-WRITE inoculation: `first_value(status) OVER (PARTITION BY ticket_id ORDER BY changed_at) ... GROUP BY ticket_id → INVALID. status and changed_at are neither grouped nor aggregated. Use min_by/max_by aggregate form OR drop GROUP BY and wrap in SELECT DISTINCT.`

Single targeted edit; no broad rewrite. After FIX-A, re-probe Q3-shape from a different angle (e.g. "first and last login_method per user", "earliest and latest event_type per session") to confirm durability.

---

## Q4 nuance (minor — WATCH-ITEM, not FIX-A)

The responder used `FLOOR(x*100)/100` as the truncation form. FOR POSITIVE values this is equivalent to canonical `truncate(x*100)/100`. For NEGATIVE values they DIFFER (FLOOR rounds toward -infinity, truncate rounds toward zero):
- `FLOOR(-1.235*100)/100 = -1.24` (toward -infinity)
- `truncate(-1.235*100)/100 = -1.23` (toward zero)

Resources have correct `truncate(x*100)/100` canonical at r27:1143-1145 + r27:1300-1301 + r27:1335. Minor accuracy nudge only — not a FIX-A target because: (a) iter655 question framed in positive-revenue context, (b) tie-case worked example (1.235 → 1.24 vs 1.23) is correct, (c) overall framing is sound. If a future probe asks about truncation on signed values (negative balances, P&L) and responder repeats FLOOR substitution, add a 1-line inoculation at r27:1335 explicitly calling out FLOOR-vs-truncate-on-negatives divergence. Until then, HOLD.

---

## Topic average updates

- **SQL query best practices for OLAP / r23** — Q3 first-AND-last-status-per-ticket FAIL (responder produced broken window-mixed-with-GROUP-BY hybrid instead of routing to r23:636 canonical) -1.0 ding; Q4 round-vs-truncate-2dp FLOOR-instead-of-truncate minor accuracy nuance -0.1. Net DOWN this iter — primarily on Q3.
- **Analytical query patterns on Iceberg+Trino / r07** — Q1 ROW_NUMBER per-customer running-counter ASC durability-confirmed +0.25; Q2 percent-of-total payment_method share via SUM(COUNT(*)) OVER () durability-confirmed +0.25. Net UP slightly.
- **Oracle PL/SQL → dbt + Trino / r27** — Q4 round(x,d) HALF_UP semantics durability-confirmed +0.25; truncate(x*100)/100 toward-zero canonical durability-confirmed at r27:1143/1335 still HOLDS even though responder used FLOOR substitute. Net flat.
- **Federation** — NOT probed this iter, 4.49944/322 row UNCHANGED (consecutive non-probe count +1 → 323; ZERO probe iter645-655 streak = 11 iterations).

---

## DO NOT (per discipline)

- DO NOT touch r22 §13.x federation guardrails (4.49944/323 thin, ZERO probe 11-iter streak).
- DO NOT re-edit r07:1263 percent-of-total share canonical (Q2 HOLDS clean).
- DO NOT re-edit r27:1626 ROW_NUMBER ASC running-counter canonical (Q1 HOLDS clean).
- DO NOT re-edit r27:1143/1335 round-vs-truncate canonical (Q4 minor nudge only — content is correct; responder used FLOOR substitute that works for positive values; no FIX needed unless future probe asks about negatives).
- DO NOT rewrite iter534-654 locks.
- DO NOT add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban).
- DO NOT fabricate dayname()/initcap.
- DO NOT add DISTINCT-ON Postgres-leak (iter634 ban).
- DO NOT bump training/state.json (per directive).

---

## Verified docs (Trino 467)

- trino.io/docs/current/functions/window.html — ROW_NUMBER semantics; "All Aggregate functions can be used as window functions by adding the OVER clause."
- trino.io/docs/current/sql/select.html — GROUP BY rule: SELECT columns must be grouped or aggregated; this applies INSIDE window function arguments and OVER clauses too.
- trino.io/docs/current/functions/aggregate.html — min_by(x, y) / max_by(x, y) signatures: "Returns the value of x associated with the minimum/maximum value of y over all input values."
- trino.io/docs/current/functions/math.html — round(x, d) signature; truncate(x) 1-arg only "drops digits after decimal point" (toward-zero); FLOOR(x) "returns x rounded down to the nearest integer" (toward -infinity, NOT toward zero — they diverge on negatives).

---

## Meta-note

iter655 is the first FAIL-per-Q iteration in a sustained STRONG-PASS streak (iter651: 4.9375, iter652: 4.96875, iter653: 4.6875, iter654: 5.00). The overall 4.00 PASS label holds because Q1 + Q2 are perfect 5.0 anchoring the average, but Q3 collapsed to 1.75 on a real Trino validity bug — the responder mixed window functions with GROUP BY in a way that the analyzer rejects. The fix is NOT to add new content (resources already have the correct min_by/max_by canonical at r23:636/643-644 from iter638 PIN); the fix is a LANDING-POINT REINFORCEMENT / DECISION CANONICAL that explicitly says "for first AND last value per group, use min_by/max_by + GROUP BY; do NOT mix first_value/last_value window functions with GROUP BY because the window arguments aren't grouped/aggregated → analyzer error." Cross-anchor so the responder hits the decision BEFORE writing the broken hybrid.

The Q4 FLOOR-instead-of-truncate is a minor and the answer is correct for the stated positive-revenue use case; do not over-fix.

iter656 recommended action: **FIX-A = r23 first-AND-last-value-per-group DECISION CANONICAL** (1 new card at r23:636 area + inoculation against first_value/last_value mixed with GROUP BY + cross-anchor to keywords). Single targeted edit, no broad rewrite. After FIX-A, if Q3-shape re-probes from a different angle pass cleanly, the lock is durable.

**OVERALL: 4.00 PASS — Q1+Q2 perfect anchor the average; Q3 hard per-Q FAIL on window-mixed-with-GROUP-BY validity bug = iter656 FIX-A target (DECISION CANONICAL at r23:636 area + first_value/last_value-mixed-with-GROUP-BY inoculation); Q4 minor FLOOR-instead-of-truncate nudge held as WATCH-ITEM; federation NOT probed (4.49944/323 ZERO probe 11-iter streak).**
