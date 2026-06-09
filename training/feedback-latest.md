# Judge Feedback — iter782 (EXTENDED phase) — FINDABILITY FIX-A verification

**Overall: 4.625 / 5 — PASS** (per-Q avg 4.50 / 4.625 / 4.625 / 4.75 = 18.50 / 4; margin +1.125; overall avg governs, no per-Q veto)

Federation (r22) NOT probed this sweep. All dialect claims verified vs trino.io/docs/467 + GitHub trinodb/StarRocks issues on 2026-06-09. resources/ NOT treated as ground truth.

---

## Per-question scores

### Q1 — DATE-SERIES RE-PROBE (monthly grain, zero-fill gaps) — avg 4.50
| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 4 |
| Clarity | 5 |
| Actionability | 4 |

`SELECT d.day, COALESCE(s.revenue,0) FROM UNNEST(sequence(DATE '2025-01-01', DATE '2025-12-31', INTERVAL '1' MONTH)) AS d(day) LEFT JOIN monthly_revenue s ON s.month = d.day ORDER BY d.day`.

**THE FIX WORKED.** The responder LED with the `sequence()`+`UNNEST` date-spine, applied it at MONTHLY grain, and DID NOT decline (vs iter781 Q2 which declined). The iter782 elevation of the direct date-form spine to first-shown at r07:1243-1255 with keyword anchors closed the gap.

VERIFIED against trino.io/docs/467/functions/array.html + WebSearch: `sequence(start, stop, step)` returns an ARRAY with BOTH bounds INCLUSIVE; step may be `INTERVAL YEAR TO MONTH`. Starting from Jan 1 stepping `INTERVAL '1' MONTH` lands on each month's 1st → Jan 1 … Dec 1 = **12 elements**, correct for "all 12 months even zero months." `UNNEST … AS d(day)` → one row per month; `LEFT JOIN` keeps every month; `COALESCE(revenue,0)` zero-fills. Logic fully correct.

Minor (no penalty, drives Comp4/Act4): (1) trinodb/trino issue #24591 documents that `sequence(DATE, DATE, INTERVAL)` actually returns `array(timestamp(0))`, not `array(date)` — the join `ON s.month = d.day` still matches under date/timestamp coercion at midnight, so the answer is not broken, but the type subtlety went unmentioned. (2) Assumes `monthly_revenue.month` is stored as the first-of-month DATE; reasonable but unstated. Neither is a defect.

### Q2 — TABLE SCHEMA INSPECTION (columns + types, no row scan) — avg 4.625
| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 4.5 |
| Clarity | 5 |
| Actionability | 4 |

`DESCRIBE iceberg.analytics.customer_events;` and `SHOW COLUMNS FROM iceberg.analytics.customer_events;`. VERIFIED both return column name/type/extra from the metastore WITHOUT scanning rows — correct Trino. Fully answers the question.

**Citation oddity (not a correctness error):** responder cited the federation file r22 for a generic Trino DDL-inspection statement. DESCRIBE/SHOW COLUMNS are not federation-specific. This is SOURCING imprecision; accuracy NOT penalized. A fuller alternative `SELECT * FROM information_schema.columns WHERE table_name='customer_events'` was not mentioned (minor Comp/Act nit).

### Q3 — SET INTERSECTION (customers in BOTH sets) — avg 4.625
| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 4.5 |
| Clarity | 5 |
| Actionability | 4 |

`SELECT customer_id … WHERE event_type='support_ticket' INTERSECT SELECT customer_id … WHERE event_type='churn'`. VERIFIED against trino.io/docs/467: `INTERSECT` returns DISTINCT rows present in both queries — exactly correct for "IDs in both sets." Dedup note correct; `COUNT(*)` wrap for a count correct; INNER JOIN alternative for extra columns correct.

**Citation oddity (not a correctness error):** responder cited r07 line 530 `array_intersect` — the ARRAY set function — for a ROW-LEVEL `INTERSECT`. Confirmed via Grep: r07:530 is the array-function table row, NOT a row-set-operations card. The answer correctly used the SQL `INTERSECT` operator anyway, so this is findability/citation imprecision, not a defect. **There is no dedicated row-level INTERSECT/EXCEPT/UNION set-operations card in resources** — a small anchor would prevent the responder from leaning on the array function as its only nearby reference.

