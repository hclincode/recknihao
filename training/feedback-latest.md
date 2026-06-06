# Iter 515 Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 4.0469 PASS (+0.547 above 3.5 floor) — 114th consecutive extended-phase PASS

**Per-question summary**:
- Q1 GREATEST RE-PROBE — **4.9375 STRONG PASS** — iter515 r27 §4.4D greatest/least canonical CONFIRMED LANDED (26th leading-canonical bulletproofing instance)
- Q2 SUBSTR-negative RE-PROBE — **4.9375 STRONG PASS** — iter515 r27 §4.3 substr-negative note CONFIRMED LANDED (27th leading-canonical bulletproofing instance)
- Q3 FIRST_VALUE/LAST_VALUE vs ROW_NUMBER — **3.1875 CONTENT-GAP UNDER-ANSWER** — honest punt, NO fabrication; iter516 fix target
- Q4 dbt var() configurable lookback — **3.125 CONTENT-GAP UNDER-ANSWER** — partial punt (gave `{% set %}` workaround, not var()), NO fabrication; iter516 fix target

Overall avg = (4.9375 + 4.9375 + 3.1875 + 3.125)/4 = 16.1875/4 = **4.0469 PASS**. Margin +0.547 above floor — tighter than recent norm; two simultaneous content-gap under-answers offset two STRONG PASSes. Same shape as iter514 (+0.484): two leading-canonical re-probes both land cleanly, two new content gaps surface.

---

## Q1 — GREATEST row-wise max RE-PROBE — 4.9375 STRONG PASS

**Dimensions**: Accuracy 5.0, Clarity 5.0, Applicability 5.0, Completeness 4.75

**What was correct (verified against trino.io/docs/current/functions/comparison.html)**:
- `greatest(score_q1, score_q2, score_q3)` is the correct Trino built-in for row-wise max across columns
- Explicitly disambiguates from `MAX(...)` aggregate ("DO-NOT use MAX(c1,c2,c3) — aggregate, one arg") — exactly the confusion the question probes
- **LOAD-BEARING NULL SEMANTICS CORRECT**: "NULL if ANY arg NULL (Oracle-compatible)" — matches Trino docs verbatim ("Like most other functions in Trino, they return null if any argument is null") and correctly notes this DIFFERS from PostgreSQL (which skips NULLs and returns NULL only if ALL are NULL)
- COALESCE-wrap workaround `greatest(coalesce(a,0), coalesce(b,0), coalesce(c,0))` for "treat NULL as 0" use case — actionable, matches r27 §4.4D canonical
- Cousin/sister distinction with `coalesce()` (first-non-null, not max) implicit in the framing

