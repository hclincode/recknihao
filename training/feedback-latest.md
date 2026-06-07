# Iter 626 Judge Feedback — 2026-06-07 (EXTENDED PHASE)

**Pin: Trino 467 / Iceberg connector / Hive Metastore (prod_info.md verified). Docs verified today against trino.io/docs/467.**

**OVERALL: 5.00 STRONG PASS** (margin +1.50 above 3.5 floor). Federation NOT probed (4.49944/310 row UNCHANGED). All four answers docs-verbatim zero-defect. **FIX A (trim-char re-probe) RESOLVED. dayname() NOT fabricated.**

---

## Per-question scores

### Q1 — Strip TRAILING '#' padding from alphanumeric SKU 'WIDGET####' -> 'WIDGET' — **5/5/5/5 = 5.00 STRONG PASS — FIX A RESOLVED**
Answer: `trim(TRAILING '#' FROM sku_code) AS clean_sku`. Stated trim supports specific chars, TRAILING removes from the end, alphanumeric-safe.

VERIFIED trino.io/docs/467/functions/string.html (WebSearch confirmed 2026-06-07): two trim forms — `trim(string) → varchar` (whitespace) AND `trim([[specification][string] FROM] source) → varchar` "Removes any leading and/or trailing characters as specified up to and including string from source" with specification = LEADING/TRAILING/BOTH. Docs examples verbatim: `trim('!' FROM '!foo!')` → `'foo'`, `trim(BOTH '$' FROM '$var$')` → `'var'`, and **`trim(TRAILING 'ER' FROM upper('worker'))` → `'WORK'`** — the exact TRAILING char-set form the responder used. So `trim(TRAILING '#' FROM 'WIDGET####')` → `'WIDGET'` CORRECT. The char-set is treated literally (alphanumeric-safe), no numeric cast, string-preserving. **iter625 CAST-fragility RESOLVED**: responder used the trim-char form, NOT `CAST(CAST(code AS integer) AS varchar)` (which would ERROR on alphanumeric 'WIDGET####' and reinterpret as a number). The r27 §4.3-STRIP-ZEROS canonical (added iter626) routed clean first-probe. Zero defects.

### Q2 — Round a 0-100 score to the nearest 5 (73->75, 61->60) — **5/5/5/5 = 5.00 STRONG PASS**
Answer: `CAST(ROUND(nps_score / 5.0) * 5 AS INTEGER) AS score_band`. Divide by 5.0, round, multiply by 5; noted `/5.0` decimal forces float division (no integer truncation).

VERIFIED trino.io/docs/467/functions/math.html: `round(x)` "Returns x rounded to the nearest integer." Trace: `round(73/5.0)=round(14.6)=15`, `*5=75` ✓; `round(61/5.0)=round(12.2)=12`, `*5=60` ✓. The `/5.0` (decimal literal) forces DECIMAL/DOUBLE division so `73/5.0=14.6` not integer-truncated 14 — correct and load-bearing; the decimal-division note is exactly the right caveat. Trino round is round-half-away-from-zero, so the x.5 boundary (e.g. 12.5→13) lands sensibly; no off-by-one. Outer `CAST(... AS INTEGER)` cleanly yields an integer band. Zero defects.

### Q3 — Day-of-week NAME ('Monday') from a date/timestamp — **5/5/5/5 = 5.00 STRONG PASS — dayname() NOT FABRICATED**
Answer: `format_datetime(CAST(opened_at AS timestamp), 'EEEE') AS day_name`. Honestly noted couldn't find an explicit "day name" worked example but inferred Joda `'EEEE'` = full day name; cast DATE→timestamp because format_datetime needs a timestamp. Did NOT use `dayname()`.

VERIFIED trino.io/docs/467/functions/datetime.html (WebFetch 2026-06-07): (1) **NO `dayname()` function exists** in the Trino 467 datetime function list — responder did NOT fabricate it. (2) `format_datetime(timestamp, format) → varchar` exists and "use a format string that is compatible with JodaTime's DateTimeFormat pattern format" — takes a timestamp, uses Joda patterns. (3) Joda DateTimeFormat (joda.org/joda-time/key_format.html): pattern letter `E` = day-of-week TEXT; "If the number of pattern letters is 4 or more, the full form is used" → `'EEEE'` → `'Monday'` (full name), `'EEE'` → `'Mon'` (abbreviated). So `'EEEE'` is the CORRECT token for the full day name. (4) The `CAST(date AS timestamp)` is correct — format_datetime takes a timestamp, and a DATE arg would type-mismatch; the cast is the right type-bridge (iter615-style type note). (5) `day_of_week()` (ISO 1=Mon..7=Sun)+CASE is the valid alternative the responder did NOT need. The honest "couldn't find explicit docs / inferred" framing is fine — the idiom is verified-correct. Zero defects.

### Q4 — Single most frequent product per store (mode per group) — **5/5/5/5 = 5.00 STRONG PASS**
Answer: `ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY COUNT(*) DESC) AS rn` over a `GROUP BY store_id, product_id` subquery (`COUNT(*) AS order_count`), outer `WHERE rn = 1`.

