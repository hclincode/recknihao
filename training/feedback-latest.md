# Judge Feedback — iter1082 (2026-06-18)

**Overall average: 4.78 — PASS** (threshold 3.5; margin +1.28)

Verified BOTH directions against RAW git-tag 467 source (functions/string.md, functions/array.md, sql/select.md) plus WebSearch. Clean sweep — zero source-verified defects across all four answers.

RAW source URLs checked:
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/string.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/select.md

---

## Q1 — strip a SET of characters (asterisks + spaces) off both ends — Score 4.94

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4.75
- `trim(BOTH '*' FROM name)` and `trim(BOTH '* ' FROM name)` are valid Trino 467 SQL-standard trim syntax `trim([BOTH|LEADING|TRAILING] [chars] FROM source)`.
- **CHARACTER-SET CLAIM CONFIRMED (the focal point):** the `chars` argument is a SET of characters each stripped individually, NOT a literal substring. The dispositive evidence is the documented behavior `TRIM(TRAILING 'na' FROM 'banana')` → `'ba'`: a literal-substring interpretation would strip a single `'na'` and yield `'bana'`; instead ALL trailing `'n'`/`'a'` characters are removed → `'ba'`, proving set semantics. string.md phrasing "Removes any leading and/or trailing characters as specified" + verbatim examples (`trim(BOTH '$' FROM '$var$')`→'var', `trim(TRAILING 'ER' FROM upper('worker'))`→'WORK') corroborate. Matches the standing [Trino trim Char-Set] pin.
- So `trim(BOTH '* ' FROM '**Widget Pro**')` correctly strips any leading/trailing `'*'` or `' '` → `'Widget Pro'`. Exactly the right tool for the asked task (strip a set, not just whitespace, not a literal substring).
- LEADING/TRAILING/BOTH side-selection explanation correct. Minor: did not call out that order of chars in the set is irrelevant (cosmetic, not a defect).

## Q2 — count distinct user_id per plan_type — Score 4.88

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4.5
- `SELECT plan_type, COUNT(DISTINCT user_id) AS unique_users FROM subscriptions GROUP BY plan_type` is standard, valid Trino 467 — one distinct aggregation per group, optimized via MarkDistinct internally.
- Single-arg `count()` note CONFIRMED: `COUNT(DISTINCT a, b)` multi-arg is a PARSE error; distinct COMBINATIONS use `COUNT(DISTINCT ROW(user_id, plan_type))` (or `COUNT(DISTINCT (a,b))`). Matches [Trino COUNT DISTINCT Single-Arg] pin. The combo aside is accurate and a useful disambiguation, not over-warning.

## Q3 — first 3 array elements without UNNEST — Score 4.88

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4.5
- `slice(scores, 1, 3)` valid Trino 467. array.md VERIFIED: "Subsets array x starting from index start (or starting from the end if start is negative) with a length of length."
- 1-based start CONFIRMED (Trino arrays are 1-based). Returns fewer elements if the array is shorter than start+length (bounded subset) — correct. Negative start counts from the end CONFIRMED, so `slice(scores, -3, 3)` = last 3. Result stays an array (no UNNEST) — exactly the ask.

## Q4 — UNION vs UNION ALL — Score 4.81

- Accuracy 5 / Completeness 4.75 / Clarity 5 / Actionability 4.5
- select.md VERIFIED: "If neither is specified, the behavior defaults to DISTINCT" and "If ALL is specified all rows are included even if identical." So bare UNION dedups, UNION ALL keeps all — correct.
- Perf framing is accurate (not over-warning): UNION incurs a dedup pass (sort/hash), UNION ALL skips it and is the cheaper default; use bare UNION only when cross-result dedup is actually required. On disjoint inputs the dedup is wasted work — a reasonable, defensible guidance, not a defect. Could optionally have mentioned UNION ALL + manual GROUP BY when dedup IS needed but inputs are pre-deduped within each branch (minor completeness nit).

---

## No anti-patterns present

No `::`-cast / QUALIFY / false-semi-join / fabricated-function / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / over-warning / broken-secondary-alternative. All four imported-prior-family facts (trim char-set, count single-arg, slice 1-based/negative, UNION-default-DISTINCT) were verified correct in BOTH directions.

## Recommendation

DEFAULT NO-OP — margin +1.28, clean sweep. No resource edit, no commit content change. All four topics already PASSED in the rubric; this sweep reconfirms string-trim, array-slice, count-distinct, and set-operation accuracy. MUST NOT bump state.json (teacher already at 1082).
