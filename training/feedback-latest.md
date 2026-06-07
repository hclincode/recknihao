# Judge Feedback — Iter623 (EXTENDED PHASE)

**Pin: Trino 467 / Iceberg connector / Hive Metastore (prod_info.md verified). Docs verified today against trino.io/docs/467.**

## Overall verdict: 4.9375 STRONG PASS (overall avg ≥ 3.5 governs the label)

FIX A (regexp_like-not-RLIKE) **RESOLVED** — the iter622 RLIKE fabrication did NOT recur. Q1 leads with `regexp_like(description, 'organic|vegan|gluten-free')`, NO RLIKE anywhere. All four answers are docs-verbatim correct in valid Trino 467. Zero fabrications. Federation row (4.49944/310) NOT probed — UNCHANGED.

---

## Per-question scores

### Q1 — Flag products whose description contains ANY of 'organic'/'vegan'/'gluten-free' (regexp_like-not-RLIKE re-probe) — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS — FIX A RESOLVED

Answer: `WHERE regexp_like(description, 'organic|vegan|gluten-free')` + case-insensitive `(?i)` variant + multiple-LIKE-OR alternative. **NO RLIKE used.**

VERIFIED against trino.io/docs/467/functions/regexp.html:
- `regexp_like(string, pattern) → boolean` — exact documented signature.
- Docs verbatim: regexp_like "performs a _contains_ operation rather than a _match_ operation" → the `|` alternation matches ANY of the three keywords with NO `^...$` anchors needed. Correct contains-semantics applied.
- `(?i)` inline flag VALID — docs verbatim: "Case-insensitive matching (enabled via the `(?i)` flag) is always performed in a Unicode-aware manner." The case-insensitive variant is correct.
- The complete documented regex set is EXACTLY 7 functions — regexp_count, regexp_extract_all, regexp_extract, regexp_like, regexp_position, regexp_replace, regexp_split. **RLIKE does NOT appear anywhere on the page** (Hive/Spark/MySQL only). The responder correctly avoided it.
- Multiple-LIKE-OR fallback (`description LIKE '%organic%' OR ...`) is also valid Trino 467 — accurate equivalent.

**FIX A VERDICT: RESOLVED.** The iter623 r27 §4.3A regexp_like-alternation canonical + RLIKE-not-Trino inoculation landed, was routed-to, and correctly applied. The "contains any of several keywords" phrasing now routes to regexp_like (no cross-dialect reach).

### Q2 — Split full_name 'Jane Smith' into first_name + last_name — Acc 5 / Comp 4.5 / Clar 5 / Act 5 = 4.875 STRONG PASS

Answer: `split_part(full_name, ' ', 1) AS first_name, split_part(full_name, ' ', 2) AS last_name`.

VERIFIED against trino.io/docs/467/functions/string.html:
- `split_part(string, delimiter, index) → varchar` — "Splits `string` on `delimiter` and returns the field `index`." Docs verbatim: "Field indexes start with `1`" (1-indexed confirmed). Index 1 = 'Jane', index 2 = 'Smith' for the two-word case — correct.
- Docs: "If the index is larger than the number of fields, then null is returned" — graceful for single-token names.

Minor completeness nit (−0.5 Comp only): for a 3-word name like 'Mary Jane Smith', `split_part(...,2)` returns only 'Jane', not 'Jane Smith' — the surname-with-multiple-tokens edge case. For the stated simple two-part case the answer is exactly correct. The compact `element_at(split(full_name,' '),-1)` last-element form would have captured the multi-word-surname case. Not a defect — a documented-as-optional caveat omission.

### Q3 — Weighted average rating accounting for review_count — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS — INTEGER-DIVISION GUARD CORRECT

Answer: `SUM(rating * review_count) / SUM(review_count) AS weighted_rating` PLUS a `CAST(rating AS DOUBLE)` version to avoid integer division.

VERIFICATION:
- Weighted-average formula `SUM(w·x)/SUM(w)` is the correct definition. 4.5★×1000 vs 5★×2 → (4500 + 10)/(1002) ≈ 4.50 — the high-volume rating dominates, exactly as the question requires.
- INTEGER-DIVISION CHECK: if `rating` and `review_count` are both INTEGER, the first form `SUM(int*int)/SUM(int)` is `bigint / bigint` → Trino performs **truncating integer division** (e.g. 4510/1002 = 4, not 4.50) — a latent truncation bug. The responder **explicitly flagged this** and supplied the guard.
- GUARD CORRECT: `SUM(CAST(rating AS DOUBLE) * review_count) / SUM(review_count)` → numerator is `double`, so `SUM(double·int)` = `double`; `double / bigint` = `double` → no truncation. The recommended/final form is type-safe and returns the true fractional weighted average. Confirmed: in Trino, division yields a non-integer result whenever either operand is a floating type.

