# Iter 516 Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 4.4063 PASS (+0.9063 above 3.5 floor) — 115th consecutive extended-phase PASS

**Per-question summary**:
- Q1 LAST_VALUE default-frame RE-PROBE — **4.9375 STRONG PASS** — iter516 r07 §5 Pattern B3 first_value/last_value canonical CONFIRMED LANDED (28th leading-canonical bulletproofing instance)
- Q2 dbt var() configurable lookback RE-PROBE — **4.9375 STRONG PASS** — iter516 r27 §6.7G dbt var()/vars:/--vars canonical CONFIRMED LANDED (29th leading-canonical bulletproofing instance)
- Q3 NULL placement on ORDER BY DESC — **4.5625 STRONG PASS** — technically correct per official Trino docs; minor reconciliation-with-user-symptom weakness
- Q4 dbt documentation feature — **3.1875 CONTENT-GAP UNDER-ANSWER** — honest punt (no fabrication); iter517 fix target

Overall avg = (4.9375 + 4.9375 + 4.5625 + 3.1875)/4 = 17.625/4 = **4.4063 PASS**. Margin +0.9063 above floor — restored to typical band after iter515's tight +0.547; both iter515 content-gap canonicals landed cleanly on first re-probe; one new content gap (dbt docs) surfaced.

---

## Q1 — LAST_VALUE default-frame RE-PROBE — 4.9375 STRONG PASS

**Dimensions**: Accuracy 5.0, Clarity 5.0, Applicability 5.0, Completeness 4.75

