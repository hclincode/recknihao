# Judge Feedback — iter724

Mode: extended-phase light verification (4 Q&A re-probe of string/numeric/datetime scalar functions).
All dialect claims VERIFIED against trino.io/docs/467 (math.html, string.html, datetime.html) — not against resources/.

## Q1 — Force exactly two decimal places
Scores: Accuracy 4.5 | Completeness 3.5 | Clarity 5 | Actionability 4.5
- `round(revenue, 2)` is a docs-correct Trino 467 form: math.html — `round(x, d)` "Returns x rounded to d decimal places." VERIFIED.
- HALF_UP claim: Trino's `round` does use round-half-up (round-half-away-from-zero) semantics — correct, and the Oracle analogy is a reasonable bridge for the migrating engineer.
- **DECIMAL-cast defect (iter723 Q4) is CLOSED.** The responder emitted NO bare `col DECIMAL(p,s)` SELECT-list declaration. The only typed expressions are the legitimate `ROUND(revenue, 2)` call and a plain `revenue AS raw_value` alias. No parse-error-shaped synthesis slip recurred. The iter724 §4.4A inoculation appears to be holding.
- Accuracy/Completeness nuance (per directive): the user asked to "store/display as EXACTLY two decimal places" for a FLOAT/DOUBLE input. `round(double, 2)` returns a **DOUBLE** — it rounds the VALUE but does not pin the SCALE, so 20.00000001 → 20.0 may still render as `20.0`, not `20.00`. The fixed-scale guarantee for storage/display comes from `CAST(revenue AS DECIMAL(18,2))`, which returns a DECIMAL with scale exactly 2. The responder omitted the CAST-to-DECIMAL form entirely. round(x,2) is a legitimate, non-penalized form, so this is weighed only as a Completeness shortfall, not an accuracy error. Accuracy held at 4.5 ("returns 19.99 and 20.00" slightly overstates display fidelity for a DOUBLE result).

## Q2 — Character position of a substring
Scores: Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5
- `strpos(url, '/dashboard')` — string.html VERIFIED: "Returns the starting position of the first instance of substring in string. Positions start with 1. If not found, 0 is returned." 1-indexed + 0-if-absent both stated correctly.
- 3-arg `strpos(url, '/', 2)` for the n-th occurrence — VERIFIED: `strpos(string, substring, instance) → bigint` returns the position of the N-th instance (negative instance searches from the end). The 3-arg form is real in Trino 467 and used correctly. No flag.

## Q3 — Replace all occurrences
Scores: Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5
- `replace(user_agent, '/', ' ')` — string.html VERIFIED: 3-arg `replace(string, search, replace)` "Replaces all instances of search with replace in string." Correctly explained that EVERY slash is replaced. Worked example correct.

## Q4 — Extract hour for GROUP BY
Scores: Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5
- `EXTRACT(HOUR FROM event_timestamp)` — datetime.html VERIFIED valid; `hour(x)` returns 0–23 and is the documented equivalent shorthand (`HOUR → hour()` in the extraction-field table). Either form acceptable; not penalized.
- `GROUP BY EXTRACT(HOUR FROM event_timestamp)` repeating the expression (not a SELECT alias) is valid Trino. ORDER BY on the `hour_of_day` alias is also valid. Whole query parses and is semantically correct.

## Scores summary

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 4.5 | 3.5 | 5 | 4.5 | 4.375 |
| Q2 | 5 | 5 | 5 | 5 | 5.000 |
| Q3 | 5 | 5 | 5 | 5 | 5.000 |
| Q4 | 5 | 5 | 5 | 5 | 5.000 |

Per-dimension overall: Accuracy 4.875 | Completeness 4.625 | Clarity 5 | Actionability 4.875
**OVERALL AVERAGE = 4.844 → PASS** (threshold 3.5; overall average governs)

## Q1 verdict (explicit)
**The bare `col DECIMAL(p,s)` SELECT-list DECIMAL-cast defect is CLOSED.** No bare parameterized-type declaration appeared in any answer this iteration; the responder used the legitimate `ROUND(revenue, 2)` form. The iter724 §4.4A defang/canonical co-location is doing its job.

## Teacher feedback / iter725 flag
- **NEW MINOR GAP (Completeness only, low priority):** Q1's "force exactly two decimal places for storage/display" ask is best served by `CAST(revenue AS DECIMAL(18,2))` (fixed scale), ideally with a one-line router: `round(x,2)` rounds the VALUE but stays DOUBLE (may still display as 20.0); `CAST(x AS DECIMAL(18,2))` guarantees scale-2 for storage/display. The CAST-to-DECIMAL canonical already exists (r27:1175/1191, r23 §3.1B/C) — the responder just did not surface it for a "two decimal places" phrasing. Consider adding "force two decimal places / store as two decimals / fixed scale for display" keyword anchors NEXT TO the `round(x, d)` content (likely r07 analytical patterns, where the responder sourced Q1) so a money-rounding phrasing also routes to the DECIMAL fixed-scale form. Findability/co-location nudge, NOT a correctness fix — do not churn the correct canonical.
- iter725: re-probe Q1 once more after any co-location edit to confirm the responder offers BOTH `round(x,2)` and `CAST(... AS DECIMAL(18,2))` for the "exactly two decimal places for storage" phrasing. No other gaps detected; Q2/Q3/Q4 bulletproof.
