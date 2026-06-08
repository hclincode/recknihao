# Judge Feedback — iter725

Mode: extended-phase scrutiny re-probe (string/numeric/decimal scalar functions + array max). All dialect claims VERIFIED against trino.io/docs/467 (string.html, conversion.html, array.html, language/types.html) — not against resources/.

## Per-question scores (Accuracy / Completeness / Clarity / Actionability)

### Q1 — lock a numeric column to exactly two decimal places
- Accuracy: 5
- Completeness: 4
- Clarity: 5
- Actionability: 5
- **Q1 avg: 4.75**

Verdict on the directive's three checks:
- (a) YES — `DECIMAL(18,2)` as a CREATE TABLE column type is a valid AND appropriate answer to "lock the column to exactly two decimal places." Scale = 2 pins exactly two stored decimal places at the storage/schema level; this is the correct fixed-scale form for "always hold exactly two decimals."
- (b) CONFIRMED — the responder did NOT emit a bare `col DECIMAL(p,s)` in a SELECT list. It used `monthly_revenue DECIMAL(18,2) NOT NULL` inside a `CREATE TABLE`, which is valid column-DDL and is NOT the iter723 defect. **The bare-declaration defect STAYS CLOSED.**
- (c) Minor completeness gap: the question was storage-leaning ("want the column to always hold exactly two decimals"), so CREATE TABLE is the primary correct response. It omitted the inline `CAST(monthly_revenue AS DECIMAL(18,2))` form for converting an EXISTING value/column in place. One sentence pointing at the cast form would have made it complete. Costs 1 point on Completeness only.
- HALF_UP: "Incoming values rounded HALF_UP when cast to this type" is accurate — Trino's cast-to-DECIMAL uses round-half-up (away from zero); source-verified in r23 §3.1C and consistent with prior docs verification.

**FINDABILITY FLAG (fixed-scale DECIMAL form): RESOLVED.** The responder surfaced the fixed-scale DECIMAL form on a storage-phrased question, cited the money-decimal canonical (§3.1/§3.1B/§3.1C), and produced no defect. The iter724/iter725 cross-ref work landed.

### Q2 — strip leading/trailing whitespace
- Accuracy: 5 / Completeness: 5 / Clarity: 5 / Actionability: 5
- **Q2 avg: 5.0**

`TRIM(customer_name)` is correct. Docs-verified (string.html): "trim(string) — Removes leading and trailing whitespace from string." The " Acme Corp " → "Acme Corp" example is concrete and correct. Citation precision is irrelevant per directive; the ANSWER is fully correct.

### Q3 — cast text column to a number
- Accuracy: 5 / Completeness: 5 / Clarity: 5 / Actionability: 5
- **Q3 avg: 5.0**

`CAST(daily_active_users AS BIGINT)` for arithmetic + numeric sort, and `TRY_CAST(... AS BIGINT)` for bad-value tolerance (→NULL), both docs-verified (conversion.html): cast(varchar AS bigint) parses a numeric string; try_cast "returns null if the cast fails." The lexicographic-vs-numeric explanation ("10" sorts before "9" as text, 10>9 as number) is accurate and is exactly the user's confusion. Fully correct and complete.

### Q4 — single max value out of an array WITHOUT exploding — SCRUTINIZED
- Accuracy: 2 / Completeness: 2 / Clarity: 4 / Actionability: 2
- **Q4 avg: 2.5**

The user EXPLICITLY asked for the max of an array column "WITHOUT exploding the whole array into rows." The clean docs-correct single-function answer is **`array_max(response_times_array)`** — verified at trino.io/docs/467/functions/array.html: "array_max(array) — Returns the maximum value of input array." One row in / one row out, NO unnest, NO group by. It is precisely what the user asked for. The responder MISSED it.

What the responder gave instead:
- PRIMARY: `CROSS JOIN UNNEST(...) ... MAX(...) GROUP BY` — this IS exploding the array into rows, the exact opposite of the user's stated constraint. Computes a correct value but directly contradicts the ask and changes query shape/cost vs a scalar function.
- SECONDARY: `GREATEST(coalesce(arr[1],0), coalesce(arr[2],0), arr[3]...)` — fragile fixed-index hack; only valid for a KNOWN fixed array length, `coalesce(...,0)` corrupts a max over negative values (benign here since latencies are non-negative), and it silently ignores elements beyond the hardcoded indices.

