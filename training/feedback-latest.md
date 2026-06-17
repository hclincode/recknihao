# Judge Feedback — iter1005

**OVERALL: 4.6875 — PASS** (75.0/16; margin +1.1875; OVERALL AVERAGE governs, no per-Q veto)

Verified BOTH directions against trino.io/docs/467 + RAW git-tag 467 source (language/types.md, sql/select.md, functions/array.md, functions/string.md) + GitHub issues — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark + dbt) — all 4 questions fit; no federation/auth angle.

---

## Per-question scores

### Q1 — date spine + LEFT JOIN so missing days show 0 — **4.8125 CLEAN**
- `sequence(DATE '2026-01-01', current_date, INTERVAL '1' DAY)` VERIFIED valid (array.md: "Generate a sequence of dates from start to stop, incrementing by step. The type of step can be either INTERVAL DAY TO SECOND or INTERVAL YEAR TO MONTH"); bounds inclusive — CORRECT.
- `UNNEST(...) AS d(day)` spine + `LEFT JOIN ... ON s.event_date = d.day` + `COALESCE(s.signup_count, 0)` = canonical zero-fill — CORRECT.
- "Trino has no generate_series (Postgres) — use sequence()" CORRECT (no Postgres folklore drag-in).
- Variant `UNNEST(sequence(0,29)) AS t(n)` + `date_add('day', n, current_date - INTERVAL '30' DAY)` valid; integer sequence inclusive; `current_date - INTERVAL '30' DAY` valid (date − singular DAY qualifier, NOT bare-integer, NOT quarter/week trap).
- Acc 5.0 / Comp 4.75 / Clar 4.75 / App 4.75.

### Q2 — inline plan-tier label + monthly price without a separate table — **4.40625 (minor ding — secondary-example dialect wart)**
- PRIMARY deliverable (the actual question): `CASE WHEN plan_tier='starter' THEN 'Starter Plan' ...` for label + a second CASE for `monthly_price` — fully CORRECT and directly answers "inline lookup without a separate table." First-match-wins, ELSE catch-all sound.
- SECONDARY "better architectural approach" = a dimension table with `CREATE TABLE iceberg.analytics.plan_dimensions (...) WITH (partitioning = ARRAY[])`. ★ **DIALECT WART:** an EMPTY `ARRAY[]` literal has no determinable element type in Trino (general rule: "cannot determine type of empty array" → needs a cast such as `CAST(ARRAY[] AS ARRAY(varchar))`), and `WITH (partitioning = ARRAY[])` is NOT a documented or idiomatic way to declare an unpartitioned Iceberg table. The documented idiom is to **OMIT the `partitioning` property entirely** (omission → unpartitioned). At best non-idiomatic; plausibly an error depending on connector property parsing. Minor deduction because it is the optional secondary example, not the deliverable; the INSERT...VALUES + LEFT JOIN star-schema framing is otherwise correct and well-explained.
- Acc 4.25 / Comp 4.5 / Clar 4.5 / App 4.375.
- **TEACHER NOTE (no edit required this iter — single occurrence, secondary example):** if an "unpartitioned Iceberg table DDL" Q recurs, the canonical answer is to OMIT `partitioning`. Watch for `partitioning = ARRAY[]` recurrence → only on 2-in-2 consider a LIGHT additive note in r09 ("declare unpartitioned by OMITTING the partitioning property; a bare ARRAY[] literal needs a cast and is not idiomatic"). DO NOT churn on a one-off in a secondary aside.

### Q3 — read ROW fields; `WHERE properties.device='mobile'` "syntax error" — **4.84375 CLEAN (KEY)**
- Dot notation `properties.device` (SELECT and WHERE) VERIFIED CORRECT (types.md: "Named row fields are accessed with field reference operator (.)"; `CAST(ROW(1, 2.0) AS ROW(x BIGINT, y DOUBLE)).x`).
- `(properties).*` parenthesized "expand all fields" VERIFIED CORRECT (select.md: "row_expression.* [AS (column_alias ...)] ... All fields of the row define output columns"; example `(CAST(ROW(1, true) AS ROW(...))).*` — parentheses required). NOT a fabrication.
- "Common mistakes" correctly identified: `properties['device']` (MAP subscript — wrong for ROW), `element_at(properties,'device')` (MAP/ARRAY — wrong for ROW), `json_extract_scalar` (JSON strings — wrong for native ROW). Correctly distinguishes native ROW from MAP and from JSON-in-VARCHAR.
- Bonus `CAST(json_parse(properties) AS ROW(...)).device` for the VARCHAR-holding-JSON case — valid and useful disambiguation.
- Acc 5.0 / Comp 4.75 / Clar 4.875 / App 4.75.

