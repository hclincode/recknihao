# Iter1120 — Judge Feedback

**Overall verdict: 4.7188 STRONG PASS (NO-OP + WATCH STREAM)** (margin +1.22 above 3.5). Three clean STRONG-PASS answers (Q1/Q2/Q3 all 5.0000) plus one Q4 syntax slip on the copy-pasteable DDL: the responder bundled three ADD COLUMN clauses into a single ALTER TABLE statement (Postgres/MySQL-style comma-separated multi-operation), which **is a PARSE ERROR on Trino 467** — `ALTER TABLE ... ADD COLUMN` takes exactly ONE column per statement on Trino 467 per trino.io/docs/current/sql/alter-table.html and github.com/trinodb/trino/blob/467/docs/src/main/sphinx/sql/alter-table.md grammar (single ADD COLUMN clause, no comma list). Conceptual claims in Q4 (metadata-only, instant, no lock, downstream not broken, old rows read NULL, explicit-column queries unaffected, `SELECT *` picks them up) are ALL fully correct — only the DDL example is broken. Q1 nails the dbt `strategy='check' + check_cols` no-`updated_at` pattern with hash-comparison framing; Q2 lands the bare `ANALYZE iceberg.x.y` syntax (no `TABLE` keyword), the NDV → CBO join-order/broadcast logic, the Iceberg auto-min/max-no-NDV distinction, AND a sound realistic-alternative-causes diagnostic list (partition pruning failure / small-files decay / data skew) with `EXPLAIN (TYPE DISTRIBUTED)` as the verification step; Q3 cleanly picks `any_match(arr, x -> starts_with(x, 'beta_'))` with no UNNEST and lists the full higher-order family (all_match/none_match/filter).

---

## Source verifications (Trino 467 raw + rendered docs, dbt docs)

- **Q4 ALTER TABLE single-ADD-COLUMN-per-statement** — VERIFIED PARSE ERROR ON RESPONDER'S DDL:
  - trino.io/docs/current/sql/alter-table.html synopsis quoted verbatim: `ALTER TABLE [ IF EXISTS ] name ADD COLUMN [ IF NOT EXISTS ] column_name data_type [ DEFAULT default ] [ NOT NULL ] [ COMMENT comment ] [ WITH (...) ] [ FIRST | LAST | AFTER after_column_name ]` — grammar is **SINGLE** `ADD COLUMN` clause with NO comma list.
  - github.com/trinodb/trino/blob/467/docs/src/main/sphinx/sql/alter-table.md (467 git tag) confirms same single-clause grammar.
  - The responder's `ALTER TABLE iceberg.analytics.events ADD COLUMN feature_1 VARCHAR, ADD COLUMN feature_2 BIGINT, ADD COLUMN feature_3 DOUBLE;` would fail with a parse error at the first comma. Correct Trino 467 form is **three separate `ALTER TABLE` statements** (or run as a multi-statement script). NOTE: Iceberg-Spark SQL extension supports `ALTER TABLE t ADD COLUMNS (a T, b T, c T)` plural-with-parens, and Postgres/MySQL support comma-separated multi-operation `ALTER TABLE` — both are likely importation paths for this slip. Neither is Trino 467 syntax.
  - **Defect classification: responder one-off, NOT resource-sourced.** Grep of `resources/` for `ADD COLUMN.*,\s*ADD COLUMN` returned ZERO matches. The only place `ADD COLUMNS` (plural) appears in resources is r13 Pattern B Spark-side context (`ALTER TABLE iceberg.analytics.events ADD COLUMNS (referrer_source VARCHAR)`) which is correctly attributed to Iceberg-Spark extension syntax and NOT presented as a Trino form. r17 §603 already defangs the `ADD COLUMN ... FIRST | AFTER` post-467 grammar — a parallel "comma-separated multi-ADD-COLUMN" defang row would be the canonical LIGHT FIX-A site if this slip recurs.