**Minor deduction (-0.25 Completeness)**: no explicit pre-emption of Postgres-divergence as a footnote (the answer says "Oracle-compatible" but doesn't flag "different from Postgres" as a separate callout). Non-load-bearing.

**Iter515 r27 §4.4D greatest/least canonical CONFIRMED LANDED** on first re-probe. This is the 26th consecutive leading-canonical bulletproofing landing instance. Iter514 Q3 content gap (responder said "I don't have enough information... resources do not document GREATEST()") is GONE.

---

## Q2 — SUBSTR-negative RE-PROBE — 4.9375 STRONG PASS

**Dimensions**: Accuracy 5.0, Clarity 5.0, Applicability 5.0, Completeness 4.75

**What was correct (verified against trino.io/docs/current/functions/string.html)**:
- `substr(product_code, -4)` ports DIRECTLY from Oracle — no rewrite needed
- Trino docs verbatim: "A negative starting position is interpreted as being relative to the end of the string"
- Worked example `substr('ACME-0042', -4)` → `'0042'` correct
- **LOAD-BEARING no-right()/no-left() callout CORRECT**: "Trino has NO right()" with the literal error message `Function 'right' not registered` — engineer immediately knows the right() reflex is wrong and what error they'd see if they tried it
- Symmetric idiom table: `substr(s, -n)` for last n chars, `substr(s, 1, n)` for first n chars — fully actionable
- Confirmed by direct WebFetch of trino.io/docs/current/functions/string.html: full string-function list contains NO `right()` or `left()` — only substr/substring

**Minor deduction (-0.25 Completeness)**: no explicit `substring()` alias mention (substr and substring are interchangeable in Trino). Non-load-bearing.

**Iter515 r27 §4.3 substr-negative + Trino-has-no-right()/no-left() canonical CONFIRMED LANDED** on first re-probe. This is the 27th consecutive leading-canonical bulletproofing landing instance. Iter514 Q4 content gap (responder said "resources don't document negative index... cannot confirm" + hedged `right(s,5)` "if Trino has a right() function") is GONE.

---

## Q3 — FIRST_VALUE/LAST_VALUE vs ROW_NUMBER — 3.1875 CONTENT-GAP UNDER-ANSWER (HONEST PUNT)

**Dimensions**: Accuracy 4.0, Clarity 3.5, Applicability 2.5, Completeness 2.75

**Honest punt — no fabrication, no penalty for safety posture**:
- Responder said "resources don't document FIRST_VALUE/LAST_VALUE specifically"
- Pointed to ROW_NUMBER()=1 subquery + window.html as the available canonical
- Did NOT fabricate first_value/last_value semantics, frame defaults, or partition behavior — correct safety posture

**Why it's a content gap, not a fail**:
- Trino 467 HAS `first_value(x)`, `last_value(x)`, `nth_value(x, n)` as value window functions (verified at trino.io/docs/current/functions/window.html)
- For "first event per session", `first_value(event_type) OVER (PARTITION BY session_id ORDER BY event_time)` works AND ROW_NUMBER()=1 subquery works — they're both valid
- ROW_NUMBER()=1 is often preferred when you need the WHOLE first row (multiple columns from the first event), not just one column — the responder's ROW_NUMBER fallback is a legitimate answer for the underlying intent
- Resource gap: there's no resource block documenting first_value/last_value/nth_value at all — Haiku had nothing to ground a comparison answer in

**Dimension breakdown**:
- Accuracy 4.0: nothing said is wrong; ROW_NUMBER()=1 is a valid pattern for "first per session"; the punt is honest
- Clarity 3.5: the punt + workaround is clear but doesn't compare FIRST_VALUE vs ROW_NUMBER (the actual question)
- Applicability 2.5: engineer learns ROW_NUMBER()=1 but can't make the comparison decision the question asked for
- Completeness 2.75: missed FIRST_VALUE/LAST_VALUE/NTH_VALUE existence + the LAST_VALUE default-frame gotcha (see below) + the "when to use which" rubric

### LOAD-BEARING NUANCE for the iter516 canonical (DO NOT skip this)

Per trino.io/docs/current/functions/window.html (also confirmed via ANSI SQL spec + every other engine that implements it):

- **DEFAULT window frame** = `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (when `ORDER BY` is present in the OVER clause)
- **`first_value(x) OVER (PARTITION BY p ORDER BY o)`** WORKS for "first per partition" because the frame starts at UNBOUNDED PRECEDING — the first row in the frame is the first row in the partition under the ORDER BY
- **`last_value(x) OVER (PARTITION BY p ORDER BY o)`** returns the CURRENT ROW's value, NOT the partition's last value, because the default frame ENDS at CURRENT ROW. This is the #1 gotcha across engines.
- To get the true partition-last value, you MUST extend the frame: `last_value(x) OVER (PARTITION BY p ORDER BY o ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)`
- ROW_NUMBER()=1 subquery sidesteps the frame question entirely AND lets you project all columns from the first row, not just one — preferred when the "first event" use case needs multiple fields

The iter516 teacher canonical must surface this gotcha prominently; without it the responder will (under future probe) confidently emit `last_value(...) OVER (PARTITION BY ... ORDER BY ...)` and silently return the wrong values.

---

## Q4 — dbt configurable lookback window with var() — 3.125 CONTENT-GAP UNDER-ANSWER (PARTIAL PUNT)

**Dimensions**: Accuracy 3.5, Clarity 3.75, Applicability 2.5, Completeness 2.75

**Partial punt — no fabrication, but under-answered the actual question**:
- Responder said "no explicit var() documentation in resources" — honest about the gap
- Gave a `{% set lookback_days = 30 %}` Jinja compile-time-literal workaround (real dbt Jinja, parses cleanly) + `WHERE occurred_at >= date_add('day', -{{ lookback_days }}, current_date)` — the WHERE clause is valid Trino 467
- Hedged "for CLI-time look for `dbt run --vars`" without giving the actual mechanism
- Did NOT fabricate var() syntax — correct safety posture

**Why it's a content gap, not a fail**:
- The user's actual ask was "configurable without hardcoding" — `{% set %}` IS hardcoded (it's a literal at compile time, the same as a magic number); to change it you still edit the model file
- `{{ var('lookback_days', 30) }}` IS the right answer (verified at docs.getdbt.com/reference/dbt-jinja-functions/var): defines a default of 30, overridable from CLI per run without touching the model
- Resource gap: no resource block documenting dbt var() — Haiku had nothing to anchor the answer in, so it gave the closest thing it could verify (Jinja `{% set %}`)

**Dimension breakdown**:
- Accuracy 3.5: nothing technically wrong; `{% set %}` works; mention of `--vars` is correct in spirit; the only flaw is mismatched fit (workaround doesn't actually solve the "no hardcoding" requirement)
- Clarity 3.75: explanation is clear but conflates two different mechanisms
- Applicability 2.5: engineer ships the `{% set %}` form, doesn't get per-run CLI configurability, has to come back later
- Completeness 2.75: missed the actual var() form + dbt_project.yml vars: block + --vars CLI override

### LOAD-BEARING DETAILS for the iter516 canonical (verified at docs.getdbt.com/reference/dbt-jinja-functions/var)

The real dbt var() mechanism has THREE pieces:

1. **In the model SQL** — `{{ var('lookback_days', 30) }}` where 30 is the default if not otherwise set
   ```sql
   select * from {{ ref('events') }}
   where occurred_at >= date_add('day', -{{ var('lookback_days', 30) }}, current_date)
   ```

2. **In `dbt_project.yml`** — project-level defaults under a `vars:` block:
   ```yaml
   vars:
     lookback_days: 30
   ```

3. **CLI override at runtime** — `--vars` flag with YAML dict syntax:
   ```bash
   dbt run --select fct_events --vars '{lookback_days: 7}'
   ```
   (Also valid: `dbt run --vars '{"lookback_days": 7}'` JSON-style; both work because YAML is a superset of JSON.)

**Precedence**: CLI `--vars` > `dbt_project.yml` vars: > inline default in `var('name', default)` call.

The iter516 teacher canonical must include all three pieces. Without the dbt_project.yml + CLI pieces, the answer is incomplete; without the inline default, the model fails when no override is set.

---

## Federation row status

Federation NOT probed this iter — **r22 §13.x federation guardrails UNTOUCHED, federation rubric row stays 4.49944/310** per iter472–515 directive + iter515 task constraint.

---

## New fabrications this iter

**NONE.** Both content-gap answers were honest/partial punts (Q3 = honest punt, Q4 = partial punt with `{% set %}` workaround that is real dbt Jinja, not invented). Correct safety posture.

---

## Iter516 PRIMARY FIX TARGETS for the teacher

### FIX A (PRIMARY, NEW CANONICAL) — Trino value window functions: first_value / last_value / nth_value

Location candidate: r07 (analytical query patterns on Iceberg+Trino) or r23 (SQL patterns) — add new sub-section adjacent to existing ROW_NUMBER / RANK canonical.

**Required content**:
1. Keyword anchors line: "first event per session, last event per session, first value vs row number, last_value gotcha, last_value default frame, value window functions Trino, first_value last_value nth_value Trino, first per partition, first row per group, first-event-per-session, first event per user, last event per user"
2. THE SIGNATURE TABLE:
   - `first_value(x) OVER (PARTITION BY p ORDER BY o)` → value of x in the first row of the partition (works with default frame)
   - `last_value(x) OVER (PARTITION BY p ORDER BY o ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)` → value of x in the last row of the partition (REQUIRES explicit frame extension)
   - `nth_value(x, n) OVER (PARTITION BY p ORDER BY o ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)` → value of x in the nth row (also requires extended frame)
3. **THE LAST_VALUE DEFAULT-FRAME GOTCHA** — explicit callout with worked example showing wrong vs right:
   - WRONG: `last_value(event_type) OVER (PARTITION BY session_id ORDER BY event_time)` → returns CURRENT ROW's event_type (the default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`)
   - RIGHT: `last_value(event_type) OVER (PARTITION BY session_id ORDER BY event_time ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)` → returns the last event_type in the session
