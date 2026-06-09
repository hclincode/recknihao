# Judge Feedback — iter882 (EXTENDED PHASE)

**Overall: 4.97 STRONG PASS** (per-Q 5.00 / 5.00 / 4.875 / 5.00 = 19.875 / 4 = 4.96875; margin +1.47)
Overall average governs; no per-Q veto. FEDERATION NOT PROBED — federation row (4.49944/310) UNCHANGED.

**iter883 recommendation: DEFAULT NO-OP.** All four answers are dialect-clean. BOTH "critical verification" premises in the run-prompt (Q3 date_diff-month boundary-based, Q4 format_data_size built-in) turned out to be INVERTED — the responder was right on both. Adding any "fix" would corrupt correct content. Teacher: ZERO edits.

---

## Per-question scoring

### Q1 — per-account list of all plan names in chronological order, as an array, one query — **5.00**
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

Responder: `array_agg(plan_name ORDER BY started_at)` (ORDER BY INSIDE the aggregate), `array_join(array_agg(... ORDER BY ...), ', ')` for a delimited string, and `listagg(plan_name, ', ') WITHIN GROUP (ORDER BY started_at)` as the Oracle-compatible string form.

VERIFIED vs trino.io/docs/467/functions/aggregate.html: "Some aggregate functions such as `array_agg()` produce different results depending on the order of input values. This ordering can be specified by writing an ORDER BY clause within the aggregate function" with example `array_agg(x ORDER BY y DESC)`; `listagg` signature verbatim `LISTAGG(expression [, separator] [ON OVERFLOW ...]) WITHIN GROUP (ORDER BY sort_item, [...])`. `array_join` confirmed present on functions/list.html (A-section). All three forms correct; ORDER-BY-inside-aggregate is the right place (a trailing ORDER BY would order rows, not array elements). No defect.

### Q2 — forward-fill / LOCF (carry most recent non-null health score forward) — **5.00**
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

Responder: `LAST_VALUE(health_score) IGNORE NULLS OVER (PARTITION BY customer_id ORDER BY health_score_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`; correctly stressed the frame must be look-back (UNBOUNDED PRECEDING..CURRENT ROW); correctly added that you must densify with `sequence()` + LEFT JOIN first if days are physically missing.

VERIFIED vs trino.io/docs/467/functions/window.html: IGNORE NULLS IS supported on value window functions — verbatim "By default, null values are respected. If `IGNORE NULLS` is specified, all rows where `x` is null are excluded from the calculation." `last_value`/`first_value` confirmed on functions/list.html. The explicit `ROWS UNBOUNDED PRECEDING AND CURRENT ROW` frame is exactly right and important: without an explicit frame, `last_value` uses the default RANGE frame (peers included), which is NOT a forward-fill. The densify-first caveat is the production-correct nuance. Canonical LOCF answer. No defect.

### Q3 — count COMPLETE months between signup_date and today ("45 days ago = 1 full month") — **4.875**
Accuracy 5 / Completeness 4.75 / Clarity 5 / Actionability 4.75

Responder: `date_diff('month', signup_date, current_date)`, CLAIMED it counts COMPLETE elapsed months (day-aware, not 30-day windows), with examples `date_diff('month', DATE '2024-01-15', DATE '2024-02-14') -> 0` (NOT a full month), `... '2024-02-15' -> 1`, `... '2024-03-15' -> 2`.

**THE RUN-PROMPT'S "MOST LIKELY" HYPOTHESIS IS WRONG. THE RESPONDER IS CORRECT.**

VERIFIED — git-tag 467 source `io/trino/operator/scalar/DateTimeFunctions.java` `diffDate`:
```java
return getDateField(UTC_CHRONOLOGY, unit).getDifferenceAsLong(DAYS.toMillis(date2), DAYS.toMillis(date1));
```
with `new DateTimeFieldProvider("month", ISOChronology::monthOfYear)`. The month field's `getDifferenceAsLong` is Joda-Time's, documented (joda.org DateTimeField apidocs) verbatim: "Computes the difference between two instants, as measured in the units of this field. **Any fractional units are dropped from the result.**" It is the exact inverse of `add` (`getDifferenceAsLong(add(instant, v), instant) == v`), and `add` is day-aware (e.g. 2000-08-20 + 6 months = 2001-02-20, day-of-month preserved). Therefore the difference is DAY-AWARE: a full month must fully elapse (the day-of-month must be reached) before the count increments.

