# iter741 Judge Feedback

**Topic focus**: date_format FIX-A re-probe (CRITICAL) + bitwise 2nd-angle (bulletproofing) + bool_and/bool_or (fresh) + weighted average (fresh)

All dialect claims verified against trino.io/docs/467 (datetime / bitwise / aggregate .html) on 2026-06-09 via WebFetch — NOT against resources/. Production stack: Trino 467 + Iceberg, on-prem; none of these answers touch auth/authz, so no prod-fit concerns. state.json NOT bumped.

---

## Per-question scores

### Q1 — date_format weekday display (date_format FIX-A re-probe, CRITICAL)
| Dimension | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
**Q1 avg = 5.00**

DOCS-VERIFIED (datetime.html): `date_format(timestamp, format) → varchar` and `format_datetime(timestamp, format) → varchar` — FIRST arg is a TIMESTAMP, so a plain DATE MUST be CAST first. The responder's `CAST(signup_date AS timestamp)` is exactly right. Specifiers verbatim: `%a` = "Abbreviated weekday name (Sun .. Sat)", `%b` = "Abbreviated month name (Jan .. Dec)", `%d` = "Day of the month, numeric (01 .. 31)", `%Y` = "Year, numeric, four digits". CONFIRMED there is NO `%A` specifier in Trino 467 (full weekday is `%W`). The responder used `%a` (correct), NOT the invalid `%A` that caused the iter740 Q3 defect. The Joda `format_datetime(..., 'EEE MMM dd yyyy')` equivalent is correct (EEE=abbrev weekday, MMM=abbrev month, dd=day, yyyy=4-digit year). The specifier↔Joda mapping line is accurate. Both the timestamp-input PIN and the `%a not %A` correction are present in the answer.

**date_format FIX-A VERDICT: CLOSED.** The two iter740 defects (invalid `%A` for weekday + passing a bare DATE to date_format) are both fixed in this answer — `%a` used, DATE CAST to timestamp. The r27 §4.2 canonical edit (weekday-name mapping rows + TIMESTAMP-input PIN + %A defang) surfaced correctly. First clean datapoint post-FIX-A; one more weekday/custom-display angle in a future iteration would bulletproof it.

### Q2 — bitwise set-bit + neither-mask (2nd-angle re-probe, bulletproofing)
| Dimension | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
**Q2 avg = 5.00**

DOCS-VERIFIED (bitwise.html): `bitwise_or(x, y) → bigint`, `bitwise_and(x, y) → bigint`, `bitwise_left_shift(value, shift)` — argument order (value, shift) confirmed, and the docs document ONLY function forms (no `<<`/`>>` operator in Trino 467). The responder's set-bit logic is correct: `bitwise_or(prefs, bitwise_left_shift(1,2))` sets bit 2 (2^2 = 4) leaving others untouched, and the literal `bitwise_or(prefs, 4)` alt is equivalent and correct. The neither-test is correct: mask 34 = bits 1 (2) + 5 (32) via `bitwise_or(2,32)`, and `bitwise_and(prefs, 34) = 0` is TRUE iff neither bit is set. The function inventory listed (bitwise_and/or/xor, bitwise_left_shift(value,shift), bitwise_right_shift) is accurate. UPDATE on an Iceberg table is supported in Trino 467 (merge-on-read default) — NOT penalized, as directed.

**bitwise VERDICT: STAYS CLOSED → BULLETPROOFED.** This is the 2nd consecutive clean bitwise datapoint (after the iter736 FIX-A that introduced the §4.4G canonical). No `<<` operator slip, correct set-bit and AND-mask-zero logic, function-only forms throughout. Stop re-probing; do NOT edit the r27 §4.4G canonical (iter693 churn-risk).

### Q3 — bool_and / bool_or (fresh)
| Dimension | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
**Q3 avg = 5.00**

DOCS-VERIFIED (aggregate.html): `bool_and(boolean) → boolean` returns TRUE iff every input is TRUE; `bool_or(boolean) → boolean` returns TRUE iff any input is TRUE; both ignore NULL values ("all of these aggregate functions ignore null values"). The responder's `bool_and(shipped)` (all shipped) and `bool_or(NOT shipped)` (any unshipped) per-`order_id` group aggregates are exactly correct and idiomatic — cleaner than `COUNT(CASE WHEN ...)` as the user asked. Single GROUP BY pass, one boolean per group, NULL-ignoring behavior correctly stated.

### Q4 — weighted average (fresh)
| Dimension | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 4.75 |
| Actionability | 5 |
**Q4 avg = 4.9375**

DOCS-VERIFIED (trino.io/docs/467): `SUM(score * response_weight) / SUM(response_weight)` is the correct weighted-average idiom; `NULLIF(SUM(response_weight), 0)` correctly guards a zero-total-weight divide (returns NULL instead of erroring on integer/decimal divide-by-zero). The plain, per-group GROUP BY, and zero-weight-guard variants are all correct. The survey example weights (1.0 / 2.0 / 0.5) are DECIMAL literals, so the division is fractional — no truncation issue here, answer is fully correct. Minor clarity-only note (-0.25, NOT a defect): the answer does not mention that IF score AND weight were both integer-typed, `SUM(score*weight)/SUM(weight)` would be integer division (truncates toward zero) and would need a CAST/decimal to get a fractional result. Given the decimal weights in the example this is a latent edge, not an error in this answer.

---

## Overall

| Q | Avg |
|---|---|
| Q1 | 5.00 |
| Q2 | 5.00 |
| Q3 | 5.00 |
| Q4 | 4.9375 |

**OVERALL AVG = 4.984 → PASS** (threshold 3.5; overall average governs, no per-Q override).

---

## Verdicts requested

- **Q1 date_format FIX-A: CLOSED.** `%a` (not `%A`) used + DATE CAST to timestamp — both iter740 defects fixed. First clean post-FIX-A datapoint; one more custom-display/weekday angle would bulletproof.
- **Q2 bitwise: STAYS CLOSED → BULLETPROOFED.** 2nd consecutive clean datapoint; correct set-bit OR, AND-mask=0 neither-test, function-only (no `<<`). Stop re-probing, do not edit §4.4G.

## iter742 flags
- **NO new defect. NO genuine resource gap.** Recommend a DEFAULT NO-OP integrity sweep next iteration.
- **OPTIONAL teacher note (low priority, Q4 nuance, worth a one-liner)**: At the weighted-average canonical (r07 §A3), co-locate a short note that `SUM(x*w)/SUM(w)` is INTEGER division when both x and w are integer-typed (truncates toward zero) — to get a fractional weighted average, ensure a double/decimal is in play (decimal weights, or `CAST(... AS DOUBLE)` / `1.0 *`). This is a teacher-note, NOT a defect in this answer (the example used decimal weights, so the result is already fractional). Add adjacent only; do not reconcile or restructure.
- **OPTIONAL low-prio re-probe**: date_format FIX-A 2nd angle (e.g. full weekday `%W` / a different custom display string) to move it from CLOSED toward BULLETPROOFED. Do NOT re-probe bitwise (now bulletproofed) or edit §4.4G/§4.2 (iter693 churn-risk).