4. WHEN-TO-USE-WHICH table:
   - `first_value(col)` — when you need ONE column from the first row of each partition (single column projection, frame-default-friendly)
   - `last_value(col, FRAMED)` — when you need ONE column from the last row of each partition (frame-extension required)
   - `ROW_NUMBER() = 1` subquery — when you need MULTIPLE columns from the first row (whole-row projection)
   - `ROW_NUMBER() OVER (ORDER BY o DESC) = 1` — when you need MULTIPLE columns from the last row (whole-row projection, no frame headache)
   - `nth_value(col, n, FRAMED)` — for the nth row when n is fixed (e.g., 2nd event); for variable n use ROW_NUMBER
5. WORKED "first event per session" comparison block:
   ```sql
   -- Pattern A: first_value (single column, frame-default works)
   SELECT session_id, first_value(event_type) OVER (PARTITION BY session_id ORDER BY event_time) AS first_event
   FROM events;

   -- Pattern B: ROW_NUMBER() = 1 (multiple columns)
   SELECT session_id, event_type, event_time, page_url
   FROM (
     SELECT *, ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY event_time) AS rn
     FROM events
   ) WHERE rn = 1;
   ```
6. DO-NOT-WRITE bans:
   - "last_value(col) OVER (PARTITION BY p ORDER BY o) gives the partition's last value" (it does NOT — default frame ends at CURRENT ROW)
   - "Trino doesn't have first_value/last_value" (it DOES — verified trino.io/docs/current/functions/window.html)
   - "first_value and ROW_NUMBER()=1 always give the same result" (they do for SINGLE-column first-per-partition; differ when you need multiple columns or need last value)
   - "nth_value works with default frame" (it does NOT for n past current row position — needs explicit frame extension)
