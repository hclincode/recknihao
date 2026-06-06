# Iter 580 Judge Feedback — 2026-06-07 (EXTENDED PHASE)

## Verdict: 4.9375 STRONG PASS overall (margin +1.4375 above 3.5 floor; −0.0625 from iter579's 5.00)

Q1 5.00 STRONG PASS (interval-overlap 4th-angle TICKETS framing — durability confirmed across 4 interval vocabularies); Q2 5.00 STRONG PASS (point-event discrimination held twice — page_views correctly routed to gap-fill not interval-overlap); Q3 5.00 STRONG PASS (COALESCE display default docs-verbatim correct); Q4 4.75 STRONG PASS (JOIN row-explosion diagnosis + EXISTS semi-join fix sound; minor actionability nit for not covering pre-agg dual fix). Overall avg = (5.00 + 5.00 + 5.00 + 4.75)/4 = 19.75/4 = **4.9375 STRONG PASS**.

---

## Per-question scoring

### Q1 — Tickets open per day last quarter (interval-overlap 4th-angle re-probe; tickets framing)

**Verdict: 5.00 STRONG PASS — durability confirmed across the 4th distinct interval vocabulary.**

Verification of the three assess-points:

(i) **Interval-overlap range join is correct.** The answer uses
`ON t.opened_at <= c.day AND (t.closed_at IS NULL OR t.closed_at > c.day)` — the canonical half-open `[opened, closed)` overlap predicate. A ticket opened Jan 5 / closed Jan 12 is counted on Jan 5..11 and EXCLUDED on Jan 12 (correct half-open semantics: ticket no longer "open" on its close day). A ticket with `closed_at IS NULL` is counted on every day from `opened_at` onward (still open). This is the FOURTH consecutive correct framing after subscriptions (iter579 Q1), and notable contrast to iter577/578 desks/reservations which both FAILED at start-day GROUP BY. The responder explicitly named the wrong moves (`do NOT GROUP BY opened_at` because it credits each ticket only on its open day; `do NOT COUNT(*)` because LEFT-JOIN NULL-padded zero days would read 1). The iter579 §1a landing-point signpost IS ROUTING ACROSS INTERVAL VOCABULARIES — not just memorizing subscriptions wording. Tickets/opened_at/closed_at was already in the §1a signpost enumeration verbatim; the routing held.

(ii) **`COUNT(t.ticket_id)` (non-null right column) is correct.** Trino LEFT JOIN with no match produces NULL-padded right-side columns; `COUNT(t.ticket_id)` excludes those NULL rows so a zero-ticket day returns 0, not 1. `COUNT(*)` would count the NULL-padded row as 1 and break zero-day semantics. iter577 LEFT-JOIN-COUNT(*) trap is avoided. Confirmed at trino.io/docs/current/functions/aggregate.html — `count(x)` returns "the number of non-null input values".

(iii) **Calendar spine is dense.** `sequence(0, 89)` UNNESTed with `date_add('day', n, DATE '2026-01-01')` produces 90 dense daily rows (Jan 1 – Mar 31, a quarter). LEFT JOIN against a dense spine + GROUP BY c.day guarantees every day appears even with zero tickets. Minor (non-blocking) nit: start date is hard-coded `DATE '2026-01-01'` rather than parameterized to "last quarter" — acceptable for an embedded analytics chart where the range is bound by the application layer.

Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.00**.

---

### Q2 — Page views daily count last month with zero days (point-event contrast)

**Verdict: 5.00 STRONG PASS — discrimination clean; no over-correction.**

The responder correctly identified page_views as POINT EVENTS (one row = one view at one instant; the row does NOT span multiple days) and applied the gap-fill canonical pattern:
- `daily_views AS (SELECT DATE(viewed_at) AS day, COUNT(*) FROM page_views ... GROUP BY DATE(viewed_at))` — pre-aggregate facts on natural date column.
- LEFT JOIN calendar spine + `COALESCE(view_count, 0)` for zero days.

