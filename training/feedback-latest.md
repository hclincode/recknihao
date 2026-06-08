# Judge Feedback — iter764 (FIX-A verification: ROLLUP SUM-placement RE-PROBE)

All four forms verified against trino.io/docs/467 (sql/select.html, functions/datetime.html, functions/aggregate.html, language/types.html) on 2026-06-09. Do NOT rely on resources/ as ground truth.

## Q1 — ROLLUP on date-parts (year+quarter from one timestamp) + per-year subtotal + grand total — RE-PROBE for BULLETPROOFED

Verified:
- CTE computes the PARTS (signup_year, signup_quarter, user_id) — NOT a pre-aggregated COUNT/SUM. CORRECT.
- OUTER query does `COUNT(user_id)` under `GROUP BY ROLLUP(signup_year, signup_quarter)` — the aggregate is in the OUTER query, ROLLUP is over the named columns. This is the analysis-valid form (select.html: "all output expressions must be either aggregate functions or columns present in the GROUP BY clause"). COMPILES.
- ROLLUP over column NAMES, not expressions — the EXTRACTs are pre-computed in the CTE and aliased. CORRECT (select.html: "Complex grouping operations do not support grouping on expressions ... Only column names are allowed"). The iter763 on-expression issue did NOT recur.
- `EXTRACT(QUARTER FROM signup_ts)` and `EXTRACT(YEAR FROM signup_ts)` are valid Trino 467 (datetime.html: QUARTER and YEAR are supported EXTRACT fields). CORRECT.
- GROUPING bitmask 0/1/3 (no WHEN-2) is exactly right for ROLLUP(year, quarter): 0=detail, 1=year subtotal (quarter rolled up), 3=grand total. Value 2 is impossible for ROLLUP. CORRECT.
- ORDER BY GROUPING(...), year NULLS LAST, quarter NULLS LAST — correct shape ordering; NULLS LAST is the Trino 467 default and explicit here. CORRECT.
- The iter763 SUM-placement synthesis-slip (pre-aggregate-in-CTE → bare reference under outer ROLLUP) did NOT recur.

Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

## Q2 — Per region: total revenue / distinct active users (ratio of two aggregates)

Verified:
- `ROUND(SUM(revenue) / COUNT(DISTINCT user_id), 2)` per region. COUNT(DISTINCT) returns BIGINT (aggregate.html). For a money/DECIMAL (or DOUBLE) revenue column, SUM(revenue) is DECIMAL/DOUBLE, and DECIMAL/BIGINT (or DOUBLE/BIGINT) division is NOT integer division — it preserves fractional precision, so ROUND(...,2) is correct. CORRECT for the money scenario.
- WHERE user_id IS NOT NULL + GROUP BY region. Sound.
- approx_distinct noted as a fast alternative for huge cohorts — valid (aggregate.html, HLL, ~2.3% std error). CORRECT.
- Completeness nit (minor): did not explicitly flag the integer-division trap that WOULD apply if revenue were an INTEGER/BIGINT column. For a conventionally-DECIMAL money column this is a non-issue; do not heavily penalize.

Scores: Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5 — **avg 4.75**

## Q3 — Duplicate email detection (natural-key appears > once)

Verified:
- `GROUP BY email HAVING COUNT(*) > 1` is the canonical duplicate-key idiom in Trino 467 (select.html: HAVING filters groups post-aggregation). CORRECT.
- WHERE email IS NOT NULL + ORDER BY occurrence_count DESC. Clean, surfaces only emails appearing >1.

Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

## Q4 — Per user: count of distinct calendar days active

Verified:
- `COUNT(DISTINCT CAST(occurred_at AS DATE)) GROUP BY user_id`. CAST(timestamp AS DATE) drops time-of-day (datetime.html: date(x) is an alias for CAST(x AS date)); COUNT(DISTINCT) counts unique non-null dates (aggregate.html). CORRECT — counts distinct calendar days.

Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 4 | 5 | 5 | 4.75 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = 4.9375 → 4.94 — STRONG PASS** (threshold 3.5; overall governs, no single-Q veto).

## Status calls

- **ROLLUP-on-date-parts is now BULLETPROOFED.** Q1 is the 2nd consecutive clean datapoint (iter763 fixed, iter764 confirms): the query COMPILES, the COUNT is correctly in the OUTER query (SUM-placement slip did NOT recur), ROLLUP is over pre-computed named columns (on-expression issue did NOT recur), EXTRACT(QUARTER) is valid, and the GROUPING 0/1/3 bitmask is correct. The full ROLLUP saga is now FULLY CLOSED across all three failure modes: construct-choice (iter761), on-expression (iter763), and SUM-placement (iter763→764). The iter764 inoculation defang at the r28 CTE-then-ROLLUP canonical did its job.
- **Q2 ratio-of-aggregates (SUM over COUNT DISTINCT): CLEAN.** Division is correct for DECIMAL revenue; only a minor completeness note about the integer-revenue edge.
- **Q3 dup-detection (HAVING COUNT > 1): CLEAN.**
- **Q4 distinct-days-per-group (COUNT DISTINCT CAST-DATE): CLEAN.**

No new gap, defect, or cross-card contradiction surfaced.

## iter765 designation

**DEFAULT NO-OP / durability-breadth** with 4 fresh picks. ROLLUP saga is fully closed and bulletproofed; Q2/Q3/Q4 are clean. No FIX-A warranted. Suggested optional angles for iter765: a 4th ROLLUP angle (e.g. 3-level hierarchy region→country→city to confirm bitmask 0/1/3/7) only if probing durability; otherwise pick 4 genuinely fresh patterns. Do NOT re-edit the r28 ROLLUP card (router + column-names clarifier + SUM-placement defang all intact and verified) — churn risk on a now-bulletproofed topic.
