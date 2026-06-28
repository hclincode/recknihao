# Iteration 1233 — Judge Feedback

**Verdict: 4.6875 STRONG PASS (margin +1.1875).** Q1 + Q3 + Q4 clean technically; Q2 is 4.0 BORDERLINE on a framing self-contradiction (canonical SQL is correct, but "Oracle syntax ports directly with zero changes" framing is factually wrong — Oracle places `IGNORE NULLS` INSIDE the parens, Trino requires OUTSIDE, and the engineer's parse error was EXACTLY from that placement difference). Iter average = (4.875 + 4.0 + 4.875 + 5.0)/4 = **18.75/4 = 4.6875**.

**ITER1232 LIGHT FIX-A REACHED — `r27 §6.7A1 custom-generic-test-schema.yml-test_-prefix-drop` watch CLOSES.** Q1 this iteration is the re-probe; responder produced a pin-perfect answer (4.875), modern `tests/generic/` + `{% test name(model,...) %}` block-name-drops-test_ + bare-name schema.yml call + the precise dbt-prepends-test_ error mechanism + legacy `{% macro test_NAME %}` backward-compat note. The §6.7A1 card is keyword-magnetic on the test_-prefix-trap question family.

- **Q2 framing slip (NOT load-bearing, NO FIX-A).** Responder said "your Oracle syntax ports directly with zero changes" but Oracle SQL is `LAST_VALUE(x IGNORE NULLS) OVER (...)` (inside parens) and Trino 467 requires `LAST_VALUE(x) IGNORE NULLS OVER (...)` (outside parens between args and OVER). Verified via [trinodb/trino#1244](https://github.com/trinodb/trino/pull/1244) test cases `lag(c2, 1) IGNORE NULLS over (...)` — null-treatment clause goes between closing args paren and OVER. The engineer's parse error came precisely from porting the inside-parens form. Responder's *displayed Trino SQL is correct* (placement outside parens, UNBOUNDED PRECEDING..CURRENT ROW look-back frame, IGNORE NULLS support claim on FIRST_VALUE/LAST_VALUE/NTH_VALUE/LAG/LEAD all correct), but the "zero changes" claim contradicts the SQL and the engineer's own Q stem. **GREP EVIDENCE — resource coverage is excellent, not a content gap**: r07 §1500-1670 has a LEADING CANONICAL forward-fill block + a DO-NOT-WRITE table with five grep-findable WRONG/RIGHT rows (`LAST_VALUE(col IGNORE NULLS) OVER (...)` ❌ vs `LAST_VALUE(col) IGNORE NULLS OVER (...)` ✅, same for FIRST_VALUE/LAG/LEAD/NTH_VALUE) + the mnemonic "close the args, then IGNORE NULLS, then OVER". r23 §2168-2218 has a parallel DO-NOT-WRITE row also pinned with verbatim parse error message `mismatched input 'IGNORE'`. So the placement-DIFFERENTIAL claim has full resource coverage. This is a recall-ceiling slip on the framing claim, not a content gap. Aligns with `feedback_responder_broken_secondary_alternative.md` / `feedback_responder_overwarning_folklore.md` family — per-instance one-off, NO FIX-A. SOFT WATCH `iter1233 Q2 IGNORE-NULLS Oracle-vs-Trino placement-zero-changes-framing`: re-probe 4-8 iters with similar Oracle-port-to-Trino LOCF framing.
- **Q1/Q3/Q4 clean.** Q1 modern + legacy custom-generic-test pin-perfect against docs.getdbt.com/best-practices/writing-custom-generic-tests (verbatim "macro name `test_<NAME>`, but call it by `<NAME>` in schema.yml — drop the prefix"). Q3 dbt var() top-level vars block + `{{ var('name', default) }}` two-arg form + CLI `--vars '{name: val}'` YAML-dict-string + precedence CLI > project > default all verbatim verified against docs.getdbt.com/docs/build/project-variables; INTERVAL '{{ var(...) }}' DAY interpolation correctly renders to valid Trino INTERVAL '7' DAY. Q4 `date_trunc('month'|'quarter', x)` mapping pin-perfect against trino.io/docs/467/functions/datetime.html with the exact unit list "millisecond, second, minute, hour, day, week, month, quarter, year" and same-type-as-input return.

Per-question summary:
- **Q1 4.875** — custom generic test: modern `tests/generic/test_amount_order.sql` + `{% test amount_order(model, column_a, column_b) %}` block (BARE name, no test_ prefix) + schema.yml `- amount_order: {column_b: gross_amount}` bare-name call + dbt-prepends-test_ error mechanism explanation + legacy `{% macro test_amount_order %}` in macros/ backward-compat note all correct. **iter1232 FIX-A REACHED — watch CLOSES.**
- **Q2 4.0** — IGNORE NULLS forward-fill: SQL pin-perfect (placement outside parens, UNBOUNDED PRECEDING..CURRENT ROW look-back frame, supported on FIRST/LAST/NTH_VALUE + LAG/LEAD); "Oracle ports directly with zero changes" framing CONTRADICTS the displayed SQL and the engineer's parse error. Resource coverage of the placement difference is excellent (r07 + r23 both have DO-NOT-WRITE rows + grep-findable WRONG/RIGHT token tables + mnemonic). Recall-ceiling slip on framing claim, NO FIX-A.
- **Q3 4.875** — dbt var() lookback: top-level vars: in dbt_project.yml + `{{ var("lookback_days", 7) }}` two-arg form + CLI `--vars '{lookback_days: 7}'` YAML-dict-string + CLI > project > default precedence + don't-use-{% set %} caveat (compile-time constant, not CLI-overridable) all correct. INTERVAL string interpolation renders to valid Trino.
- **Q4 5.0** — `date_trunc('month'|'quarter', event_date)` mapping pin-perfect; unit list, return-type, week-ISO-Monday all verified.

**NO new FIX-A warranted.** Q2 slip is recall-ceiling on a Trino-vs-Oracle DIFFERENTIAL claim that's already documented at length in r07 + r23 (the responder produced the correct Trino SQL — only the framing about "zero changes" is wrong). Resource coverage on the IGNORE NULLS placement difference is among the strongest in the corpus.

**WATCH STATE:**
- **CLOSED:** `iter1232 r27 custom-generic-test-schema.yml-test_-prefix-drop` — Q1 4.875 PIN-PERFECT.
- **NEW SOFT WATCH:** `iter1233 Q2 IGNORE-NULLS Oracle-vs-Trino placement-zero-changes-framing` — re-probe 4-8 iters with similar Oracle-port-to-Trino LOCF framing. Expect responder to call out the inside-vs-outside placement difference rather than claim "zero changes."
- **CARRIED OPEN WATCHES** (continued from iter1232): iter1231 NEXT_DAY-closing-note-contradicts; iter1230 EXISTS-over-warning + ::cast; iter1215 strpos-3-arg CEILING (no churn); iter1213 session_properties / (+)-mnemonic; iter1229 @v1-Spark-syntax; iter1208 width_bucket-boundary.

**Topic routing this iter:**
- Q1 → "dbt model contracts" (4.4230/15 → 4.4513/16 PASSED, margin +0.9513; consistent with iter1232 Q3 routing for custom-generic-test family)
- Q2 → "Analytical query patterns on Iceberg+Trino" (4.5749/165 → 4.5715/166 PASSED, margin +1.0715; LOCF / forward-fill canonical)
- Q3 → "Improving complex SQL performance on Trino with dbt" (4.5415/52 → 4.5478/53 PASSED, margin +1.0478; dbt mechanics for env-specific defaults)
- Q4 → "Oracle PL/SQL → dbt+Trino" (4.4573/198 → 4.4600/199 PASSED, margin +0.9600; Oracle dialect rewrite)

All four required topics remain PASSED with healthy margins. All required topics in the rubric continue PASSED. No regression risk identified.

---

## Q1 — Engineer hit "Could not find generic test 'test_amount_order'": named macro `test_amount_order` + schema.yml `- test_amount_order: {column_a: net_amount, column_b: gross_amount}`. Where does the file live, the full macro block, EXACT schema.yml entry that resolves?

**Score: 4.875** — Acc 5.0 / Clar 4.5 / App 5.0 / Compl 5.0

Responder shape:
- **Diagnosis**: `Could not find generic test 'test_amount_order'` = the `test_` prefix trap (dbt prepends `test_` at lookup → searches for `test_test_amount_order` → not found).
- **Modern preferred form**:
  - File: `tests/generic/test_amount_order.sql` (file NAME can include the test_ prefix freely; only the BLOCK name must drop it)
  - Macro block:
    ```jinja
    {% test amount_order(model, column_a, column_b) %}
    SELECT * FROM {{ model }}
    WHERE {{ column_a }} > {{ column_b }}
       OR {{ column_a }} IS NULL
       OR {{ column_b }} IS NULL
    {% endtest %}
    ```
    — block name `amount_order` BARE (no `test_` prefix).
- **schema.yml entry**:
  ```yaml
  models:
    - name: fct_orders
      columns:
        - name: net_amount
          data_tests:
            - amount_order:
                column_b: gross_amount
  ```
  — call by bare name `amount_order`, `column_a` resolves from `name: net_amount` context.
- **Why error happens**: dbt prepends `test_` at lookup, so YAML `- test_amount_order:` makes dbt search for macro `test_test_amount_order` (doesn't exist).
- **Legacy alternative**: `{% macro test_amount_order(...) %}` in `macros/test_amount_order.sql` STILL backward-compatible; YAML call identical bare `amount_order:` (dbt strips the `test_` prefix from the macro name to match the YAML).

**Load-bearing facts VERIFIED:**

1. **Modern `{% test NAME(model, ...) %}` block in `tests/generic/`** — verified verbatim at [docs.getdbt.com/best-practices/writing-custom-generic-tests](https://docs.getdbt.com/best-practices/writing-custom-generic-tests) (WebFetched this iter): block syntax shown as `{% test is_even(model, column_name) %} ... {% endtest %}`, file paths `tests/generic/` (preferred) or `macros/` (legacy).
2. **Block name does NOT include `test_` prefix** — verbatim from docs: "Key point: The test block name does NOT include the `test_` prefix."
3. **schema.yml call by bare name, dbt prepends `test_`** — verbatim from docs: "dbt prepends `test_` to the lookup. If your macro is named `{% test amount_order %}`, dbt finds it as `test_amount_order`." Engineer's YAML `- test_amount_order:` causes dbt to search `test_test_amount_order` → `Could not find generic test`.
4. **Legacy `{% macro test_NAME %}` form backward-compatible** — historically dbt supported `{% macro test_NAME %}` in `macros/` with the `test_` prefix auto-stripped at lookup; the modern `{% test NAME %}` block in `tests/generic/` is preferred but the macro form still resolves. Responder correctly noted both.

**Minor shave (Compl -0.0):** Could have explicitly called out that the engineer's file may need to be MOVED from `macros/` to `tests/generic/` IF they used the `{% test ... %}` block form (which only works in `tests/generic/` not `macros/`); but the answer is clear that the BLOCK NAME is the actual error so the file location is secondary. Not load-bearing.

Engineer leaves with: exact file path + exact macro block (bare name) + exact schema.yml call (bare name) + crystal-clear "dbt prepends test_" mechanism. **iter1232 FIX-A `r27 §6.7A1 custom-generic-test-schema.yml-test_-prefix-drop` REACHED — watch CLOSES.** **Topic routed to "dbt model contracts"** (data-integrity test declaration, same routing as iter1232 Q3 + iter1216/1218/1221/1229 Q3 accepted_values/not_null/relationships).

---

## Q2 — Forward-fill NULLs: `account_daily(account_id, snapshot_date, feature_flag)` one row/account/day, `feature_flag` only on change days (most NULL). Need each row to carry last non-null `feature_flag` up to that date. Oracle `LAST_VALUE(feature_flag IGNORE NULLS) OVER (...)` parse-errors in Trino on IGNORE NULLS. Does Trino support IGNORE NULLS, and the correct forward-fill pattern?

**Score: 4.0** — Acc 3.5 / Clar 3.5 / App 4.5 / Compl 4.5

Responder shape:
- **YES, Trino 467 supports IGNORE NULLS.**
- **Canonical SQL**:
  ```sql
  LAST_VALUE(feature_flag) IGNORE NULLS OVER (
    PARTITION BY account_id ORDER BY snapshot_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS feature_flag_filled
  ```
- Supported on `LAST_VALUE`, `FIRST_VALUE`, `NTH_VALUE`, `LAG`, `LEAD` in 467.
- **Said "your Oracle syntax ports directly with zero changes."**

**Load-bearing facts VERIFIED:**

1. **IGNORE NULLS supported on first_value/last_value/nth_value/lag/lead in Trino 467** — verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html): "By default, null values are respected. If `IGNORE NULLS` is specified, all rows where x is null are excluded from the calculation."
2. **Placement is OUTSIDE parens, between args and OVER** — verified via [trinodb/trino#1244](https://github.com/trinodb/trino/pull/1244) test cases `lag(c2, 1) IGNORE NULLS over (partition by c3 order by c1 asc)` — null-treatment clause goes between closing args paren and OVER.
3. **UNBOUNDED PRECEDING..CURRENT ROW look-BACK frame** is the canonical LOCF shape. Correct.
4. **Responder's displayed SQL is CORRECT Trino 467 syntax** — placement outside parens, look-back frame, supported function.

**Framing slip (Acc -1.5, Clar -1.5) — "your Oracle syntax ports directly with zero changes" is FACTUALLY WRONG.**

- Oracle places IGNORE NULLS INSIDE the parens: `LAST_VALUE(feature_flag IGNORE NULLS) OVER (...)`.
- Trino 467 requires IGNORE NULLS OUTSIDE the parens: `LAST_VALUE(feature_flag) IGNORE NULLS OVER (...)`.
- The engineer's parse error came PRECISELY from porting Oracle's inside-parens form to Trino.
- So there IS a required change: move IGNORE NULLS outside the parens.
- The responder's CANONICAL SQL shows the correct OUTSIDE-parens placement, so the displayed code WORKS — but the framing claim "zero changes" CONTRADICTS the displayed SQL and the engineer's own Q stem ("parse-errors in Trino on IGNORE NULLS").

**GREP EVIDENCE — resource coverage is excellent, NOT a content gap:**
- `r07 §1500-1670` LEADING CANONICAL forward-fill block has a DO-NOT-WRITE table with five grep-findable WRONG/RIGHT rows:
  - `LAST_VALUE(col IGNORE NULLS) OVER (...)` ❌ PARSE ERROR
  - `LAST_VALUE(col) IGNORE NULLS OVER (...)` ✅
  - (parallel rows for FIRST_VALUE / LAG / LEAD / NTH_VALUE)
- Plus the mnemonic: "Close the args paren, then `IGNORE NULLS`, then `OVER` — three tokens in that order."
- `r23 §2168-2218` parallel DO-NOT-WRITE row pinned with verbatim parse error message `mismatched input 'IGNORE'`.

So the placement-DIFFERENTIAL claim has full resource coverage. This is a recall-ceiling slip on the framing claim, not a content gap. Engineer who copies the SQL gets a working query but is left confused about why their original parse-errored if "zero changes" needed.

**NO FIX-A** — recall-ceiling slip on a framing claim, aligns with `feedback_responder_broken_secondary_alternative.md` / `feedback_responder_overwarning_folklore.md` family (per-instance one-off, no resource fix). SOFT WATCH `iter1233 Q2 IGNORE-NULLS Oracle-vs-Trino placement-zero-changes-framing` re-probe 4-8 iters.

Engineer leaves with: correct working Trino SQL + accurate support claim + minor confusion about whether Oracle's syntax really ports unchanged. The SQL is what's load-bearing; the framing is what's docked. **Topic routed to "Analytical query patterns on Iceberg+Trino"** (LOCF / forward-fill canonical).

---

## Q3 — dbt var() for dev(7d) vs prod(90d) lookback. Where to declare the var + default, how to reference in model SQL (is `CURRENT_TIMESTAMP - INTERVAL '{{ var("lookback_days") }}' DAY` correct?), how to override on CLI vs CI default.

**Score: 4.875** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 4.5

Responder shape:
- **Declare in `dbt_project.yml` TOP-LEVEL `vars:`**:
  ```yaml
  vars:
    lookback_days: 90  # prod default
  ```
- **Reference in model SQL**:
  ```sql
  WHERE event_ts >= CURRENT_TIMESTAMP - INTERVAL '{{ var("lookback_days", 7) }}' DAY
  ```
  — two-arg `var(name, default)` form; Jinja renders to `INTERVAL '7' DAY` which IS valid Trino 467.
- **CLI override**: `dbt run --select events --vars '{lookback_days: 7}'` for dev.
- **Prod CI uses the 90 default** (no `--vars` flag).
- **Precedence**: CLI `--vars` > `dbt_project.yml` `vars:` > function default `var('name', 7)`.
- **Don't use `{% set %}`** for this — compile-time constant, not CLI-overridable.

**Load-bearing facts VERIFIED:**

1. **Top-level `vars:` block in dbt_project.yml** — verified verbatim at [docs.getdbt.com/docs/build/project-variables](https://docs.getdbt.com/docs/build/project-variables).
2. **`{{ var("name", default) }}` two-arg form** — verified: `select '{{ var("event_type", "default_value") }}' as event_type`.
3. **CLI `--vars '{name: val}'`** YAML-dict-string syntax — verified: `$ dbt run --vars '{event_type: signup, region: us}'`; JSON form `'{"event_type": "signup"}'` also valid.
4. **Precedence CLI > project > function default** — verified verbatim: "Variables passed via `--vars` override `dbt_project.yml` definitions."
5. **Trino INTERVAL string-quoted integer literal** — `INTERVAL '7' DAY` is valid Trino 467 syntax; Jinja renders the `{{ var(...) }}` to `7` before SQL parse, so the final SQL is `INTERVAL '7' DAY`. Correct.
6. **`{% set %}` is compile-time constant, not CLI-overridable** — correct; `{% set X = 7 %}` bakes the value at parse time, no way to override from CLI. The responder's caveat is sound.

**Minor shave (Compl -0.5):** Could mention `target.name == 'dev'` profile-target branching as an alternative for environment-specific defaults — e.g., `{{ var('lookback_days', 7 if target.name == 'dev' else 90) }}` — but unprompted; the var()+CLI override approach the engineer asked about is correct and complete.

Engineer leaves with: exact yaml block location + exact var() reference + working CLI command + clear precedence + correct INTERVAL interpolation pattern. **Topic routed to "Improving complex SQL performance on Trino with dbt"** (dbt mechanics for env-specific deployment patterns).

---

## Q4 — Oracle `TRUNC(date,'MM')` / `TRUNC(date,'Q')` errors in Trino (numeric rounding). Trino equivalent for month/quarter boundaries — function name + arg mapping.

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

Responder shape:
- **Use `date_trunc(unit, date_or_timestamp)`** — Trino's equivalent.
- **Month**: `date_trunc('month', event_date)` for first-of-month.
- **Quarter**: `date_trunc('quarter', event_date)` for first-of-quarter.
- **Args**: `date_trunc(unit, date_or_timestamp)`, unit a string literal, returns same type as input.
- **Units**: `millisecond / second / minute / hour / day / week (Monday ISO) / month / quarter / year`.

**Load-bearing facts VERIFIED:**

1. **`date_trunc(unit, x)` signature** — verified verbatim at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): `date_trunc(unit, x) → [same as input]`.
2. **Unit list verbatim**: "millisecond, second, minute, hour, day, week, month, quarter, year" — matches responder's list exactly.
3. **Week is ISO Monday-start** — consistent with the documented `week()` function returning "ISO week of the year" (1-53), which uses Monday as week-start per ISO 8601.
4. **Return type same as input** — verified: `date_trunc('month', timestamp_col)` returns timestamp; `date_trunc('month', date_col)` returns date.
5. **Why Oracle TRUNC fails in Trino**: Trino `truncate(x)` is numeric-only (rounds toward zero), no second-arg date string. The responder correctly framed this as "numeric rounding" — engineer's TRUNC parse error mechanism explained.

No slips. Pin-perfect. Engineer leaves with: direct Oracle→Trino function mapping + complete unit list + return-type clarity + why-Oracle-TRUNC-fails diagnosis. **Topic routed to "Oracle PL/SQL → dbt+Trino SQL migration"** (canonical Oracle dialect rewrite, same routing as prior TRUNC and TO_CHAR Oracle-fn re-probes).
