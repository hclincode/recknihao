# Judge Feedback — Iter 625 (EXTENDED PHASE)

**Pin: Trino 467 / Iceberg connector / Hive Metastore (prod_info.md verified). Docs verified today against trino.io/docs/467.**

**Overall: 4.78125 PASS** (margin +1.28 above 3.5 floor). FEDERATION NOT PROBED (4.49944/310 row UNCHANGED).

**HEADLINE: initcap INOCULATION TOOK.** The iter625 fabrication-trap re-probe fired exactly as planned and the responder PASSED it cleanly: Q1 explicitly stated "Trino does not have an `initcap()` function like Postgres" (NO fabrication) AND led with the verified `regexp_replace(lower(s),'(\w)(\w*)', x -> upper(x[1]) || lower(x[2]))` lambda title-case idiom — which is the **verbatim Trino docs example**. Q2 (`date_diff('day',...)`) and Q3 (`ROW_NUMBER()` outer-`WHERE rn=2`) are docs-verbatim zero-defect. The only ding is Q4: the double-`CAST` works for the stated purely-numeric example `'00042'->'42'` but is FRAGILE (cast error on any alphanumeric code) and the responder did NOT offer the more-robust `trim(LEADING '0' FROM x)` string-preserving form — a completeness/robustness gap, NOT an accuracy failure (the SQL runs correctly for the stated case).

---

## Per-question scores

### Q1 — Title-case company names (initcap fabrication-trap re-probe) — Acc 5 / Comp 5 / Clar 5 / Act 5 = **5.00 STRONG PASS — INITCAP NOT FABRICATED**

Responder: STATED "Trino does not have an `initcap()` function like Postgres" + used `regexp_replace(lower(company_name), '(\w)(\w*)', x -> upper(x[1]) || lower(x[2])) AS title_cased`; traced `'acme widgets inc' -> 'Acme Widgets Inc'`.

**INITCAP ABSENCE CONFIRMED**: WebFetch trino.io/docs/467/functions/string.html — the complete documented string-function list is `chr, codepoint, concat, concat_ws, hamming_distance, length, levenshtein_distance, lower, lpad, ltrim, luhn_check, position, replace, reverse, rpad, rtrim, soundex, split, split_part, split_to_map, split_to_multimap, strpos, starts_with, substr, substring, translate, trim, upper, word_stem` — **`initcap` is ABSENT.** The responder correctly declared the absence and did NOT invent the function. The iter625 fabrication inoculation (state.json: r27:937 upgraded row + new sec4.3 STR-FAMILY INITCAP/title-case sub-block with keyword anchors) LANDED and was routed-to.

**IDIOM VERIFIED VERBATIM**: WebFetch trino.io/docs/467/functions/regexp.html confirms the lambda `regexp_replace` overload: "The lambda expression `function` is invoked for each match with the capturing groups passed as an array" and the **exact docs example** `SELECT regexp_replace('new york', '(\w)(\w*)', x -> upper(x[1]) || lower(x[2])); -- 'New York'`. The responder's idiom is character-for-character this example. `x[1]` = group 1 (first letter), `x[2]` = group 2 (rest of word); `upper(x[1]) || lower(x[2])` per word. TRACE `'acme widgets inc'`: each `(\w)(\w*)` match → `Acme`, `Widgets`, `Inc` → **`Acme Widgets Inc` CORRECT.** Zero defects.

### Q2 — Days from today until each invoice's due_date — Acc 5 / Comp 5 / Clar 5 / Act 5 = **5.00 STRONG PASS**

Responder: `date_diff('day', current_date, due_date) AS days_until_due`; noted signature `(unit, start, end)`, negative = overdue.

**VERIFIED** trino.io/docs/467/functions/datetime.html: signature `date_diff(unit, timestamp1, timestamp2)`, "Returns `timestamp2 - timestamp1` expressed in terms of `unit`." So `date_diff('day', current_date, due_date)` = `due_date - current_date` in days → **positive when due_date is in the future** (correct framing), **negative when due_date has passed** (correct "negative = overdue" note). Arg order correct (current_date as start, due_date as end). DATE args valid for the 'day' unit. Zero defects.

### Q3 — Second-highest single sale per store (runner-up, not max) — Acc 5 / Comp 5 / Clar 5 / Act 5 = **5.00 STRONG PASS**

Responder: inner `ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY sale_amount DESC) AS rn`, outer `WHERE rn = 2`; noted `RANK()` for ties.

