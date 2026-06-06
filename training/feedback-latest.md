# Iter576 Judge Feedback

**Phase**: extended (iter576)
**Mode**: per-question scoring, 4 questions
**Pinned target**: Trino 467 + Iceberg connector (Hive Metastore + MinIO/S3) per `prod_info.md`.

---

## Q1 — sub-day interval-overlap + zero-period re-probe (concurrent sessions per hour)

**Pattern claimed by responder**: CTE chain — bounds (min login..today+23h) → hourly_calendar (sequence + UNNEST INTERVAL '1' HOUR) → session_counts (LEFT JOIN with `s.login_time <= c.hour AND (s.logout_time IS NULL OR s.logout_time > c.hour)`, `COUNT(*)`) → final (COALESCE 0).

### Verification

(i) **GOOD — half-open interval-overlap predicate** `s.login_time <= c.hour AND (s.logout_time IS NULL OR s.logout_time > c.hour)` is the correct sub-day-grain generalization of the iter575 day-grain canonical. NULL-still-open branch handled. Dense hourly spine via `sequence(date_trunc('hour', lo), date_trunc('hour', hi), INTERVAL '1' HOUR)` + `UNNEST` is correct (iter575 lock generalizes mechanically from DAY to HOUR by swapping the interval literal). NOT a CURRENT_DATE snapshot (uses CURRENT_TIMESTAMP cast to DATE for the upper bound). NOT a closed BETWEEN.

(ii) **BAD — COUNT(\*)-with-LEFT-JOIN-on-empty-hours bug** (the iter568 lock SHOULD have caught this). The responder used `COUNT(*)` inside session_counts after a LEFT JOIN. For an overnight hour with ZERO matching sessions, the LEFT JOIN still emits ONE row (c.hour + all-NULL session columns); `COUNT(*)` counts that padded row as **1**, not 0. The outer `COALESCE(concurrent_sessions, 0)` is therefore vacuous because `COUNT(*)` never returns NULL — it returns 1. So every zero-active overnight hour will WRONGLY show `active_sessions = 1` instead of `0`, exactly defeating the "row for EVERY hour incl. overnight hours where count drops to ZERO" requirement the question emphasized.

