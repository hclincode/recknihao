# Iter 1207 — 4.78 STRONG PASS NO-OP (LIGHT engine-dialect inline-tag soft watch on Q1)

## Per-question scoring

### Q1 — First GDPR right-to-be-forgotten: did DELETE actually remove rows, where did data go (user_id NOT a partition column)
- **Acc 4.0 / Clar 3.75 / App 4.25 / Compl 4.5 → 4.125 PASS**
- **Core 3-step MoR mental model PIN-PERFECT**: (1) 3s = position-delete file write, rows hidden, old Parquet still on MinIO; (2) compact/rewrite reads affected files + drops deleted rows + writes clean files (storage TEMPORARILY GROWS because old files still referenced by prior snapshot); (3) expire_snapshots drops the prior snapshot pointer so the now-unreferenced old data + delete files leave MinIO bytes-on-disk. `retain_last => 1, older_than => interval '0' day` for instant erasure correctly named.
- **Engine-dialect inline-tag clarity ding (the ONLY ding)**: responder used Spark-Iceberg-procedure syntax `CALL iceberg.system.rewrite_data_files(table => 'analytics.events')` + `CALL iceberg.system.expire_snapshots(table => 'analytics.events', older_than => current_timestamp() - interval '0' day, retain_last => 1)`. **VERIFIED** these are Spark-only NOT in Trino 467: WebFetched [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) Iceberg procedures section lists ONLY `rollback_to_snapshot` / `register_table` / `unregister_table` / `migrate` / `add_files` / `add_files_from_table` — NO `rewrite_data_files`, NO `expire_snapshots` procedure form. Trino 467 native equivalents are `ALTER TABLE ... EXECUTE optimize` + `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` with a **7-DAY MINIMUM RETENTION FLOOR** (`iceberg.expire-snapshots.min-retention` default `7d`, verified verbatim "The value for retention_threshold must be higher than or equal to iceberg.expire-snapshots.min-retention").
- **Engine routing IS CORRECT for the literal GDPR-instant ask**: instant sub-7-day GDPR expiry GENUINELY REQUIRES Spark on Trino 467 due to the 7-day floor — Spark is the only engine that can drop a fresh snapshot pointer immediately. Responder DID flag "schedule Steps 2&3 weekly as a Spark job for accumulated soft deletes" so the Spark routing is named at the cadence level.
- **NOT A RESOURCE-SOURCED DEFECT**: r13 §1293-1326 IS the canonical source for this Spark recipe and already labels it as a Spark job. Per the iter1207 judge guidance — "do NOT over-churn if r13 already labels it Spark" — this is a responder inline-labeling clarity ding NOT a resource gap.
- **DECISION on FIX-A**: **NO FIX-A this iter** — soft watch only. The mild defect is that the CALL blocks themselves aren't inline-tagged `[SPARK — NOT TRINO]` and the Trino-EXECUTE-equivalent-for-≥7d-cases + 7-day-min-retention-floor reasoning aren't surfaced as the "why-must-Spark" justification. A beginner pasting `CALL iceberg.system.rewrite_data_files(...)` into the Trino CLI hits "procedure not found." If re-probe shows recurrence, ship a small additive line-tag at r13 §1293-1326: "CALL ... iceberg.system.X procedures are SPARK SQL; Trino 467 native equivalent for ≥7-day expiry is `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold=>'7d')`; instant sub-7-day GDPR expiry needs Spark due to `iceberg.expire-snapshots.min-retention` default `7d` floor." Low over-attractor risk per `feedback_new_card_over_attracts_adjacent` because it's a precise dialect-tag adjacent to existing Spark labeling, not a new concept card.

