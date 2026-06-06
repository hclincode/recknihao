# Iter 579 Judge Feedback — 2026-06-07 (EXTENDED PHASE)

## Verdict: 5.00 STRONG PASS overall (margin +1.50 above 3.5 floor; +1.0625 swing from iter578's 3.9375)

Q1 5.00 STRONG PASS (interval-overlap THIRD attempt RESOLVED — landing-point signpost ROUTED); Q2 5.00 STRONG PASS (point-event discrimination CLEAN, no over-correction); Q3 5.00 STRONG PASS (AVG OVER () empty window docs-verbatim correct); Q4 5.00 STRONG PASS (TRY_CAST + try() docs-verbatim correct). Overall avg = (5.00 + 5.00 + 5.00 + 5.00)/4 = 20.00/4 = **5.00 STRONG PASS**.

**Headline**: iter579 FIX A — relocating the interval-overlap routing signpost from inside r07 §4 H3 to the TOP of the gap-fill H2 landing point in r07 §1a area — **WORKED**. The 2-iteration recurring FAIL on the start-day-GROUP-BY interval-overlap miss (iter577 reservations FAIL + iter578 desks FAIL) is **RESOLVED ON THE THIRD ATTEMPT**. The meta-rule about findability-fix placement at the responder's landing-point H2 (NOT buried inside topical H3 the responder doesn't open) is now empirically validated on a second controlled test (after iter578's dbt-generic-tests landing-point H2 win).

---

## Per-question scoring

### Q1 (interval-overlap THIRD attempt — the headline durability probe)
**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.00 STRONG PASS**

Question: subscriptions active per day last 30 days, NULL cancel_date = still active, zero-fill empty days.

Responder's SQL:
```sql
WITH calendar AS (SELECT d AS day FROM UNNEST(sequence(current_date - INTERVAL '30' DAY, current_date, INTERVAL '1' DAY)) AS t(d))
SELECT c.day, COUNT(s.subscription_id) AS active_subscriptions
FROM calendar c
LEFT JOIN subscriptions s ON s.signup_date <= c.day AND (s.cancel_date IS NULL OR s.cancel_date > c.day)
GROUP BY c.day ORDER BY c.day;
```

**(i) INTERVAL-OVERLAP RANGE JOIN — CONFIRMED CORRECT.** The responder used the canonical `signup_date <= c.day AND (cancel_date IS NULL OR cancel_date > c.day)` range-join predicate — NOT a `GROUP BY DATE(signup_date)` start-day collapse. Half-open `[signup, cancel)` semantics correct for "active on day X means signed up on or before X AND not yet cancelled by X." A subscription signed Jan 1 and cancelled Jan 20 will appear on every day Jan 1 through Jan 19 (Jan 20 excluded because end is half-open). NULL cancel_date = still active = covers every day from signup_date onward. The recurring iter577/578 start-day-GROUP-BY semantic defect is GONE. Verified `sequence(date, date, INTERVAL '1' DAY)` syntax valid Trino 467 — per docs: `sequence(date '2023-10-20', date '2023-11-11', INTERVAL '7' DAY)` is the documented form.

**(ii) COUNT(s.subscription_id) — CONFIRMED CORRECT.** Uses the non-null right column from the LEFT JOIN, NOT `COUNT(*)`. On a day with zero active subscriptions, LEFT JOIN produces one calendar-only row with all `s.*` columns NULL → `COUNT(s.subscription_id)` returns 0 (the iter577 trap-card-correct form). `COUNT(*)` would have returned 1 on every zero-active day (counting the NULL-padded row itself). Responder explicitly explained this distinction.

**(iii) LEFT JOIN keeps every calendar day — CONFIRMED CORRECT.** Every day Jan 1–30 appears in output even when no subscription overlaps that day. The combination LEFT JOIN + COUNT(non-null right col) is the iter575+iter577-canonical zero-fill form.

**Bonus quality**: responder explicitly named the WRONG-MOVE (`do NOT GROUP BY signup_date — that counts each sub only on its signup day`), explained the overlap predicate counts a sub on every day it spans, and discriminated COUNT(non-null) vs COUNT(*) on LEFT JOIN. This is exactly what the iter579 signpost was designed to route.

**THE iter577/578 RECURRING FAIL IS RESOLVED.** The landing-point signpost at the top of §4 routed the responder correctly on the third attempt.

### Q2 (point-event contrast — discrimination check)
**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.00 STRONG PASS**

Question: daily payment count last 30 days with zero-fill — do I need the interval-overlap thing or is normal GROUP BY date + LEFT JOIN fine?

Responder said: these are DIFFERENT patterns. Payments are POINT EVENTS (one row = one date), so:
```sql
daily_payments AS (SELECT date_trunc('day', paid_date) AS day, COUNT(*) AS cnt FROM payments WHERE paid_date >= current_date - INTERVAL '30' DAY GROUP BY date_trunc('day', paid_date))
SELECT c.day, COALESCE(dp.cnt, 0) AS payment_count
FROM calendar c LEFT JOIN daily_payments dp ON dp.day = c.day
```
Interval-overlap NOT needed because payments don't span days.

**DISCRIMINATION CONFIRMED CLEAN.** Responder correctly distinguished point-event (group-by-date + LEFT JOIN to spine + COALESCE(0)) from interval-active (range-join overlap). Did NOT over-correct by wrongly applying interval-overlap to a point event. This is exactly the signpost discrimination working as designed: route INTERVAL questions to range join, route POINT EVENT questions to gap-fill canonical.

**COUNT(*) here is correct** — the LEFT JOIN is from spine to the PRE-AGGREGATED `daily_payments` CTE; inside the CTE there's no LEFT JOIN so COUNT(*) safely counts payment rows. The COALESCE(0) on the outer LEFT JOIN handles zero-days. This is NOT the iter577 LEFT-JOIN-COUNT(*) trap (that trap is about COUNT(*) directly on a LEFT JOIN to raw facts; here the COUNT happens inside an INNER pre-agg that's then LEFT JOINed to the spine).

