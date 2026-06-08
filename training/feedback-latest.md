# Judge Feedback — iter710

**Verdict: PASS** (overall avg 4.0625; threshold 3.5)
**FIX-A status (Q1 — 2-bucket has-X-vs-doesn't rollup):** CLOSED
**Q3 defect (first query, ungrouped column in GROUP BY):** genuine analyzer-error defect; resource teaches the rule (r23:1770-1805, r07:1573-1635, r23:2421) so this is a **responder synthesis slip**, not a missing-content gap. Findable; flag as a candidate FIX-A only if it recurs.

---

## Per-question sub-scores

### Q1 — two-totals summary (logged-in vs never-logged-in) — FIX-A re-probe

**Shape returned:** two scalar subqueries in the SELECT list — `SELECT (SELECT COUNT(DISTINCT user_id) FROM users u WHERE EXISTS (... )) AS users_with_logins, (SELECT COUNT(DISTINCT user_id) FROM users u WHERE NOT EXISTS (...)) AS users_never_logged_in;` — **one row, two columns**. Not a row per user. Not the iter709 grain-wrong `GROUP BY customer_id, label` form.

Verified against Trino 467 docs:
- Scalar subqueries in SELECT — valid (each correlated subquery returns a single scalar).
- `NOT EXISTS` — valid, NULL-safe anti-join (unlike `NOT IN` with nullable RHS).
- Output grain is exactly the two totals asked for.

This is a third valid shape next to the teacher's GROUP-BY-label 2-row form and the `COUNT(*) FILTER` single-row form — all three answer the question correctly. The responder did NOT reproduce the iter709 grain-wrong `GROUP BY customer_id, label` defect. **Q1 FIX-A is CLOSED.**

Minor wart: `COUNT(DISTINCT user_id)` is slightly heavier than needed since `user_id` in `users` is presumed unique — `COUNT(*)` would do — but not wrong, just defensive.

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | Scalar subqueries, `NOT EXISTS` semantics, two-column-one-row grain all correct in Trino 467. |
| Completeness | 4 | Got the answer + NULL-safety contrast vs `NOT IN`. Could have mentioned the GROUP-BY-label 2-row form or `COUNT(*) FILTER` as siblings. |
| Clarity | 4 | Compact; two nested subqueries are denser than the GROUP-BY-label form would be for a beginner. |
| Actionability | 5 | Drop-in SQL with both totals labeled. |

**Q1 avg: 4.50**

---

### Q2 — parse text ISO-ish timestamp string

Verified against trino.io/docs/current/functions/datetime.html:
- `parse_datetime(string, format)` → `timestamp with time zone`, Joda-Time format — correct.
- Joda escaping of literal `T` via doubled single quotes (`''T''`) — correct.
- `date_parse(string, format)` → `timestamp` (no tz), MySQL-style %-specifiers — correct.
- Can't-use-SELECT-alias-in-WHERE — correct (WHERE evaluates before SELECT projection; per trinodb/trino #16533).

Gap: the literal input "2026-06-08T14:32:00" is canonical ISO-8601 — the most idiomatic Trino 467 form is `from_iso8601_timestamp(created_at)` (single arg, no format string). The responder's two offered forms WORK but `from_iso8601_timestamp` would be the cleanest answer; this is a completeness ding, not an accuracy one.

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | Both `parse_datetime` and `date_parse` valid Trino 467; format strings correct; alias-in-WHERE warning accurate. |
| Completeness | 3 | Missed `from_iso8601_timestamp` — the most direct answer for ISO-8601 input. Could also have noted that partition pruning won't engage on a parsed text column vs a native timestamp column. |
| Clarity | 4 | Clear; Joda quote-escaping is fiddly to read but explained. |
| Actionability | 4 | Drop-in WHERE clause + alias caveat. |

**Q2 avg: 4.00**

---

### Q3 — custom status sort (CRITICAL defect)

**FIRST query is INVALID Trino 467.** `SELECT ticket_id, status, COUNT(*) ... GROUP BY status` — `ticket_id` is neither grouped nor aggregated. Trino 467 analyzer rejects with `'ticket_id' must be an aggregate expression or appear in GROUP BY clause` (verified via AWS re:Post + r23:1774 in repo). The responder's own prose justification — "the CASE in ORDER BY is aggregate-like, legal in ORDER BY even though not in GROUP BY" — addresses the wrong concern. The ORDER BY CASE on the grouping column IS legal; the bug is `ticket_id` in SELECT.

Worse, the first query also has a **grain confusion of the iter709/710 FIX-A family**: mixing per-row `ticket_id` with a `GROUP BY status` aggregate. If `ticket_id` were moved to GROUP BY it would silently change the grain to one row per (ticket, status) pair — same shape-confusion family FIX-A is meant to inoculate against.

**SECOND query is valid Trino 467:**
- `SELECT status, CASE ... AS sort_order, COUNT(*) FROM support_tickets GROUP BY status ORDER BY sort_order` — every non-aggregate SELECT column (`status`) is in GROUP BY; the `sort_order` CASE depends only on the grouping column; ORDER BY by SELECT-list alias name IS allowed (unlike GROUP BY by alias). Clean.

The literal question ("sort statuses Open→In Progress→Resolved→Closed") has a simpler correct answer the responder never offered: `SELECT ticket_id, status FROM support_tickets ORDER BY CASE status WHEN 'Open' THEN 1 ... END` (no GROUP BY, no COUNT). The responder over-aggregated.

**Resource gap check:** r23:1770-1805 has an extensive diagnostic for exactly this error class ("'X' must be an aggregate expression or appear in GROUP BY clause"), with the email-domain stray-column canonical, three remedies, and even a row in the "same trap" table — `"How many orders per status?" — stray column trap: SELECT order_id, status, COUNT(*) ... GROUP BY status — stray order_id`. That row is literally Q3's bug. r07:1573-1635 also has the rule. The content IS there and findable — the responder failed to apply it.

Verdict: **responder synthesis slip**, not a content gap. Keyword anchors in r23:1799-1803 cover "How many orders per status?" — close to Q3's phrasing. If this defect repeats in iter711, a FIX-A inserting an "ORDER BY CASE for custom sort" companion that links to the stray-column diagnostic would be warranted, but a single occurrence is more likely synthesis noise than systemic.

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 2 | First query is a hard analyzer error; second is correct. Showing an invalid query AS the lead canonical, with a misleading prose justification, is a serious accuracy failure. |
| Completeness | 3 | Second query is correct; missed the no-GROUP-BY shape that literally answers the question. |
| Clarity | 3 | Reasoning prose is actively misleading ("the CASE is aggregate-like, legal in ORDER BY even though not in GROUP BY" — fixes the wrong thing). |
| Actionability | 3 | Second query is copy-paste runnable. A reader who copies the first one will see a Trino error. |

**Q3 avg: 2.75**

---

### Q4 — count distinct products per customer

Verified against Trino 467 docs:
- `COUNT(DISTINCT col)` with `GROUP BY` — valid, NULL-skipped.
- `approx_distinct(col)` — HyperLogLog, ~2.3% standard error. Correctly attributed to `approx_distinct`, NOT confused with `approx_percentile` (the iter697 sketch lock holds).
- `ORDER BY num_unique_products DESC` clean (alias in ORDER BY is allowed).

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | Both forms correct; NULL-skip note accurate; HLL attribution correct. |
| Completeness | 5 | Exact answer + scale-out fallback. |
| Clarity | 5 | One-line beginner-friendly explanation of why DISTINCT is needed. |
| Actionability | 5 | Copy-paste runnable. |

**Q4 avg: 5.00**

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 4 | 4 | 5 | 4.50 |
| Q2 | 5 | 3 | 4 | 4 | 4.00 |
| Q3 | 2 | 3 | 3 | 3 | 2.75 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg: 4.0625 → PASS** (16 sub-scores summed = 65; 65/16 = 4.0625)

---

## Teacher feedback for iter711

**Primary signal:** Q1 FIX-A is closed — the responder routed cleanly to a valid 2-totals shape (scalar subqueries in SELECT) and did not regress to the iter709 GROUP-BY-customer-id grain bug. The iter710 sibling card landed correctly.

**Q3 defect — synthesis slip on already-covered content.** r23:1770-1805 already has the comprehensive stray-column diagnostic with `"How many orders per status?"` literally in the same-trap table — but the responder synthesized an invalid query anyway and tacked on a misleading prose justification.

Possible iter711 directions (only one, low-risk, NOT both):

1. **MINIMAL — add a one-line guard:** at the top of any "ORDER BY CASE for custom sort" anchor in r07, add an explicit "if your sort question does NOT also ask for a count, DO NOT add GROUP BY — sort the raw rows" guard. Addresses the over-aggregation pattern (responder added unnecessary GROUP BY).

2. **DEFER:** treat Q3 as a one-off synthesis slip; re-probe in iter711 with a similar custom-sort phrasing (e.g., "sort priorities low→medium→high→critical") to see if it recurs. If it recurs, then write a FIX-A; if it doesn't, no new content needed.

**Recommendation: option 2 (DEFER).** The content is already in r23; adding more risks bloat without addressing the actual failure mode (the responder didn't read r23's diagnostic, or read it and didn't apply it). One occurrence with three correctly-handled neighbors (Q1, Q2, Q4 all PASS) is below the threshold for a content fix. Per the "reconcile don't append" guidance — and per the "near-threshold topics need consistently-accurate answers" memory — adding another card in r07 for a topic r23 already covers risks the responder citing the wrong one.

**Q2 minor completeness:** consider extending the parse-datetime-from-string anchor with `from_iso8601_timestamp(string)` listed FIRST for ISO-8601 input (the most common SaaS log-event format), with `parse_datetime` Joda and `date_parse` MySQL-style retained as format-string fallbacks. Small inclusivity win, not a fix.

**Locks held — DO NOT REWRITE:** all 260+ prior locks remain in force. The iter710 sibling card (2-bucket has-X-vs-doesn't rollup) is now confirmed working — keep it intact. resources/22 federation file remains HARD LOCKED.

**PIN TRINO 467** — all dialect forms verified against trino.io/docs/current and the 467 release notes; nothing in this iteration requires updating the ban list.

Sources verified:
- [Trino datetime functions](https://trino.io/docs/current/functions/datetime.html) — parse_datetime, date_parse, from_iso8601_timestamp
- [Trino SELECT — GROUP BY rules](https://trino.io/docs/current/sql/select.html)
- [AWS re:Post — "must be an aggregate expression or appear in GROUP BY clause"](https://repost.aws/questions/QU9yS3JVk_R1WXCQJoS_uzTw/must-be-an-aggregate-expression-or-appear-in-group-by-clause)
- [trinodb/trino #16533](https://github.com/trinodb/trino/issues/16533) — GROUP BY does not accept SELECT-list alias by name
