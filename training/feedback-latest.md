# Judge Feedback — Iter 832 (EXTENDED PHASE)

**Mode:** DEFAULT NO-OP durability sweep — teacher made ZERO resource edits this iteration.
**Federation:** NOT probed this iteration (r22 §13.x untouched; federation row stays 4.49944/310 FAIL).
**Verification:** All dialect claims PINNED + verified against trino.io/docs/467 (conditional.html, datetime.html, aggregate.html) on 2026-06-09.

---

## Per-question scores

### Q1 — boolean is_verified → 'Yes'/'No' label, SQL vs app layer
**Scores:** Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

- VERIFIED (conditional.html): `if(condition, true_value, false_value)` is a valid Trino 467 3-arg form ("returns true_value if condition is true, otherwise false_value"); the 2-arg `if(cond, value)` also exists (returns NULL when false). `CASE WHEN ... THEN ... ELSE ... END` (searched form) valid, evaluates left to right.
- Both forms responder gave are correct. "SQL not app layer" is the right call (label is a pure presentation transform; keeping it in SQL avoids per-row app logic and is reusable across consumers).
- IF-is-two-way / CASE-for->2-outcomes guidance is accurate.
- NULL nuance (with `ELSE 'No'`, a NULL `is_verified` maps to 'No') is acceptable and not relevant to this ask — no ding.

### Q2 — first populated of mobile/office/fax → 'primary contact number'
**Scores:** Accuracy 4.5 / Completeness 4 / Clarity 5 / Actionability 4.5 → **avg 4.50**

- VERIFIED (conditional.html): `coalesce(value1, value2[, ...])` "returns the first non-null value in the argument list" — left-to-right, returns NULL only if all are NULL. Core answer is CORRECT and the single-expression / no-nested-IF recommendation is the right idiom.
- **MINOR COMPLETENESS/PRECISION DING (empty-string vs NULL):** The engineer's wording was "nothing only if all three are **empty**." COALESCE tests NULL, NOT empty string `''`. For phone columns an empty string `''` is a plausible "blank" representation — and COALESCE would RETURN that `''` (it is not NULL), so the result is `''` rather than skipping to the next column. The responder restated this imprecisely ("mobile if not empty, else office...") — that gloss conflates "not empty" with "not NULL."
- The robust answer should have flagged the distinction and offered the empty-string-tolerant form:
  `COALESCE(NULLIF(mobile_phone,''), NULLIF(office_phone,''), NULLIF(fax_number,''))`
  (`NULLIF(col,'')` converts `''`→NULL so COALESCE skips it).
- Not an accuracy FAIL — COALESCE is exactly right for NULL-blank columns, which is the common case. The half-point Accuracy ding + one-point Completeness ding reflect the un-flagged `''` edge case on columns where empties are realistic.

### Q3 — SUM monthly revenue, count NULL months as 0
**Scores:** Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

- VERIFIED (aggregate.html): "Except for count(), count_if(), max_by(), min_by() and approx_distinct(), all aggregate functions ignore null values and return null for no input rows or when all values are null." So `SUM(revenue)` SKIPS NULL inputs row-by-row, and returns NULL only when the entire group is NULL / empty. `COALESCE(SUM(revenue), 0)` then converts that all-NULL/empty group-total NULL → 0. Fully correct.
- The "don't filter rows out" requirement is honored — COALESCE acts on the group total, no WHERE removes rows.
- Equivalent alt `SUM(COALESCE(revenue,0))` would also work (per-row 0-fill before summation); not required. Responder's wrap is the cleaner idiom and it cited the matching resource line.

### Q4 — ISO week number from created_at timestamp
**Scores:** Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

- VERIFIED (datetime.html): `week(x)` "returns the ISO week of the year from x. The value ranges from 1 to 53"; `week_of_year(x)` "is an alias for week()"; the EXTRACT field table maps `WEEK` → `week()`, so `EXTRACT(WEEK FROM created_at)` returns the same ISO week. All three forms valid and equivalent.
- "Native, no manual computation" is correct — no need to hand-roll ISO week math.
- Cited resource line (r07) matches the verified canonical.

---

## Overall

| Q | Acc | Comp | Clar | Act | avg |
|---|-----|------|------|-----|-----|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 4.5 | 4 | 5 | 4.5 | 4.50 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = (5.00 + 4.50 + 5.00 + 5.00) / 4 = 4.875 → STRONG PASS** (threshold 3.5; margin +1.375; overall avg governs, no per-Q veto).

**Headline:** ALL 4 clean, ZERO dialect defects. All four critical verification targets — (a) IF/CASE, (b) COALESCE first-non-null, (c) COALESCE(SUM)/all-NULL-group, (d) week_of_year/EXTRACT(WEEK) — PASSED against trino.io/docs/467. The only deduction is a small Q2 completeness/precision ding: COALESCE tests NULL not empty-string `''`, and the responder did not flag that on phone columns an empty `''` would be returned (not skipped) — the empty-string-tolerant `NULLIF(col,'')` wrap was the missing nuance. Not an accuracy failure; COALESCE is correct for the NULL-blank case.

---

## Directive for iter833

**iter833 = DEFAULT NO-OP / durability-breadth sweep.** No open defect; no FIX-A required.

- **OPTIONAL low-priority inoculation (do NOT pre-churn):** if a future probe phrases "blank/empty" on text/contact columns where `''` is plausible, add a one-line empty-string-vs-NULL note + `COALESCE(NULLIF(col,''), ...)` canonical ADJACENT to the existing COALESCE first-non-null card (r07, near the `primary_contact_number` content). Only escalate to FIX-A if a 2nd "empty vs null" probe under-scores on this; a single minor completeness ding does not warrant a resource edit.
- Suggest fresh adjacent probes: `NULLIF` zero-divide guard, `try()`/`TRY_CAST` safe parse, `date_trunc('week', ts)` (week-start vs week-number distinction), multi-branch `CASE` with >2 outcomes.
- HOLD all iter534–831 locks. Federation row UNCHANGED (not probed). DO NOT bump training/state.json (already 832).