### Q3 (global aggregate via empty OVER — FRESH)
**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.00 STRONG PASS**

Question: each order's amount AND overall average across all orders in the same result, no second query/join.

Responder: `AVG(amount) OVER () AS avg_order_amount`. Empty OVER means every row sees the global average computed in one pass. Noted SUM/COUNT/MIN/MAX work the same way.

**VERIFIED at trino.io/docs/current/functions/window.html (VERBATIM)**: "All Aggregate functions can be used as window functions by adding the OVER clause. The aggregate function is computed for each row over the rows within the current row's window frame." An empty `OVER ()` window means the frame is the entire (unpartitioned, unordered) input — i.e., the global aggregate per row. Standard SQL. Zero defects.

### Q4 (TRY_CAST dirty data — FRESH)
**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.00 STRONG PASS**

Question: numeric column has junk ('N/A', blank); CAST fails the whole query; how to get NULL instead?

Responder: `TRY_CAST(amount_str AS DECIMAL(10,2))` returns NULL on unparseable values; `COALESCE(TRY_CAST(...), 0)` for a default; noted `try(expression)` is the general-purpose form for any erroring expression (div-by-zero, invalid JSON), TRY_CAST is the cast-specific sibling.

**VERIFIED at trino.io/docs/current/functions/conversion.html (VERBATIM)**: "**try_cast**(value AS type) → type — Like cast(), but returns null if the cast fails." **VERIFIED at trino.io/docs/current/functions/conditional.html** for `try()`: evaluates an expression and returns NULL on error; useful for corrupt/invalid data; pairs with COALESCE for default values. Both responder claims match docs verbatim. The TRY_CAST vs try() distinction is correct and useful (TRY_CAST is cast-specific; try() wraps any expression).

---

## Topic average updates

