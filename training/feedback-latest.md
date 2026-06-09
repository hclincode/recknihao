# Judge Feedback — iter821 (DEFAULT NO-OP durability sweep)

**Verdict: overall avg 4.94 — STRONG PASS.** Phase: extended. Teacher made zero resource edits this iteration (durability sweep). All four answers verified clean against trino.io/docs/467. No defect surfaced. The load-bearing Q3 row-tuple comparison claim was scrutinized hardest and is CONFIRMED VALID.

## Per-question scores

### Q1 — count elements in an array (`cardinality` vs `unnest`+count) — avg 5.00
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- `cardinality(tags)` → bigint element count: VERIFIED vs array.html ("Returns the cardinality (size) of the array x"). Correct idiom; UNNEST+COUNT is the wrong/expensive tool and the responder correctly scoped UNNEST to "array INTO rows" only. Clean copy-attractive SQL, cited r07 §1a.3. Standing cardinality pin holds.

### Q2 — divide-by-zero guard (return NULL not error) — avg 4.94
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4.75
- `100.0 * successful_events / NULLIF(total_events, 0)`: VERIFIED. NULLIF(a,b) returns NULL when a=b else a (conditional.html); denom=0 → NULLIF→NULL → division yields NULL, no error. The `100.0 *` leading literal correctly forces decimal/double arithmetic (avoids integer-division truncation) AND scales to percent — responder explained both effects. Minor actionability ding only: did not mention `TRY(...)` alt or that NULL renders blank in some dashboards (cosmetic, not required). Cited r07 ~line 1715.

### Q3 — age in completed whole years from birthdate — avg 5.00  ← CRITICAL VERIFICATION TARGET
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- **Row-tuple comparison `(month(cd), day(cd)) < (month(dob), day(dob))` is VALID in Trino 467.** Confirmed via GitHub issue trinodb/trino#9528: the error path is `RowType.checkElementNotNull` raising "ROW comparison not supported **for fields with null elements**" — which proves ROW ordering comparison (`<`/`>`) IS supported when fields are non-null and orderable; the only restriction is null elements. `month()`/`day()` of a non-null DATE return non-null integers, so the comparison is well-formed lexicographic (month first, then day). NOT a defect.
- `date_diff('year', d1, d2)` returns the YEAR-FIELD difference (boundaries crossed), so it over-counts by 1 before this year's birthday — exactly why the CASE subtracts 1. (Note: a WebFetch summarizer wrongly claimed date_diff measures "complete elapsed years"; that is incorrect — the established Trino behavior is the field-difference, and the canonical's own DO-NOT-WRITE note confirms it. Disregarded the unreliable summary.)
- Worked example born 2000-06-15 / today 2026-06-14: year-diff 26, `(6,14) < (6,15)` TRUE → 25. Correct.
- **Faithful canonical reproduction, NOT an improvisation.** Responder reproduced the r23:1687 LEADING CANONICAL "AGE IN COMPLETED WHOLE YEARS" verbatim — same CASE form, same row-tuple comparison, identical worked example (incl. the birthday-today boundary). Teacher verified that canonical vs trino.io/docs/467 on 2026-06-07. The simpler `WHERE date_add('year', N, dob) <= current_date` filter form exists in the same canonical for "at least N years old" predicates; not needed for a SELECT-age question. Clean.

### Q4 — remove duplicate values within an array — avg 4.81
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4.25
- `array_distinct(tags)`: VERIFIED vs array.html ("Remove duplicate values from the array x"). Trino preserves first-occurrence order (established behavior; docs prose does not restate order but the implementation is first-occurrence-stable). Responder correctly scoped UNNEST+dedup+reaggregate as the unnecessary heavy alternative. Minor actionability ding: order-preservation asserted without a worked before/after example, but the claim is correct. Cited r07 §1a.3 line 607.

## Overall

(5.00 + 4.94 + 5.00 + 4.81) / 4 = **4.94 — STRONG PASS** (threshold 3.5; overall average governs, no per-Q veto).

All dialect claims verified against trino.io/docs/467 (array.html, conditional.html, datetime.html, comparison.html) + GitHub trinodb/trino#9528 for the ROW-comparison support boundary, on 2026-06-09.

## iter822 directive — DEFAULT NO-OP / durability-breadth sweep

No open defect. All four topics clean; Q3 row-comparison confirmed valid (highest-risk claim cleared).

- **iter822 = DEFAULT NO-OP durability sweep** (teacher: zero edits expected).
- Re-probe suggestions (fresh angles, do not re-ask identical phrasings):
  - Q3 age: probe a **leap-day birthdate (Feb 29)** or the **"at least N years old" WHERE filter** form to bulletproof the second canonical branch from a different angle.
  - Q1/Q4 arrays: probe `array_distinct` numeric-array order-preservation with a worked before/after, or `cardinality` on a NULL/empty array (0 vs NULL behavior).
  - Q2: probe `TRY(...)`-based guard vs NULLIF, or a GROUP BY ratio where NULLIF guards an aggregate denominator.
- **PRESERVE (churn risk — verified clean):** r23:1687 AGE-IN-COMPLETED-WHOLE-YEARS canonical (CASE row-tuple form + worked example + `date_add('year',N,dob)<=current_date` filter + DO-NOT-WRITE bare-date_diff note), r07 §1a.3 cardinality/array_distinct cards, r07 ~1715 NULLIF divide-by-zero guard, plus full iter534–820 pin inventory.
- DO NOT bump training/state.json (already 821).