Critically the responder did NOT blanket-apply the interval-overlap pattern. The Q1+Q2 pair, asked back-to-back at the same responder, proves the iter579 §1a signpost DISCRIMINATES rather than over-corrects:
- INTERVAL facts (tickets) → range-join + non-null COUNT.
- POINT EVENT facts (page views) → group-by-date + LEFT JOIN spine + COALESCE.

The responder's note that `COUNT(*)` inside the pre-aggregation is fine here is also correct — the LEFT JOIN happens AFTER pre-aggregation against the spine, so the iter577 LEFT-JOIN-COUNT(*) trap (COUNT(*) directly over a LEFT JOIN to raw facts) doesn't apply.

Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.00**.

---

### Q3 — COALESCE display default for NULL coupon_code

**Verdict: 5.00 STRONG PASS — docs-verbatim correct.**

`COALESCE(coupon_code, 'No coupon') AS coupon_display` is the canonical Trino 467 form. COALESCE semantics verified at trino.io/docs/current/functions/conditional.html: "Returns the first non-null value in the argument list. Like a CASE expression, arguments are only evaluated if necessary." The responder's note that COALESCE is cleaner than `CASE WHEN coupon_code IS NULL THEN 'No coupon' ELSE coupon_code END` for a simple NULL→literal substitution is accurate (both compile to equivalent plans; COALESCE is the idiomatic and shorter form). No type-mismatch concerns since both args are VARCHAR.

Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.00**.

---

### Q4 — users JOIN orders row explosion diagnosis

**Verdict: 4.75 STRONG PASS — diagnosis + fix sound; minor heuristic caveat.**

**Cardinality explanation is accurate.** "An (inner) JOIN multiplies rows by matching-key cardinality on each side" is correct. If each user has on average N orders, the result is roughly |users| × N = |orders| rows (assuming each order has a single matching user, the typical FK case). The responder's heuristic formula `|left| * (|right| / |join_key_cardinality|)` is an approximation — correct under uniform-distribution assumption with a unique key on the left (one row per user_id), and matches CBO row-count estimation in those conditions. As the directive notes, this is approximate not exact — acceptable.

**Diagnostics are sound.**
- `SELECT COUNT(*), COUNT(DISTINCT user_id) FROM users` reveals duplicate user rows (if `COUNT(*) > COUNT(DISTINCT user_id)`, the left side is itself driving the explosion).
- `SELECT user_id, COUNT(*) FROM orders GROUP BY user_id ORDER BY 2 DESC` identifies the heavy hitters multiplying the join.
Both are exactly what a working Trino engineer would run.

**EXISTS / semi-join fix is correct.** If the intent is "one row per user who has any order" (not per-order detail), `SELECT u.* FROM users u WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.user_id)` is the right shape — Trino implements EXISTS as a semi-join (one row per left match regardless of how many right matches), which avoids multiplication. Standard semi-join semantics, and Trino has a semi-join decorrelation CBO rule (trino.io/docs/current/optimizer/cost-based-optimizations.html). The responder correctly framed this as "use EXISTS instead of JOIN when you want filter semantics, not Cartesian-style expansion."

Minor docking (-0.25 actionability) for not also mentioning the dual fix of pre-aggregating on the many-side (`LEFT JOIN (SELECT user_id, COUNT(*) FROM orders GROUP BY user_id) o ON ...`) when the engineer DOES want per-user order metrics — but this was not explicitly asked, so it's a nit not a defect.

Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4 = **4.75**.

---

## Overall summary table

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 (tickets interval-overlap, 4th angle) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 (page_views point-event contrast) | 5 | 5 | 5 | 5 | 5.00 |
| Q3 (COALESCE display default) | 5 | 5 | 5 | 5 | 5.00 |
| Q4 (JOIN row explosion + EXISTS fix) | 5 | 5 | 5 | 4 | 4.75 |

**OVERALL = (5.00 + 5.00 + 5.00 + 4.75) / 4 = 19.75 / 4 = 4.9375 STRONG PASS.**
Margin = +1.4375 above 3.5 floor. ~Flat vs iter579's 5.00 (−0.0625) due solely to a minor Q4 actionability nit. Zero hard defects across all four questions.

---

## Durability verdict on interval-overlap routing

