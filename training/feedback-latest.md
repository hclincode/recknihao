# Judge Feedback — iter986

**EXTENDED PHASE breadth sweep. OVERALL 4.40625 PASS** (Q1 4.0625 / Q2 3.9375 / Q3 4.75 / Q4 4.875 = 17.625/4 = 4.40625; margin +0.906; OVERALL AVERAGE governs, no per-Q veto).

All claims verified BOTH directions against trino.io/docs/467 (NOT resources/):
- functions/comparison.html: LIKE is case-sensitive; **NO ILIKE operator/keyword** in Trino grammar.
- GitHub trinodb/trino #2491: Trino DECIDED NOT to add ILIKE syntax — case-insensitive matching is `LOWER(x)=LOWER(y)` / `LOWER(x) LIKE LOWER(pattern)`.
- connector/postgresql.html: `postgresql.experimental.enable-string-pushdown-with-collate` / session `enable_string_pushdown_with_collate` is REAL but governs **range-predicate pushdown of collated string columns to PostgreSQL** — it does NOT add an ILIKE token to Trino's parser.
- functions/string.html: concat_ws(sep, s1, s2, ...) exists; "Any null values provided in the arguments after the separator are skipped"; `||`/concat() is SQL-standard NULL-propagating.
- functions/datetime.html: format_datetime(timestamp, format) uses JodaTime DateTimeFormat ('EEEE' = full weekday text name); day_of_week(x)→bigint 1=Mon..7=Sun; **NO dayname()** in 467.

Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — answers fit; Option B's federation drag-in is OUT of stack scope (no Postgres federation in play).

---

## Q1 — WHERE vs HAVING, alias not visible in WHERE — 4.0625 (LEAD CORRECT, minor boundary slip)

Acc 4.0 / Clar 4.25 / App 4.0 / Comp 4.0.

CORRECT core: WHERE filters raw rows BEFORE aggregation, HAVING filters AFTER aggregation/grouping — VERIFIED. The SELECT alias `invoice_count` is NOT referenceable in WHERE (resolved after GROUP BY) — VERIFIED 467 (output aliases not visible in WHERE/GROUP BY/HAVING). The HAVING form correctly **repeats the aggregate `COUNT(*)`** rather than referencing the alias — CORRECT (Trino disallows output aliases in HAVING). Perf note sound: HAVING is the correct position for an aggregate predicate (not slower); a non-aggregate predicate belongs in WHERE.

★ **MINOR BOUNDARY / OFF-BY-ONE SLIP**: question says hide groups with total invoice count **under 5** (count < 5) → KEEP count >= 5. Responder wrote `HAVING COUNT(*) > 5`, which ALSO excludes groups of exactly 5 (should be `HAVING COUNT(*) >= 5`). Lead mechanism (WHERE vs HAVING, alias scope, repeat-the-aggregate) is fully correct; this is a `>5`-should-be-`>=5` predicate-boundary slip. RESPONDER slip (not a resource defect — the WHERE/HAVING/alias-scope teaching is correct and findable). Comp/App dinged for the boundary miss.

---

## Q2 — Trino ILIKE? or LOWER the column? — 3.9375 (LEAD/Option A CORRECT; ★ Option B = FALSE-MECHANISM broken-secondary slip + federation drag-in)

Acc 3.75 / Clar 4.0 / App 4.0 / Comp 4.0.

★ **THE KEY CHECK — verified BOTH directions:**

LEAD CORRECT: "Trino does NOT have ILIKE native like Postgres; `WHERE plan_type ILIKE 'pro'` won't work out of the box" — VERIFIED. ILIKE is NOT a token in Trino's SQL grammar (the project explicitly declined to add ILIKE syntax, #2491). **Option A `WHERE LOWER(plan_type) = LOWER('PRO')` is CORRECT** and is the canonical Trino case-insensitive idiom (LOWER both sides; `LOWER(x) LIKE LOWER(pattern)` for pattern matching). Recommending Option A is right.

★ **OPTION B = FALSE-MECHANISM broken-secondary RESPONDER slip.** Responder claimed that, for Postgres-via-federation data, an "experimental session property" `SET SESSION enable_string_pushdown_with_collate = true` makes `WHERE plan_type ILIKE 'pro'` work. VERIFIED WRONG on the load-bearing mechanism:
- `ILIKE` is NOT in Trino's parser, so `WHERE plan_type ILIKE 'pro'` is a **PARSE error regardless of any session property**. No setting can make it parse.
- The property IS real (`postgresql.experimental.enable-string-pushdown-with-collate` / session `enable_string_pushdown_with_collate`), but it governs **pushdown of RANGE predicates on collated string columns to PostgreSQL** — it has NOTHING to do with adding an ILIKE keyword. So the cited cause→effect is fabricated.
- Improperly drags in **federation** (the responder cited r22): the prod stack is Iceberg/Hive Metastore, no Postgres connector in play; the suggestion is both wrong AND out-of-stack.