**Analytical query patterns on Iceberg+Trino** (Q1 interval-overlap subscriptions re-probe THIRD attempt r07 §1a landing-point signpost + Q2 point-event payments contrast r07 §1a + Q3 AVG OVER () empty window r07 §5 patterns)
- 4.1869/37 → (4.1869·37 + 5.00)/38 = **4.2083/38** (+0.0214 Q1 strong lift; landing-point signpost ROUTED, interval-overlap THIRD-attempt PASS)
- → (4.2083·38 + 5.00)/39 = **4.2287/39** (+0.0204 Q2 strong lift; clean discrimination, no over-correction)
- → (4.2287·39 + 5.00)/40 = **4.2480/40** (+0.0193 Q3 strong lift; global aggregate per row via empty OVER docs-verbatim correct)

**SQL query best practices for OLAP** (Q4 TRY_CAST dirty data r07/r23 patterns)
- 4.4652/147 → (4.4652·147 + 5.00)/148 = **4.4688/148** (+0.0036 Q4 modest lift)

Federation NOT probed — **4.49944/310 row UNCHANGED**.

---

## PRIMARY WINS

1. **CRITICAL PRIMARY: iter577/578 recurring interval-overlap FAIL is RESOLVED on the third attempt.** The iter579 FIX A routing-signpost relocation (from inside §4 H3 to the TOP of the gap-fill H2 landing point in r07 §1a area, BEFORE any gap-fill SQL example, with a one-line cross-ref at the END of the gap-fill canonical) routed cleanly. The responder navigated to the correct interval-overlap pattern instead of the start-day-GROUP-BY trap that had recurred for two consecutive iters. The two-pattern signpost approach (POINT EVENT → group-by-date + LEFT JOIN + COALESCE; INTERVAL → range-join overlap + COUNT(non-null right col)) discriminated correctly on Q2 — did NOT over-correct.
2. **DISCRIMINATION CONFIRMED**: Q1 and Q2 together prove the signpost discriminates rather than blanket-applying. Q1 used interval-overlap (subscriptions span days), Q2 used group-by-date (payments don't). Same iter, same responder, different correct routes. This is the controlled-experiment evidence that the landing-point signpost frames the choice cleanly without forcing a single recipe.
3. **Q3 AVG OVER () empty window** — global-aggregate-per-row pattern docs-verbatim correct.
4. **Q4 TRY_CAST + try()** — both forms docs-verbatim correct; clean cast-specific vs general-purpose distinction.

## PRIMARY FAILURES

None. All four answers PASS at 5.00. Zero defects across accuracy, completeness, clarity, actionability.

---

## Meta-rule observation

**iter579 = 42nd consecutive iter (iter537-579) where meta-rule discipline materially affected the verdict.** This iter validates the CONTROLLED-EXPERIMENT lesson from iter578 (NEW H2 at landing-point won; placement inside non-landing H3 lost) on a SECOND independent case: the same placement-not-content findability principle that fixed dbt-generic-tests in iter578 also fixed interval-overlap in iter579. **The meta-rule is now empirically validated on two structurally different findability fixes**: when content-correct fixes fail to route, the fix is in the wrong PLACE not the wrong WORDS — relocate the steer one level UP the responder's keyword-match tree to where the question's keywords ACTUALLY land, not where a domain expert would topically file it. The "topically correct" file is determined by where the RESPONDER LANDS, not by where the content belongs in a domain expert's mental ontology.

The signpost worked AT THE LANDING POINT (top of gap-fill H2 §1a area) — exactly where iter578's post-mortem predicted the responder would scan first for "every day shown / 0 must appear" framing. The cross-ref at the END of the gap-fill canonical reinforced the routing for any responder that scanned past the signpost.

**WebSearched and verified VERBATIM**:
- trino.io/docs/current/functions/conversion.html: "**try_cast**(value AS type) → type — Like cast(), but returns null if the cast fails."
- trino.io/docs/current/functions/window.html: "All Aggregate functions can be used as window functions by adding the OVER clause. The aggregate function is computed for each row over the rows within the current row's window frame."
- trino.io/docs/current/functions/datetime.html: `sequence(date '...', date '...', INTERVAL '7' DAY)` form is documented.
- trino.io/docs/current/functions/conditional.html: `try()` evaluates an expression and returns NULL on error; pairs with COALESCE for default values.

---

## iter580 directive (next teacher actions)

**HEADLINE STATE**: iter579 RESOLVES the iter577/578 recurring interval-overlap FAIL on the third attempt. The landing-point signpost in r07 §1a (top of gap-fill H2) successfully routes both INTERVAL and POINT-EVENT questions. The fix is durable for at least one third-attempt probe.

**iter580 PRIMARY MOVES**:

1. **FIX A — NO-OP. iter579 signpost is DURABLE for one probe; needs SECOND independent confirmation to mark as fully bulletproofed.** Do NOT touch the §1a landing-point signpost. Do NOT touch the cross-ref at the end of the gap-fill canonical. Do NOT touch the §4 interval-overlap H3 content. iter580 should re-probe interval-overlap on a FOURTH fresh domain framing to confirm the fix holds across a second independent test angle (the iter537 standard is "tested from at least two different question angles" before marking a topic-level fix as durable).

2. **iter580 PROBE TARGETS**:
   - **HIGHEST priority**: re-probe interval-overlap on a FRESH fourth-attempt framing to verify durability — suggest "concurrent video conferences per hour yesterday" or "open support tickets per priority per day this quarter" or "employees employed per day per department last year." Different domain vocabulary (sessions, tickets, employment) than subscriptions/desks/reservations. Goal: confirm the §1a signpost routes from any "X active/open/in-progress per day" framing.
   - **HIGH priority**: re-probe POINT-EVENT contrast (the iter579 Q2 angle) on a fresh fourth-attempt to confirm the signpost discriminates rather than over-correcting — suggest "page views per day last week with zero-fill" or "signups per day last quarter" (point events with zero days). Confirm the signpost does NOT route point events through interval-overlap.
   - **MEDIUM priority**: verify Q3 AVG OVER () empty window durability on a fresh angle — suggest "show each row alongside the customer-level max / min" (needs PARTITION BY OVER (PARTITION BY customer_id)) or "running total alongside per-row value" (needs OVER (ORDER BY date)).
   - **MEDIUM priority**: verify Q4 TRY_CAST durability on a fresh angle — suggest "try() with division by zero" or "TRY_CAST inside a CASE" or "TRY_CAST DATE column with invalid format."
   - **LOW priority**: federation if nudging 4.49944/310 above 4.5 (just outside the 4.5 raised threshold; one strong PASS would cross it). Only if a bulletproofed federation angle exists per the project_all_topics_passed memory.

3. **NO RESOURCE CHURN this iter** — iter579's signpost worked. Do not edit r07 §1a or §4 unless an iter580 probe surfaces a new defect.

4. **CONTINUE the meta-rule discipline**: read for SEMANTICS not STRUCTURE (the iter577/578 SQL had all the structural pieces of an interval-overlap query but the start-day-GROUP-BY semantics gave the wrong answer); place findability fixes at the responder's LANDING POINT (not at the domain-expert-topical location); discriminate findability defects from coverage defects via grep before writing new content.

---

## VERDICT

**iter579 OVERALL: 5.00 STRONG PASS** — interval-overlap recurring FAIL RESOLVED on third attempt (landing-point signpost ROUTED), point-event discrimination CLEAN (did NOT over-correct), AVG OVER () empty window docs-verbatim correct, TRY_CAST + try() docs-verbatim correct. Zero defects across all four questions. The placement-not-content findability meta-rule is now empirically validated on a SECOND independent case. iter580 = NO resource churn, re-probe interval-overlap on a fourth-attempt framing for durability confirmation, no federation churn.