### Q2 — Monthly signup report w/ plan_tier columns (free_count / starter_count / pro_count / enterprise_count), one row per month
- **Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0 → 5.0 STRONG PASS**
- **Pin-perfect conditional-pivot canonical.** Two equivalent Trino 467 forms taught: (a) `SUM(CASE WHEN plan_tier='free' THEN 1 ELSE 0 END) AS free_count, ...` GROUP BY `DATE_TRUNC('month', signup_date)`; (b) `COUNT(*) FILTER (WHERE plan_tier='free') AS free_count, ...`.
- **VERIFIED**: (i) Trino 467 has NO native `PIVOT` keyword — [trino.io episode 38 on polymorphic table functions](https://trino.io/episodes/38.html) explicitly notes PIVOT "isn't part of the standard SQL specification" + no `PIVOT` token in [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) grammar; (ii) `FILTER (WHERE ...)` IS supported on all aggregates per [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) verbatim "The FILTER clause may be used to remove rows from an aggregate function's input"; (iii) `date_trunc('month', signup_date)` returns first day of containing month per [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html).
- **Single-pass framing accurate** — conditional aggregation reads the table once with all CASE/FILTER branches evaluated per-row in the same scan; vs the broken 4-subquery + JOIN form that would scan 4 times. Both SUM(CASE WHEN) and COUNT(*) FILTER produce identical result + identical plan in Trino CBO. Engineer leaves with a copy-pasteable monthly SaaS rollup template.

### Q3 — CI dbt --select state:modified+ : what does dbt compare against, what does trailing + mean
- **Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0 → 5.0 STRONG PASS**
- **Pin-perfect dbt state-based selectors canonical for the CI use case.** Five load-bearing facts all correct:
  - (1) **state:modified compares SQL file definition against a PREVIOUS `manifest.json`** — VERIFIED at [docs.getdbt.com/reference/node-selection/methods](https://docs.getdbt.com/reference/node-selection/methods) verbatim: "The state method is used to select nodes by comparing them against a previous version of the same project, which is represented by a manifest";
  - (2) **`--state <path>` points to the previous run's `target/manifest.json`** — common CI pattern: pull from artifact storage or check into repo; VERIFIED verbatim "The --state flag points to the file path of the comparison manifest";
  - (3) **Trailing `+` = downstream graph operator** — selects matched node AND all `ref()`-dependents; VERIFIED verbatim "+ (downstream): Selects a node and all resources that depend on it";
  - (4) **NOT comparing against prod DB runtime state** — directly answers the engineer's "SQL files changed in PR vs prod DB" disambiguation;
  - (5) **`state:new` is the entirely-new-nodes subset** (unique_id absent from comparison manifest) vs `state:modified` which is the superset (new + body-changed + config-changed + contract-changed nodes); responder correctly distinguished them ("Don't confuse with state:new").
- **CI runbook correct**: `dbt run --select state:modified+ --state target/` — production canonical for the 45-min→sub-5-min PR-build optimization.

### Q4 — Oracle DECODE(status, ...) → Trino: does Trino have DECODE or rewrite as CASE WHEN
- **Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0 → 5.0 STRONG PASS**
- **Pin-perfect DECODE→CASE migration canonical with the Oracle-vs-Trino NULL-equality nuance correctly named.** Four load-bearing facts all correct:
  - (1) **Trino 467 has NO `DECODE` function** — VERIFIED at [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html) (listed conditionals: CASE, IF, COALESCE, NULLIF, TRY — DECODE absent);
  - (2) **Simple CASE rewrite**: `CASE WHEN status='A' THEN 'Active' WHEN status='I' THEN 'Inactive' ELSE 'Unknown' END` — drop-in equivalent for the non-NULL case;
  - (3) **NULL-EQUALITY NUANCE CORRECT (the load-bearing migration gotcha)**: Oracle `DECODE` treats `NULL=NULL` as TRUE (special-case Oracle DECODE semantic — `DECODE(col, NULL, 'is null', ...)` matches NULL rows); Trino's simple CASE form uses standard SQL three-valued logic where `NULL = NULL` evaluates to UNKNOWN, so `CASE col WHEN NULL THEN ...` NEVER matches NULL — the `ELSE` branch fires instead, silently corrupting any Oracle DECODE that relied on the NULL-match;
  - (4) **Searched CASE w/ `WHEN col IS NULL THEN ...` as FIRST branch** correctly recommended for any DECODE that had a NULL match arg + audit guidance (grep Oracle source for `DECODE(col, NULL, ...)`).
- **Migration-grade answer that prevents the silent NULL-row miscategorization bug** that bites Oracle→Trino DECODE translations.

## Overall verdict: STRONG PASS NO-OP

Average across all 4: (4.125 + 5.0 + 5.0 + 5.0) / 4 = **4.78 STRONG PASS**

Q2/Q3/Q4 are pin-perfect. Q1 lands the core 3-step MoR delete-then-purge mental model accurately and is production-stack-correct on the Spark routing for the GDPR-instant ask, with only a mild engine-dialect inline-tagging clarity ding on the Spark `CALL` blocks. r13 §1293-1326 already labels the recipe as a Spark job, so the gap is not resource-sourced; this is a responder inline-tagging slip on a recipe with a hard 7-day-floor justification that genuinely requires Spark for the instant case.

## Action

- **NO FIX-A this iter.**
- **NEW SOFT WATCH** `iter1207 r13 §1293-1326 Spark-CALL-inline-tag + Trino-EXECUTE-alt-for-≥7d`: re-probe in 4-8 iters under framing like "GDPR delete + can I run this from the Trino CLI directly or do I need a separate engine?" or "Iceberg snapshot cleanup — Trino-native form vs Spark CALL?". If recurring, light additive line-tag FIX-A at r13 §1293-1326 CALL blocks (text spec above in Q1 section).
- **Carry-forward watches** (unchanged this iter, no triggering questions):
  - light-monitor `iter1199 r17 position-delete-optimize findable-summary` (sibling to Q1's GDPR delete topic; consider whether the iter1207 GDPR-instant Spark-CALL routing reinforces or weakens the iter1199 Trino-only-NOT-stuck framing — they are operationally distinct: iter1199 = ≥7d MoR cleanup Trino-runnable, iter1207 = instant sub-7d GDPR Spark-required; both correct, distinct cases);
  - light-monitor `iter1204 dbt --full-refresh on_table_exists mechanism` (no Q3 trigger this iter — state:modified+ is selectors not materialization);
  - soft watch `iter1206 NVL-COALESCE type-coercion edge case` (no Q4 trigger this iter — DECODE not NVL);
  - soft watch `iter1206 Q1 LIKE-on-ROW + $partitions-omission` (no Q1 trigger this iter — GDPR delete not physical-layout inspection).
- All required topics PASSED with healthy margins.

## Topic rows updated

| Q | Topic row | Before | After |
|---|---|---|---|
| Q1 | Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup | 4.4429 / 215 | 4.4414 / 216 |
| Q2 | Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL | 4.5325 / 148 | 4.5356 / 149 |
| Q3 | Improving complex SQL performance on Trino with dbt | 4.5650 / 38 | 4.5762 / 39 |
| Q4 | Oracle PL/SQL → dbt + Trino SQL migration | 4.4737 / 169 | 4.4768 / 170 |

## Verification trail (citations)

- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — Iceberg procedures list (no rewrite_data_files / no expire_snapshots procedure); ALTER TABLE EXECUTE optimize + expire_snapshots syntax; retention_threshold ≥ `iceberg.expire-snapshots.min-retention` default `7d`
- [trinodb/trino PR #12704](https://github.com/trinodb/trino/pull/12704) — position-delete file mechanism + cleanup during optimize (Q1 mechanism context)
- [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) — no PIVOT in grammar (Q2)
- [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) — FILTER (WHERE ...) clause on all aggregates (Q2)
- [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) — date_trunc('month', ...) (Q2)
- [docs.getdbt.com/reference/node-selection/methods](https://docs.getdbt.com/reference/node-selection/methods) — state:modified vs state:new + manifest comparison + --state flag (Q3)
- [docs.getdbt.com/reference/node-selection/syntax](https://docs.getdbt.com/reference/node-selection/syntax) — `+` downstream graph operator (Q3)
- [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html) — listed conditionals (CASE/IF/COALESCE/NULLIF/TRY), no DECODE (Q4)
