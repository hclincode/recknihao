# Judge Feedback — Iteration 501

**Date**: 2026-06-06
**Phase**: extended
**Overall**: 4.7969 STRONG PASS (+1.2969 above 3.5 floor)

---

## Per-Question Scores

### Q1 — Trino date arithmetic (days between two dates; +30 days for trial expiration)

**Score: 4.875 STRONG PASS** — Accuracy 4.75, Clarity 5.0, Actionability 5.0, Completeness 4.75

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.75 | `date_diff('day', d1, d2)` argument order `(unit, from, to)` returning later-minus-earlier verified at trino.io/docs/current/functions/datetime.html. `date_add('day', N, d)` verified. `signup_date + INTERVAL '30' DAY` verified valid. `date_add('day', -7, current_date)` verified. **Minor mislabel (-0.25)**: answer says bare-integer `current_date - 30` produces a "PARSE ERROR" — strictly speaking this is a **type-resolution error** ("`'-'` cannot be applied to date, integer"), not a parse error. The query parses fine; the analyzer rejects it. Engineer impact is identical (statement fails), so non-load-bearing. |
| Clarity | 5.0 | Two distinct patterns (operator-form and function-form) shown side-by-side; negative-value subtraction explicit. |
| Actionability | 5.0 | Copy-pasteable forms for both the diff and the +30-day expiration case. |
| Completeness | 4.75 | Covers diff, add, subtract, and the bare-integer anti-pattern. Could note `current_date + INTERVAL '30' DAY` returns DATE preserved, but non-blocking. |

**Verified clean**: `date_diff(unit, from, to)` order, `date_add(unit, N, ts)` order, INTERVAL syntax, negative-N for subtraction.

---

### Q2 — Oracle TO_CHAR / TO_DATE → Trino equivalents (copy-paste error fix)

**Score: 4.9375 STRONG PASS** — Accuracy 5.0, Clarity 4.75, Actionability 5.0, Completeness 5.0

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | Confirmed Trino has NO `to_char`/`to_date` (function-not-registered). `date_format(ts, '%Y-%m-%d')` MySQL-style verified. `format_datetime(ts, 'yyyy-MM-dd')` Joda-style verified. `date_parse('2024-01-01', '%Y-%m-%d')` MySQL-style verified. `parse_datetime('2024-01-01', 'yyyy-MM-dd')` Joda-style verified. `from_iso8601_date(...)` exists. Both `date_parse` and `parse_datetime` return TIMESTAMP/TIMESTAMP WITH TIME ZONE, so CAST AS DATE is the correct shape for getting a DATE. Format-mask mapping rows accurate (`YYYY`→`%Y`/`yyyy`, `MM`→`%m`/`MM`, `DD`→`%d`/`dd`, `HH24`→`%H`/`HH`, `MI`→`%i`/`mm`, `SS`→`%s`/`ss`). |
| Clarity | 4.75 | Side-by-side MySQL-vs-Joda specifier table is exactly what an Oracle dev migrating to Trino needs. |
| Actionability | 5.0 | Engineer can copy any of the three TO_DATE replacements (date_parse+CAST, parse_datetime+CAST, from_iso8601_date) and pick by format. |
| Completeness | 5.0 | Covers no-such-function symptom, two formatter families with format-string differences, parse-return-type → CAST necessity, ISO 8601 shortcut. |

**Verified clean**: All four functions and the MySQL-vs-Joda specifier split.

---

### Q3 — dbt seeds for small static country-code CSV lookup

**Score: 4.6875 STRONG PASS** — Accuracy 4.75, Clarity 4.75, Actionability 4.75, Completeness 4.5

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.75 | `seeds/` is the correct default directory (verified docs.getdbt.com/reference/project-configs/seed-paths — "By default, dbt expects your seed files to be located in the seeds subdirectory"). `data/` was the pre-1.0 default — correct historical note. `dbt seed` / `dbt seed --select country_codes` verified. `+column_types` in dbt_project.yml verified (docs.getdbt.com/reference/resource-configs/column_types). `ref('country_codes')` standard. **Important nuance partially wrong**: answer says seeds NOT auto-run by `dbt run`/`dbt build`. `dbt run` is correct — runs models only. **`dbt build` DOES include seeds** per docs.getdbt.com/reference/commands/build — "builds and tests your selected resources such as models, seeds, snapshots, and tests." So claim is half-wrong on `dbt build`. -0.25. |
| Clarity | 4.75 | Clear directory → command → ref usage chain; <1MB sizing rule of thumb is correct. |
| Actionability | 4.75 | Engineer can drop the CSV and run the seed command immediately. |
| Completeness | 4.5 | Misses the `dbt build` includes-seeds nuance (above). Could note seeds are version-controlled and meant for STATIC reference data (country codes ARE the canonical example — engineer should be told this is the right tool for their use case). Otherwise complete. |

**Verified clean**: seeds/ default, column_types config, dbt seed command isolation from dbt run.
**Verified WRONG**: `dbt build` claim — `dbt build` DOES execute seeds by default.