**VERIFIED** trino.io/docs/467/functions/window.html: `row_number()` "Returns a unique, sequential number for each row, starting with one, according to the ordering of rows within the window partition." PARTITION BY store_id + ORDER BY sale_amount DESC → rn=1 is the max, **rn=2 is the runner-up per store** = exactly the second-highest single sale. Window functions "execute after the HAVING clause but before the ORDER BY clause" → a window alias cannot appear in same-level `WHERE`, so the subquery-then-outer-`WHERE rn=2` wrapper is the CORRECT idiom (not a same-level WHERE-on-window-alias error). The `RANK()`-for-ties note is ACCURATE: ROW_NUMBER breaks ties arbitrarily (could skip a tied co-leader); RANK assigns equal rank to ties so `rn=2` captures all values at the second distinct level — the right nuance for "true runner-up value." Zero defects.

### Q4 — Strip leading zeros from padded product code `'00042'->'42'` (robustness check) — Acc 4 / Comp 3.5 / Clar 5 / Act 4 = **4.125 PASS — CORRECT-BUT-FRAGILE; missed the trim(LEADING) string idiom**

Responder: `CAST(CAST(product_code AS integer) AS varchar) AS clean_code` (double-cast `'00042' -> 42 -> '42'`); also gave the integer-only `CAST(product_code AS integer)` form.

**WORKS FOR THE STATED NUMERIC EXAMPLE**: `CAST('00042' AS integer)` = 42, `CAST(42 AS varchar)` = `'42'` — correct, runs cleanly, leading zeros gone. So this is NOT an accuracy failure for the stated case (Acc not floored).

**FRAGILITY (the robustness gap)**:
- (a) **Cast error on any non-numeric char** — `'00042A'`, `'SKU-042'`, `'0xF'` → `CAST(... AS integer)` raises a conversion error and the query fails. A product *code* is an identifier that frequently carries letters/dashes, so re-interpreting it as a number is semantically odd and brittle.
- (b) **`'00000' -> '0'`** via the cast (all-zeros collapses to a single `'0'`), whereas a pure string-strip `trim(LEADING '0' FROM '00000')` yields `''` (empty) — different edge behavior the responder didn't flag either way.
- (c) Loses any intended non-numeric formatting.

**MORE ROBUST STRING-PRESERVING IDIOM (VERIFIED, NOT OFFERED)**: WebFetch trino.io/docs/467/functions/string.html confirms `trim` supports the char-set + specification form: docs verbatim "Removes any leading and/or trailing characters as specified up to and including `string` from `source`" with examples `trim('!' FROM '!foo!')` → `'foo'`, `trim(LEADING FROM '  abcd')` → `'abcd'`, `trim(BOTH '$' FROM '$var$')` → `'var'`, `trim(TRAILING 'ER' FROM upper('worker'))` → `'WORK'`. Thus **`trim(LEADING '0' FROM product_code)`** strips leading zeros while preserving the string type and surviving alphanumeric codes (`'00042A' -> '42A'`, `'SKU-042'` unaffected by leading-zero strip) — the canonical, robust answer the responder did not reach.

**VERDICT**: correct-for-the-stated-case but **fragile + incomplete** — a completeness/robustness ding (Comp 3.5, Act 4, Acc 4), NOT a wrong-function-choice hard-fail (the double-cast genuinely solves `'00042'`). Diagnosis: landing-point gap — there is no strip-leading-zeros canonical anchored at the r27/r23 string family, so the responder synthesized the plausible double-cast instead of the purpose-built `trim(LEADING '0' FROM ...)`. State.json correctly held this as a WATCH-ITEM; this probe now CONVERTS it to a recommended (low-cost) add (see iter626 directive) because the trap fired and the responder missed the robust form.

---

## Overall computation

- Per-Q averages: Q1 5.00, Q2 5.00, Q3 5.00, Q4 4.125 → (5.00+5.00+5.00+4.125)/4 = **4.78125**
- Dim-avg cross-check: Acc (5+5+5+4)/4=4.75, Comp (5+5+5+3.5)/4=4.625, Clar (5+5+5+5)/4=5.00, Act (5+5+5+4)/4=4.75 → (4.75+4.625+5.00+4.75)/4 = **4.78125** — agree.
- **GOVERNING LABEL = PASS** (overall avg 4.78125 >= 3.5; no per-Q gate; all per-Q avgs >= 4.125).

---

## Explicit verdicts

**1. INITCAP VERDICT (CRITICAL — inoculation confirmation): PASS — the responder did NOT fabricate initcap.** It explicitly stated Trino has no `initcap()` (CONFIRMED absent from trino.io/docs/467/functions/string.html) AND used the correct title-case idiom (verbatim docs example, traces to `'Acme Widgets Inc'`). The iter625 initcap inoculation TOOK. No further initcap action needed beyond durability holds.