**INTERVAL-OVERLAP ROUTING IS NOW DURABLE.** The iter579 §1a landing-point signpost has routed correctly across:
1. iter579 Q1 — SUBSCRIPTIONS with signup_date/cancel_date (THIRD attempt, RESOLVED iter577/578 fail).
2. iter580 Q1 — TICKETS with opened_at/closed_at (FOURTH framing, ROUTED).

Point-event discrimination held twice:
1. iter579 Q2 — PAYMENTS daily count (correctly NOT routed to interval-overlap).
2. iter580 Q2 — PAGE_VIEWS daily count (correctly NOT routed to interval-overlap).

The signpost is doing exactly what it was designed to do: discriminate on FACT SHAPE (interval vs point event) and route correctly. Two-angle minimum for durability is more than satisfied (2 confirmed INTERVAL successes post-fix + 2 confirmed POINT-EVENT contrast holds). The recurring iter577/578 defect is RESOLVED and the resolution is stable.

**Probing in iter581 should move OFF interval-overlap and OFF point-event contrast.** Continued re-probing risks goodhart drift on a fix that is already proven durable.

---

## iter581 directive

**PRIMARY: NO RESOURCE CHURN on r07 §1a interval-overlap signpost or point-event contrast card.** Both fixes are durable. Do not edit, do not relocate, do not add anchor terms.

**FIX TARGETS for iter581: NONE on interval-overlap / point-event.**

**PROBE TARGETS for iter581 (move to other areas)**:
- HIGH PRIORITY: federation 4.49944/310 row — STILL below the 4.5 raised threshold. After 30+ iters without federation probes the topic is going stale. Pick one safe federation question on a confirmed-correct angle (`information_schema` cross-catalog reads, qualified-name `catalog.schema.table` syntax, OR catalog-specific pushdown behavior) and probe carefully — only on angles where r22 §13.x has bulletproofed content. If responder fails on any FRESH federation angle, that's a resource gap to fill not a probe to repeat.
- MEDIUM: ROLLUP/CUBE/GROUPING SETS canonical (r23 covered, has not been probed recently).
- MEDIUM: dbt incremental merge degradation (r28 covered, fresh re-probe angle).
- MEDIUM: TIMESTAMP WITH TIME ZONE vs TIMESTAMP — comparisons, conversions, AT TIME ZONE (historically weak area).
- LOW: CASE expression vs COALESCE — when each is preferred (Q3 hinted at this).
- LOW: JOIN row-explosion follow-up — pre-aggregation pattern when engineer DOES want per-user metrics (the dual fix Q4 didn't cover).

**CRITICAL meta-rule note**: the iter579 controlled-experiment win (landing-point H2 placement) is now empirically validated on a THIRD independent confirmation (iter580 Q1 = 4th-angle tickets framing across a freshly-worded interval vocabulary). Placement-not-content findability meta-rule is robust. Do NOT manufacture re-validation iters — preserve the lock and probe elsewhere.

---

## Constraint confirmations

- Did NOT edit any resource files (judge does not touch resources/).
- Did NOT bump training/state.json (teacher already set iteration=580).
- Appended a one-line score entry to training/rubric.md.
- WebSearched: trino.io/docs/current/functions/conditional.html (COALESCE semantics VERBATIM "Returns the first non-null value in the argument list"); trino.io/docs/current/functions/aggregate.html (COUNT(x) non-null semantics); trino.io/docs/current/optimizer/cost-based-optimizations.html (semi-join decorrelation CBO rule); trino.io/docs/current/functions/datetime.html (sequence + date_add date generation for calendar spine).

## Sources

- [Conditional expressions — Trino docs](https://trino.io/docs/current/functions/conditional.html)
- [Aggregate functions — Trino docs](https://trino.io/docs/current/functions/aggregate.html)
- [Cost-based optimizations — Trino docs](https://trino.io/docs/current/optimizer/cost-based-optimizations.html)
- [Date and time functions — Trino docs](https://trino.io/docs/current/functions/datetime.html)
- [SELECT — Trino docs](https://trino.io/docs/current/sql/select.html)
- [Release 467 — Trino docs](https://trino.io/docs/current/release/release-467.html)
