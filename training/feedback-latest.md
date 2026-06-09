# Judge Feedback — iter888 (EXTENDED PHASE)

**Overall: 4.95 STRONG PASS** (per-Q 5.00 / 5.00 / 4.8125 / 5.00 = 19.8125/4 = 4.953; margin +1.45 over the 3.5 threshold; overall average governs, no per-Q veto).

**FEDERATION NOT PROBED** this iter — the 4.49944/310 federation row is UNCHANGED. All 4 questions were general Trino 467 SQL-function dialect probes (array/string/math). **All 4 dialect-clean → iter889 DEFAULT NO-OP.**

Every responder claim VERIFIED against trino.io/docs/467 (multi-source: the relevant category page + functions/list.html index), WebFetch 2026-06-10, PIN Trino 467. Per the iter882 lesson, I did NOT flag any correct claim as a defect — each was confirmed against the authoritative source first.

---

## Q1 — array membership in WHERE without UNNEST — **5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)

Responder: `WHERE contains(roles, 'admin')` (boolean membership, case-sensitive exact match); case-insensitive via `contains(transform(roles, x -> lower(x)), lower('admin'))`.

VERIFIED vs trino.io/docs/467 functions/array.html (+ list.html C/T index):
- `contains(x, element) -> boolean` — verbatim "Returns true if the array `x` contains the `element`." Element membership, boolean result — CORRECT.
- `transform(array(T), function(T,U)) -> array(U)` — verbatim "Returns an array that is the result of applying `function` to each element of `array`." So `transform(roles, x -> lower(x))` lowercases each element, and the outer `contains` then does a case-insensitive membership test — CORRECT and idiomatic.

**(a) CONFIRMED**: `contains()` is the right no-UNNEST membership test (boolean) and the `transform`-based case-fold is valid. No defect. No gap.

## Q2 — first char position of 'error' in a string — **5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)

Responder: `strpos(notes, 'error')` (1-based, 0 if not found); `WHERE strpos(notes,'error') > 0`; 3-arg `strpos(s, sub, -1)` for the LAST occurrence (negative instance counts from the end).

VERIFIED vs trino.io/docs/467 functions/string.html (+ list.html S index):
- `strpos(string, substring)` — verbatim "Returns the starting position of the first instance of `substring` in `string`. Positions start with `1`. If not found, `0` is returned." 1-based + 0-absent — CORRECT.
- `strpos(string, substring, instance)` — verbatim "Returns the position of the N-th `instance` of `substring` in `string`. When `instance` is a negative number the search will start from the end of `string`." So `strpos(s, sub, -1)` = LAST occurrence — CORRECT.

**(b) CONFIRMED**: strpos is 1-based / 0-on-absent, and the 3-arg negative-instance counts-from-the-end (−1 = last) form is correct. No defect.

## Q3 — count items in a comma-separated string -> 4 — **4.8125** (Acc 5 / Comp 4.75 / Clar 4.5 / Act 5)

Responder: `cardinality(split(selected_features, ','))` -> 4; mentioned TRIM for spaces but the TRIM framing was muddled (whole-string TRIM vs per-element).

VERIFIED vs trino.io/docs/467 functions/string.html + array.html (+ list.html S/C index):
- `split(string, delimiter)` — verbatim "Splits `string` on `delimiter` and returns an array." Delimiter is a LITERAL string (the `split(string, delimiter, limit)` overload also exists). For `'export,sso,api,webhooks'` this yields `['export','sso','api','webhooks']`.
- `cardinality(x) -> bigint` — array element count.
- `cardinality(split(s, ','))` correctly counts the items — CORE ANSWER CORRECT (returns 4).

Minor deductions (NOT defects):
- **Clarity (4.5)**: the TRIM remark is genuinely muddled — a single `TRIM` on the whole string trims only the outer ends, not per-element spaces (e.g. `'a, b, c'` would need a per-element transform like `transform(split(s,','), x -> trim(x))`, not a whole-string TRIM). The core answer is unaffected because the question's input has no spaces, but the aside is loosely worded.
- **Completeness (4.75)**: edge cases unstated — empty string `''` -> `split` gives `['']` cardinality **1** (not 0); trailing comma `'a,b,'` -> `['a','b','']` cardinality **3**. As the run-prompt directs, these are completeness nuances only; the core answer is correct.

**(c) CONFIRMED**: `cardinality(split(s, ','))` is the correct item-count construction. No defect — only a clarity nit (TRIM aside) and an edge-case completeness nuance.

## Q4 — sign function to tag positive/negative/zero — **5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)

Responder: `sign(score)` returns 1 (n>0) / -1 (n<0) / 0 (n=0); `CASE sign(score) WHEN 1 THEN 'positive' WHEN -1 THEN 'negative' WHEN 0 THEN 'zero' END`; works on any numeric type.

VERIFIED vs trino.io/docs/467 functions/math.html (+ list.html S index):
- `sign(x)` EXISTS — "signum function of x": returns **0 if argument is 0, 1 if greater than 0, -1 if less than 0**. CORRECT.
- Floating-point additional behavior (doc verbatim): "-0 if the argument is -0, NaN if the argument is NaN, 1 if the argument is +Infinity, -1 if the argument is -Infinity." So for a `double` NaN, `sign(NaN) = NaN` — an edge nuance the run-prompt already flagged; not relevant to the integer/normal-value tagging use case.
- For a double column `sign` returns a double `1.0/-1.0/0.0`; the `CASE ... WHEN 1 ...` integer-literal comparison coerces fine (numeric comparison), so the responder's CASE works on any numeric type — CORRECT.

**(d) EXPLICITLY CONFIRMED: `sign()` EXISTS in Trino 467 and returns 1 / -1 / 0 for positive / negative / zero respectively.** The responder's CASE-on-sign tagging is correct. (Double NaN -> NaN is the only edge nuance, outside the normal-value use case and noted in the prompt.) No defect.

---

## iter889 RECOMMENDATION: **DEFAULT NO-OP**

All 4 answers dialect-clean and verified against trino.io/docs/467 (array/string/math .html + functions/list.html index), PIN 467. No defect surfaced; no FIX-A; no escalation; teacher ZERO edits.

- Do NOT add any "wrong" card for Q1–Q4 — every form (`contains`/`transform`, `strpos` 1-based + negative-instance, `cardinality(split())`, `sign()`) is correct.
- Do NOT flag the correct Q3 `cardinality(split())` or Q4 `sign()` claims as defects (iter882 lesson — verified against source first).
- OPTIONAL findability micro-polish only (skip if it churns any pin): a neutral 1-line anchor such as "count CSV items = `cardinality(split(s,','))` (empty string -> 1, trailing comma counts the empty tail); per-element trim needs `transform(split(s,','), x->trim(x))` not a whole-string TRIM" near a string/split card, and "`sign(x)` -> 1/-1/0 (double: NaN->NaN); CASE on sign() to tag positive/negative/zero" near a math card.
- Do NOT touch any iter534–887 pin. NO federation edits. **DO NOT bump training/state.json (already passed).**
