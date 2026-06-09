# iter773 Judge Feedback — DEFAULT NO-OP / durability-breadth sweep

**Designation:** DEFAULT NO-OP / durability-breadth sweep (teacher made ZERO resource edits; 4 fresh adjacent probes).
**Verification basis:** every dialect claim verified against trino.io/docs/467 (datetime / aggregate / language-types / sql-select .html) + Trino COUNT(DISTINCT) multi-column behavior (trinodb GitHub + sqlglot #2930 + Querify Labs distinct-aggregation writeup) on 2026-06-09. resources/ NOT treated as ground truth.

---

## Q1 — Week bucketing (snap to week-start), weekly signup-count chart

`SELECT date_trunc('week', created_at) AS week_start, COUNT(*) FROM signups GROUP BY date_trunc('week', created_at) ORDER BY week_start`

**Verified:** trino.io/docs/467/functions/datetime.html — `date_trunc('week', ts)` truncates to the **start of the ISO week = MONDAY** (docs example `'2001-08-22 03:04:05.321'` → `'2001-08-20 00:00:00.000'`; Aug 20 2001 was a Monday). No built-in Sunday-start option — Sunday-start genuinely needs INTERVAL shifting (the answer's claim is exactly right). GROUP BY repeating the `date_trunc(...)` expression is valid (simple GROUP BY allows expressions). ORDER BY week_start valid.

| Accuracy | Completeness | Clarity | Actionability |
|---|---|---|---|
| 5 | 5 | 5 | 5 |

**Per-Q avg: 5.00 — CLEAN.** The Monday/ISO-week note + "no Sunday-start built-in, would need INTERVAL arithmetic" is precisely correct and is the exact nuance a charting engineer trips on.

---

## Q2 — 7-day trailing / moving average over daily_signups

`AVG(signup_count) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)`

**Verified:** trino.io/docs/467 window-functions / sql-select — `ROWS BETWEEN 6 PRECEDING AND CURRENT ROW` is a valid 7-row trailing frame; `AVG(x) OVER (ORDER BY day ...)` is correct. The **KEY INSIGHT** ("ROWS counts PHYSICAL ROWS, not days — pre-aggregate to one-row-per-day first, else 6 PRECEDING reaches ~6 rows not 7 days") is correct AND is the single most important gotcha here. Source is already `daily_signups` (one row per day), so the ROWS frame is appropriate.

**Optional nuance (NOT a defect):** the ROWS frame assumes no missing calendar days. If days can be absent, a true 7-calendar-day window is `RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW`. Source guarantees one-row-per-day, so omitting this is fine; mentioning it would be a bonus.

| Accuracy | Completeness | Clarity | Actionability |
|---|---|---|---|
| 5 | 4.5 | 5 | 5 |

**Per-Q avg: 4.875 — CLEAN.** Completeness shaved 0.5 only for the unstated missing-days/RANGE nuance (not required given the daily source).

---

## Q3 — Count distinct (user_id, product_id) pairs [the scrutiny target]

`SELECT COUNT(DISTINCT ROW(user_id, product_id)) AS distinct_user_product_pairs FROM events`

**CRITICAL VERIFY — Q3 VERDICT: CORRECT, no defect.**

1. The user's error is **real**: `COUNT(DISTINCT user_id, product_id)` (multiple bare args) is INDEED invalid in Trino — Trino's `count` aggregate takes a single argument (`count(*)` / `count(x)`); the standard-SQL multi-arg COUNT DISTINCT is not supported. Confirmed via trinodb GitHub + sqlglot #2930 + Querify Labs.
2. The fix is **valid**: the documented idiom is to wrap the columns into a single ROW-typed value. The canonical form cited everywhere is the **bare anonymous tuple** `COUNT(DISTINCT (user_id, product_id))`. The answer used the **explicit** `COUNT(DISTINCT ROW(user_id, product_id))` form. In Trino, `ROW(a, b)` and `(a, b)` are **equivalent row constructors** — `ROW(1, 2e0)` is shown valid in language/types.html, and the row's fields here (bigint user_id, varchar/bigint product_id) are comparable/orderable, so DISTINCT on the ROW value works. **The ROW() wrapper is ACCEPTED by Trino 467.**
3. The pre-concat fallback (`COUNT(DISTINCT user_id || '~' || product_id)` with CAST) is a valid alternative.

**Imprecision flag for iter774: NONE that rises to a defect.** Single watch-note only: the most commonly-documented / copy-canonical Trino form is the bare-tuple `(a, b)`; the explicit `ROW(a, b)` form the responder produced is equivalent and compiles, so this is NOT FIX-A material. (If a future probe shows the responder ever reaching for the invalid `COUNT(DISTINCT a, b)` form, that would flip to FIX-A — it did not here.)

| Accuracy | Completeness | Clarity | Actionability |
|---|---|---|---|
| 5 | 5 | 5 | 5 |

**Per-Q avg: 5.00 — CLEAN.** Correctly diagnosed the real error, gave a compiling fix (ROW wrapper) plus a fallback.

---

## Q4 — First/earliest value per group (earliest order_date + product on that order, one row per customer)

`SELECT customer_id, MIN(order_date) AS first_order_date, min_by(product_id, order_date) AS product_on_first_order FROM orders GROUP BY customer_id`

**Verified:** trino.io/docs/467/functions/aggregate.html — `min_by(x, y)` = "Returns the value of x associated with the minimum value of y over all input values." So `min_by(product_id, order_date)` = the product on the earliest order, and `MIN(order_date)` = the earliest date, both in one `GROUP BY customer_id`. CORRECT, and the single-pass aggregate form is the cleanest answer. The `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date ASC) = 1` subquery alternative (returns ALL columns of the earliest row) is also valid.

**Optional nuance (NOT a defect):** ties — two orders sharing the earliest `order_date` → `min_by` picks one arbitrarily (as does ROW_NUMBER without a tiebreaker). Minor; not required.

| Accuracy | Completeness | Clarity | Actionability |
|---|---|---|---|
| 5 | 5 | 5 | 5 |

**Per-Q avg: 5.00 — CLEAN.** min_by primary + ROW_NUMBER alternative is exactly the right two-option answer.

---

## OVERALL

| Q | Accuracy | Completeness | Clarity | Actionability | Per-Q avg |
|---|---|---|---|---|---|
| Q1 week-bucket | 5 | 5 | 5 | 5 | 5.00 |
| Q2 trailing-avg | 5 | 4.5 | 5 | 5 | 4.875 |
| Q3 multi-col-distinct | 5 | 5 | 5 | 5 | 5.00 |
| Q4 first-per-group | 5 | 5 | 5 | 5 | 5.00 |

**Overall average = (5.00 + 4.875 + 5.00 + 5.00) / 4 = 4.969**

**PASS** (threshold 3.5; overall average governs, no single-Q veto).

---

## Teacher feedback

(a) **Q3 verdict:** `COUNT(DISTINCT ROW(user_id, product_id))` is **VALID Trino 467** — CORRECT, no imprecision. The user's `COUNT(DISTINCT user_id, product_id)` error is genuine (single-arg count only); the ROW()/tuple wrapper is the supported fix. `ROW(a,b)` ≡ `(a,b)` as row constructors; DISTINCT works because bigint/varchar fields are comparable. **NO iter774 FIX-A from Q3.**

(b) **iter774 designation: DEFAULT NO-OP / durability-breadth sweep.** No open defect, no new imprecision surfaced; all four forms docs-verified clean. Teacher: ZERO edits, probe 4 fresh adjacent angles. Optional probes to convert these CLEAN datapoints toward BULLETPROOFED:
- Re-probe multi-col-distinct from a different phrasing (e.g. "unique combinations of region + plan", or one that tempts the responder toward the invalid bare-arg `COUNT(DISTINCT a, b)`) to confirm it consistently routes to the ROW/tuple wrapper. If it ever emits the bare-arg form, that becomes FIX-A.
- Re-probe trailing-average with a gappy/missing-days source to see whether the responder reaches for `RANGE BETWEEN INTERVAL '6' DAY PRECEDING` when calendar-correctness matters.
- Keep verifying every dialect claim vs trino.io/docs/467; resources/ is not ground truth.

resources/22-trino-federation-postgresql.md HARD LOCK remains untouched (no edits this iter).
