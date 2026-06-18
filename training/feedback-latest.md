# Judge Feedback — iter1091 (2026-06-18)

Verified BOTH directions vs RAW git-tag 467 sources:
- functions/array.md — `contains_sequence` EXISTS; `array_position` first-occurrence/1-based/0-if-absent
- functions/datetime.md — `day_of_week` ISO 1=Mon..7=Sun; `format_datetime` Joda; NO `dayname`
- functions/comparison.md — GREATEST/LEAST return NULL if ANY arg null (NOT Postgres all-null rule)
- functions/conditional.md — COALESCE "first non-null value"
- WebSearch corroboration of `contains_sequence` consecutive-subsequence semantics

---

## Q1 — funnel: did 'add_to_cart' go DIRECTLY to 'checkout' without exploding the array

**Scores: Accuracy 2.0 / Completeness 2.5 / Clarity 4.0 / Actionability 2.5**

CORRECTNESS DEFECT (PRIMARY answer, not an aside). The responder used
`array_position(funnel_steps,'checkout') = array_position(funnel_steps,'add_to_cart') + 1`.
`array_position` returns ONLY the **first occurrence** of each value (verified RAW array.md:
"Returns the position of the first occurrence of the `element` in array `x` (or 0 if not found)").

Counterexample (source-verified failure): `funnel_steps = ARRAY['add_to_cart','view','add_to_cart','checkout']`.
The user DID go add_to_cart→checkout back-to-back (positions 3→4). But
`array_position('add_to_cart')=1` (first occ) and `array_position('checkout')=4`, so `1+1=2 ≠ 4`
→ the expression returns **FALSE → a FALSE NEGATIVE**. The approach is correct ONLY when each step
value appears at most once in the array. Repeated steps are the norm in real event/funnel arrays
(users add to cart, browse, add again, then check out), so this is a genuine correctness defect for
the general case, not a stylistic nit. The complementary case `ARRAY['add_to_cart','checkout','add_to_cart']`
returns TRUE only by luck.

MISSED CANONICAL: Trino 467 has the purpose-built function
`contains_sequence(x, seq)` — VERIFIED in RAW functions/array.md: "Return true if array `x` contains
all of array `seq` as a subsequence" (WebSearch confirms: consecutive, same order). The exact, robust,
no-explosion answer is:
`contains_sequence(funnel_steps, ARRAY['add_to_cart','checkout'])`.
This handles duplicates correctly, expresses "directly followed by" natively, and needs no WHERE guard
or position arithmetic. The responder did not mention it. Clarity is decent (the array_position mechanics
are explained accurately in isolation), but the assembled solution does not correctly answer the question.

## Q2 — first non-null of preferred_name, full_name, email (no nested CASE)

**Scores: Accuracy 5.0 / Completeness 4.75 / Clarity 5.0 / Actionability 5.0**

`COALESCE(preferred_name, full_name, email) AS display_name` is exactly right. Verified RAW
conditional.md: COALESCE "Returns the first non-null `value` in the argument list." Left-to-right
first-non-null is precisely COALESCE's contract; no CASE needed. Clean, canonical, zero defects.

## Q3 — day-of-week NAME like "Wednesday" from a timestamp

**Scores: Accuracy 4.88 / Completeness 4.88 / Clarity 5.0 / Actionability 4.88**

`format_datetime(CAST(created_at AS timestamp), 'EEEE')` returns the full weekday name. Verified
RAW datetime.md: format_datetime "Formats `timestamp` as a string using `format`" with JodaTime
DateTimeFormat patterns; `EEEE` is the Joda token for the full text weekday name (Monday..Sunday).
The responder correctly warns NOT to use `CAST(day_of_week(ts) AS VARCHAR)` (that yields the NUMBER),
and correctly notes `day_of_week(created_at)` returns ISO 1=Monday..7=Sunday (verified RAW: "Returns
the ISO day of the week... `1` (Monday) to `7` (Sunday)"). There is NO `dayname()` built-in in 467
(verified — responder did not fabricate one). The `CAST(... AS timestamp)` is harmless/defensive when
the column is already a timestamp; `date_format(created_at, '%W')` is an equally-valid alternative not
shown. No defect.

## Q4 — largest of wholesale_cost, retail_price, discounted_price in one row (no CASE)

**Scores: Accuracy 5.0 / Completeness 5.0 / Clarity 5.0 / Actionability 5.0**

`GREATEST(wholesale_cost, retail_price, discounted_price)` is exactly right. Verified RAW
comparison.md: GREATEST/LEAST "return null if any argument is null. Note that in some other databases,
such as PostgreSQL, they only return null if all arguments are null." The responder's caveat ("GREATEST
returns NULL if ANY arg is NULL") is correct AND the `GREATEST(COALESCE(col,0), ...)` workaround to
treat NULLs as 0 is valid. Matches the [Trino GREATEST/LEAST NULL] pin. Fully correct both directions.

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 2.0 | 2.5 | 4.0 | 2.5 | 2.75 |
| Q2 | 5.0 | 4.75 | 5.0 | 5.0 | 4.94 |
| Q3 | 4.88 | 4.88 | 5.0 | 4.88 | 4.91 |
| Q4 | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 |

**Dimension averages:** Accuracy (2.0+5.0+4.88+5.0)/4 = 4.22; Completeness (2.5+4.75+4.88+5.0)/4 = 4.28;
Clarity (4.0+5.0+5.0+5.0)/4 = 4.75; Actionability (2.5+5.0+4.88+5.0)/4 = 4.345.

**Overall average = (2.75 + 4.94 + 4.91 + 5.0) / 4 = 4.40 → PASS** (overall ≥ 3.5; no per-question veto).

### Source-verified defects
- **Q1 (correctness defect):** `array_position`-arithmetic is a FALSE-NEGATIVE solution whenever a step
  value repeats in the array (verified counterexample `['add_to_cart','view','add_to_cart','checkout']`).
  The MISSED canonical is `contains_sequence(funnel_steps, ARRAY['add_to_cart','checkout'])` — the
  purpose-built consecutive-subsequence function (RAW functions/array.md). This is NOT merely a
  less-robust alternative; for the general funnel question (which permits repeats) it returns the wrong
  answer. Recommend the teacher add a findable `contains_sequence` card for "step A directly followed by
  step B in an array" funnel questions, and re-probe from a 2nd angle (e.g. "did event X come immediately
  before event Y") to confirm the responder reaches for `contains_sequence` rather than position math.
- Q2/Q3/Q4: zero source-verified defects.

No ::/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/
over-warning/broken-secondary issues elsewhere. Iteration PASSES on the overall average, but Q1 is a
real correctness gap on the array-funnel-adjacency pattern — this is the actionable finding this sweep.
MUST NOT bump state.json (already 1091). NO federation probe.
