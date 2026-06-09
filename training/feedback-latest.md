# Judge Feedback — iter775 (FIX-A verification: LAG-by-N dense-series re-probe)

**Overall: 4.94 — STRONG PASS** (threshold 3.5). All 4 answers docs-verified against trino.io/docs/467 on 2026-06-09. resources/ NOT treated as ground truth.

This was a FIX-A iteration. iter774 Q1 surfaced a resource emphasis/findability defect: the responder REFUSED `LAG` for a dense series and pushed the user-rejected self-join. iter775 added a LAG-FIRST ROUTER + dense-vs-sparse disambiguator at r07:2802-2839 and defanged the "never use LAG" blanket. **Q1 re-probes the fix on an explicitly dense series.**

---

## Q1 — LAG-by-N on an explicitly DENSE daily series (FIX-A RE-PROBE, CRITICAL)

**User ask:** daily_active_users, exactly one row per day no gaps, want each day's count next to the count 7 rows back (week-over-week), explicitly NOT a self-join.

**Answer:** `LAG(dau_count, 7) OVER (ORDER BY day_date) AS count_7_days_ago`. Explicitly: "exactly one row per day no gaps → LAG(metric, 7) counts exactly 7 rows backward = 7 calendar days; offset is ROWS not periods; no self-join needed." Cites r07 LAG-FIRST ROUTER (2802-2839). LED with LAG, did NOT refuse it, did NOT push self-join.

**Verification (window.html):** `lag(x, offset)` = "Returns the value at offset rows before the current row in the window partition." Default offset 1; requires ORDER BY. On a dense gapless one-row-per-day table, `LAG(dau_count, 7) OVER (ORDER BY day_date)` = the value exactly 7 days back. The offset-is-ROWS-not-calendar-periods caveat is correctly stated, and the dense-series precondition that makes 7-rows == 7-days is correctly flagged.

**THE FIX WORKED.** The iter774 defect (refuse LAG / force self-join) did NOT recur. Responder routed straight to the LAG-FIRST canonical, led with LAG, gave the literal docs answer the user asked for, and correctly stated the rows-vs-periods precondition.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.00** |

---

## Q2 — ARRAY membership (filter tags containing 'vip')

**Answer:** `contains(tags, 'vip')` in WHERE. Notes Postgres `ANY()` is not the translation; `contains()` is the Trino array-membership function. Cites r07 §1a.3 array quick reference.

**Verification (array.html):** `contains(x, element) → boolean` — "true if the array x contains the element." Array-only (not varchar substring — that's strpos/LIKE). `contains(tags, 'vip')` is correct for an `array(varchar)` column. The Postgres ANY()/@> note is accurate. The standing contains-is-ARRAY-ONLY pin is correctly applied here (genuine array column).

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.00** |

---

## Q3 — Divide-by-zero guard (conversions/visits)

**Answer:** `conversions * 1.0 / NULLIF(visits, 0)` → NULL when visits=0; `COALESCE(..., 0)` if you want 0 instead. Cites r07 divide-by-zero guard.

**Verification (conditional.html):** `NULLIF(value1, value2)` = "Returns null if value1 equals value2, otherwise returns value1." So `NULLIF(visits, 0)` → NULL when visits=0, and `x / NULL` → NULL (no divide-by-zero error). `conversions * 1.0` forces non-integer (double) division. `COALESCE(..., 0)` to coerce the NULL to 0. All correct, standard guard.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.00** |

---

## Q4 — Year-month label ('YYYY-MM' for monthly grouping)

**Answer:** `substr(CAST(CAST(event_timestamp AS DATE) AS varchar), 1, 7) AS month_label`; OR `format_datetime(event_timestamp, 'yyyy-MM')`. Warns Joda lowercase `mm` = MINUTE not month ('yyyy-mm' silently yields year-minute). Cites r23 YYYY-MM label section.

**Verification (datetime.html):** (1) `CAST(date AS varchar)` yields 'YYYY-MM-DD'; `substr(...,1,7)` = 'YYYY-MM' — valid. (2) `format_datetime(timestamp, format)` uses Joda-Time DateTimeFormat: `yyyy`=four-digit year, uppercase `MM`=month, lowercase `mm`=MINUTE. The critical warning that `'yyyy-mm'` is a year-minute bug is ACCURATE for Joda/format_datetime. Both forms produce '2026-03'. (date_format(ts, '%Y-%m') is the MySQL-style alternative — not needed, would also work.)

This is a high-value answer: the lowercase-mm=minute gotcha is the single most common silent bug in this pattern, and the responder surfaced it unprompted.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.00** |

---

## Overall

| Q | Topic | Avg |
|---|---|---|
| Q1 | LAG-by-N dense series (FIX-A re-probe) | 5.00 |
| Q2 | array membership (contains) | 5.00 |
| Q3 | divide-by-zero guard (NULLIF) | 5.00 |
| Q4 | year-month label (format_datetime Joda) | 5.00 |

**Overall avg = 5.00 — STRONG PASS.** No imprecision found on any axis across all four answers.

---

## Teacher feedback

1. **(a) Is LAG-by-N CLOSED?** YES — Q1 is the **1st clean post-fix datapoint**. The iter775 FIX-A (LAG-FIRST ROUTER at r07:2802-2839 + dense-vs-sparse disambiguator + defanged "never use LAG" blanket) WORKED. The responder led with LAG on the explicitly-dense series, did not refuse it, did not push the self-join, and correctly stated the offset-is-rows / dense-series precondition. **LAG-by-N is CLOSED but NOT YET BULLETPROOFED** — per the two-datapoint rule, it needs ONE more clean datapoint from a different phrasing before promotion to BULLETPROOFED.

2. **iter776 designation — DEFAULT NO-OP / durability-breadth sweep.** No open defect, no new imprecision surfaced. Teacher should make ZERO edits. RECOMMEND ONE of the 4 fresh probes be a **fresh LAG-by-N phrasing** (e.g. day-over-day `LAG(x,1)` on a dense daily table, or LEAD-by-N for a forward look on a dense series, or a partitioned dense series `LAG(x,N) OVER (PARTITION BY series_id ORDER BY t)`) to convert LAG-by-N from CLOSED → BULLETPROOFED. The other 3 should be fresh adjacent angles.

3. **PRESERVE (churn risk):** the LAG-FIRST ROUTER and dense-vs-sparse disambiguator (r07:2802-2839) are verified clean and load-bearing — do NOT rewrite. Keep the self-join FORM A scoped to SPARSE series and the inline "never use LAG" defang at r07:2822. The contains-ARRAY-ONLY pin, NULLIF divide-guard, and format_datetime-Joda-yyyy-MM-lowercase-mm-is-minute card are all verified clean — leave them be.

4. **Standing pins all held:** LAG-dense-vs-self-join-sparse (now CLOSED), contains-ARRAY-ONLY, NULLIF-divide-guard, format_datetime-yyyy-MM-lowercase-mm-is-minute, plus the full iter534-774 inventory. No regressions observed.
