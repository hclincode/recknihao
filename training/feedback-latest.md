# iter824 Judge Feedback — FIX-A verification (GROUP-BY-alias) + bool_and NULL re-probe

**Overall: 4.625 — PASS** (threshold 3.5; overall average governs, no per-Q veto)

All dialect claims docs-verified vs trino.io/docs/467 (aggregate/string/array/math .html) + WebSearch (round half-up) on 2026-06-09.

| Q | Topic | Acc | Comp | Clar | Act | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | email-domain GROUP + COUNT + sort | 5 | 5 | 5 | 5 | **5.00** | CLEAN — **FIX LANDED** |
| Q2 | flatten array-of-arrays | 5 | 5 | 5 | 5 | **5.00** | CLEAN |
| Q3 | round to 2 decimals | 5 | 4.5 | 5 | 5 | **4.875** | CLEAN |
| Q4 | all-items-fulfilled bool_and | 2.5 | 4 | 4.5 | 3.5 | **3.625** | **DEFECT (NULL-semantics accuracy)** |

## Q1 — GROUP-BY-alias fix LANDED -> CLOSED

The iter823 Q3 defect (responder emitted `GROUP BY <select-alias>`, which Trino rejects per GH#16533) is **FIXED**. This iteration the responder produced a fully runnable Trino 467 query:

- `GROUP BY split_part(email, '@', 2)` — grouped by the **repeated input EXPRESSION**, which IS valid Trino 467 (verified: GROUP BY accepts input col / expression / ordinal). NO alias in GROUP BY.
- `ORDER BY signup_count DESC` — ORDER BY a **SELECT alias**, which IS allowed in Trino 467 (verified). The responder used the asymmetry correctly: alias forbidden in GROUP BY, allowed in ORDER BY.
- `split_part(email,'@',2)` verified 1-indexed; field 2 after `@` -> `'jane@gmail.com'` -> `'gmail.com'`. Domain extraction correct.

No regression to the defanged `GROUP BY domain (alias)` form. The fix card at the split_part landing + the §8 GROUP-BY-rules asymmetry card both worked. **CLOSE the GROUP-BY-alias defect** (1st post-fix clean datapoint; one more angle — e.g. `GROUP BY 1` ordinal phrasing or HAVING-on-alias — would bulletproof it).

## Q2 — flatten CLEAN

`flatten(nested_arrays_column)` verified: array.html "Flattens an array(array(T)) to an array(T) by concatenating the contained arrays." One flat array per row, type array(E), no row multiplication. Correctly steers away from UNNEST+re-aggregate. ARRAY[ARRAY[1,2],ARRAY[3,4]] -> ARRAY[1,2,3,4] confirmed.

## Q3 — round CLEAN (minor nuance only)

`round(price, 2)` verified: math.html "Returns x rounded to d decimal places." Rounding mode HALF_UP / half-away-from-zero (confirmed via source/WebSearch). On DECIMAL, round(19.235,2)=19.24 is exact. Minor completeness ding (−0.5): the answer asserts the half-up examples without noting that on a **DOUBLE** column the binary representation can make round(19.235,2) imprecise (exact only on DECIMAL). Per directive this is a minor nuance, not a hard error — the Oracle-ROUND equivalence framing is apt and useful.

## Q4 — bool_and NULL claim is WRONG (accuracy defect)

bool_and is the correct function (vs MAX(CASE)/FILTER) and the SQL skeleton is right and clean. BUT the accuracy claim fails:

> Responder: "If even one is **FALSE OR NULL** -> FALSE."

**This is incorrect for Trino 467.** Verified vs aggregate.html: bool_and/bool_or are NOT in the exception list (count/count_if/max_by/min_by/approx_distinct), so they follow the standard rule — **"all of these aggregate functions ignore null values."** Therefore:

- bool_and over `[TRUE, NULL]` -> **TRUE** (NULL ignored), NOT FALSE.
- bool_and over `[NULL]` (all null) -> NULL, not FALSE.

Consequence: an order whose only un-fulfilled line item has `is_fulfilled = NULL` would be **wrongly flagged TRUE (all fulfilled)** — a silent wrong-result bug in production. To treat a NULL flag as not-fulfilled the responder must write `bool_and(COALESCE(is_fulfilled, false))`. Accuracy scored 2.5 (function/skeleton correct, NULL semantics materially wrong); actionability 3.5 (engineer who copies it gets a query that runs but mis-handles the realistic NULL-line-item case).

## iter825 directive — FIX-A (inline NULL-semantics clarify at bool_and card)

Make iter825 a **FIX-A** at the r07/r23 bool_and/bool_or card:

1. Inline-clarify that **bool_and / bool_or IGNORE NULL inputs** (standard aggregate NULL-skip): bool_and([TRUE, NULL]) -> TRUE; all-NULL group -> NULL.
2. Add the canonical for treating NULL-as-not-fulfilled: `bool_and(COALESCE(is_fulfilled, false)) AS all_items_fulfilled`. Lead with this when the question framing is "if even one is not fulfilled / missing -> false."
3. Inline-defang the WRONG claim on its own line: `-- WRONG: "a NULL flag makes bool_and return FALSE" — NULL is IGNORED, not FALSE`.
4. Keyword anchors: bool_and null, all true ignore null, treat null as false, all items fulfilled, every row true including nulls.

PRESERVE: the iter824 split_part GROUP-BY-1 / repeated-expression fix card + §8 GROUP-BY-alias asymmetry rule card (both LANDED), flatten/round canonicals, and the full iter534-823 pin inventory. NO federation edits (margin thin, federation 4.49944/310). DO NOT bump state.json (already 824).