7. Verified-sources line: trino.io/docs/current/functions/window.html

### FIX B (PRIMARY, NEW CANONICAL) — dbt var() configurable model variable

Location candidate: r25 (dbt patterns) or r27 (Oracle PL/SQL → dbt + Trino migration §6.x dbt-config cluster) — adjacent to existing dbt config / sources / freshness canonicals.

**Required content**:
1. Keyword anchors line: "dbt var, dbt configurable variable, dbt without hardcoding, dbt lookback window variable, dbt CLI vars override, dbt run --vars, dbt_project.yml vars block, dbt parametrize model, dbt runtime configuration, dbt change value without editing model"
2. THE THREE-PIECE PATTERN:
   - Piece 1 (model SQL): `{{ var('lookback_days', 30) }}` with default
   - Piece 2 (dbt_project.yml): `vars:` block at project level with `lookback_days: 30`
   - Piece 3 (CLI override): `dbt run --vars '{lookback_days: 7}'` YAML dict (also accepts JSON dict `'{"lookback_days": 7}'`)
3. PRECEDENCE: CLI --vars > dbt_project.yml vars: > inline default in var() call
4. WORKED END-TO-END EXAMPLE:
   ```sql
   -- models/fct_recent_events.sql
   {{ config(materialized='incremental', unique_key='event_id') }}
   SELECT *
   FROM {{ ref('stg_events') }}
   WHERE occurred_at >= date_add('day', -{{ var('lookback_days', 30) }}, current_date)
   {% if is_incremental() %}
     AND occurred_at > (SELECT COALESCE(MAX(occurred_at), TIMESTAMP '1970-01-01') FROM {{ this }})
   {% endif %}
   ```
   ```yaml
   # dbt_project.yml
   vars:
     lookback_days: 30
   ```
   ```bash
   # Daily run (uses 30-day default from dbt_project.yml)
   dbt run --select fct_recent_events

   # Backfill (override to 90 days)
   dbt run --select fct_recent_events --vars '{lookback_days: 90}'
   ```
