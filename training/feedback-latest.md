# Judge Feedback — Iter829 (EXTENDED PHASE)

**Mode:** DEFAULT NO-OP durability sweep — teacher made ZERO resource edits. Final/extended phase: single end-of-iteration evaluation.

**Federation:** NOT probed this iteration (row unchanged, stays 4.49944/310).

**Verification:** All dialect claims verified against trino.io/docs/467 (datetime.html, string.html, window/aggregate) via WebSearch + WebFetch on 2026-06-09. Trino 467 EXTRACT field set + day() confirmed against the pinned 467 datetime doc page.

---

## Per-question scores

### Q1 — count per pricing plan (GROUP BY + COUNT)
`SELECT plan_name, COUNT(*) AS customer_count FROM iceberg.analytics.customers GROUP BY plan_name`
- Accuracy 5 — trivially correct, canonical Trino GROUP BY aggregation; valid 467.
- Completeness 5 — fully answers "count per group"; correctly framed as "basic, no tricks."
- Clarity 5 — minimal, no unexplained jargon; matches the beginner's mental model.
- Actionability 5 — directly runnable on the prod iceberg catalog.
- **Q1 avg = 5.00**

### Q2 — % of total per sales rep, 1 decimal
`ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)`
- Accuracy 5 — VERIFIED: window function over an aggregate is valid in a GROUP BY query (windows execute after aggregation); empty `OVER ()` = single partition over all group rows = grand total across all reps. `100.0 *` forces decimal division (avoids integer-truncation trap). `ROUND(x, 1)` = exactly 1 decimal. All correct for Trino 467.
- Completeness 5 — answers the "make a percentage column" ask end-to-end; the WHERE filter scopes to this quarter; output shape ("Sarah, 12 deals, 23.4%") matches the request.
- Clarity 5 — each clause annotated (per-rep count, grand total, decimal forcing, rounding); the integer-division gotcha is explained, which is exactly the trap a beginner would hit.
- Actionability 5 — runnable; engineer knows exactly what to do.
- **Q2 avg = 5.00**

### Q3 — filter company names over 50 chars
`length(company_name)` ... `WHERE length(company_name) > 50`
- Accuracy 5 — VERIFIED string.html: `length(string)` returns the length in characters (Unicode code points) as integer; `WHERE length(...) > 50` filters correctly. (Minor un-penalized nuance: code points vs grapheme clusters differ for combining-char/emoji text — irrelevant for company-name length filtering.)
- Completeness 5 — answers both "function for # of characters" and "filter over 50."
- Clarity 5 — names the function plainly, states return type.
- Actionability 5 — runnable.
- **Q3 avg = 5.00**

### Q4 — extract day-of-month (1-31)
`EXTRACT(DAY_OF_MONTH FROM created_at)`
- Accuracy 5 — CRITICAL CHECK PASSED. VERIFIED trino.io/docs/467 datetime.html: `DAY_OF_MONTH` IS a valid EXTRACT field in Trino 467 (it is an alias for `day()`; `day_of_month(x)` convenience function also exists). The responder's field list (YEAR, MONTH, QUARTER, WEEK, DAY, DAY_OF_MONTH, DAY_OF_WEEK, DAY_OF_YEAR, HOUR, MINUTE, SECOND) is accurate — all are valid 467 extract fields. No defect. (DAY and DAY_OF_MONTH are interchangeable; both return 1-31.)
- Completeness 4.75 — fully answers the extract + GROUP BY ask. Minor: did not surface the simpler equivalent `day(created_at)` function (one-token alternative to the EXTRACT form), which is the cleaner idiom for "just the day number." Not a defect — purely a completeness nicety.
- Clarity 5 — clear, with the full field reference and a worked GROUP BY/ORDER BY example.
- Actionability 5 — runnable.
- **Q4 avg = 4.9375**

---

## Overall

| Q | Acc | Comp | Clar | Act | avg |
|---|-----|------|------|-----|-----|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 4.75 | 5 | 5 | 4.9375 |

**Overall avg = (5.00 + 5.00 + 5.00 + 4.9375) / 4 = 4.984375** (round 4.984)
**Margin = +1.484 over the 3.5 threshold. PASS (overall avg governs, no per-Q veto).**

**Headline:** ALL 4 CLEAN, ZERO dialect defects. Both critical verification targets passed: (Q4) DAY_OF_MONTH is a genuine Trino 467 EXTRACT field (alias for day()) — NOT a fabrication; (Q2) `SUM(COUNT(*)) OVER ()` window-over-aggregate is valid and computes the grand total. The integer-division/`100.0` decimal-forcing reasoning in Q2 is correct and well-explained. Only sub-5 mark is a Q4 completeness nicety (omitted the simpler `day(created_at)` alias) — neither a resource defect nor a responder slip.

## iter830 directive

**iter830 = DEFAULT NO-OP / durability-breadth sweep.** No open defect surfaced; this was a clean sweep of SQL fundamentals (GROUP-BY-count / percentage-of-total-window / string-length-filter / EXTRACT-day-of-month). Do NOT churn any card.

- OPTIONAL low-pri inoculation ONLY if a future probe under-scores: near the EXTRACT/date-part card, surface the one-token `day(ts)` / `month(ts)` / `year(ts)` convenience functions as the simpler equivalent of the EXTRACT(... FROM ...) form (do NOT pre-churn — the EXTRACT form is already correct and copy-attractive).
- Suggested fresh adjacent picks for iter830: `date_trunc('day', ts)` day-bucketing vs day-of-month extraction (different intent), `COUNT(DISTINCT x)` per group, ratio-to-group `100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY region)` (partitioned percentage, contrast with empty-OVER grand-total), `last_day_of_month(date)`.

HOLD all iter534-827 locks. Federation row UNCHANGED. DO NOT bump training/state.json (already 829).
