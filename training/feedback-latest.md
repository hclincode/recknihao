# Judge Feedback — iter726

**Topic**: array_max FIX-A re-probe + modulo + starts_with/ends_with + date-grouping
**Verification**: every dialect claim checked against trino.io/docs/467 (array.html, math.html, string.html, functions/list.html) via WebFetch/WebSearch — NOT against resources/.

## Per-question scores

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | array_max within array, no explode | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | modulo / divisibility (% and mod) | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | starts_with / ends_with | 5 | 4.5 | 5 | 5 | 4.875 |
| Q4 | strip time → date for grouping | 5 | 5 | 5 | 5 | 5.00 |

**OVERALL AVG = 4.969 — PASS** (threshold 3.5; overall average governs, no per-Q override).

## Docs-verification record (trino.io/docs/467)

- **Q1 array_max** — VERBATIM `array_max(x) → x` "Returns the maximum value of input array." (and `array_min(x) → x` "Returns the minimum value of input array."). Single-arg array reducer, no UNNEST. CONFIRMED.
- **Q2 modulo** — VERBATIM `mod(n, m) → [same as input]` "Returns the modulus (remainder) of n divided by m." Modulus operator `%` IS in the Mathematical operators table ("Modulus (remainder)"). BOTH exist and are equivalent. CONFIRMED.
- **Q3 starts_with** — VERBATIM `starts_with(string, substring) → boolean` "Tests whether substring is a prefix of string." PRESENT in functions/string.html AND in the alphabetical functions/list.html under S. `ends_with` is ABSENT from string.html and absent from the alphabetical list. The responder's BOTH claims are TRUE.
- **Q4 date grouping** — `CAST(created_at AS DATE)` → DATE type; `date_trunc('day', created_at)` → timestamp at midnight; both produce a valid day-level grouping key. Trino requires GROUP BY to repeat the full expression (alias not usable here). CONFIRMED.

## array_max FIX-A verdict (Q1)

**CLOSED.** Direct re-probe of the iter725 Q4 defect (2.50 — responder gave CROSS JOIN UNNEST(arr)…MAX…GROUP BY which EXPLODES, plus the fragile GREATEST(coalesce(arr[i],0)…) fixed-index hack, and MISSED array_max). This iteration the responder gave **exactly** `array_max(monthly_invoices)` — one function, one row in / one row out, NO UNNEST, NO GROUP BY, NO GREATEST-index hack — and correctly stated NULL/empty → NULL. The iter726 PIN canonical added to r07 §1a worked: keyword path landed, defangs were not copied. FIX-A CLOSED. Score 5.00.

## Q3 starts_with docs-verification verdict (the key check this iteration)

**`starts_with` EXISTS in Trino 467** (functions/string.html: `starts_with(string, substring) → boolean`; also in functions/list.html under S). **`ends_with` does NOT exist in Trino 467** (absent from both string.html and the alphabetical list). The directive's hypothesis that "starts_with may be a Spark/Snowflake/DuckDB dialect-leak fabrication that parse-errors" is itself INCORRECT for Trino — starts_with is genuinely native. The responder's answer is fully accurate on BOTH halves:
1. "Use starts_with(string, substring) for prefix tests … starts_with is a native Trino function" — TRUE, docs-verified.
2. "there is NO ends_with function in Trino 467 — use LIKE '%.suffix' or substr" — TRUE, docs-verified.

**NO iter727 flag for Q3.** No RESOURCE-DEFECT, no SYNTHESIS-SLIP. resources/23 (cited source) is correct on this point — do NOT "fix" it. If the teacher greps r23 for starts_with, the expectation is that it is documented as a real native function; leave it intact. Q3 accuracy must NOT be scored down — scored 5 on accuracy.

Minor completeness note only (not score-driving): responder could optionally mention `strpos(s, prefix) = 1` or `substr(s, 1, length(prefix)) = prefix` as portable prefix alternatives. Gravy, not a gap — Completeness 4.5.

## Teacher feedback (actionable)

- **No edits required.** All four answers are docs-correct; the array_max FIX-A is confirmed CLOSED across a fresh phrasing ("peak month … without exploding"). The iter726 PIN is doing its job.
- **Do NOT touch starts_with content.** starts_with is a real Trino 467 function; responder and r23 are both correct. Any "correction" would introduce an error.
- **Optional (low priority) findability nudge:** near the r23 starts_with / suffix-test content, co-locate the portable `strpos(s, prefix)=1` and `substr(s,1,length(prefix))=prefix` alternatives plus an explicit "Trino has starts_with but NOT ends_with — use LIKE '%suffix' / substr(s,-n)" one-liner so the suffix half routes cleanly. Additive only; current content is not wrong.
- Preserve all iter534-726 locks. resources/22 HARD LOCK untouched.

## Notes
- state.json NOT modified (per directive).
- This is the first PASSING datapoint for `array_max` (iter725 Q4 was a FAIL on this exact ask). One more re-probe from a different angle recommended before treating array_max as bulletproofed.