Neither form satisfies "without exploding," and neither is the idiomatic answer. Clarity survives (readable; the "don't UNNEST without GROUP BY" caveat is sound). Accuracy/Completeness/Actionability scored down because the answer fails the literal, emphasized requirement.

NULL note: per Trino semantics `array_max` returns NULL if the array contains any NULL element. For non-null latency arrays this is a non-issue; the canonical should state the NULL-element behavior.

---

## Overall

| Q | Avg |
|---|---|
| Q1 | 4.75 |
| Q2 | 5.0 |
| Q3 | 5.0 |
| Q4 | 2.5 |

**Overall average = (4.75 + 5.0 + 5.0 + 2.5) / 4 = 4.3125**

**PASS** (overall avg 4.3125 ≥ 3.5; overall average governs, no per-Q override). Q4 alone is a fail-grade answer but does not sink the iteration.

---

## Q4 array_max gap — precise characterization for iter726

This is a **FINDABLE-BUT-MISSING gap, NOT a landing-point miss.**

- Grep of all of `resources/` for `array_max`/`array_min`: **ZERO matches.** The function appears nowhere in the corpus. The responder could not surface it because no canonical exists to find.
- Nearest existing array content: r07:454 (top-N-from-an-array via `array_sort` + `slice`, the iter675 Q2 shape) and the `greatest`/`least` row-wise-across-columns canonicals (r23:1404, r27:1381) — neither is the single-element-from-one-array scalar reducer the user wanted.
- Because the closest neighbor teaches array_sort+slice and UNNEST+aggregate but NOT array_max, the responder reached for UNNEST+MAX and the GREATEST hack — the wrong-but-locally-available forms.

### Teacher action for iter726 (recommended)
1. GREP first to confirm (judge already did: zero array_max/array_min hits). Then ADD a LEADING CANONICAL for scalar array reducers in r07 §1a (adjacent to the existing array_sort/slice and MAP-explode canonicals), titled on the user's phrasing: "single max/min value out of an array WITHOUT exploding into rows."
   - PRIMARY: `array_max(arr)` / `array_min(arr)` — docs-verified one-function answer, one row in/out, no UNNEST, no GROUP BY.
   - State NULL-element semantics: `array_max` returns NULL if any element is NULL; show `array_max(filter(arr, x -> x IS NOT NULL))` only if NULLs expected.
   - Cross-ref the family: `array_sort` (full ordering), `slice` (top-N), `element_at`/`arr[1]` (single index).
   - Keyword anchors: max value from an array, highest value in an array column, max of a list without unnest, array max Trino, single largest element of an array, biggest value in an array, min/max over an array column, without exploding the array.
2. INLINE-DEFANG (un-copyable, per the iter693/694 lesson) the two wrong-but-tempting forms this iter exposed: the `CROSS JOIN UNNEST ... MAX ... GROUP BY` form marked "❌ this EXPLODES into rows — the opposite of what was asked; use array_max" and the fixed-index `GREATEST(coalesce(arr[1],0), ...)` hack marked "❌ fragile; only a known fixed length, and coalesce-to-0 corrupts a max over negatives."
3. Add a one-line cross-ref from r27 §4.4D (greatest/least row-wise canonical) → "for max of a SINGLE array column use array_max, not greatest+indexing; see r07 §1a." Disambiguate: array_max = max WITHIN ONE ARRAY VALUE; greatest = max ACROSS COLUMNS in one row. Both collide on "highest value" keywords, so the new canonical needs an explicit array-vs-across-columns disambiguator.

---

## Locks to preserve
Q1 confirms the money-DECIMAL CAST canonical (r27, r23 §3.1B/§3.1C) and the iter724 §4.4A bare-declaration inoculation are HELD and effective. Do not churn them. The iter726 array_max work is purely ADDITIVE to r07 §1a.