---

### Q4 — 2B-row × 50K-row join broadcast vs partitioned distribution

**Score: 4.6875 STRONG PASS** — Accuracy 4.75, Clarity 4.5, Actionability 5.0, Completeness 4.75

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.75 | BROADCAST=replicate small table to all workers vs PARTITIONED=hash-repartition both sides — correct. **`join_distribution_type` session property VERIFIED CORRECT** (NOT a fabricated `distributed_join_distribution_type`); values BROADCAST/PARTITIONED/AUTOMATIC verified at trino.io/docs/current/optimizer/cost-based-optimizations.html. **`join_max_broadcast_table_size` session property NAME VERIFIED CORRECT** at trino.io/docs/current/optimizer/cost-based-optimizations.html. **Default 100 MB VERIFIED CORRECT** ("By default, the replicated table size is capped to 100MB"). EXPLAIN RemoteExchange[REPLICATE]=broadcast vs [REPARTITION]=partitioned verified. Trino-has-no-`/*+ hint */` syntax correct (comments are silently dropped). Missing/stale ANALYZE causing AUTOMATIC to mis-pick correct. **Minor concern (-0.25)**: answer's example `SET SESSION join_max_broadcast_table_size = '50MB'` — value should be unquoted DataSize literal or `'50MB'` string-style depending on form; the string form generally works but the property type is DataSize. Both forms are accepted in Trino, so non-load-bearing. Did NOT use the Spark-ism `ANALYZE TABLE` — used bare `ANALYZE <table>` which is the correct Trino form (verified trino.io/docs/current/sql/analyze.html). |
| Clarity | 4.5 | Two distribution types are clearly contrasted; EXPLAIN signal interpretation is concrete. The session-property + ANALYZE + size-cap troubleshooting flow is well-ordered. |
| Actionability | 5.0 | Engineer gets: (1) session SET to force, (2) dbt pre_hook form for dbt context, (3) ANALYZE remediation if CBO is starved, (4) size-cap bump knob, (5) EXPLAIN verification step. End-to-end. |
| Completeness | 4.75 | Covers the symptom, the two distribution modes, two control knobs (type + size cap), the CBO-stats reason, EXPLAIN verification, and the no-hint caveat. Could mention `join-distribution-type` system-level config-property counterpart but engineer-level session control is the immediate ask. |

**Q4 session-property verification — explicit outcomes for this iter's critical check**:

- `join_distribution_type` — **VERIFIED CORRECT**. Values `BROADCAST` / `PARTITIONED` / `AUTOMATIC` verified at trino.io/docs/current/optimizer/cost-based-optimizations.html. **NOT a recurrence of the prior `distributed_join_distribution_type` fab.**
- `join_max_broadcast_table_size` — **VERIFIED CORRECT** (exact name). Confirmed at trino.io/docs/current/optimizer/cost-based-optimizations.html.
- Default 100 MB — **VERIFIED CORRECT**. Doc: "By default, the replicated table size is capped to 100MB."
- EXPLAIN RemoteExchange `REPLICATE` (broadcast) vs `REPARTITION` (partitioned) — **VERIFIED CORRECT**.
- No `/*+ hint */` syntax in Trino — **VERIFIED CORRECT** (hints are parsed as comments and ignored).
- `ANALYZE <table>` (bare, NO `TABLE` keyword) — **VERIFIED CORRECT** at trino.io/docs/current/sql/analyze.html. Answer did NOT write Spark-ism `ANALYZE TABLE`. Clean.

---

## Overall Iter501 Verdict

**OVERALL AVG = (4.875 + 4.9375 + 4.6875 + 4.6875) / 4 = 19.1875 / 4 = 4.7969 STRONG PASS**

(+1.2969 above 3.5 floor; 100th consecutive PASS in extended phase.)

### Verified Clean
- Trino `date_diff`/`date_add` argument orders and unit-string literal
- Trino INTERVAL operator-form date arithmetic
- Trino has NO `to_char`/`to_date`
- `date_format`/`date_parse` use MySQL specifiers; `format_datetime`/`parse_datetime` use Joda
- `date_parse`/`parse_datetime` return TIMESTAMP → CAST AS DATE
- `from_iso8601_date` exists
- dbt seeds default directory is `seeds/`; `data/` was pre-1.0
- `+column_types` config in `dbt_project.yml`
- `dbt seed` is independent of `dbt run`
- BROADCAST vs PARTITIONED join distribution semantics
- **`join_distribution_type` session property name + values (BROADCAST/PARTITIONED/AUTOMATIC)**
- **`join_max_broadcast_table_size` session property name + 100 MB default**
- EXPLAIN `REPLICATE`/`REPARTITION` interpretation
- Trino has no `/*+ BROADCAST */` query hints
- Bare `ANALYZE <table>` Trino form (NOT Spark `ANALYZE TABLE`)

### New Issues Found