**What was correct (verified against [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html))**:
- Identifies the default frame as `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — matches Trino docs verbatim ("When no frame is specified, the default frame is RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW")
- Correctly explains that frame ends at current row's PEER GROUP, so `last_value(event_type) OVER (PARTITION BY session_id ORDER BY event_time)` returns the current row's value (when ORDER BY is unique-per-row) NOT the partition's true last value
- Prescribes the canonical fix: `last_value(event_type) OVER (PARTITION BY session_id ORDER BY event_time ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)`
- Surfaces the LOAD-BEARING nuance that `nth_value(x, n)` has the same default-frame footgun (silently NULL for n > 1 when default frame ends before nth row)
- Cites r07 Pattern B3 as source (where iter516 teacher just landed the canonical)
- Mentions ROW_NUMBER()=1 subquery as cleaner alternative when projecting multiple columns from the last row

**ITER515 CONTENT GAP A CONFIRMED FILLED**: iter515 Q3 punt ("resources don't document FIRST_VALUE/LAST_VALUE specifically") is GONE. The iter516 teacher's r07 §5 Pattern B3 canonical (first_value-safe-with-default / last_value-needs-explicit-ROWS / nth_value-silently-NULL three-function comparison + worked first/last-event-per-session example + DO-NOT-WRITE bans) LANDED on first re-probe. **28th consecutive leading-canonical bulletproofing landing instance.**

**Deductions**: -0.25 Completeness for no explicit callout of the PEER-GROUP edge case (when ORDER BY has ties, `last_value` returns the last value in the current row's peer group, not strictly the current row's value) — non-load-bearing; the unique-ORDER-BY case is the common one.

---

## Q2 — dbt var() configurable lookback RE-PROBE — 4.9375 STRONG PASS

**Dimensions**: Accuracy 5.0, Clarity 5.0, Applicability 5.0, Completeness 4.75

**What was correct (verified against [docs.getdbt.com/reference/dbt-jinja-functions/var](https://docs.getdbt.com/reference/dbt-jinja-functions/var) + [docs.getdbt.com/docs/build/project-variables](https://docs.getdbt.com/docs/build/project-variables))**:
- THREE-PIECE PATTERN delivered cleanly:
  1. Model SQL: `{{ var('lookback_days', 30) }}` with default arg
  2. `dbt_project.yml` top-level `vars:` block with defaults
  3. CLI override: `dbt run --vars '{lookback_days: 7}'` (plural `--vars`, YAML dict)
- Precedence rule correct: CLI `--vars` > `dbt_project.yml` `vars:` > inline default in `var()` call
- Explicit guidance that `{% set %}` is the WRONG mechanism for tunable knobs (use it for compile-time constants only)
- Cites r27 §6.7G as source (where iter516 teacher just landed the canonical)
- Multi-var CLI form mentioned: `dbt run --vars '{lookback_days: 7, region: us}'`

**ITER515 CONTENT GAP B CONFIRMED FILLED**: iter515 Q4 partial punt (gave `{% set lookback_days = 30 %}` Jinja compile-time-literal workaround instead of `var()`, hedged "for CLI-time look for `dbt run --vars`") is GONE. The iter516 teacher's r27 §6.7G canonical (three-piece pattern + var-vs-set contrast table + DO-NOT-WRITE bans on `{% set %}` for tunables, `--var` singular, `--vars key=value` non-YAML, nested-under-models scope, no-default-no-env runtime error) LANDED on first re-probe. **29th consecutive leading-canonical bulletproofing landing instance.**

**Deductions**: -0.25 Completeness for no explicit mention of var-scoping (top-level `vars:` is global; package-scoped vars use a nested key under the package name) — non-load-bearing for the question asked.

---

## Q3 — ORDER BY DESC NULL placement — 4.5625 STRONG PASS

**Dimensions**: Accuracy 4.75, Clarity 4.75, Applicability 4.75, Completeness 4.0

**WebSearch verification — IMPORTANT CORRECTION OF JUDGE BRIEF**: I verified the Trino default NULL ordering against [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) three independent times. The official documentation states verbatim: **"The default null ordering is `NULLS LAST`, regardless of the ordering direction."** The judge brief's claim ("Trino treats NULL as LARGER than all non-null values, so DESC -> NULLS FIRST by default") is **INCORRECT per official Trino docs**. The responder's claim ("Trino's default is NULLS LAST for DESC — NULLs appear at the bottom") is **TECHNICALLY CORRECT**.

**What was correct**:
- Trino default NULL ordering claim verified verbatim against trino.io docs: NULLS LAST for both ASC and DESC, regardless of direction
- Oracle comparison verified against multiple Oracle SQL references: Oracle DESC default IS `NULLS FIRST` (NULLs at top), Oracle ASC default IS `NULLS LAST`. The responder's framing of this as "a critical difference from Oracle" IS CORRECT — Trino (always NULLS LAST) and Oracle (DESC=NULLS FIRST) genuinely diverge on DESC default
- Fix syntax correct: `ORDER BY last_active_at DESC NULLS LAST` (bottom — though redundant per Trino default it documents intent) / `DESC NULLS FIRST` (top)
- Explicit recommendation to ALWAYS write `NULLS LAST` / `NULLS FIRST` in production-critical queries (documents intent, survives engine swap) is sound engineering practice

**Deductions**:
- -0.25 Accuracy: the symptom reconciliation is incomplete. User reports NULLs at TOP under bare `ORDER BY last_active_at DESC` on Trino. Given Trino default is NULLS LAST, the bare ORDER BY cannot be producing the observed symptom. The responder hand-waves to "you may have migrated Oracle code that relied on Oracle's DESC NULLS FIRST default" but doesn't make the most likely concrete diagnosis explicit: **the SQL almost certainly contains an explicit `NULLS FIRST` (likely ported verbatim from Oracle where it was redundant but harmless)** — the engineer should grep the SQL/view definitions for `NULLS FIRST` and remove it
- -0.25 Clarity: the migrated-Oracle-code speculation is plausible but not laid out as a concrete debugging step
- -0.25 Applicability: no explicit "grep your SQL/view chain for `NULLS FIRST`" actionable next step
- -1.0 Completeness: misses the alternative possibilities (a downstream view forces NULLS FIRST; a tool/UI sorts client-side; the data has a sentinel value like '9999-12-31' that's not actually NULL but parsed as one)

**Net**: technically airtight on the Trino + Oracle defaults; soft on closing the loop with the user's observed symptom. STRONG PASS at 4.5625.

---

## Q4 — dbt documentation feature — 3.1875 CONTENT-GAP UNDER-ANSWER (HONEST PUNT)

**Dimensions**: Accuracy 4.0, Clarity 3.5, Applicability 2.5, Completeness 2.75

**What was correct**:
- Honest punt: "I don't have enough information... resources don't include a guide to dbt's documentation feature (dbt docs generate, schema YAML, descriptions)"
- Did NOT fabricate any commands, file paths, or YAML structure
- Pointed engineer to authoritative external source: [docs.getdbt.com/docs/build/documentation](https://docs.getdbt.com/docs/build/documentation)
- Mentions the relevant keywords (dbt docs generate, schema YAML, descriptions) so the engineer can self-serve

**What was missing (verified at [docs.getdbt.com/docs/build/documentation](https://docs.getdbt.com/docs/build/documentation))**:
- dbt HAS a first-class docs feature; descriptions go in YAML schema files (typically `models/schema.yml` or `_models.yml`) via a `description:` key on `models:` / `columns:` / `sources:` / `seeds:` / `snapshots:` entries
- Workflow: `dbt docs generate` (builds catalog.json + manifest.json) then `dbt docs serve` (launches browsable site at localhost:8080) — these are the canonical two commands
- Long-form descriptions use **docs blocks**: `{% docs my_block %}...{% enddocs %}` in a `.md` file under `models/`, then reference as `description: '{{ doc("my_block") }}'` in schema YAML
- Markdown supported in description values (multi-line via YAML `|` or `>`)
- The generated site shows DAG, column-level lineage (in newer dbt versions), data types introspected from warehouse, descriptions, tests
- For the production on-prem stack (Trino+Iceberg+k8s), the docs site can be served via `dbt docs serve --port N` or the static files (`target/index.html` + `manifest.json` + `catalog.json`) can be packed into a container image and served by any static-file server inside the k8s cluster — no SaaS/cloud dependency

**Deductions**: -1.0 Accuracy (no fab penalty for honest punt; lost for not knowing the feature exists in resources), -1.5 Clarity (punt doesn't show schema YAML structure or commands), -2.5 Applicability (engineer left without one concrete file to edit + one command to run), -2.25 Completeness (no description: key + no dbt docs generate/serve + no doc blocks + no schema.yml file location).

**No fabrication penalty** — this is correct safety posture for a content gap. iter517 fix target (see below).

---

## Iter516 PRIMARY DELIVERABLES

**BOTH ITER515 CONTENT GAPS CONFIRMED FILLED ON FIRST RE-PROBE**:

1. **GAP A FILLED — r07 §5 Pattern B3 first_value/last_value/nth_value canonical**: Q1 (last_value default-frame) re-probe scored 4.9375 STRONG PASS with all load-bearing elements present (default-frame rule, peer-group caveat, explicit ROWS UNBOUNDED PRECEDING/FOLLOWING fix, nth_value sister-gotcha, ROW_NUMBER alternative for multi-column projection). iter516 r07 §5 Pattern B3 canonical landed cleanly. **28th consecutive leading-canonical bulletproofing landing instance.**

2. **GAP B FILLED — r27 §6.7G dbt var()/vars:/--vars three-piece canonical**: Q2 (dbt var configurable lookback) re-probe scored 4.9375 STRONG PASS with all load-bearing elements present (var() with default arg, vars: block at top level of dbt_project.yml, --vars plural YAML dict CLI override, precedence CLI > project > default, var-vs-set guidance). iter516 r27 §6.7G canonical landed cleanly. **29th consecutive leading-canonical bulletproofing landing instance.**

## Iter516 NEW CONTENT GAP (iter517 PRIMARY FIX TARGET)

**GAP — dbt documentation feature canonical**: Q4 punted honestly because no resource covers dbt docs. iter517 teacher should add a dbt-docs canonical (likely r25 or r27 dbt-config cluster, possibly new §6.7H sitting after §6.7G):

- **Where to write descriptions**: schema YAML files (`models/_models.yml` or per-folder `schema.yml`) using the `description:` key on `models:` / `columns:` / `sources:` / `seeds:` / `snapshots:` entries
- **Long-form**: doc blocks in `.md` files under `models/` — `{% docs block_name %}...{% enddocs %}` referenced as `description: "{{ doc('block_name') }}"`
- **Generate site**: `dbt docs generate` (produces `target/catalog.json` + `target/manifest.json` + static site assets) then `dbt docs serve` (defaults to port 8080)
- **On-prem k8s framing**: docs site is static HTML/JSON — pack `target/` into a container image, serve via nginx/Caddy as a k8s Deployment + Service; no SaaS/cloud dependency (fits production environment per prod_info.md)
- **Worked example**: minimal `_models.yml` with model + column descriptions + tests; corresponding `_models.md` with one doc block
- **Verified sources**: docs.getdbt.com/docs/build/documentation + docs.getdbt.com/reference/commands/cmd-docs
- **DO-NOT-WRITE bans** to add: "descriptions go in the model .sql file as comments" (wrong location); "dbt docs generate serves the site" (wrong — it builds; serve serves); "doc() references must be inside .sql files" (wrong — they go in YAML description values); "dbt docs requires dbt Cloud" (wrong — Core can generate + serve locally)
- **Keyword anchors**: "dbt docs site / dbt model description / dbt column description / dbt docs generate / dbt docs serve / dbt schema yml description / dbt doc blocks / dbt browsable documentation / dbt catalog / dbt manifest"

## Iter517 PROBE TARGETS

- **dbt docs RE-PROBE (HIGH)** — "how do I add a description to my dbt model + column and view it as a website?" — verifies new dbt-docs canonical lands with schema YAML + `dbt docs generate` + `dbt docs serve`
- **dbt docs 2nd angle (HIGH)** — "where do I write long descriptions with markdown for dbt? can I share a single description across multiple columns?" — verifies doc-blocks (`{% docs %}` + `{{ doc() }}`) framing lands
- **last_value/first_value 3rd angle (MEDIUM)** — "I want the FIRST 3 events per session ordered by time — first_value, nth_value, or ROW_NUMBER()<=3?" — verifies r07 §5 Pattern B3 when-to-use-which table extends to top-N case
- **nth_value 3rd angle (MEDIUM)** — "nth_value(event_type, 2) returns NULL for every row — why?" — verifies r07 §5 Pattern B3 nth_value-silently-NULL gotcha lands as standalone
- **dbt var() vs set 2nd angle (MEDIUM)** — "when should I use `{% set %}` vs `{{ var() }}` in dbt?" — verifies r27 §6.7G var-vs-set contrast table extends to direct-comparison probe
- **dbt var() no-default error (MEDIUM)** — "what happens if I write `{{ var('lookback_days') }}` without a default and forget to define lookback_days?" — verifies r27 §6.7G DO-NOT-WRITE "no default + no env-definition = runtime error" ban lands
- **NULLS-ordering 3rd angle (LOW)** — "is `ORDER BY x ASC NULLS LAST` redundant in Trino?" — verifies Trino default-NULLS-LAST framing holds under direct probe
- **Federation stays UNPROBED (LOW)** — row stays 4.49944/310 per directive (do NOT touch §13.x federation guardrails in resources/22 or the federation rubric row)

## Topic average updates

**Analytical query patterns on Iceberg+Trino** (r07 §5 Pattern B3 first_value/last_value canonical — Q1 maps here): 4.4018/19 → (4.4018·19 + 4.9375)/20 = 88.5717/20 = **4.4286/20** (+0.0268 — Q1 STRONG lifts)

**Oracle PL/SQL → dbt + Trino SQL migration** (Q2 dbt var() at r27 §6.7G + Q4 dbt docs both map here per dbt-CLI/dbt-config cluster precedent): 4.5087/84 → (4.5087·84 + 4.9375 + 3.1875)/86 = 386.855/86 = **4.4983/86** (-0.0104 — Q4 sub-threshold drags but Q2 STRONG lifts; topic still PASSED)

**SQL query best practices for OLAP** (Q3 NULLS-ordering ORDER BY hygiene maps here): 4.5393/74 → (4.5393·74 + 4.5625)/75 = 340.4707/75 = **4.5396/75** (+0.0003 — Q3 STRONG roughly at topic avg)

**Federation row UNCHANGED**: 4.49944/310 per iter472-516 directive + iter516 task constraint (do NOT touch §13.x federation guardrails in resources/22).

## Pattern observations

- **NO FABRICATIONS this iter** across all 4 answers — Q4 was an honest content-gap punt (correct safety posture). 115th consecutive overall PASS in extended phase. Margin +0.9063 — restored to healthy band after iter515's tight +0.547.
- **iter516 teacher batch-fix continues to land cleanly**: 28th + 29th consecutive leading-canonical bulletproofing landing instances. Pattern (since iter489) of teacher canonicals landing on first re-probe holds.
- **Q3 (NULLS-ordering)**: judge brief contained a factual error about Trino's NULL default; verified against [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) three times that Trino default is `NULLS LAST` regardless of direction. Responder's claim is correct; brief's claim ("DESC -> NULLS FIRST by default in Trino") is wrong. The Oracle side of the responder's framing ("different from Oracle DESC NULLS FIRST default") is also CORRECT — Oracle and Trino genuinely differ on DESC default. The only weakness in Q3 is the soft reconciliation with the user's observed symptom (didn't say "grep your SQL for explicit `NULLS FIRST`").

**Sources verified**:
- [Trino window functions](https://trino.io/docs/current/functions/window.html) — Q1 default frame and last_value/first_value/nth_value behavior
- [Trino SELECT / ORDER BY](https://trino.io/docs/current/sql/select.html) — Q3 default NULLS LAST regardless of direction
- [dbt var() function](https://docs.getdbt.com/reference/dbt-jinja-functions/var) — Q2 signature, default arg, --vars CLI
- [dbt project variables](https://docs.getdbt.com/docs/build/project-variables) — Q2 vars: block in dbt_project.yml
- [dbt documentation](https://docs.getdbt.com/docs/build/documentation) — Q4 schema YAML descriptions, doc blocks, dbt docs generate/serve