5. CONTRAST with `{% set %}` Jinja (the iter515 responder's workaround) — explicit table:
   - `{% set lookback_days = 30 %}` — compile-time literal, changing requires editing the model file, NOT CLI-overridable
   - `{{ var('lookback_days', 30) }}` — runtime parameter with default, CLI-overridable per run without editing the model
   - `{% set %}` is fine for derived/computed Jinja values used multiple times in the same model; `var()` is the right tool for "configurable without hardcoding"
6. DO-NOT-WRITE bans:
   - "use `{% set %}` for configurable model variables" (it's NOT configurable per run — it IS hardcoded)
   - "`--vars` uses comma-separated key=value" (it's a YAML/JSON dict)
   - "`--vars` is set in profiles.yml" (it's a CLI flag; profiles.yml doesn't accept vars)
   - "`var()` without a default errors only at runtime" (it errors at compile time with `Required var 'foo' not found`)
7. Verified-sources line: docs.getdbt.com/reference/dbt-jinja-functions/var + docs.getdbt.com/docs/build/project-variables

---

## Iter516 JUDGE PROBE TARGETS

**HIGH priority** (verify fix-A and fix-B both land):
- **first_value/last_value re-probe** ("I want the first event per session — use first_value or ROW_NUMBER()? what about the last event?") — verifies FIX A canonical lands + the LAST_VALUE default-frame gotcha is communicated correctly
- **last_value default-frame 2nd angle** ("does `last_value(x) OVER (PARTITION BY p ORDER BY o)` give the partition's last value?") — direct probe of the gotcha; expected: "NO, it gives the CURRENT ROW under the default frame; you need `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`"
- **dbt var() re-probe** ("I want lookback_days configurable from the CLI without editing the model — how?") — verifies FIX B canonical lands with the `{{ var('name', default) }}` + dbt_project.yml + `--vars` three-piece pattern
- **dbt var() 2nd angle** ("what's the difference between `{% set %}` and `{{ var() }}` in dbt?") — verifies the contrast block lands and the responder routes "configurable" to var() not set

**MEDIUM priority** (verify iter515 r27 §4.4D + §4.3 hold under different angles):
- **greatest/least with mixed types** ("can greatest mix DECIMAL and DOUBLE columns?") — verifies type-coercion edge isn't fabricated
- **substr-negative bounded** ("what does `substr('abc', -10)` return — error or empty string?") — verifies the safe-on-overshoot edge isn't fabricated
- **nth_value 3rd angle** ("can I get the 2nd event per session with nth_value?") — verifies frame-extension callout extends past last_value

**LOW priority**:
- Federation stays UNPROBED — row stays 4.49944/310

---

## Topic-average update math (for the next judge pass)

Q1 (greatest/least) maps primarily to **SQL query best practices for OLAP** (per-row max/min idiom, cleaner-than-CASE-WHEN canonical).
Q2 (substr-negative + no right()/no left()) maps primarily to **Oracle PL/SQL → dbt + Trino SQL migration** (Oracle SUBSTR direct-port canonical at r27 §4.3).
Q3 (first_value/last_value vs ROW_NUMBER) maps primarily to **SQL query best practices for OLAP** (window-function canonical) and secondarily to **Analytical query patterns on Iceberg+Trino** (first-event-per-session funnel idiom).
Q4 (dbt var() configurable lookback) maps primarily to **Oracle PL/SQL → dbt + Trino SQL migration** (dbt-config canonical at r27 §6.x).

**SQL query best practices for OLAP**: 4.5401/72 → (4.5401·72 + 4.9375 + 3.1875)/74 = 335.9087/74 = **4.5393/74** (-0.0008 — Q1 STRONG lifts, Q3 sub-threshold drags, net near-flat)

**Oracle PL/SQL → dbt + Trino SQL migration**: 4.5203/82 → (4.5203·82 + 4.9375 + 3.125)/84 = 378.7271/84 = **4.5087/84** (-0.0116 — Q4 sub-threshold drags, Q2 STRONG lifts, net negative)

**Federation row UNCHANGED**: 4.49944/310 (not probed)

All probed topics remain comfortably above their pass thresholds. No topic drops below 3.5; no PASSED topic drops below 4.0.

---

## Summary

- **Overall iter515 = 4.0469 PASS** (+0.547 above floor; 114th consecutive extended-phase PASS)
- **BOTH iter514 content gaps FILLED**: Q1 greatest/least + Q2 substr-negative both CONFIRMED LANDED on first re-probe (26th + 27th leading-canonical bulletproofing landing instances)
- **TWO NEW iter515 content gaps surface**: Q3 first_value/last_value + Q4 dbt var() — both honest/partial punts, NO fabrication, correct safety posture
- **Iter516 PRIMARY FIX TARGETS**: (FIX A) first_value/last_value/nth_value canonical with the LAST_VALUE default-frame gotcha; (FIX B) dbt var() three-piece canonical (`{{ var('name', default) }}` + `vars:` block in dbt_project.yml + `--vars` CLI override) with explicit `{% set %}` vs `var()` contrast
- **NO new fabrications this iter**
- **Federation rubric row stays 4.49944/310, r22 §13.x guardrails untouched**
