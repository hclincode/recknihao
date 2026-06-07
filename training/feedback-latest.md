# Iter 657 — Judge Feedback

**Overall: 4.375 PASS** (margin +0.875 above 3.5 floor; swing DOWN from iter656's 4.625; **Q1 REGRESSED — the iter655 window-mixed-with-GROUP-BY invalid hybrid REPRODUCED as the LEAD answer**; the iter656 FIX-A inoculation did NOT fully hold for this phrasing)

---

## Per-question scores

### Q1 — first AND latest login status per user in one row (FIX-A re-probe #3) — **2.50 FAIL (per-Q)**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 2 | **FIX-A REGRESSION.** The LEAD/PRIMARY form (FORM 1) is **INVALID Trino 467**: `SELECT user_id, FIRST_VALUE(login_status) OVER (PARTITION BY user_id ORDER BY logged_at ASC) AS first_login_status, LAST_VALUE(login_status) OVER (PARTITION BY user_id ORDER BY logged_at ASC ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_login_status FROM login_events GROUP BY user_id`. The query has `GROUP BY user_id` but the window functions reference `login_status` and `logged_at` which are NEITHER in GROUP BY NOR aggregated. Verified against trino.io/docs/current/sql/select.html: *"When a GROUP BY clause is used in a SELECT statement all output expressions must be either aggregate functions or columns present in the GROUP BY clause."* Window functions are evaluated AFTER GROUP BY, so their arguments must reference grouped columns or aggregates — bare `login_status` / `logged_at` references in a GROUP BY user_id query raise the analyzer error "must be an aggregate expression or appear in GROUP BY clause." This is the EXACT iter655 Q3 invalid hybrid that iter656 FIX-A (r23:636 DO-NOT-WRITE) was supposed to inoculate against. FORM 2 (`ROW_NUMBER() PARTITION BY user_id ORDER BY logged_at ASC/DESC` in a subquery, then `MAX(CASE WHEN rn_asc=1 THEN login_status END)` + symmetric DESC, GROUP BY user_id in outer) IS valid. But an engineer pasting the lead form gets a parse/analyzer error. Score reflects: lead-form invalidity is dominant — production users paste the first shown query. |
| Completeness | 3 | Two forms given, one valid one not, AND the docs-canonical `min_by(login_status, logged_at) AS first_login_status, max_by(login_status, logged_at) AS last_login_status FROM login_events GROUP BY user_id` aggregate idiom (PREFERRED ✅ at r23:654-663 per iter656 DECISION block) was NOT selected. This is now the **2nd-3rd consecutive non-selection** of min_by/max_by for the "first AND last per group in one row" shape — escalating from soft-watch to ACTIONABLE. |
| Clarity | 3 | Two-form presentation creates choice load, but the broken form is presented as primary with no warning. No flag that FORM 1's combination of window-functions + GROUP BY is invalid. Engineer doesn't know to skip to FORM 2 until the analyzer errors. |
| Actionability | 2 | Engineer pasting FORM 1 hits an analyzer error. Engineer pasting FORM 2 ships. Net actionability depends on which form is copied; lead-form-first paste-behavior is the realistic norm. |

**FIX-A verdict: REGRESSED.** The iter656 r23:636 DECISION block / DO-NOT-WRITE inoculation did NOT prevent recurrence on this phrasing ("first AND latest login STATUS per user in one row"). The responder still reaches for FIRST_VALUE/LAST_VALUE window functions AND still combines them with GROUP BY in the same query level. Hypothesis: the inoculation lives at the min_by/max_by anchor (r23:636) where the responder lands when keyword-routing for "first and last per group" — but the responder is ALSO landing at the first_value/last_value lock (likely r07:something) when keyword-routing for "first AND latest value", and at THAT anchor there is no cross-link warning "if you also want one-row-per-group, do NOT add GROUP BY here — use min_by/max_by." The inoculation needs to exist AT BOTH ROUTING DESTINATIONS, not just at the min_by/max_by anchor.

### Q2 — order status breakdown as percent summing to 100 — **5.00 STRONG PASS**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | `SELECT status, COUNT(*) AS order_count, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS percentage FROM orders GROUP BY status` — exact canonical Trino percent-of-grand-total-with-GROUP-BY form. Verified: `SUM(COUNT(*)) OVER ()` is the double-aggregate idiom where the inner `COUNT(*)` is the per-group aggregate and the outer `SUM(...) OVER ()` is the grand-total window over the post-GROUP-BY result set. `100.0 *` forces float division. ROUND(,2) is 2-arg round to 2 decimal places. Percentages will sum to 100 modulo rounding. Fully valid Trino 467. |
| Completeness | 5 | Single-pass clean query, addresses the "sums to 100" requirement directly. |
| Clarity | 5 | Reads naturally; explains the SUM(COUNT(*)) OVER () pattern in context. |
| Actionability | 5 | Drop-in production-ready. |

### Q3 — average star rating per product to 1 decimal — **5.00 STRONG PASS**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | `SELECT product_id, ROUND(AVG(star_rating), 1) AS avg_rating FROM product_reviews GROUP BY product_id` — trivial composition of AVG aggregate + 2-arg ROUND(x, d) where d=1 decimal place. Verified valid Trino 467 (round signature confirmed at r23:558 + Trino math functions docs). |
| Completeness | 5 | Addresses the question directly, no surplus. |
| Clarity | 5 | One-line query, plain reads. |
| Actionability | 5 | Drop-in production-ready. |

### Q4 — distinct list of all tags across all orders — **5.00 STRONG PASS**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | Two valid forms. FORM 1: `SELECT DISTINCT tag FROM orders CROSS JOIN UNNEST(tags) AS t(tag) ORDER BY tag` — canonical Trino UNNEST-and-distinct idiom; CROSS JOIN UNNEST explodes the array column into one row per element, then SELECT DISTINCT collapses to unique tag values. Fully valid Trino 467 (verified r07:54-61 worked example + trino.io UNNEST docs). FORM 2: `SELECT ARRAY_AGG(DISTINCT tag ORDER BY tag) AS all_tags FROM orders CROSS JOIN UNNEST(tags) AS t(tag)` — single-array-wrap variant. Verified Trino's restriction is: with DISTINCT in an aggregate, the ORDER BY expressions must appear in the aggregate's arguments (per trino/trino issue #20725: "For aggregate function with DISTINCT, ORDER BY expressions must appear in arguments"). In this query, the ORDER BY expression `tag` IS the aggregate argument — same `tag` — so the restriction is satisfied and the form is valid Trino. (This is a NORMAL aggregate, not a window — distinct from the forbidden `array_agg(DISTINCT) OVER (...)` window-DISTINCT shape.) |
| Completeness | 5 | Two valid alternatives covering both "flat distinct list" and "single-array result" framings of the question. |
| Clarity | 5 | Reads naturally; the UNNEST-then-DISTINCT pattern is documented as the standard array-flattening idiom. |
| Actionability | 5 | Either form is drop-in. |

---

## Overall average

(2.50 + 5.00 + 5.00 + 5.00) / 4 = **4.375 PASS**

Per-question pass status: Q1 FAIL (2.50), Q2/Q3/Q4 all 5.00 STRONG PASS. Overall average governs the PASS/FAIL label (per directive — no per-question quality-gate override).

---

## iter658 FIX-A — STRENGTHEN first-AND-last-per-group inoculation (mandatory)

**Failing question**: Q1 at per-Q 2.50 (lowest, and below 3.5 per-Q floor).

**Diagnosis**: The iter656 FIX-A added a DECISION block at r23:636 zone (min_by/max_by anchor) with PREFERRED ✅ for `min_by/max_by` and DO-NOT-WRITE ❌ for the window-mixed-with-GROUP-BY hybrid. This held on iter656 Q1 (firmware version re-probe — 4.50 PASS) but did NOT hold on iter657 Q1 (login status re-probe — 2.50 FAIL). The difference is which keywords the responder routes to first. The iter657 phrasing "first AND latest login STATUS per user in one row" appears to be routing the responder to the FIRST_VALUE/LAST_VALUE window-function lock (likely at r07) — NOT to the r23:636 min_by/max_by anchor where the iter656 DECISION block lives. At the first_value/last_value lock, there is no inoculation reminding the responder "if you ALSO want one row per group, do NOT add GROUP BY here — use min_by/max_by instead." So the responder reaches for first_value/last_value (correct for the one-row-per-event case) and then ALSO bolts on GROUP BY user_id (to collapse to one row per user) → produces the iter655 invalid hybrid.

**Recommended teacher action for iter658**:

1. **(PRIMARY)** Add a cross-link / inoculation block AT the first_value/last_value lock itself (find via grep `first_value` in r07). The block should say verbatim something like:

   > **DO NOT combine first_value/last_value with GROUP BY in the same query level.** If you want ONE ROW PER GROUP (e.g., one row per user with their first AND latest status), do NOT add GROUP BY to a first_value/last_value query — first_value/last_value are window functions and produce one row per INPUT row (or one row per partition only with SELECT DISTINCT). For one-row-per-group "first and last value per group" use `min_by(value, ordering_col)` + `max_by(value, ordering_col) GROUP BY group_col` — see r23:636 DECISION block.

   This ensures the responder hits the warning at WHICHEVER routing destination it lands at — both the min_by/max_by anchor AND the first_value/last_value anchor get the inoculation.

2. **(SECONDARY)** Make min_by/max_by even MORE unmissable as THE canonical answer for the "first AND last value per group in one row" shape:
   - Add additional keyword anchors at r23:636 zone for the iter657 phrasings: "first and latest login status per user", "earliest and most recent value per group", "first and last STATE per ID". The current keyword anchors apparently miss the "STATUS per USER" phrasing.
   - Consider adding a short DECISION TREE near top of r23 ordering helpers section: "Need first AND last value per group in one row? → min_by/max_by aggregate. Need first/last value per partition with one row per INPUT row? → first_value/last_value window. NEVER combine window-function shape with GROUP BY in same query level."

3. **(SOFT-WATCH escalating to ACTIONABLE)** min_by/max_by non-selection has now occurred on iter656 Q1 (didn't reach canonical but FORMs were valid) AND iter657 Q1 (didn't reach canonical AND lead FORM was invalid). Two consecutive non-selections + one invalidity. This is no longer "soft-watch" — it is the **iter658 FIX-A**. If after iter658's edits the responder STILL doesn't route to min_by/max_by on the next re-probe, consider a more drastic restructuring (e.g., moving the min_by/max_by DECISION block to the TOP of r23 or to r07 itself).

---

## What's working well (do NOT touch)

- Q2 percent-of-grand-total with `SUM(COUNT(*)) OVER ()` — fully locked, canonical answer.
- Q3 `ROUND(AVG(x), 1)` — trivial composition is reliably synthesized from primitives.
- Q4 CROSS JOIN UNNEST + DISTINCT — canonical Trino array-flattening idiom is reliably routed.
- These three answers are textbook-perfect and demonstrate the resources are well-organized for their respective shapes.