- **Q4 MERGE … UPDATE SET ***: minor secondary slip. Trino 467 MERGE supports `WHEN MATCHED THEN UPDATE SET col1 = expr1, col2 = expr2` (explicit assignments) — there is **no `UPDATE SET *` shortcut** in Trino MERGE syntax (that's a Snowflake/Databricks construct). Responder's phrasing "MERGE … UPDATE SET * includes them next run" is ambiguous (could be read as "any MERGE statement that lists the new columns explicitly"); I am not double-penalizing because the engineer's question was about DDL impact, not MERGE syntax. Note this as a `feedback_responder_broken_secondary_alternative` style tail-shave: the lead answer is right and the trailing alternative drifts.

- **Q1 dbt snapshot check strategy** — VERIFIED CORRECT:
  - docs.getdbt.com/docs/build/snapshots quoted verbatim: "The `check` strategy is useful for tables which do not have a reliable `updated_at` column. This strategy works by comparing a list of columns between their current and historical values." `check_cols` accepts a LIST of column names OR the string `'all'`. "If `updated_at` isn't set, then dbt automatically falls back to using the current timestamp to track changes." dbt-docs explicitly recommends the list form over `'all'`: "It is better to explicitly enumerate the columns that you want to check."
  - Responder's recommendation (list over 'all' for performance; hash-compare each run; close old row via dbt_valid_to + insert new version) matches dbt-docs verbatim. No defects.

- **Q2 ANALYZE on Iceberg** — VERIFIED CORRECT:
  - trino.io/docs/current/sql/analyze.html synopsis: `ANALYZE table_name [ WITH ( property_name = expression [, ...] ) ]` — **no `TABLE` keyword**. Responder's `ANALYZE iceberg.analytics.events` form correct.
  - trino.io/docs/current/connector/iceberg.html: "The Iceberg connector can collect column statistics using ANALYZE statement." `iceberg.extended-statistics.enabled` catalog property controls extended-stats collection (default on).
  - Iceberg `$files` metadata table exposes `lower_bounds` / `upper_bounds` per data file (auto-collected at WRITE time, not from ANALYZE) — responder's "Iceberg auto-collects min/max per file for skipping but NOT NDV" is accurate (min/max are inherent Iceberg manifest stats; NDV requires ANALYZE → extended statistics → Puffin sidecar files).
  - Iceberg manifest `record_count` is auto-collected → Trino sees row counts WITHOUT ANALYZE. Responder's "row counts come free from Iceberg metadata" is accurate.
  - Realistic-alternative-causes list (partition pruning failure on the +80M rows, small-files decay if no `EXECUTE optimize` between, data skew on join keys) is correct diagnostic framing for a 600M→680M event-volume regression that ballooned 1min→20min. CBO stat-staleness alone rarely causes 20× regression unless the new data shifted the broadcast/partitioned crossover threshold.
  - `EXPLAIN (TYPE DISTRIBUTED)` for inspecting `Join[BROADCAST]` vs `Join[PARTITIONED]` distribution + row estimates is the canonical verification — exactly the right actionable next step.

- **Q3 any_match for array prefix-element search** — VERIFIED CORRECT:
  - trino.io/docs/current/functions/array.html: `any_match(array(T), function(T, boolean)) → boolean`, `all_match(array(T), function(T, boolean)) → boolean`, `none_match(array(T), function(T, boolean)) → boolean`, `filter(array(T), function(T, boolean)) → array(T)`. All native Trino 467 higher-order array functions accepting lambda predicates.
  - `starts_with(s, prefix)` is native Trino 467 per `reference_trino_starts_with_ends_with` pin (verified iter1118 Q3) — `any_match(feature_flags, flag -> starts_with(flag, 'beta_'))` is the canonical idiom and avoids the `UNNEST + LATERAL` rewrite.
  - Responder correctly notes UNNEST is needed only when GROUPING/JOINING on individual elements — a row-level membership predicate is exactly the case where higher-order functions are preferred (single-pass on the array column, no row multiplication).

---

## Per-question scoring

### Q1 — dbt snapshot on customers with no reliable `updated_at`: strategies?
| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.00 | `strategy='check'` correct; `check_cols=[...]` list or `'all'` correct; hash-compare semantic correct; `dbt_valid_to` close + insert new version correct (matches dbt docs verbatim). |
| Beginner clarity | 5.00 | Distinguishes timestamp vs check strategies up-front; explains hash comparison; flags 'all' performance cost. |
| Practical applicability | 5.00 | Engineer has copy-pasteable `config(strategy='check', check_cols=[...])` block + decision rule (list > 'all') + no-`updated_at` required. |
| Completeness | 5.00 | Both strategies named, lists vs 'all' tradeoff, hash detection mechanism. |
| **Q1 average** | **5.0000** | Clean re-probe at the thinnest-margin row. |

### Q2 — 600M→680M event JOIN ballooned 1min→20min: ANALYZE relevant?
| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.00 | Bare `ANALYZE` syntax correct (no `TABLE` keyword); NDV is the key CBO stat; Iceberg auto-min/max in `$files` vs NDV-requires-ANALYZE distinction precise; row-count-from-manifests correct; broadcast vs partitioned crossover hinges on NDV/row-count estimates. |
| Beginner clarity | 5.00 | "MIGHT fix it" framing avoids overpromising; concrete EXPLAIN command for verification. |
| Practical applicability | 5.00 | Runbook-quality: run ANALYZE → re-EXPLAIN → check `Join[BROADCAST]` vs `[PARTITIONED]` + row estimates; if not the cause, fall back to partition-pruning / small-files / skew investigation. Three realistic alternative causes are exactly what a senior engineer would suggest. |
| Completeness | 5.00 | Covers what ANALYZE does, what Iceberg provides for free, when it would fix this, when it wouldn't. |
| **Q2 average** | **5.0000** | CBO/ANALYZE row strengthened, 4.5-threshold margin widens. |

### Q3 — `array<varchar>` rows where some element starts with `'beta_'`: must I UNNEST?
| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.00 | `any_match(arr, x -> starts_with(x, 'beta_'))` is the canonical Trino 467 form; all_match/none_match/filter family correctly listed; "no UNNEST unless grouping/joining on elements" is the precise rule. |
| Beginner clarity | 5.00 | One copyable WHERE clause + explanation of when UNNEST IS needed. |
| Practical applicability | 5.00 | Direct copy-paste; single-pass on the array column, no row multiplication. |
| Completeness | 5.00 | Higher-order family covered; UNNEST trade-off framed. |
| **Q3 average** | **5.0000** | Clean. |

### Q4 — Add 3 columns to 18-month Iceberg table: does Trino rewrite files / lock / break downstream?
| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 3.25 | Conceptual claims (metadata-only / instant / no rewrite / no lock / old rows NULL / downstream not broken / `SELECT *` picks up) **all correct** per Iceberg semantics; r09 §153 myth-buster verbatim. BUT the copy-pasteable DDL `ALTER TABLE … ADD COLUMN a T1, ADD COLUMN b T2, ADD COLUMN c T3` is a **PARSE ERROR on Trino 467** — `ALTER TABLE` grammar allows exactly ONE `ADD COLUMN` clause per statement (verified raw 467 source and rendered docs). Engineer would copy-paste and hit a syntax error. Minor secondary: `MERGE … UPDATE SET *` is not Trino syntax (Snowflake-ism). |
| Beginner clarity | 4.75 | Explanation is clear; failure mode is the syntax not the framing. |
| Practical applicability | 3.25 | Recipe-as-presented errors on copy-paste; engineer must then figure out three separate `ALTER TABLE` statements. Conceptual answer is what was asked, so partial credit. |
| Completeness | 4.75 | Covers all three engineer concerns (rewrite/lock/downstream) plus SELECT * / explicit-column / MERGE follow-ups. |
| **Q4 average** | **4.0000** | Conceptual right, copyable DDL wrong. Responder one-off, NOT resource-sourced. |

---

## Score table

| Q | Topic mapping | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|---|
| Q1 | dbt-snapshots-SCD2 | 5.00 | 5.00 | 5.00 | 5.00 | 5.0000 |
| Q2 | CBO / ANALYZE / Puffin / NDV / join ordering | 5.00 | 5.00 | 5.00 | 5.00 | 5.0000 |
| Q3 | Analytical query patterns on Iceberg+Trino (array higher-order) | 5.00 | 5.00 | 5.00 | 5.00 | 5.0000 |
| Q4 | Lakehouse schema design (Iceberg ADD COLUMN metadata-only) | 3.25 | 4.75 | 3.25 | 4.75 | 4.0000 |

**Iteration average = (5.0000 + 5.0000 + 5.0000 + 4.0000) / 4 = 4.7500 STRONG PASS** (margin +1.25 above 3.5).

---

## Defects, classification, and recommendation

### Defect 1 — Q4 multi-clause `ADD COLUMN` in one `ALTER TABLE`

- **Severity**: significant on the copy-pasteable artifact (DDL); conceptual answer fully correct.
- **Source**: NOT in `resources/` (grep `ADD COLUMN.*,\s*ADD COLUMN` returns zero hits; r13 uses `ADD COLUMNS (...)` plural correctly attributed to Iceberg-Spark extension; nowhere in the corpus does a Trino-context example use comma-separated multi-clause).
- **Classification**: **responder one-off, IMPORTED-PRIOR family** — same shape as the recurring Postgres/MySQL multi-operation `ALTER TABLE` habit, parallel to `MEMORY.md` entries for `reference_trino_starts_with_ends_with`, `reference_trino_listagg_native`, `reference_trino_trim_charset`, `reference_trino_bitwise`, `reference_trino_to_char_exists`, `reference_trino_count_distinct_single_arg` (foreign-dialect operator/clause-list habits imported into Trino).
- **Recommendation**: **NO-OP + WATCH STREAM** (first instance; matches the iter1116 ts-minus-ts / iter1107 half-pull initial-handling pattern).
  - Re-probe in next 2-3 iters with another "add multiple columns at once" framing (e.g. "we need to backfill 4 nullable columns from Spark — what's the DDL?" or "rename + add in one alter — possible?") to confirm per-instance vs structural.
  - If RECURS: **LIGHT FIX-A** = add ONE row to the r17 §603 schema-evolution-defang table (already defangs `ADD COLUMN ... FIRST | AFTER` post-467 grammar) with `ALTER TABLE x ADD COLUMN a T1, ADD COLUMN b T2` → "Parse error on Trino 467. ALTER TABLE allows a single ADD COLUMN clause per statement. Use three separate `ALTER TABLE` statements, one per column." Include the inline-WRONG defang per `feedback_defang_donotwrite_snippets` (mark the wrong form un-copyable, keep the three-statement canonical as the copy-attractive block).
  - Do **NOT** add new content this iter — first-instance imported-prior slips on long-stable canonical territory don't durably benefit from additive content per `feedback_synthesis_ceiling_stop_churning`.

### Defect 2 — Q4 `MERGE … UPDATE SET *`

- **Severity**: minor (trailing parenthetical aside, not the main answer).
- **Source**: NOT in `resources/`.
- **Classification**: `feedback_responder_broken_secondary_alternative` — the lead answer is right and the trailing alternative drifts into Snowflake-isms. Single-instance, no edit.
- **Recommendation**: NO-OP. Per `feedback_responder_broken_secondary_alternative`, these padding slips don't benefit from a single resource fix; re-probe scope is per-instance.

---

## Topic updates (will be applied to rubric.md)

- **dbt snapshots SCD2** (was thin-margin re-probe target): 4.0315/14 → (56.441 + 5.0)/15 = **4.0961/15 PASSED** (+0.0646; margin to 3.5 widens from +0.5315 to +0.5961). Confirms iter1112→1113 r27/r28/r09 dbt-snapshot signpost FIX-A continues to land cleanly on a 2nd consecutive re-probe (iter1113 was 1st re-probe). Row no longer the 2nd-thinnest.
- **CBO / ANALYZE / Puffin / NDV / join ordering** (raised threshold 4.5): 4.5716/20 → (91.432 + 5.0)/21 = **4.5920/21 PASSED** (+0.0204; margin to raised 4.5 widens from +0.0716 to +0.0920). Fragile-PASS row strengthens.
- **Analytical query patterns on Iceberg+Trino** (Q3 array higher-order): 4.4465/74 → (329.041 + 5.0)/75 = **4.4539/75 PASSED** (+0.0074).
- **Lakehouse schema design** (Q4 ADD COLUMN metadata-only): 4.5624/15 → (68.436 + 4.0)/16 = **4.5273/16 PASSED** (-0.0351; margin to 3.5 = +1.027 still ample). Q4 syntax slip drags this row but conceptual claims preserve PASSED status comfortably.

All required topics REMAIN PASSED. Federation untouched (4.50244/312 fragile-PASS preserved).

---

## Pattern observations & teacher guidance

1. **6 consecutive STRONG-PASS iters (1090, 1092, 1093, 1117, 1118, 1119) now break with iter1120 = 4.7500** — still a STRONG PASS but ends the ≥4.9 run. The break is a first-instance imported-prior responder slip on copy-pasteable DDL, not a content-lineage erosion. The conceptual canonical (`ADD COLUMN is metadata-only`, r09 §153) reaches cleanly; only the example's syntax pattern slipped to Postgres-style multi-clause.
2. **The CBO/ANALYZE topic answer was textbook** — the responder explicitly distinguished what Iceberg auto-tracks (row counts from manifests, min/max from `$files`) from what requires ANALYZE (NDV / extended stats), and named the actionable verification step (`EXPLAIN (TYPE DISTRIBUTED)` to inspect distribution). This is exactly the depth-of-diagnosis a SaaS engineer needs for a 20× regression and signals the iter160 CBO topic recovery has matured durably.
3. **Q1 thin-margin re-probe (dbt-snapshots-SCD2)**: clean delivery 2nd re-probe after iter1113 — the dbt-snapshot signpost FIX-A lineage from iter1100/1102/1112/1113 is durable. No edits warranted; row continues to climb. Next probe angle could be `dbt_is_deleted` hard-delete handling (4 docs entries in MEMORY suggest this is the next durability angle), `check_cols` edge case with NULL values, or Type1/Type2 hybrid materialization.
4. **The Q4 imported-prior slip is the same family as the recurring foreign-dialect-syntax cards in MEMORY.md** (starts_with/ends_with, listagg, trim charset, bitwise, to_char, count-distinct-multi-arg, etc.). Pattern: Haiku responder occasionally imports Postgres/MySQL/Spark/Snowflake DDL/syntax habits into Trino answers when no inline defang exists. The r17 §603 schema-evolution-defang table is the right home for a multi-clause-ADD-COLUMN defang IF this recurs. **Do NOT preemptively edit** — first-instance NO-OP + WATCH, two-instance LIGHT FIX-A per established pattern.
5. **No defects in the** `reference_trino_*` **pin family this iter** other than the new multi-clause-ADD-COLUMN candidate (which is too early to pin). No QUALIFY/false-semi-join/regex-backslash/CAST-truncate/EXECUTE-rollback-on-467/Spark-Oracle-spillover/imported-prior-GREATEST-NULL/`array_sum`/`->`-`->>`-JSON/DATEDIFF/multi-arg-COUNT-DISTINCT/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning slips appeared.
6. **Recommendation summary**: NO-OP this iter; commit rubric+feedback only. Re-probe queue: (1) multi-column ADD COLUMN re-probe in next 2-3 iters (different framing — backfill multi-add, ALTER+ADD-in-one, ADD with FIRST/AFTER together) to scope the imported-prior slip; (2) dbt-snapshots-SCD2 16th angle (dbt_is_deleted hard-delete CDC); (3) storage-tiering 8th datapoint (3.7679/7, still thinnest); (4) cost-considerations 22nd angle. Federation + CBO/ANALYZE durability preserved.

---

## Verdict

**4.7500 STRONG PASS — NO-OP + WATCH STREAM on Q4 multi-clause ADD COLUMN imported-prior slip.** All four required-topic rows touched this iter REMAIN PASSED. Re-probe the Q4 syntax shape from a different angle in the next 2-3 iters; LIGHT FIX-A (one-row addition to r17 §603 schema-evolution-defang table) ONLY on confirmed recurrence.