**2. Q4 VERDICT: the double-cast is CORRECT-BUT-FRAGILE; `trim(LEADING '0' FROM ...)` is the MORE ROBUST form.** The double-cast solves the stated numeric example but errors on alphanumeric codes and re-interprets an identifier as a number. The `trim(LEADING '0' FROM product_code)` char-set form (VERIFIED supported in Trino 467) is string-preserving and survives alphanumeric codes — the canonical answer.

---

## iter626 directives

**PRIMARY (convert WATCH-ITEM → small additive canonical): ADD a strip-leading-zeros canonical at the r27/r23 string landing point (the sec4.3 STR-FAMILY block, right where the new initcap sub-block now lives).**
- Keyword anchors: "strip leading zeros / remove leading zeros / unpad / left-pad removal / zero-padded code / drop leading zeros without hard-coding the count."
- Canonical (string-preserving, ROBUST, handles alphanumeric): `trim(LEADING '0' FROM product_code)`. Cite docs verbatim "trim([[specification][string] FROM] source)" with the `trim(LEADING ...)`/char-set examples.
- Note the edge: `trim(LEADING '0' FROM '00000')` → `''` (empty); if a single `'0'` is desired for all-zeros, wrap `NULLIF(trim(...),'')` → COALESCE to `'0'`, or use `CASE`.
- DO-NOT-WRITE / fragility note for the double-cast: `CAST(CAST(code AS integer) AS varchar)` strips zeros ONLY for purely-numeric codes and ERRORS on any non-numeric char (`'00042A'`, `'SKU-042'`); use it only when the code is guaranteed integer; prefer `trim(LEADING '0' FROM ...)` for identifier-style codes.
- Reconcile-in-place; additive only; do NOT touch the iter625 initcap sub-block, the r27:937 row, or any iter534-624 lock.

**DURABILITY HOLDS (NO-OP)**: initcap title-case canonical (VALIDATED this iter — durable), `date_diff('day',current_date,due)` arg-order/sign canonical (clean), ROW_NUMBER-outer-`WHERE rn=N` second-highest canonical + RANK-for-ties note (clean).

**DO NOT**: touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter625); re-edit the iter625 initcap/title-case sub-block (validated — durable); re-edit the date_diff / ROW_NUMBER-runner-up canonicals (clean); add `::`-casts (iter571 PIN); EXTRACT(EPOCH) (iter562 ban); QUALIFY; RLIKE (iter623 ban); PERCENTILE_CONT (iter611 ban); touch iter534-624 locks; bump training/state.json (already 625); git commit/push.

**Fabrications/slips this iter**: NONE in the accuracy sense. Q1 correctly DECLARED initcap's absence (not a fabricated-absence — it IS absent). No `::`-cast, no QUALIFY, no RLIKE, no invalid-clause-placement, no off-by-one (Q3 rn=2 correct, Q2 arg-order correct), no type-mismatch (DATE date_diff valid), no fabricated function. The sole quality concern is Q4's correct-but-fragile double-cast (robustness/completeness gap, flagged + content directive, NOT a label override).

**Docs verified today (2026-06-07)**: trino.io/docs/467/functions/string.html (full string-fn list — `initcap` ABSENT — Q1; `trim` LEADING/char-set form `trim([[spec][string] FROM] source)` + examples — Q4); trino.io/docs/467/functions/regexp.html (lambda `regexp_replace` "capturing groups passed as an array" + verbatim `'new york' -> 'New York'` example — Q1); trino.io/docs/467/functions/datetime.html (`date_diff(unit, ts1, ts2)` = "`timestamp2 - timestamp1` expressed in terms of `unit`" — Q2); trino.io/docs/467/functions/window.html (`row_number()` "starting with one" + window fns run after HAVING before ORDER BY → outer-wrapper for WHERE — Q3).

**OVERALL: 4.78125 PASS — initcap inoculation CONFIRMED (Q1 correctly declared absence + used verbatim regexp_replace lambda title-case idiom -> 'Acme Widgets Inc'); Q2 date_diff('day',current_date,due) arg-order/sign correct; Q3 ROW_NUMBER outer-WHERE rn=2 runner-up + RANK-for-ties correct; Q4 double-cast correct-but-fragile (errors on alphanumeric codes) — iter626 = ADD trim(LEADING '0' FROM x) strip-leading-zeros canonical at r27/r23 string landing point with keyword anchors + double-cast fragility note; federation row stays 4.49944/310.**