Trino 467 docs confirm (https://trino.io/docs/467/functions/aggregate.html):
> "`count(*)` — Returns the number of input rows."
> "`count(x)` — Returns the number of non-null input values."

The CORRECT form with a LEFT JOIN is `COUNT(s.session_id)` (or any non-null right-table column), which counts only real matches → 0 for empty hours. With `COUNT(s.session_id)`, COALESCE is not even needed (COUNT returns 0, not NULL, when no non-null rows are found). This is exactly the documented iter568 trap: `COUNT(*)` vs `COUNT(col)` after a LEFT JOIN.

(iii) **MINOR — yesterday scope drift**: question asked for "yesterday" (24 hours), but the bounds CTE uses `MIN(login_time)` (full history) → today 23:00. The hourly spine therefore spans far more hours than requested. Pattern correct, scope wider than asked.

### Corrected query (fix b + c)

```sql
WITH bounds AS (
  SELECT
    CAST(CURRENT_DATE - INTERVAL '1' DAY AS TIMESTAMP) AS lo,
    CAST(CURRENT_DATE AS TIMESTAMP) - INTERVAL '1' HOUR AS hi
),
hourly_calendar AS (
  SELECT h AS hour
  FROM bounds
  CROSS JOIN UNNEST(sequence(lo, hi, INTERVAL '1' HOUR)) AS t(h)
),
session_counts AS (
  SELECT c.hour, COUNT(s.session_id) AS active_sessions  -- COUNT(col), not COUNT(*)
  FROM hourly_calendar c
  LEFT JOIN sessions_table s
    ON s.login_time <= c.hour
   AND (s.logout_time IS NULL OR s.logout_time > c.hour)
  GROUP BY c.hour
)
SELECT hour, active_sessions FROM session_counts ORDER BY hour;
```

### Scores

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 2 | Range-join + half-open predicate correct, BUT COUNT(*)+LEFT JOIN bug breaks the exact zero-hour requirement; scope drift extends spine to full history not yesterday |
| Completeness | 3 | Covers spine, range-join, NULL handling — but fails the "zero overnight hours" core requirement |
| Clarity | 4 | CTE chain readable, COALESCE intent clear |
| Actionability | 3 | Can copy/paste but will get wrong (1 instead of 0) for empty hours; user needs to debug |
| **Avg Q1** | **3.0** | |

---

## Q2 — IGNORE NULLS placement on FIRST_VALUE / NTH_VALUE

**Responder said**: SAME spot as LAST_VALUE — outside the closing args paren, before OVER. `FIRST_VALUE(value) IGNORE NULLS OVER (...)`; `NTH_VALUE(value, 2) IGNORE NULLS OVER (...)`. Showed WRONG inside-the-args forms as parse errors. Applies to FIRST_VALUE/LAST_VALUE/LAG/LEAD/NTH_VALUE.

### Verification

Verified against Trino 467 grammar (search result quoting SQL standard window grammar):
> "For FIRST_VALUE and LAST_VALUE: `<first or last value> ( <value expression> ) [ <null treatment> ]` where `<null treatment>` is `RESPECT NULLS | IGNORE NULLS`"
> "For NTH_VALUE: `NTH_VALUE ( <value expression> , <nth row> ) [ <from first or last> ] [ <null treatment> ]`"
> "The functions that support the IGNORE/RESPECT NULLS clause are: LAG, LEAD, FIRST_VALUE, LAST_VALUE, and NTH_VALUE."
> "The `<null treatment>` clause appears AFTER the parentheses of the function and its arguments, but BEFORE the OVER clause."

Responder's placement is EXACTLY correct for all five functions. Inside-paren placement is indeed a parse error. iter572 IGNORE-NULLS-placement lock generalizes correctly across all five window-function variants.

### Scores

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | Exact match to grammar across all five functions |
| Completeness | 5 | Covered FIRST_VALUE, NTH_VALUE, mentioned LAG/LEAD/LAST_VALUE; included the wrong form as parse error contrast |
| Clarity | 5 | Clear before/OVER positioning |
| Actionability | 5 | Engineer copies the exact pattern |
| **Avg Q2** | **5.0** | |

---

## Q3 — NOT IN negative-case NULL trap

**Responder said**: Three-valued logic — if subquery returns any NULL, `NOT IN` evaluates to UNKNOWN for every outer row → empty result. Fix: `NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id)` or `LEFT JOIN ... WHERE o.customer_id IS NULL`. Explained why IN works but NOT IN doesn't. Said never use NOT IN with a nullable column.

### Verification

Three-valued logic explanation is correct: `customer_id NOT IN (a, b, NULL)` desugars to `customer_id <> a AND customer_id <> b AND customer_id <> NULL`. The last term is UNKNOWN, so the whole AND is UNKNOWN (cannot be TRUE) → row filtered out. This is the standard SQL semantic and Trino 467 honors it. NOT EXISTS uses correlated-equality which is FALSE (not UNKNOWN) when no match, so it correctly returns the "never ordered" customers. LEFT JOIN + IS NULL anti-join is also correct and idiomatic in Trino.

IN works because `customer_id IN (a, b, NULL)` returns TRUE if any match is TRUE; only returns UNKNOWN if no match is TRUE and at least one is NULL. So for "customer ordered" semantics, NULL doesn't break the positive case.

All three fixes are valid in Trino 467. Recommendation to "never use NOT IN with a nullable subquery column" is good defensive guidance.

### Scores

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | Three-valued logic, NOT EXISTS, anti-join — all correct |
| Completeness | 5 | Two correct fixes, explanation of asymmetry between IN and NOT IN |
| Clarity | 5 | Concrete `<> NULL = UNKNOWN` walk-through |
| Actionability | 5 | Engineer gets two drop-in fixes |
| **Avg Q3** | **5.0** | |

---

## Q4 — LAG period-over-period (no self-join)

**Responder said**: `LAG(daily_revenue) OVER (ORDER BY revenue_date) AS prior_day_revenue`; `daily_revenue - LAG(daily_revenue) OVER (ORDER BY revenue_date) AS day_over_day_change`; first row returns NULL (use COALESCE for 0); `LAG(col, n)` for n-row offset (e.g. LAG(.,7) week-over-week); single-pass, no self-join.

### Verification

Trino 467 window docs (https://trino.io/docs/467/functions/window.html) confirm:
> "`lag(x[, offset[, default_value]])` — Returns the value at `offset` rows before the current row in the window partition."
> "The default `offset` is `1`."
> "If the offset refers to a row that is not within the partition, the `default_value` is returned, or if it is not specified `null` is returned."

Responder's claims all check out:
- LAG defaults offset to 1 → "previous day" correct under `ORDER BY revenue_date`.
- First row returns NULL when no default — correct.
- `LAG(col, 7)` for week-over-week — correct n-row offset semantics.
- Single-pass / no self-join is the well-known advantage.

### Scores

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | LAG semantics, defaults, n-offset all correct |
| Completeness | 5 | Includes both prior_day column and DoD-change expression; mentions COALESCE; week-over-week extension |
| Clarity | 5 | Clean, no jargon dump |
| Actionability | 5 | Direct copy-paste, no self-join requirement met |
| **Avg Q4** | **5.0** | |

---

## Overall

| Question | Avg |
|---|---|
| Q1 (sub-day interval-overlap + zero-hour) | 3.0 |
| Q2 (IGNORE NULLS FIRST_VALUE / NTH_VALUE) | 5.0 |
| Q3 (NOT IN NULL trap) | 5.0 |
| Q4 (LAG no self-join) | 5.0 |
| **Overall avg** | **4.5** |

**Verdict: PASS** (4.5 >= 3.5 threshold). However, Q1 exposed a genuine accuracy defect — the COUNT(\*)-after-LEFT-JOIN trap (iter568 lock) was NOT applied when the iter575 interval-overlap pattern was generalized to the hour grain with a LEFT JOIN. The responder pulled the LEFT JOIN + COALESCE(0) variant from r07 §1a but used `COUNT(*)` instead of `COUNT(s.session_id)`, breaking the exact zero-hour requirement.

---

## iter577 directive — for the teacher

**ADD a grep-findable COUNT(\*)-vs-COUNT(col)-AFTER-LEFT-JOIN trap H3 anchored inside the r07 §4 interval-overlap recipe** (lines ~894-970). This is a natural trap pairing: anyone who switches the iter575 INNER JOIN canonical to LEFT JOIN + COALESCE 0 to "keep zero-active rows in the spine" will reach for `COUNT(*)` (which is what r07's other LEFT JOIN+COALESCE examples may use) and silently get 1 instead of 0 for empty buckets.

### Specific edit recommendation (iter577 FIX A)

Inside r07 §4 interval-overlap H3, immediately after the LEFT JOIN + COALESCE 0 variant, add:

> **TRAP — when you switch to LEFT JOIN for zero-active buckets, you MUST use `COUNT(s.session_id)` NOT `COUNT(*)`.** A LEFT JOIN still emits one (bucket, all-NULL right side) row for empty buckets; `COUNT(*)` counts that padded row as 1, so every zero-active overnight hour wrongly shows 1 instead of 0. The outer `COALESCE(..., 0)` is useless because `COUNT(*)` never returns NULL — it returns 1. Use `COUNT(s.session_id)` (or any non-null right-table column); it counts only real matches (0 for empty buckets) and you don't even need COALESCE.
>
> ```sql
> -- WRONG (every zero-active hour shows 1, not 0):
> SELECT c.hour, COUNT(*) AS active
> FROM hourly_calendar c LEFT JOIN sessions s ON ...
>
> -- RIGHT (zero-active hours show 0):
> SELECT c.hour, COUNT(s.session_id) AS active
> FROM hourly_calendar c LEFT JOIN sessions s ON ...
> ```

**Grep-findability**: include keywords `COUNT(*) LEFT JOIN`, `zero-active`, `zero hour`, `padded row`, `overnight`, `empty bucket` so a re-probe of this question family hits this card.

**Also add sub-day-grain hour-scope example** explicitly: when the question says "yesterday only", show `bounds` as `(CAST(CURRENT_DATE - INTERVAL '1' DAY AS TIMESTAMP), CAST(CURRENT_DATE AS TIMESTAMP) - INTERVAL '1' HOUR)` so the spine covers exactly 24 hourly buckets, not full history.

### Cross-reference

This trap is the SAME COUNT(\*)-vs-COUNT(col) lock that already exists in r23 §4 — but r23's anchor is in a generic LEFT JOIN aggregation context, not in the interval-overlap context where the LEFT JOIN+COALESCE pattern is the WHOLE point. The responder demonstrably did not bridge the two. Adding the trap card directly inside r07 §4 interval-overlap H3 with the keyword anchors above will close that gap.

### State

- DO NOT bump state.json — teacher already set iter to 576.
- Rubric: append one-line passing entry (4.5 PASS).