VERIFIED trino.io/docs/467/functions/window.html: `row_number()` "Returns a unique, sequential number for each row, starting with one, according to the ordering of rows within the window partition." Window functions run after HAVING but before ORDER BY and cannot appear in WHERE → the outer-query wrapper (`WHERE rn = 1`) is the CORRECT idiom (not a same-level WHERE on the window alias). Pattern is sound: the subquery `GROUP BY store_id, product_id` produces per-(store,product) counts; `ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY COUNT(*) DESC)` ranks products within each store by their group count (ordering by the group aggregate `COUNT(*)` inside the window over the GROUP BY is valid Trino 467); `rn=1` keeps the single most frequent product per store. This is the EXACT mode-per-group form (count-then-rank). `approx_most_frequent(buckets, x, capacity)` is the approximate-at-scale alternative; the ROW_NUMBER-over-exact-count form here is the EXACT answer and correct. Ties: ROW_NUMBER picks one arbitrarily (minor, expected for "the single most frequent"). Zero defects.

---

## Overall

Per-Q averages: 5.00 / 5.00 / 5.00 / 5.00. Dimension averages: Acc 5.00, Comp 5.00, Clar 5.00, Act 5.00 → **(5.00+5.00+5.00+5.00)/4 = 5.00**. Per-Q cross-check (5.00+5.00+5.00+5.00)/4 = 5.00 — agree. Overall-avg GOVERNS label = **STRONG PASS**. No per-Q gate triggered.

## EXPLICIT FIX A verdict (trim-char re-probe)
**RESOLVED.** The responder used `trim(TRAILING '#' FROM sku_code)` — the trim char-set form (LEADING/TRAILING/BOTH chars FROM source) — NOT a numeric cast. The iter625 `CAST(CAST(code AS integer) AS varchar)` fragility (errors on alphanumeric, reinterprets identifier as number) did NOT recur. Alphanumeric-safe, string-preserving, docs-verbatim correct.

## EXPLICIT dayname verdict
**AVOIDED FABRICATION + correct idiom.** Trino 467 has NO `dayname()` function (verified against the datetime function list); the responder did NOT invent it. It used `format_datetime(ts, 'EEEE')` — `format_datetime` exists, takes a timestamp, uses JodaTime patterns, and Joda `'EEEE'` is the correct token for the full day name ('Monday'). The DATE→timestamp cast is the correct type-bridge. The honest "inferred, couldn't find explicit example" note is acceptable because the idiom is verified-correct.

## Slips / fabrications
**NONE.** No fabricated feature/absence (no dayname()), no `::`-cast, no QUALIFY, no invalid-clause-placement, no off-by-one (Q2 round-to-5 traces exactly; Q4 rank correct), no type-mismatch (Q3 cast correct), no wrong-function-choice. All four functions/idioms (trim char-set, round, format_datetime+Joda 'EEEE', ROW_NUMBER-over-GROUP-BY) are real Trino 467 and correctly applied.

## iter627 directive: DURABILITY NO-OP
All four canonicals routed clean first-probe. **Recommend NO-OP.** Push fresh breadth instead of re-editing. Optional only: a symmetric Q3 re-probe starting from a TIMESTAMP column (no cast needed) to confirm the responder OMITS the cast when the input is already a timestamp, and/or a `day_of_week()+CASE` re-phrasing to confirm the number→name CASE branch.

**DO NOT**: touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter626); re-edit the r27 §4.3-STRIP-ZEROS trim-char canonical (FIX A validated — durable); re-edit the round / format_datetime-'EEEE' / ROW_NUMBER-mode-per-group landing points (clean); add `::`-casts (iter571 PIN); EXTRACT(EPOCH) (iter562 ban); QUALIFY; PERCENTILE_CONT (iter611 ban); fabricate dayname()/initcap; touch iter534-625 locks; bump training/state.json (already 626); git commit/push.

**WebFetched/verified today (2026-06-07, Trino 467)**: functions/string.html (trim char-set form `trim([[spec][string] FROM] source)` + `trim(TRAILING 'ER' FROM upper('worker'))`→'WORK' — Q1), functions/math.html (`round(x)` "rounded to the nearest integer" — Q2), functions/datetime.html (NO dayname(); `format_datetime(timestamp,format)` "compatible with JodaTime's DateTimeFormat"; `day_of_week` ISO 1=Mon..7=Sun — Q3), joda.org Joda DateTimeFormat ('EEEE' 4+ letters = full day name 'Monday' — Q3), functions/window.html (`row_number()` "starting with one...within the window partition" + window fns not in WHERE — Q4).

**OVERALL: 5.00 STRONG PASS — Q1 FIX A RESOLVED (trim(TRAILING '#' FROM x), no numeric cast, alphanumeric-safe); Q3 dayname() NOT fabricated (format_datetime(ts,'EEEE') Joda full-day-name, correct DATE→timestamp cast); Q2 round-to-nearest-5 (/5.0 decimal division, traces 73->75/61->60) + Q4 ROW_NUMBER-over-GROUP-BY exact mode-per-group all docs-verbatim zero-defect; iter627 = durability NO-OP; federation row stays 4.49944/310.**
