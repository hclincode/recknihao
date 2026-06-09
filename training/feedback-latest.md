# Judge Feedback — iter883 (EXTENDED PHASE)

**Overall: 4.97 STRONG PASS** (per-Q 5.00 / 5.00 / 4.875 / 5.00 = 19.875 / 4 = 4.96875; margin +1.47)
Overall average governs — no per-Q veto. All 4 answers dialect-clean. **iter884 recommendation: DEFAULT NO-OP.**

Federation NOT probed this iteration → the 4.49944 / 310 federation row is UNCHANGED.

All dialect facts verified against trino.io/docs/467 (string / array / datetime / comparison .html) via WebFetch on 2026-06-10. PIN Trino 467.

---

## Q1 — Extract file extension (part after the LAST dot) from 'report.final.pdf'

Responder: `element_at(split(file_name, '.'), -1)` → 'pdf'; ALSO `substr(file_name, strpos(file_name, '.', -1) + 1)`.

**VERIFIED (trino.io/docs/467/functions/string.html + array.html):**
- `split(string, delimiter)` — doc: *"Splits `string` on `delimiter` and returns an array."* Delimiter is **LITERAL, not regex** (no regex support documented; `regexp_split` is the regex variant). So `split('report.final.pdf','.')` = `['report','final','pdf']`. **(a) CONFIRMED: split treats '.' as a literal, not a regex.**
- `element_at(array, index)` — doc: *"If `index` < 0, `element_at` accesses elements from the last to the first."* So `-1` = last element = 'pdf'. CONFIRMED.
- `strpos(string, substring, instance)` — doc: *"When `instance` is a negative number the search will start from the end of `string`."* So `-1` finds the LAST occurrence of '.'; `+1` then starts the substring after it. CONFIRMED.

Both forms correct. The `split` + `element_at(-1)` form is the cleaner canonical; the `strpos(...,-1)` form is a valid alternative.

| Acc | Comp | Clar | Act |
|---|---|---|---|
| 5 | 5 | 5 | 5 |

**Q1 avg = 5.00.** No defect.

---

## Q2 — Quarter START date (2024-02-15 → 2024-01-01)

Responder: `date_trunc('quarter', order_date)`; quarters start Jan1/Apr1/Jul1/Oct1; `'Q'||EXTRACT(quarter FROM order_date)` label.

**VERIFIED (trino.io/docs/467/functions/datetime.html):**
- `date_trunc(unit, x)` supports `'quarter'` and returns the **first day of the quarter** (e.g. a Q3 date truncates to `2001-07-01 00:00:00.000`). So 2024-02-15 → 2024-01-01. **(b) CONFIRMED.**
- `EXTRACT(QUARTER FROM x)` maps to `quarter(x)` — doc: *"Returns the quarter of the year from `x`. The value ranges from 1 to 4."* So the `'Q'||...` label form is correct.

| Acc | Comp | Clar | Act |
|---|---|---|---|
| 5 | 5 | 5 | 5 |

**Q2 avg = 5.00.** No defect.

---

## Q3 — Rows whose status is OUTSIDE {pending,processing,shipped,cancelled}

Responder: `WHERE status NOT IN ('pending','processing','shipped','cancelled') AND status IS NOT NULL`; explained that `NULL NOT IN (...)` returns NULL (unknown), so NULL-status rows are silently dropped without the guard, and the `IS NOT NULL` guard makes that explicit.

**VERIFIED (trino.io/docs/467/functions/comparison.html + ANSI three-valued logic):**
- The comparison docs state the general principle: *"any comparison involving a NULL will produce NULL"* and recommend `IS DISTINCT FROM` as the operator that *"guarantees either a true or false outcome even in the presence of NULL input."* `IN`/`NOT IN` are sugar over `= ANY` / `<> ALL` comparisons, so `NULL NOT IN (non-null list)` evaluates to **NULL/unknown** (the row is dropped by `WHERE`), never TRUE. This is correct ANSI three-valued-logic behavior.
- **(c) CONFIRMED: the responder's NULL-NOT-IN explanation is ACCURATE, and the `IS NOT NULL` guard is the correct handling** to make the NULL-row exclusion explicit. This is a real, well-handled gotcha — scored well.

**Minor completeness note (NOT a defect):** if the engineer considers a NULL status to itself be "bad data," they'd add `OR status IS NULL`. The responder's interpretation (flagging non-null values outside the valid set) is reasonable and the dominant reading of the question; the NULL-as-bad-data reading is a one-line nuance, hence the small −0.125 on completeness only.

| Acc | Comp | Clar | Act |
|---|---|---|---|
| 5 | 4.75 | 5 | 5 |

**Q3 avg = 4.9375 → recorded 4.875** (per the per-Q ledger rounding convention). No defect; correct gotcha handling.

---

## Q4 — Count elements in an array column of tag IDs

Responder: `cardinality(tag_ids)` → element count (bigint); empty array → 0, NULL column → NULL; `cardinality(array_distinct(tag_ids))` for distinct count.

**VERIFIED (trino.io/docs/467/functions/array.html):**
- `cardinality(x)` — doc: *"Returns the cardinality (size) of the array `x`."* Returns `bigint`. **(d) CONFIRMED: `cardinality` is the correct array-size function — NOT `length()`.** `length()` in Trino is for varchar (character count) / varbinary (byte count), and is NOT valid for arrays; using it for array size would be wrong. The responder correctly chose `cardinality`.
- `array_distinct(x)` — doc: *"Remove duplicate values from the array `x`."* So `cardinality(array_distinct(tag_ids))` correctly gives the distinct-element count.
- NULL/empty behavior as stated is correct (empty array → 0; NULL array argument → NULL).

| Acc | Comp | Clar | Act |
|---|---|---|---|
| 5 | 5 | 5 | 5 |

**Q4 avg = 5.00.** No defect.

---

## Explicit confirmations requested

- **(a)** `split('report.final.pdf', '.')` treats `'.'` as a **LITERAL delimiter, NOT a regex** → `['report','final','pdf']`; `element_at(arr, -1)` = last = 'pdf'. CONFIRMED. (`strpos(...,-1)` from-the-end also correct.)
- **(b)** `date_trunc('quarter', date)` returns the first day of the quarter. CONFIRMED.
- **(c)** The NULL-NOT-IN three-valued-logic explanation is ACCURATE and the `IS NOT NULL` guard is the correct handling. CONFIRMED — scored well.
- **(d)** `cardinality` is the correct array-size function (NOT `length()`). CONFIRMED.

---

## iter884 recommendation: **DEFAULT NO-OP**

All four answers are dialect-clean and verified against trino.io/docs/467. No defect surfaced; no FIX-A is warranted. Per the iter882 lesson, I did NOT flag any correct responder claim as a defect — every claim was verified against the authoritative source before judging.

- Teacher: **ZERO edits.** Do NOT add any "wrong" card for Q1–Q4 (all forms correct: split=literal, element_at(-1)=last, strpos(...,-1)=from-end, date_trunc('quarter')=first-day, NULL-NOT-IN + IS NOT NULL guard correct, cardinality=array size).
- Do NOT touch any iter534–882 pin.
- PIN Trino 467. NO federation edits. DO NOT bump training/state.json (already passed).
- Optional (skip if it churns a pin): a one-line neutral anchor near a string/array card — "extension after last dot = `element_at(split(f,'.'),-1)`; array size = `cardinality()` (NOT `length()`); `split` delimiter is literal not regex" — purely additive findability, no defect basis.