**EXPLICIT (c): `date_diff('month', DATE '2024-01-15', DATE '2024-02-14')` returns `0` in Trino 467.** Jan15->Feb15 = 1, Jan15->Mar15 = 2. The responder's framing ("counts complete calendar months / not the approximate 30-day window") and ALL THREE examples are ACCURATE. This is NOT a defect — it is a correct, well-explained answer that needs no day-of-month adjustment (the run-prompt's proposed `- CASE WHEN day(b) < day(a)...` correction would be WRONG to apply, since date_diff already does this).

Minor completeness ding (-0.125 avg): the responder did not state the inverse-of-`add` mechanism or note the month-end edge (e.g. Jan-31 -> Feb-28: since Feb has no 31st, the partial month resolves at end-of-Feb — a rare corner). Substance fully correct; this is a nuance, not an error.

NOTE: This is the SECOND inverted-premise this iteration. Per MEMORY (Trino Division By Zero / approx_percentile Error), git-tag source settles dialect disputes over a run-prompt's "most likely" guess. Source was dispositive here.

### Q4 — format raw byte count as human-readable '2.3 KB' / '1.1 MB' — **5.00**
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

Responder: "Trino doesn't have a built-in function for byte->KB/MB conversion, so you'll need a CASE expression," then a CASE with `format('%.1f KB', bytes/1024.0)` etc.

**THE RUN-PROMPT'S "format_data_size EXISTS -> false-absence defect" PREMISE IS WRONG. THE RESPONDER IS CORRECT.**

VERIFIED across three sources:
1. trino.io/docs/467/functions/list.html + functions/conversion.html — NO built-in `format_data_size`. The only data-formatting built-in is `format_number()`, which returns SI-style units like `format_number(1000000) -> '1M'` (NOT a byte formatter, NOT '2.3 KB' shape).
2. trino.io/docs/467/routines/examples.html — verbatim: "The following `format_data_size` routine can format large values of bytes into a human readable string." It is presented as an **example SQL routine you create with CREATE FUNCTION**, NOT a built-in.
3. WebSearch (trino.io) — confirms `format_data_size` "is not a built-in function in Trino's core library, but rather an example SQL routine/UDF that can be implemented" (1024-based units B/kB/MB/GB/TB/...).

**EXPLICIT (d): `format_data_size` does NOT exist as a built-in in Trino 467.** It is a user-defined example routine. Therefore the responder's "Trino doesn't have a built-in for byte->KB/MB" is ACCURATE, not a false-absence. The manual CASE with `format('%.1f KB', bytes/1024.0)` is valid (conversion.html: `format()` uses java.util.Formatter) and is exactly what the engineer needs for the '2.3 KB' (space-separated) shape. No defect.

(Optional, not required: an even-cleaner answer could mention that `format_data_size` exists as a copy-paste example UDF in the docs if the engineer prefers a reusable function, and that its output is space-less 1024-based like '977kB' — different from the requested '2.3 KB'. Not a ding; the responder's direct CASE is the more honest fit for the exact requested format.)

---

## Cross-cutting notes
- Both Q3 and Q4 run-prompt "critical verifications" were inverted premises. The responder was correct on both; the proposed FIX-A corrections would have introduced defects. Verified against git-tag 467 source (DateTimeFunctions.java) + Joda apidocs + three doc/search sources for format_data_size. Textbook case for the standing rule: verify dialect facts against trino.io/467 and the git tag myself, do not propagate a run-prompt's guess.
- No federation probing this iteration; federation row untouched at 4.49944/310 (still below its 4.5 raised bar).

## iter883 directive: DEFAULT NO-OP
- Teacher: ZERO resource edits. Do NOT add a "date_diff month is boundary-based" card (it is day-aware/complete-months — correct as the responder stated). Do NOT add a "format_data_size is built-in" card (it is a UDF, not built-in). Do NOT mark any pin as defective.
- Do NOT touch any iter534-881 pin.
- PIN Trino 467. NO federation edits. DO NOT bump training/state.json (already passed).
- Optional fresh adjacents for next probe: `date_diff` for 'year'/'week'/'day' day-awareness; `date_add('month', n, d)` round-trip; `format_number()` units vs the format_data_size UDF; element-order guarantees of `array_agg(ORDER BY)`; `first_value IGNORE NULLS` backward-fill mirror.
