# Judge Feedback — iter803 (DEFAULT NO-OP / durability-breadth sweep)

**Date:** 2026-06-09
**Teacher edits this iteration:** ZERO (expected — durability-breadth sweep). Four probes: Q1 LAST_VALUE default-frame trap, Q2 percent_rank, Q3 count-char-via-length-diff, Q4 row-wise GREATEST over dates.
**Verification:** Every dialect claim verified against trino.io/docs/467 (functions/window.html, functions/comparison.html) + WebSearch 2026-06-09 — not relying on resources/ as ground truth.

## Q1 — LAST_VALUE: most-recent status stamped on every ticket row

`LAST_VALUE(status) OVER (PARTITION BY ticket_id ORDER BY event_time ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)`. Explicitly explained that WITHOUT the full frame, LAST_VALUE defaults to a frame ending at the CURRENT row and returns the current row's value; the full frame returns the partition's final value. Cites r07.

VERIFIED: Trino default frame with ORDER BY = RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW → bare `LAST_VALUE(x)` returns the current-row (peer) value, NOT the partition last. The explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` frame correctly extends to the partition's final row. The responder used the correct full frame AND correctly explained the trap. **Trap AVOIDED — CLEAN.** (Alternatives `max_by(status,event_time)` / `FIRST_VALUE(... ORDER BY event_time DESC)` also valid; not required.)

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

## Q2 — percent_rank: "scored better than X% of people"

`PERCENT_RANK() OVER (ORDER BY score ASC) AS fraction_below` — 0.0..1.0, lowest=0, highest=1. Cites r07 Pattern C2.

VERIFIED: percent_rank = (r-1)/(n-1), range 0..1; ASC ⇒ lowest=0, highest=1, value = fraction strictly below (ties share rank). This is the conventional metric for "better than X%". Responder did NOT confuse it with cume_dist (fraction at-or-below, range 1/n..1). CORRECT pick. Minor: could have named the percent_rank-vs-cume_dist distinction explicitly for completeness, but the chosen function is right and well-explained.

- Accuracy 5 / Completeness 4.5 / Clarity 5 / Actionability 5 — **avg 4.875**

## Q3 — count commas in csv_line (+1 = field count)

`LENGTH(csv_line) - LENGTH(REPLACE(csv_line, ',', '')) AS comma_count`; +1 = field count; worked example 'north,east,pending,3' → 4 commas → 5 fields. Cites r27 + r23.

VERIFIED: replace removes all commas; the length drop = comma count. length() and 2-arg replace(s,search) both valid Trino. Trino has no direct char-count function, so the length-diff is the canonical idiom. Worked example correct. (cardinality(split(s,',')) is an equally valid alternative; not required.) CLEAN.

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

## Q4 — row-wise max of 3 date columns

`GREATEST(last_login_date, last_purchase_date, last_support_date) AS last_activity_date`; notes GREATEST returns NULL if ANY arg is NULL in Trino (unlike Postgres), wrap `COALESCE(col, DATE '1900-01-01')` if nulls possible. Cites r23 + r27.

VERIFIED: greatest() supports DATE (also DOUBLE/BIGINT/VARCHAR/TIMESTAMP/TIMESTAMP WITH TIME ZONE) and returns NULL if any argument is NULL — Trino docs explicitly contrast Postgres. The COALESCE-sentinel workaround is apt and correctly flagged. CLEAN.

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 LAST_VALUE | 5 | 5 | 5 | 5 | 5.00 |
| Q2 percent_rank | 5 | 4.5 | 5 | 5 | 4.875 |
| Q3 count-char | 5 | 5 | 5 | 5 | 5.00 |
| Q4 GREATEST dates | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = 4.97 — PASS** (threshold 3.5).

### Explicit verdicts
- **(a) LAST_VALUE default-frame trap (Q1): AVOIDED.** Responder used the explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` frame and correctly explained that the bare/default frame returns the current row's value. The standing LAST_VALUE-default-frame-trap pin is reconfirmed CLEAN by this datapoint.
- **(b) iter804 designation: DEFAULT NO-OP / durability-breadth.** No open defect, no FIX-A needed. All four standing pins held (LAST_VALUE-default-frame-trap, percent_rank-vs-cume_dist, count-char-length-diff-replace, greatest-least-NULL-if-any-null). Teacher should make ZERO edits; suggested fresh probes for iter804: cume_dist-vs-percent_rank direct contrast / NTH_VALUE-with-frame / array_agg-DISTINCT-ORDER-BY / date_diff-week-or-quarter / regexp_replace-capture-group-backref.

PRESERVE r07 window cards (LAST_VALUE full-frame, percent_rank), r23/r27 length/replace + greatest cards — verified clean, churn risk. DO NOT bump training/state.json (already 803).