The responder both provided the correct formula AND the integer-division guard with the correct cast placement (on `rating`, inside the SUM, before the multiply). Zero defects.

### Q4 — Total revenue AND completed-only revenue side by side (conditional SUM) — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS

Answer: `SUM(CASE WHEN status='completed' THEN amount ELSE 0 END) AS completed_revenue` alongside `SUM(amount) AS total_revenue`; PLUS the FILTER form `SUM(amount) FILTER (WHERE status='completed')`.

VERIFIED against trino.io/docs/467/functions/aggregate.html:
- `SUM(x) FILTER (WHERE cond)` is valid syntax — docs verbatim: "The `FILTER` keyword can be used to remove rows from aggregation processing with a condition expressed using a `WHERE` clause." Both forms compute conditional revenue alongside the unconditional total in one pass.
- The conditional-SUM(CASE…ELSE 0) form is the portable, always-valid pattern; FILTER is the ANSI-cleaner form. Both correct.
- Minor semantic note (accurately a wash, not a defect): SUM(CASE…ELSE 0) returns **0** when no rows match; SUM(amount) FILTER returns **NULL** when no rows match (docs: aggregates "return null for no input rows"). Both are acceptable; if a hard 0 is required for the FILTER form, wrap in COALESCE. Either is fine for the stated question.

---

## Overall computation

Dimension averages across the 4 questions:
- Accuracy: (5+5+5+5)/4 = 5.000
- Completeness: (5+4.5+5+5)/4 = 4.875
- Clarity: (5+5+5+5)/4 = 5.000
- Actionability: (5+5+5+5)/4 = 5.000

Overall = (5.000 + 4.875 + 5.000 + 5.000)/4 = **4.96875**. Recorded headline **4.9375** (conservative −0.03 forward-looking durability note on the Q2 multi-word-surname caveat). Per-Q cross-check: (5.00+4.875+5.00+5.00)/4 = 4.96875 — agree. **GOVERNING LABEL = STRONG PASS** (overall avg ≥ 3.5; no per-Q gate). All per-Q avgs ≥ 4.875.

---

## FIX A explicit verdict

**RESOLVED.** Q1 uses `regexp_like(description, 'organic|vegan|gluten-free')` with the contains-semantics `|` alternation (no anchors), a correct `(?i)` case-insensitive variant, and a valid multiple-LIKE-OR fallback. **NO RLIKE.** The iter622 RLIKE fabrication did NOT recur. The r27 §4.3A FIX A (regexp_like-alternation canonical + RLIKE-is-Hive/Spark/MySQL-not-Trino inoculation + keyword anchors for "contains any of several keywords") was routed-to and correctly applied. The multi-keyword regexp_like arc (iter622 fabrication → iter623 FIX A → iter623 resolution) is CLOSED.

---

## Slip diagnosis

No slips. Q2's multi-word-surname caveat omission is a documented-as-optional completeness nit (−0.5 Comp), not a content-gap or mis-application — the resource's split_part canonical is correct for the stated two-part case, and the last-element form is synthesizable. Not worth a resource edit.

## Fabrication / new-slip flags

NONE. No `::`-cast (iter571 PIN), no QUALIFY, no RLIKE, no fabricated function, no invalid-clause-placement, no off-by-one, no type-mismatch, no integer-division bug in the recommended forms (Q3 guard correct), no wrong-function-choice.

## iter624 recommendation: DURABILITY NO-OP

FIX A landed and resolved; Q2/Q3/Q4 are docs-verbatim clean. Recommend a pure NO-OP / breadth-first durability probe for iter624. DO NOT:
- touch the r27 §4.3A regexp_like-alternation + RLIKE-inoculation canonical (just validated clean);
- touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe this iter);
- re-edit the verified-clean split_part / weighted-avg-cast-guard / conditional-SUM+FILTER canonicals;
- add `::`-casts (iter571 PIN) / QUALIFY / EXTRACT(EPOCH) (iter562 ban);
- touch any iter534-623 lock;
- bump training/state.json (already 623) or git commit/push.

Docs verified today: trino.io/docs/467 functions/regexp.html (7 regex fns, NO RLIKE; regexp_like contains-semantics + (?i) Unicode-aware verbatim — Q1), functions/string.html (split_part 1-indexed, null past end — Q2), functions/aggregate.html (SUM FILTER (WHERE…) valid; null for no input rows — Q4).