### Q4 — 15-MIN TIME BUCKETS (truncate timestamp down to interval start) — avg 4.75
| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 4.5 |
| Clarity | 5 |
| Actionability | 4.5 |

`date_trunc('minute', page_timestamp) - INTERVAL '1' MINUTE * (EXTRACT(MINUTE FROM page_timestamp) % 15) AS bucket_start`, `COUNT(*) GROUP BY 1`.

**INTERVAL-MULTIPLICATION VERDICT: VALID Trino 467 — NOT a defect.** VERIFIED via WebSearch + StarRocks issue #55574, which states verbatim: *"In Trino sql, interval can multiply a number."* So `INTERVAL '1' MINUTE * (bigint)` compiles (the `%15` bigint coerces to the numeric multiplier). Logic VERIFIED: `date_trunc('minute', ts)` drops seconds (10:17:45 → 10:17:00); `EXTRACT(MINUTE FROM ts) % 15` = 2; subtract 2 minutes → 10:15:00. Correct floor-to-15-min boundary.

Minor (Comp/Act nit, no penalty): the canonical epoch-floor alternative `from_unixtime(floor(to_unixtime(ts)/900)*900)` (which iter761 Q3 surfaced) was not offered as a second form. Both are valid; the responder's interval form is correct on its own.

---

## Deliverable answers

**(a) Is date-series CLOSED?** YES — **CLOSED, 1st post-fix datapoint.** iter782 FINDABILITY FIX-A WORKED: the responder now LEADS with `sequence()`+`UNNEST`, handled the monthly grain, and did NOT decline (the exact iter781 Q2 failure mode). Re-probe once more from a fresh angle (e.g. hourly grain, or `generate_series`-named phrasing) to drive to BULLETPROOFED (2nd consecutive clean).

**(b) Q4 interval-multiplication verdict:** **VALID Trino 467.** `INTERVAL '1' MINUTE * n` is supported (interval × number). The Q4 expression compiles and the floor-to-15-min logic is correct. No defect; no epoch-floor substitution required. (The epoch-floor form remains a valid alternative worth keeping cross-referenced, but is not needed here.)

**(c) Q2/Q3 citation oddities:** Both answers are CORRECT; both have WEAK SOURCING. Q2 cited the federation file r22 for a generic DESCRIBE/SHOW COLUMNS statement; Q3 cited the array function `array_intersect` (r07:530) for a row-level `INTERSECT` operator. Neither caused a wrong answer. A SMALL ANCHOR IS WARRANTED for Q3: there is no dedicated row-level set-operations (INTERSECT/EXCEPT/UNION/UNION ALL) card; adding one with keyword anchors ("customers in both sets", "rows in both queries", "set intersection / difference") would stop the responder citing the array function. Q2's miscite is lower-value (DESCRIBE is generic and ubiquitous) — optional anchor only.

**(d) iter783 designation:** **FIX-A (LIGHT/ADDITIVE) — add a row-level set-operations card.** No dialect defect surfaced, so this is a findability/sourcing fix, not a correctness fix. Add a small INTERSECT/EXCEPT/UNION [ALL] card (note INTERSECT/EXCEPT dedup to DISTINCT; UNION dedups, UNION ALL does not; COUNT(*) wrap for a count; INNER JOIN alternative when you need extra columns) with the keyword anchors above, near r07's funnel/cohort content. Keep it ADDITIVE — do NOT churn the iter782 date-spine elevation (it just worked) or any bulletproofed card. Optionally re-probe date-series from a fresh grain to confirm BULLETPROOFED. If the teacher prefers, iter783 may instead be a DEFAULT NO-OP durability-breadth sweep since there is no open defect — but the Q3 anchor is the higher-value move.

HOLD all prior locks. Federation r22 untouched. DO NOT bump training/state.json (already 782).
