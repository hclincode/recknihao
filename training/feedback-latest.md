# Judge Feedback — iter834 (EXTENDED PHASE, DEFAULT NO-OP durability sweep)

**Overall: 5.00 STRONG PASS** (per-Q 5.00/5.00/5.00/5.00 = 20.00/4; threshold 3.5; margin +1.50; overall avg governs, no per-Q veto)
**Federation NOT probed** (r22 §13.x untouched — federation row stays 4.49944/310, still FAIL, unaffected).
Teacher made ZERO resource edits this iteration. All 4 probes are SQL-fundamentals (datetime/comparison/conversion/select). **HEADLINE: ALL 4 CLEAN, ZERO dialect defects; all four critical verification targets PASSED vs trino.io/docs/467 (verified 2026-06-09).**

---

## Per-question scores

### Q1 — day-of-week as NAME ('Monday') — 5.00 (Acc5/Comp5/Clar5/Act5)
`format_datetime(CAST(created_at AS timestamp), 'EEEE')` -> 'Monday'.
- VERIFIED datetime.html: `format_datetime(timestamp, format)` formats using JodaTime DateTimeFormat pattern; requires a timestamp input (so a DATE must be CAST). Joda `EEEE` (4 E's) = full day name, `EEE`/`E` = short ('Mon') — CORRECT.
- VERIFIED `day_of_week(x)` returns ISO day-of-week 1 (Monday) .. 7 (Sunday) — responder's numeric-ISO note CORRECT.
- VERIFIED no `dayname()` function exists in Trino 467 (day-extraction fns are day/day_of_month/day_of_week/day_of_year/dow/doy) — responder's "do NOT use dayname()" CORRECT.
- `date_format(ts,'%W')` MySQL-style full-weekday alt was NOT offered but is not required; answer complete as-is.

### Q2 — smaller of two columns row-wise — 5.00 (Acc5/Comp5/Clar5/Act5)
`least(original_price, discounted_price) AS lower_price`.
- VERIFIED comparison.html: `least()` returns the minimum scalar argument, row-wise (NOT an aggregate), and returns NULL if ANY argument is NULL — differs from Postgres (which skips NULLs). Responder's NULL-if-any-arg-NULL caveat CORRECT.
- COALESCE-sentinel workaround `least(COALESCE(original_price,9e18), COALESCE(discounted_price,9e18))` correctly ignores NULLs by substituting a large sentinel; sound and actionable. No subquery, as asked.

### Q3 — orders with NO matching refund; NOT IN returned zero rows — 5.00 (Acc5/Comp5/Clar5/Act5)
- CRITICAL CHECK PASSED: VERIFIED the NOT IN + NULL three-valued-logic trap — if `(SELECT order_id FROM refunds)` contains even one NULL, `NOT IN` yields UNKNOWN (never TRUE) for every row, so WHERE filters out everything -> zero rows. Responder's diagnosis exactly explains the symptom.
- Fix 1 `NOT EXISTS (SELECT 1 FROM refunds r WHERE r.order_id=o.order_id)` — VERIFIED NULL-safe (EXISTS does not build a NULL-containing list; row-by-row existence check). CORRECT.
- Fix 2 `LEFT JOIN refunds r ON o.order_id=r.order_id WHERE r.order_id IS NULL` — VERIFIED equivalent NULL-safe anti-join. CORRECT.
- "NOT EXISTS preferred for readability" is a reasonable recommendation. Both fixes correct, root cause nailed.

### Q4 — format big integer with thousands separators '1,234,567' — 5.00 (Acc5/Comp5/Clar5/Act5)
`format('%,d users', user_count)` -> '1,234,567 users'; number-only `format('%,d', user_count)`.
- VERIFIED conversion.html: `format(format, args...)` EXISTS ("Returns a formatted string using the specified format string and arguments"), Java Formatter syntax. Docs literally show `format('%,.2f', 1234567.89) -> '1,234,567.89'` and `format('%03d', 8) -> '008'`.
- `%,d` = integer with grouping separators; `%,.2f` = grouped 2-decimal — both valid Java Formatter specifiers. CORRECT.
- "Do NOT use date_format/format_datetime for numbers" is an apt guard (those are timestamp-only). Output matches the concatenation ask exactly. Cited r23 format-specifiers table — confirmed present in resources/23-sql-best-practices-olap.md.

---

## Verdict & iter835 directive

- ALL 4 CLEAN; ZERO dialect defects; ZERO responder slips; all four critical verification targets confirmed against trino.io/docs/467 (datetime / comparison / conversion / select .html), 2026-06-09.
- **iter835 = DEFAULT NO-OP / durability-breadth sweep.** No open defect, no FIX-A. Do NOT pre-churn any card.
- Suggested fresh adjacent probes (do not force): `date_format(ts,'%W')` MySQL-style weekday-name alt vs format_datetime 'EEEE'; `array_min` over an ARRAY (vs least's NULL-poisoning); ANTI-JOIN via EXCEPT for the no-match pattern; `format('%,.2f', x)` currency/money grouped-decimal angle; positive-side `IN`-list NULL behavior (counterpart to the NOT IN trap).
- HOLD all iter534-833 locks (boolean-aggregate-NULL cards, GROUP-BY-alias rule, repeat-char card, group-by-month granularity card, nearest-N-min canonical, fixed-width-pad, etc.). Federation row UNCHANGED.
- DO NOT bump training/state.json (already 834).
