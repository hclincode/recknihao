# Judge Feedback — iter884 (EXTENDED PHASE)

**Overall: 4.94 STRONG PASS** (per-Q 5.00 / 5.00 / 4.875 / 5.00 = 19.875 / 4 = 4.96875; margin +1.47). Overall average governs; no per-Q veto. **FEDERATION NOT PROBED** — the 4.49944/310 federation row is UNCHANGED this iteration.

All four answers are dialect-clean and verified against authoritative Trino 467 sources. **iter885 recommendation = DEFAULT NO-OP** (zero teacher edits).

---

## Verification sources (trino.io/docs/467 + git-tag + blog, 2026-06-10)

- functions/aggregate.html — count(x) → bigint "non-null input values"; DISTINCT not separately signatured but standard.
- sql/select.html — **DISTINCT requires comparable column types**: verbatim "each output column must be of a type that allows comparison." Window frame defaults to RANGE UNBOUNDED PRECEDING.
- language/types.html — ROW "structure made up of fields … may be of any SQL type" (ROW is comparable when all fields comparable — confirmed via WebSearch applying the select.html DISTINCT comparability rule to ROW operands).
- functions/window.html + "Introducing new window features" blog (2021-03-10) + issue #609 — **RANGE-with-INTERVAL offset frames supported since v346**; SQL-standard rule: single sort key of numeric/datetime/interval; offset must be an interval addable to a datetime sort key. Example verbatim: `RANGE BETWEEN interval '1' month PRECEDING AND CURRENT ROW`.
- functions/string.html — `trim([ [ specification ] [ string ] FROM ] source)` "Removes any leading and/or trailing characters as specified"; documented example `trim(BOTH '$' FROM '$var$') → 'var'`. LEADING keyword supported with a character argument.
- functions/datetime.html — `date_trunc('month', TIMESTAMP '2022-10-20 05:10:00') → 2022-10-01 00:00:00.000` (first of month); `date_add(unit, value, x)` adds interval; `date + INTERVAL` arithmetic valid.

---

## Per-question scoring

### Q1 — COUNT distinct (customer_id, feature_id) pairs → 5.00 (Acc5/Comp5/Clar5/Act5)
Responder: `COUNT(DISTINCT ROW(customer_id, feature_id)) AS distinct_pairs`.
**(a) CONFIRMED VALID in Trino 467.** A ROW is comparable when all its fields are comparable; `SELECT DISTINCT` / `COUNT(DISTINCT …)` require each operand to be of a comparable type (select.html: "each output column must be of a type that allows comparison"). customer_id and feature_id are scalar comparable types, so `ROW(customer_id, feature_id)` is comparable and `COUNT(DISTINCT ROW(...))` correctly counts unique pairs. The alternative `COUNT(DISTINCT (a,b))` tuple form and a `GROUP BY a,b` subquery are equivalent fallbacks. No defect.

### Q2 — rolling 30-day lookback SUM → 5.00 (Acc5/Comp5/Clar5/Act5)
Responder: `SUM(amount) OVER (ORDER BY date RANGE BETWEEN INTERVAL '29' DAY PRECEDING AND CURRENT ROW)`.
**(b) CONFIRMED CORRECT.** RANGE-with-INTERVAL frames are supported since Trino 346 and are calendar/value-aware (not physical row counts). Single datetime sort key (`date`) + an interval offset addable to it satisfies the SQL-standard requirement. 29 days back + current row = 30 calendar days inclusive; with one row per date it is exactly 30 days. Responder's RANGE-vs-self-join framing is accurate. No defect.

### Q3 — strip leading '$' before CAST → 4.875 (Acc5/Comp4.75/Clar5/Act5)
Responder: `TRIM(LEADING '$' FROM invoice_amount)` → `'1250.00'`; then `CAST(... AS DECIMAL(15,2))`.
**(c) CONFIRMED VALID in Trino 467.** The SQL-standard `trim([specification][characters] FROM source)` form is documented; the docs' own example `trim(BOTH '$' FROM '$var$') → 'var'` proves the LEADING/BOTH/TRAILING + specific-character form works, so `TRIM(LEADING '$' FROM '$1250.00') = '1250.00'`. Note the character argument is a character SET (strips all leading `$`), which matches the single-`$` case here. Minor (-0.25 comp, not a defect): could note `replace(invoice_amount,'$','')` removes embedded `$` too, and a thousands-separator (`$1,250.00`) would also need the comma stripped — irrelevant to the asked input but a one-line robustness nuance. No defect.

### Q4 — first day of NEXT month → 5.00 (Acc5/Comp5/Clar5/Act5)
Responder: `date_trunc('month', trial_start_date) + INTERVAL '1' MONTH`; also `date_add('month', 1, date_trunc('month', trial_start_date))`.
**(d) CONFIRMED CORRECT + EQUIVALENT.** `date_trunc('month', x)` snaps to first-of-current-month (doc example confirms); adding `INTERVAL '1' MONTH` or `date_add('month', 1, …)` to a first-of-month date yields first-of-next-month (Mar-01 → Apr-01). Both forms valid and equivalent. No defect.

---

## iter885 recommendation: DEFAULT NO-OP

All four answers are correct and authoritatively verified. Per the iter882 lesson, do NOT flag any correct claim as a defect: do NOT add any "wrong" card for Q1–Q4 (COUNT(DISTINCT ROW), RANGE-INTERVAL, TRIM(LEADING char FROM), date_trunc+INTERVAL are all valid). Do NOT touch any iter534–883 pin. Optional micro-polish only (skip if it churns a pin): a one-line neutral anchor near a relevant card — "COUNT(DISTINCT ROW(a,b)) counts unique pairs (ROW comparable when fields comparable); RANGE BETWEEN INTERVAL '29' DAY PRECEDING = calendar-aware 30-day window; TRIM(LEADING '$' FROM s) strips a leading char set; first-of-next-month = date_trunc('month',x) + INTERVAL '1' MONTH."

PIN 467. NO federation edits. DO NOT bump training/state.json (already passed).

**Explicit confirmations requested:**
- (a) `COUNT(DISTINCT ROW(customer_id, feature_id))` — **VALID** in Trino 467; counts unique pairs.
- (c) `TRIM(LEADING '$' FROM '$1250.00')` — **VALID** in Trino 467; returns `'1250.00'`.