**Q3 — `dbt build` claim is half-wrong (load-bearing minor).** Answer says "seeds NOT auto-run by `dbt run`/`dbt build`." Correct for `dbt run`; WRONG for `dbt build`. Per docs.getdbt.com/reference/commands/build, `dbt build` runs seeds, models, snapshots, and tests together in DAG order. Engineer impact: if they switch from `dbt run` to `dbt build` thinking they still need to call `dbt seed` separately, they will double-load seeds (idempotent but wasted work) or — more likely — be confused why behavior differs from the doc. **This is a small but reproducible factual error**; teacher should reconcile-in-place where seeds-vs-build appears in resources.

**Q1 — "PARSE ERROR" mislabel (non-load-bearing minor).** `current_date - 30` is a **type-resolution error**, not a parse error. Engineer impact identical (query fails), but if they search the error message for "parse error" they will find nothing — they will find a "Cannot apply operator: date - integer"-style type message. Optional polish.

**NO new fabrications**. **NO session-property fabs** (Q4 was the high-risk question — both critical property names and the 100 MB default verified clean). **NO Spark-isms** (Q4 ANALYZE form is correct bare-Trino, not `ANALYZE TABLE`).

---

## Topic Average Updates

- **SQL query best practices for OLAP** (Q1 date arithmetic maps here): 4.5288 / 55 → (4.5288×55 + 4.875) / 56 = 253.7590 / 56 = **4.5314 / 56** (+0.0026)
- **Oracle PL/SQL → dbt/Trino migration** (Q2 TO_CHAR/TO_DATE → Trino maps here): 4.5406 / 72 → (4.5406×72 + 4.9375) / 73 = 331.8607 / 73 = **4.5460 / 73** (+0.0054)
- **Improving complex SQL performance on Trino with dbt** (Q3 dbt seeds + Q4 broadcast control both map here): 4.5926 / 12 → (4.5926×12 + 4.6875 + 4.6875) / 14 = 64.4862 / 14 = **4.6062 / 14** (+0.0136 — two STRONG PASS data points)
- **Trino federation** — UNCHANGED at **4.49944 / 310** per directive (not probed).

---

## Next-Teacher Actions for Iter502

**LOW priority** (Q3 minor reconcile):
- Grep `resources/` for any line claiming seeds are NOT executed by `dbt build`. Reconcile in place to: "`dbt build` runs seeds AND models AND snapshots AND tests in DAG order; `dbt run` runs models only; `dbt seed` runs seeds only." Cite docs.getdbt.com/reference/commands/build verbatim quote: "builds and tests your selected resources such as models, seeds, snapshots, and tests."
- Do NOT add new sections; this is reconcile-in-place per the standing directive.

**OPTIONAL polish** (Q1 mislabel):
- If a resource currently writes "parse error" for the bare-integer `current_date - 30` case, change to "type error: cannot apply operator '-' to date and integer". Non-load-bearing; only fix if grep finds an existing wrong label.

**LEAVE UNTOUCHED**:
- All §13.x federation guardrails in `resources/22*` (federation row stays 4.49944 / 310).
- r27 §6.7A dbt test mechanics (iter501 teacher fix is verified intact via this iter's STRONG PASSes).
- r09 §1a/1b dbt snapshot SCD2 canonical (verified intact iter500).
- r17 dbt view/ephemeral canonical (verified intact iter498-499).
- r13 MERGE engine-note (verified intact iter498).
- r28 §3.3/§3.3A materialization canonicals.
- iter495 dbt-trino `partitioning`-key canonical.

---

## Judge Probe Targets for Iter502

| Priority | Probe | Why |
|---|---|---|
| HIGH | `dbt build` vs `dbt run` vs `dbt seed` — does dbt build include seeds? | Iter501 Q3 showed a half-wrong claim. Need to verify the reconcile-in-place lands. |
| HIGH | Trino broadcast join — 2nd angle: "I bumped join_max_broadcast_table_size but EXPLAIN still shows REPARTITION — why?" | Q4 was solid; 2nd-angle probe should confirm CBO-stats / AUTOMATIC-mode interaction stays clean and that the 100 MB default knowledge transfers to a debugging scenario. |
| MEDIUM | Trino TO_DATE for an Oracle format mask with TZ (`'YYYY-MM-DD HH24:MI:SS TZH:TZM'`) | Q2 was strong on simple masks; probes the timezone-formatter edge of MySQL-vs-Joda. |
| MEDIUM | dbt seeds + Iceberg specifics: does dbt-trino write the seed as an Iceberg table? What partition spec / properties? | Probes the seed→Trino-target adapter behavior, which Q3 did not cover. |
| LOW | `date_diff` with `'hour'`/`'minute'` units and `current_timestamp` | Generalizes Q1 to non-day units. |
| LOW (do not probe) | Federation — UNPROBED per standing directive. |

---

## Confirmation

- Score line for iter501 appended to `training/rubric.md` history.
- `training/state.json` left at `iteration: 501` (NOT bumped per task instructions; teacher set it).
- §13.x federation guardrails in `resources/22-*` UNTOUCHED.
- Federation rubric row UNCHANGED at 4.49944 / 310.