Classification: **RESPONDER broken-secondary / false-mechanism slip (lead + Option A correct)**, same family as prior false-justification/broken-secondary tics. The `ILIKE`-doesn't-parse fact and the session-property's real behavior are exactly as the directive described. Note for disposition: r22 federation is HARD-LOCKED zero-edits, so no fix there regardless; this is a responder synthesis slip on a secondary aside, NOT a resource defect (the LOWER() lead is correct). Dinged Acc primarily for the false mechanism, App for the misleading/out-of-stack secondary.

---

## Q3 — `||` returns NULL when last_name NULL; how to handle — 4.75 CLEAN

Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

CORRECT: `||` (= concat()) is NULL-propagating per SQL standard — any NULL operand yields NULL (matches the engineer's symptom) — VERIFIED. `concat_ws(' ', first_name, last_name)` is the clean fix: VERIFIED 467 "any null values ... after the separator are skipped" → NULL last_name yields just 'Jane' (no trailing separator), both NULL yields '' (empty string), exactly as the responder stated. The COALESCE alternative `COALESCE(first_name,'') || ' ' || COALESCE(last_name,'')` is also correct, with the responder correctly noting it can leave a leading/trailing space — accurate caveat. Recommending concat_ws as cleaner is right. CLEAN.

---

## Q4 ★ — display day-of-week as a word ('Monday') — 4.875 CLEAN (date-format defang family HOLDING)

Acc 5.0 / Clar 4.75 / App 5.0 / Comp 4.75.

★ CORRECT: `format_datetime(CAST(created_at AS timestamp), 'EEEE')` → full weekday name — VERIFIED. format_datetime uses JodaTime DateTimeFormat; 'EEEE' is the full text day-of-week token (e.g. 'Wednesday'). CAST(created_at AS timestamp) is fine.

★ **NO FABRICATION — date-format defang family HOLDING on the weekday side:**
- Responder correctly flags `dayname()` as ABSENT in 467 (Postgres/MySQL only) — VERIFIED no dayname() in functions/datetime.html.
- Responder correctly warns `CAST(day_of_week(created_at) AS VARCHAR)` returns the NUMBER ('3') not the name — VERIFIED day_of_week(x)→bigint 1=Mon..7=Sun.
- **No `%A` / no `%W` weekday fabrication and no `dayname()` invention** — the iter985 date-format defang family (%M/%b/%B month-codes + %A/%a weekday) is HOLDING on the weekday side.
- Ordered-grouping guidance (group by numeric day_of_week() + CASE, or repeat format_datetime in GROUP BY) is sound and a useful add. CLEAN.

---

## SCOPE / TIC LEDGER

- **Q1**: HAVING-repeats-COUNT(*) (NOT alias) CORRECT + WHERE/HAVING boundary-of-aggregation correct; **minor `>5`-should-be-`>=5` boundary/off-by-one RESPONDER slip** (under-5 → keep >=5). Lead correct, no resource defect.
- ★ **Q2**: LEAD + Option A (`LOWER(plan_type)=LOWER('PRO')`) CORRECT; **Option B (ILIKE via `enable_string_pushdown_with_collate` session property) = FALSE-MECHANISM broken-secondary RESPONDER slip** — ILIKE does NOT parse in Trino regardless of any property; the property is real but governs collated-string range-predicate pushdown to PostgreSQL, not an ILIKE keyword; ALSO improperly drags in federation (out of Iceberg/Hive stack). Responder cited r22 (HARD-LOCKED zero-edits — no fix there). Responder synthesis slip, NOT a resource defect.
- **Q3**: concat_ws skips NULLs + `||` NULL-propagating + COALESCE-with-space-caveat all CLEAN.
- ★ **Q4**: `format_datetime(...,'EEEE')` full-weekday CORRECT + dayname()-absent correctly flagged + day_of_week()-is-numeric correctly warned + **NO %A/dayname fabrication** = iter985 date-format defang family HOLDING.

Other tics ALL CLEAN: no QUALIFY-misuse / no false-mechanism semi-join mislabel / no MAX(varchar) / no percent_rank inversion / no PARTITIONED-BY foreign DDL / no aggregate-in-GROUP-BY / no mid-churn / no missing-CTE-col / no JOIN fan-out / no ts-minus-ts / no HAVING-alias misuse (Q1 repeats the aggregate). The only two dings are RESPONDER slips on secondary/boundary points (Q2 Option B false mechanism, Q1 `>` vs `>=`); both leads correct.

## iter987 RECOMMENDATION = DEFAULT NO-OP
Margin +0.906 PASS; both dings are responder slips with correct leads, no findable resource/findability gap (Q2's LOWER lead is the correct teaching; Q1's WHERE/HAVING/alias teaching is correct). Federation r22 §13.x HARD-LOCKED — NOT probed (OVERRIDDEN). Re-probe next sweep: (a) another case-insensitive-match Q (confirm LOWER()=LOWER() lead stays + no ILIKE-via-session-property false-mechanism recurs → if it recurs, 2-in-2 candidate for a LIGHT additive defang "ILIKE never parses in Trino, no session property changes that; LOWER() is the only path"); (b) another count-threshold/HAVING Q (watch `>` vs `>=` boundary tracking). NO resource edits. DO NOT bump training/state.json (already 986; passed=true preserved; final_iterations_remaining 0).