### Q4 — build greeting "Hi Jane Smith, you are on the Growth plan" — CONCAT vs || — **4.8125 CLEAN**
- `concat_ws(' ', first_name, last_name)` skips NULLs VERIFIED (string.md: "Any null values provided in the arguments after the separator are skipped").
- `format('Hi %s %s, you are on the %s plan', ...)` printf-style VERIFIED (Trino format() = Java String.format / printf %s %d).
- `||` chain valid; ★ critical caveat VERIFIED CORRECT: `||` requires VARCHAR operands and does NOT auto-cast numerics — "'Plan ID: '||plan_id is a parse/type error; CAST or format('%d')" is RIGHT (Trino does not implicitly convert numeric↔character; explicit `CAST(x AS varchar)` required). Not a broken-secondary — the caveat is true and load-bearing.
- Decision guide (concat_ws simple / format mixed-types / CAST+|| dynamic) is accurate and actionable.
- Acc 5.0 / Comp 4.75 / Clar 4.75 / App 4.75.

---

## The 5 directed checks — resolved verdicts

1. **Q2 empty `ARRAY[]` partitioning** — ★ DIALECT WART. `WITH (partitioning = ARRAY[])` is NOT the documented way to declare an unpartitioned Iceberg table; OMIT the property instead. Bare `ARRAY[]` has no inferable element type (needs a cast). Minor deduction; secondary example only.
2. **Q3 ROW access** — CORRECT both directions. `properties.device` dot (incl. WHERE) valid; `(properties).*` parenthesized expansion valid; `['...']`/`element_at`/`json_extract_scalar` correctly flagged WRONG for native ROW.
3. **Q1 date spine** — CORRECT. `sequence(DATE,DATE,INTERVAL '1' DAY)` valid + inclusive; UNNEST + LEFT JOIN + COALESCE canonical; `UNNEST(sequence(0,29))` valid; no generate_series (Postgres-only, correctly noted).
4. **Q4 concat** — ALL THREE CORRECT. concat_ws skips NULLs; format() printf-style; `||` needs VARCHAR / no numeric auto-cast / CAST needed.
5. **PostgreSQL `::` cast** — ABSENT in all four answers. Clean (iter1003 one-off did NOT recur; ban stays double-locked r23 §3.1C + r27 §4.4A, not exercised).

---

## TICS scan
All clean except the Q2 secondary-example empty-`ARRAY[]` wart: no QUALIFY / false-mechanism-semi-join / MAX-varchar / percent_rank-inversion / fabricated-fn (sequence/unnest/date_add/coalesce/concat_ws/format/json_parse ALL real & verified; `(row).*` real) / regex-backslash / GREATEST-LEAST-NULL / date-minus-integer (Q1 INTERVAL correct) / `::`-cast (ABSENT) / broken-secondary (Q4 `||` caveat TRUE) / mid-churn / column-scope / ILIKE-conflation / INTERVAL-quarter-week / MAP-subscript-vs-element_at (Q3 ROW correctly NOT confused with MAP).

---

## RECOMMENDATION = DEFAULT NO-OP
Margin +1.1875; 3 of 4 fully clean & verified both directions; Q3 KEY ROW-access resolved CORRECT both directions; `::` did NOT recur. The sole ding is a non-idiomatic `partitioning = ARRAY[]` in Q2's OPTIONAL secondary architectural aside (the primary CASE deliverable is correct) — a single occurrence in a secondary example, NOT a findable resource gap and NOT 2-in-2. NO resource edit; NO FIX-A.

**Re-probe next sweep:**
- (a) another "unpartitioned Iceberg table DDL" / dimension-table-creation Q — confirm the canonical answer is to OMIT `partitioning`; watch `partitioning = ARRAY[]` recurrence → only on 2-in-2 a LIGHT r09 additive note.
- (b) another ROW/struct field-access Q — confirm dot + `(row).*` lead and ROW-vs-MAP-vs-JSON disambiguation stay sharp; watch INVERSE slip (recommending `element_at`/subscript for a native ROW).
- (c) another date-spine / calendar Q — confirm sequence()+UNNEST+LEFT JOIN+COALESCE and no-generate_series.
- (d) another string-build Q — confirm concat_ws-skips-NULL / format-printf / `||`-needs-VARCHAR-CAST trio.
- (e) `::`-cast stays per-instance one-off — only 2-in-2 → LIGHT nudge.

Federation r22 §13.x hard-locked NOT probed (stays 4.49944/310). MUST NOT bump state.json (already 1005; passed=true; final_iterations_remaining 0; orchestrator commits).
