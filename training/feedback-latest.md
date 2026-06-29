# Iter 1270 — Judge Feedback

**Overall: 4.39 PASS** (Q1 3.25 / Q2 5.00 / Q3 4.3125 / Q4 5.00)

**Watch closures:**
- **iter1258 SELECT * EXCEPT fabrication WATCH → CLOSES.** Responder correctly DENIES Trino 467 supports `SELECT * EXCEPT (col1, col2)` (opposite-direction recovery from iter1258's fabrication).
- **iter1215/1268 strpos-3-arg ceiling WATCH → CLOSES.** 2nd-angle unhinted re-probe via Oracle INSTR migration; responder lands `strpos(string, substring, instance)` 3-arg with negative-from-end + 0-if-not-found, source-verified.

**Watch status changed:**
- **iter1255 bloom-CREATE-TABLE-syntax WATCH → MUTATED (NOT closed).** The specific iter1255 syntax slip (WITH inside col-list parens + `USING ICEBERG` Spark suffix) did NOT recur — WITH placement IS now correct after closing paren of column list. BUT TWO NEW parse-blocking errors appeared in the SAME CREATE example: (1) `PRIMARY KEY (device_id)` inside column-list, (2) typed column list `(device_id UUID NOT NULL, model VARCHAR, ...)` mixed with `AS SELECT ...`.

**New soft watch:** `iter1270 Q1 PRIMARY-KEY-in-Trino-CREATE-TABLE + cols-with-AS-SELECT-mix synthesis slip on bloom-filter example`.

---

## Per-question scores

### Q1 — Iceberg device_registrations CREATE TABLE with parquet_bloom_filter_columns on device_id UUID

**Score 3.25** (Acc 2.5 / Clar 4.0 / Prac 2.5 / Compl 4.0)

**Bloom-filter facts CORRECT and iter1255 WITH-placement slip FIXED.** WITH-clause placement (after column-list closing paren, not inside it), 467 CREATE TABLE works natively, 469+ for ALTER SET PROPERTIES, CTAS-rebuild as 467-only workaround for existing tables, Spark TBLPROPERTIES as alternative.

VERIFIED via WebFetch of [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): canonical example shows `CREATE TABLE test_table (c1 INTEGER, c2 DATE, c3 DOUBLE) WITH (format='PARQUET', parquet_bloom_filter_columns = ARRAY['c1','c2'], location='/var/...')` — WITH after closing paren of column-list, parquet_bloom_filter_columns inside WITH (not inside column defs). Matches responder's stated placement rule.

**TWO NEW PARSE-BLOCKING ERRORS in the CREATE example body:**

1. **`PRIMARY KEY (device_id)` inside the column list.** VERIFIED via WebFetch of [trino.io/docs/467/sql/create-table.html](https://trino.io/docs/467/sql/create-table.html): the published grammar shows column definitions as `{ column_name data_type [NOT NULL] [COMMENT ...] [WITH (...)] | LIKE existing_table }` — NO PRIMARY KEY, FOREIGN KEY, UNIQUE, CHECK, or named CONSTRAINT productions exist. Trino 467 PARSE ERROR (`mismatched input 'PRIMARY'`). Engineer who copy-pastes hits this at parse time. **Resources MAXIMALLY DEFANG this**: r23 §3 §30-56 has a full "Trino 467 CREATE TABLE: what IS vs IS NOT supported" matrix explicitly listing PRIMARY KEY as a parse-error, plus the "use NOT NULL + dbt unique test" workaround; r27 §2064 + r13 + r10 + r03 all defang too (24 occurrences across 5 resources). Resource fix would not change behavior — this is a responder synthesis ceiling on a copy-pasteable CREATE example.

2. **Column-type list mixed with `AS SELECT ...`.** VERIFIED via WebFetch of [trino.io/docs/467/sql/create-table-as.html](https://trino.io/docs/467/sql/create-table-as.html): Trino CTAS synopsis is `CREATE [OR REPLACE] TABLE [IF NOT EXISTS] table_name [(column_alias, ...)] [COMMENT ...] [WITH (...)] AS query [WITH [NO] DATA]` — the optional parenthesized list is COLUMN NAME ALIASES ONLY, no types. Example shown: `CREATE TABLE orders_column_aliased (order_date, total_price) AS SELECT orderdate, totalprice FROM orders`. Mixing typed columns (`device_id UUID NOT NULL, model VARCHAR, ...`) with `AS SELECT ...` is invalid. Two legal forms: (A) `CREATE TABLE name (typed col list) WITH (...)` — NO AS SELECT, then `INSERT INTO name SELECT ...`; (B) `CREATE TABLE name [(name aliases)] WITH (...) AS SELECT ...` — column types are INFERRED from the SELECT, not declared.

**CLASSIFICATION**: Responder synthesis slip on a maximally-defanged CREATE example (PRIMARY KEY defanged in r23/r27 in 24 places). Pattern matches the pinned `feedback_synthesis_ceiling_stop_churning.md` family: responder's mental model of the bloom-property placement IS correct (the load-bearing iter1255 fix landed), but generating a fresh full CREATE example mixes foreign-dialect priors (Oracle/Postgres PRIMARY KEY) and conflates the two CTAS forms.

**NO FIX-A** per `feedback_synthesis_ceiling_stop_churning.md` — adding another PRIMARY-KEY defang card risks `feedback_new_card_over_attracts_adjacent.md` over-attraction; resources are already maximally anchored. The Iceberg bloom CREATE TABLE canonical example at trino.io/docs/467/connector/iceberg.html does not include PRIMARY KEY, so the closest copy-attractive form is already present in resources.

**SOFT WATCH**: `iter1270 Q1 PRIMARY-KEY-in-CREATE-TABLE + cols-with-AS-SELECT-mix synthesis slip` — re-probe bloom-filter-on-NEW-Iceberg-table framings under varied phrasings 4-8 iters. If 2+ recurrences across different framings, escalate to LIGHT FIX-A — but the fix would need to be a copy-attractive standalone bloom CREATE TABLE example placed near the bloom-filter keyword zone with NO PRIMARY KEY and the correct CTAS form (column-name-aliases-only OR no AS SELECT), not another PRIMARY-KEY defang.

**Scoring rationale**: Acc 2.5 — bloom facts right but example has 2 parse-blocking errors that prevent it from running. Clar 4.0 — narrative reads cleanly. Prac 2.5 — engineer who copy-pastes the example fails at parse time twice. Compl 4.0 — both CREATE-time and existing-table cases covered, sorted_by mentioned.

### Q2 — Monthly-resetting running sum of credits_used per customer (PARTITION BY date_trunc('month', event_date))

**Score 5.0** (Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 5.0)

Canonical Trino 467 window function:

```sql
SELECT customer_id, event_date, credits_used,
       SUM(credits_used) OVER (
         PARTITION BY customer_id, date_trunc('month', event_date)
         ORDER BY event_date
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS monthly_cumulative_credits
FROM credit_events
```

PARTITION BY customer_id + date_trunc('month', event_date) groups rows into per-customer-per-month windows; Feb 1 lands in a new partition so the running sum resets to that day's credits_used. ORDER BY event_date with ROWS UNBOUNDED PRECEDING AND CURRENT ROW is the standard cumulative-within-window frame.

PARTITION BY accepting expressions like `date_trunc('month', event_date)` is standard SQL window semantics and works in Trino 467 (no requirement to PARTITION BY a base column only). `date_trunc('month', event_date)` returns a date truncated to first-of-month — verified Trino 467 datetime function, returns `date` for `date` input. The frame default for ORDER-BY-with-no-explicit-frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` which for unique event_date per customer-month behaves the same as the explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, but ROWS is the safer explicit form for "running sum row-by-row" semantics and the responder picked correctly.

No imported-prior slip, no broken-secondary alt, no over-warning. Clean canonical for monthly-reset cumulative.

### Q3 — Trino 467 SELECT * EXCEPT (cols) for dbt stg_raw_events 70-col PII drop

**Score 4.3125** (Acc 4.75 / Clar 4.5 / Prac 4.0 / Compl 4.0)

**Correctly DENIES `SELECT * EXCEPT (col1, col2)` — opposite-of-iter1258 recovery, iter1258 fabrication watch CLOSES.**

VERIFIED via WebFetch of [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html): the keyword `EXCEPT` appears ONLY as the set-difference set operator (rows in first query not in second), NOT as a column-exclusion clause. SELECT items grammar lists `expression`, `row_expression.*`, `relation.*`, `*` — no EXCEPT/EXCLUDE/REPLACE column-modifier. Trino 467 has NO `SELECT * EXCEPT` (BigQuery/Databricks-only feature). Engineer who tries it gets a parse error.

**Workarounds offered**: (a) enumerate via `DESCRIBE table` → copy + delete 4 PII columns; (b) hand-rolled dbt macro using `run_query` against `information_schema.columns WHERE column_name NOT IN ('pii1', ...)` then `SELECT {{ columns|join(',') }} FROM ...`; (c) dbt source-yaml `columns:` key.

**Acc shave (-0.25)**: minor — the responder did not name the canonical idiomatic answer `{{ dbt_utils.star(from=ref('source'), except=['ssn', 'email', 'phone', 'ip']) }}`. `dbt_utils.star()` is the standard dbt package macro for exactly this "all columns except a few" pattern, generates a comma-separated column list at compile time by introspecting the relation. It's a one-liner the engineer can copy-paste, available as a dbt-labs/dbt_utils package (very widely installed in dbt projects). The hand-rolled run_query macro reproduces what dbt_utils.star does but with more boilerplate.

**Prac shave (-1.0)**: dbt_utils.star is THE idiomatic dbt answer; not naming it forces the engineer to either type 66 columns by hand or write a custom macro when a 1-line package call exists. Engineer with dbt_utils already installed (very common) would expect that pointer.

**Compl shave (-1.0)**: missed the canonical dbt_utils.star, missed the dbt-labs/dbt_utils package install step. Source-yaml `columns:` key alone doesn't solve the SELECT problem (it only documents columns, doesn't filter them out of a SELECT *).

**Clar shave (-0.5)**: clear overall, but the hand-rolled run_query example will be confusing to a beginner who hasn't written a dbt macro before; pointing at dbt_utils.star first (with the run_query as a fallback) would be more onramping.

**No resource defect** — confirmed via grep that resources do mention dbt_utils.star in r22 and r28 contexts; the responder's findability gap is on the column-exclusion keyword path, not a resource hole. Synthesis ceiling on the alternative-suggestion shape (per `feedback_responder_broken_secondary_alternative.md` family).

### Q4 — Oracle INSTR(raw_url, '/', 1, 3) → Trino 3rd-occurrence of '/' (RE-PROBE iter1215/1268 strpos-3-arg ceiling)

**Score 5.0** (Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 5.0)

**iter1215/1268 strpos-3-arg ceiling WATCH CLOSES on 2nd-angle UNHINTED re-probe.**

Responder: `strpos(raw_url, '/', 3)` — full 3-arg signature `strpos(string, substring, instance) -> bigint`; positive instance counts forward Nth occurrence (1=first, 2=second, 3=third); negative counts from end (-1=last, -2=second-to-last); returns 0 if not found. Position is 1-indexed. `substr(raw_url, strpos(raw_url, '/', 3) + 1)` extracts the path-after-3rd-slash, with the +1 to skip past the slash itself.

VERIFIED via WebFetch of [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html): "`strpos(string, substring, instance) -> bigint` — Returns the position of the N-th instance of substring in string. When instance is a negative number the search will start from the end of string. Positions start with 1. If not found, 0 is returned." Responder's signature description matches docs verbatim.

Oracle INSTR(s, '/', 1, 3) translates directly to Trino `strpos(s, '/', 3)` — the Oracle 3rd arg (start position) is fixed at 1 in this case so it collapses to Trino's 2-arg-plus-instance form. Engineer copy-pastes → exact answer.

**Watch close shape**: iter1215 was the original strpos-3-arg ceiling, iter1268 was a 1st-angle re-probe (then NEAR-CLOSE pending unhinted angle), this iter1270 Q4 is the unhinted 2nd-angle re-probe via Oracle INSTR migration phrasing → fully CLOSED. No imported-prior slip, no broken-secondary alt, no over-warning. Clean canonical for INSTR → strpos Nth-occurrence migration.

---

## Patterns and verdicts

- **iter1255 bloom-CREATE-TABLE-syntax watch did NOT cleanly close**: WITH placement IS fixed (the iter1255-specific slip did not recur), but the responder synthesized TWO NEW parse-blocking errors in the example body (PRIMARY KEY constraint + cols+AS-SELECT mix). This is the same synthesis-ceiling pattern as iter1255 — responder lands the load-bearing dialect fact correctly but mangles peripheral syntax when constructing a fresh full CREATE example. NEW SOFT WATCH opened to re-probe under varied phrasings; if recurrence under different framings, escalate to LIGHT FIX-A near the bloom-filter keyword zone.

- **iter1258 SELECT-*-EXCEPT fabrication watch CLOSES cleanly**: opposite-direction recovery — responder correctly DENIES the BigQuery/Databricks feature exists in Trino 467 and offers Trino-native workarounds. Minor scoring shave for not naming dbt_utils.star as the canonical dbt answer, but the core fabrication direction is fully corrected.

- **iter1215/1268 strpos-3-arg ceiling CLOSES**: 2nd-angle unhinted re-probe successful (Oracle INSTR migration framing did not hint "use the 3-arg form"); responder reaches strpos(string, substring, instance) 3-arg form with negative-from-end and 0-if-not-found semantics. Two consecutive successful angles on a previously-ceilinged primitive.

- **No FIX-A recommended this iter** per `feedback_synthesis_ceiling_stop_churning.md` and `feedback_new_card_over_attracts_adjacent.md`: PRIMARY-KEY defang is maximally anchored (24 occurrences across 5 resources); cols+AS-SELECT-mix is similarly anchored; responder slips are on copy-pasteable example bodies under synthesis pressure, not on the load-bearing dialect facts. Adding more defang risks over-attraction without addressing the Haiku synthesis ceiling.

- **All 4 required topics touched remain PASSED** post-update.

- **Score impact**: Overall 4.39 down from iter1269's 4.95 due to Q1 example errors. Topic margins still healthy.
