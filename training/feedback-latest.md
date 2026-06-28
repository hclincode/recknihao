# Iteration 1232 — Judge Feedback

**Verdict: 4.41 PASS (margin +0.91).** Q1 + Q2 + Q4 clean technically. **Q3 is a borderline FAIL (3.375) on a real internal contradiction**: the schema.yml YAML example shows `- test_column_order:` but the trailing prose says "call without test_ prefix in schema.yml" — engineer who copies the YAML literally hits `Could not find generic test 'test_test_column_order'` at dbt parse. Iter average = (4.625 + 4.875 + 3.375 + 4.75)/4 = 17.625/4 = **4.40625**.

- **Q3 schema.yml `test_` prefix self-contradiction (NEW LIGHT FIX-A WARRANTED).** Responder defined macro `{% macro test_column_order(...) %}` in `macros/test_column_order.sql` (legacy form, STILL backward-compatible per docs.getdbt.com), then wrote schema.yml `- test_column_order: {column_a: end_date, ...}` AND prose "call without test_ prefix in schema.yml." Mechanism: when dbt sees a generic-test name in schema.yml, it looks up the macro `test_<name>` (prepending `test_`). So schema.yml `- test_column_order:` makes dbt look up macro `test_test_column_order` — not found, parse error. Correct YAML: `- column_order: {column_a: end_date, column_b: start_date, operator: ">"}`. The prose IS right; the example contradicts it. **VERIFIED**: at [docs.getdbt.com/best-practices/writing-custom-generic-tests](https://docs.getdbt.com/best-practices/writing-custom-generic-tests) — "macro name = `test_<name>`, but call it by `<name>` in schema.yml (drop the prefix)." **GREP EVIDENCE — content gap (not resource defect)**: grep across resources/ for `test_column|macros/test_|generic test.*macro|legacy.*test_|tests/generic` returns ZERO hits; r27 only covers `accepted_values` + source freshness, not custom generic tests. Responder is doing best-effort recall without a strong anchor. **LIGHT FIX-A SPEC**: additive card to r27 (or r28) — "custom generic test for cross-column / multi-arg comparison" with: (a) modern preferred form `{% test column_order(model, column_a, column_b, operator) %}` block in `tests/generic/column_order.sql`; (b) legacy form `{% macro test_column_order(...) %}` in `macros/test_column_order.sql` STILL backward-compatible; (c) schema.yml call `- column_order: {column_a: ..., column_b: ..., operator: ...}` — **DROP the `test_` prefix in YAML** (dbt prepends it automatically when resolving); (d) DO-NOT-WRITE defang `- test_column_order:` in schema.yml (causes `Could not find generic test 'test_test_column_order'` parse error); (e) singular test path (`tests/test_dim_subscriptions_date_order.sql` — `SELECT * FROM ref WHERE end_date <= start_date`, rows = FAIL) as the simpler one-off; (f) keyword anchors: "custom generic test / reusable test / cross-column comparison / end_date < start_date / schema.yml test args / generic test macro / tests/generic folder / drop test_ prefix in schema.yml". Watch label: `iter1232 r27 custom-generic-test-schema.yml-test_-prefix-drop FIX-A`; re-probe within 4-8 iters with structurally different framing ("custom test that takes two column names" / "reusable test for `created_at < expires_at` cross-column compare").
- **Q1 minor framing nuance (NOT load-bearing).** Responder said "default 7-day snapshot retention (`iceberg.expire-snapshots.min-retention` default 7d); expire_snapshots physically deletes old snapshots; within 7 days recovery always possible." Strictly: `iceberg.expire-snapshots.min-retention` is the SAFETY FLOOR enforced when expire_snapshots IS invoked — not an auto-expiration clock. **Iceberg does NOT auto-expire snapshots** (verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) verbatim "Regularly expiring snapshots is recommended"). So until SOMEONE runs `expire_snapshots`, ALL historical snapshots remain queryable indefinitely. The 7d minimum just guarantees that even if a scheduled `expire_snapshots` runs, the LAST 7 DAYS of snapshots cannot be nuked. The framing "within 7 days recovery always possible" lands the right SAFE-WINDOW guarantee but implies a hard expiration clock at 7d that doesn't actually exist. Engineer's load-bearing action (rollback NOW within the safety window) is correct. Recall ceiling, NO FIX-A.
- **Q2 minor parse-error overstating (NOT load-bearing).** Responder said "don't mix comma+CROSS JOIN keyword (parse error)" when describing the two valid UNNEST forms. Strictly, mixing `FROM t1, t2 CROSS JOIN UNNEST(...)` is a precedence/binding ambiguity, not always a hard parse error. The recommendation to pick ONE form is sound; the "parse error" wording is slightly overstated. Recall ceiling, NO FIX-A.
- **Q1/Q2/Q4 clean otherwise.** Q1 rollback_to_snapshot 3-arg form CORRECT (Trino 467 = CALL form; ALTER TABLE EXECUTE rollback is 469+ per pinned `reference_trino_rollback_snapshot_form.md`); `$history` columns CORRECT (made_current_at/snapshot_id/parent_id/is_current_ancestor verified); "no position-delete files / no bloat from rollback" CORRECT (rollback is metadata-pointer move). Q2 UNNEST + WITH ORDINALITY canonical pin-perfect — 1-based BIGINT ordinal added LAST, alias shape `AS t(tag, position)`, LEFT JOIN UNNEST...ON TRUE for empty-array preservation. Q4 no ROWNUM + no QUALIFY + ROW_NUMBER OVER PARTITION BY + WHERE rn=1 + stable tiebreaker — all correct against Trino 467 docs.

Per-question summary:
- **Q1 4.625** — rollback_to_snapshot 3-arg CALL form + `$history` query + atomic metadata semantics + safety window all correct; "default 7-day retention" framing slight overstate (it's the expire_snapshots safety FLOOR, snapshots don't auto-expire).
- **Q2 4.875** — UNNEST WITH ORDINALITY canonical clean; "comma+CROSS JOIN mix = parse error" slight overstate but recommendation sound.
- **Q3 3.375 (BORDERLINE FAIL — LIGHT FIX-A)** — singular test correct; legacy macro form correct (still backward-compatible); prose "drop test_ prefix in schema.yml" correct; **YAML example contradicts the prose** — `- test_column_order:` in schema.yml would parse-error.
- **Q4 4.75** — ROW_NUMBER OVER PARTITION BY canonical clean; no QUALIFY in Trino 467 verified; tiebreaker note good.

**FIX-A: ONE additive card to r27 (or r28) — custom generic test name-prefix drop in schema.yml.** Per `feedback_responder_broken_secondary_alternative.md` family the slip is in the load-bearing example (engineer explicitly asked "schema.yml reference with the two column args"), not in a secondary "for completeness" appendage — so it's worth a content fix, not just per-instance churn. Content gap confirmed: ZERO resource hits for custom-generic-test name-prefix-drop in schema.yml. Light additive card. Watch label `iter1232 r27 custom-generic-test-schema.yml-test_-prefix-drop`.

---

## Q1 — Recover after bad DELETE wiped ~3M rows from `iceberg.analytics.fct_events`. Can rows be recovered, what to run, and is there a time window?

**Score: 4.625** — Acc 4.5 / Clar 4.5 / App 5.0 / Compl 4.5

Responder shape:
- **YES recoverable.** Iceberg snapshots are immutable; DELETE created a new snapshot, the prior data files still exist on MinIO until `expire_snapshots` is run.
- **Step 1 — Find pre-DELETE snapshot via `$history`**:
  ```sql
  SELECT made_current_at, snapshot_id, parent_id, is_current_ancestor
  FROM iceberg.analytics."fct_events$history"
  ORDER BY made_current_at;
  ```
- **Step 2 — Rollback (Trino 467 native CALL form)**:
  ```sql
  CALL iceberg.system.rollback_to_snapshot('analytics', 'fct_events', <snapshot_id>);
  ```
- **Semantics**: atomic metadata pointer move, instant, no data files touched, no position-delete files written, no table bloat.
- **Time window**: default safety floor `iceberg.expire-snapshots.min-retention = 7d`; within 7 days recovery always possible. Check `$snapshots` for the target.
- **Anti-pattern**: explicitly told engineer NOT to use `CREATE OR REPLACE TABLE ... AS SELECT * ... FOR VERSION AS OF <snapshot>` — rollback CALL is simpler/atomic.

**Load-bearing facts VERIFIED:**

1. **`CALL iceberg.system.rollback_to_snapshot('schema','table',id)` is the Trino 467 form** — verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) verbatim `CALL example.system.rollback_to_snapshot('testdb', 'customer_orders', 8954597067493422955)`. ALTER TABLE EXECUTE rollback_to_snapshot is 469+ per pinned `reference_trino_rollback_snapshot_form.md`. Responder correctly routes to the 467 form.
2. **`$history` columns: `made_current_at`, `snapshot_id`, `parent_id`, `is_current_ancestor`** — verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) (WebFetched this iter). All four column names match.
3. **`iceberg.expire-snapshots.min-retention` default 7d** — verified at trino.io/docs/467/connector/iceberg.html: "The minimal retention period for the `expire_snapshots` command" — default `7d`.
4. **Rollback is atomic metadata pointer move, no data-file writes, no position-delete files** — Iceberg architecture (snapshot pointer in metadata.json). Correct.
5. **CTAS-FROM-VERSION alternative explicitly defanged** — engineer told NOT to do the heavier copy-out, use rollback. Correct routing.

**Minor framing slip (Acc -0.5, Compl -0.5):** Responder said "default 7-day snapshot retention" implying a hard auto-expiration clock. **Iceberg does NOT auto-expire snapshots** (verified docs verbatim "Regularly expiring snapshots is recommended"). The 7-day default is the safety FLOOR enforced when `expire_snapshots` IS invoked — guarantees the last 7 days of snapshots cannot be nuked by accident. Until someone runs `expire_snapshots`, all snapshots remain queryable indefinitely. Engineer's actionable take-away (rollback NOW within the safety window) is still correct, but the "you have 7 days" framing might mislead an engineer who thinks the clock is ticking automatically. Recall ceiling, NO FIX-A — too minor.

Engineer leaves with: one `$history` SELECT + one `CALL rollback_to_snapshot(...)` + atomic semantics confidence. Cites r17/r13. **Topic routed to "Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup"** (rollback is the snapshot-history maintenance lever).

---

## Q2 — Unnest a `tags` array (array of strings) to one row per tag keeping `event_id` AND the position/index of each tag in its original array.

**Score: 4.875** — Acc 4.5 / Clar 5.0 / App 5.0 / Compl 5.0

Responder shape:
- **Canonical form**:
  ```sql
  SELECT event_id, t.tag, t.position
  FROM events
  CROSS JOIN UNNEST(tags) WITH ORDINALITY AS t(tag, position);
  ```
- **1-based BIGINT ordinal added LAST in the alias list** — must provide two aliases `AS t(tag, position)`, position cannot be omitted from the alias when WITH ORDINALITY is used.
- **Repeated-tag gets its TRUE position** (e.g., `tags=['x','y','x']` → positions 1, 2, 3 — not restarted).
- **Two valid forms**:
  - Explicit `CROSS JOIN UNNEST(...) WITH ORDINALITY AS t(...)` (canonical, recommended).
  - Comma-form `FROM events, UNNEST(tags) WITH ORDINALITY AS t(tag, position)` (legacy SQL implicit-join, also valid).
  - Don't mix comma + CROSS JOIN keyword (parse error per responder framing).
- **Empty/NULL array preservation**:
  ```sql
  LEFT JOIN UNNEST(tags) WITH ORDINALITY AS t(tag, position) ON TRUE
  ```
  (Rows with NULL/empty `tags` kept; ordinal padded with NULL.)

**Load-bearing facts VERIFIED:**

1. **UNNEST WITH ORDINALITY syntax + ordinal-LAST** — verified at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) verbatim "an additional ordinality column is added to the end" + docs example `UNNEST(...) WITH ORDINALITY AS t(a, b, rownumber)`. Matches r07 §156-186 pinned canonical.
2. **1-based ordinal** — confirmed by docs example output rows `1, 2, 3`.
3. **LEFT JOIN UNNEST(...) WITH ORDINALITY AS t(...) ON TRUE** — verified at the leftjoin.com / mrpbennett.dev blog explicitly demonstrates `LEFT JOIN UNNEST(...) ON TRUE` for preserving empty arrays; combining with `WITH ORDINALITY` is the standard idiom.
4. **Comma-form valid** — implicit-cross-join SQL-92 legal in Trino, equivalent to `CROSS JOIN`.

**Minor slip (Acc -0.5):** "Don't mix comma+CROSS JOIN keyword (parse error)" — strictly, mixing the two forms in the same FROM clause is a precedence/binding ambiguity issue (`FROM t1, t2 CROSS JOIN UNNEST(...)` will parse but binding may not be what the writer expected because comma binds tighter than explicit JOIN keywords). Calling it a hard parse error is slightly overstated. The recommendation to pick ONE form is sound, the wording is imprecise. Not load-bearing because the responder's two explicit examples (CROSS JOIN and comma alone) are both correct.

Engineer leaves with: one CROSS JOIN UNNEST WITH ORDINALITY query + understanding of 1-based position semantics + LEFT JOIN variant for empty-array preservation. Cites r07. **Topic routed to "Analytical query patterns on Iceberg+Trino"** (UNNEST is the array-explode analytical canonical, same routing as iter1176 Q2).

---

## Q3 — Custom generic dbt test that fails if any `dim_subscriptions` row has `end_date <= start_date` (cross-column comparison, no built-in covers it). Where the file goes, the macro, schema.yml reference with the two column args.

**Score: 3.375 (BORDERLINE FAIL — LIGHT FIX-A)** — Acc 3.0 / Clar 3.5 / App 3.0 / Compl 4.0

Responder shape:
- **Path A — Singular test in `tests/test_dim_subscriptions_date_order.sql`**:
  ```sql
  SELECT * FROM {{ ref('dim_subscriptions') }} WHERE end_date <= start_date
  ```
  Rows returned = FAIL. **CORRECT.**
- **Path B — Reusable generic test macro in `macros/test_column_order.sql`**:
  ```jinja
  {% macro test_column_order(model, column_a, column_b, operator) %}
  SELECT * FROM {{ model }} WHERE NOT ({{ column_a }} {{ operator }} {{ column_b }})
  {% endmacro %}
  ```
  **Macro definition CORRECT** (legacy form, still backward-compatible per docs.getdbt.com).
- **schema.yml example**:
  ```yaml
  models:
    - name: dim_subscriptions
      tests:
        - test_column_order: {column_a: end_date, column_b: start_date, operator: ">"}
  ```
  **THIS IS WRONG.** schema.yml call should be `- column_order:` (DROP the `test_` prefix); dbt internally prepends `test_` when resolving the macro. As written, dbt looks up macro `test_test_column_order` → "Could not find generic test 'test_column_order'" parse error.
- **Trailing prose**: "Said generic macros live in macros/ (NOT tests/), name file test_*.sql, **call without test_ prefix in schema.yml**; can add config: severity/store_failures."
  Prose says "call without test_ prefix." Example contradicts the prose.

**Load-bearing facts CHECKED:**

1. **Singular test path A correct** — `tests/<name>.sql` file with a SELECT that returns failing rows; rows returned = FAIL is the dbt singular-test convention. Verified at [docs.getdbt.com/docs/build/data-tests](https://docs.getdbt.com/docs/build/data-tests).
2. **Legacy macro form STILL backward-compatible** — verified at [docs.getdbt.com/best-practices/writing-custom-generic-tests](https://docs.getdbt.com/best-practices/writing-custom-generic-tests) (WebFetched this iter): "Why? Generic tests work a lot like macros, and historically, this was the only place they could be defined." Macro form survives; modern preferred form is `{% test column_order(...) %}` block in `tests/generic/`.
3. **schema.yml call DROPS the `test_` prefix** — verified at docs.getdbt.com: "When *calling* the test in `.yml`, you use the name *without* the prefix." dbt resolves `- column_order:` in YAML by looking up macro `test_column_order`. Correct YAML: `- column_order: {column_a: end_date, column_b: start_date, operator: ">"}`.
4. **Responder's macro `test_column_order(model, column_a, column_b, operator)`** + YAML `test_column_order:` → dbt looks up `test_test_column_order`, NOT FOUND, parse-error halt.

**Defect mechanism**: engineer who copies the YAML literally hits a `Could not find generic test 'test_column_order'` (or similar) error at `dbt parse` / `dbt test`. A careful engineer who reads to the trailing prose ("call without test_ prefix") notices the contradiction and applies the prose rule — but copy-pasta engineers fail.

**Grep evidence — content gap, NOT resource defect:** searched resources/ for `test_column`, `macros/test_`, `generic test.*macro`, `legacy.*test_`, `tests/generic`, `{% test |{% macro test_` → ZERO hits across all files. r27 covers `accepted_values` + source freshness + `relationships` + model contracts but does NOT have a canonical for "custom generic test with cross-column comparison." Responder is doing best-effort recall against an empty resource anchor.

**LIGHT FIX-A SPEC**:
- Add additive card to r27 (or r28) titled "Custom generic test for cross-column / multi-arg comparison (e.g., `end_date > start_date`)."
- Content:
  - **Modern preferred form** (dbt 0.20+): `{% test column_order(model, column_a, column_b, operator) %}` block in `tests/generic/column_order.sql`.
  - **Legacy form** (still backward-compatible): `{% macro test_column_order(model, column_a, column_b, operator) %}` block in `macros/test_column_order.sql`.
  - **schema.yml call (BOTH forms)**: `- column_order: {column_a: end_date, column_b: start_date, operator: ">"}` — **DROP the `test_` prefix in YAML** (dbt prepends it automatically when resolving the macro/test block).
  - **DO-NOT-WRITE defang**: `- test_column_order:` in schema.yml → dbt looks up `test_test_column_order`, parse error "Could not find generic test 'test_column_order'."
  - **Singular test alternative** (simpler when you don't need reusability): `tests/<name>.sql` SELECT statement; rows = FAIL.
  - **Keyword anchors**: "custom generic test / reusable test / cross-column comparison / end_date < start_date / created_at < expires_at / schema.yml test args / generic test macro / tests/generic folder / drop test_ prefix in schema.yml / Could not find generic test."
- Watch label: `iter1232 r27 custom-generic-test-schema.yml-test_-prefix-drop FIX-A`; re-probe within 4-8 iters with structurally different framing ("custom test that takes two column names" / "reusable test for `created_at < expires_at` cross-column compare" / "WHERE one column must be less than another column").

**Topic routed to "dbt model contracts"** (structurally identical data-integrity declaration as model-contracts family, same routing as iter1216 Q3 relationships and iter1218/1221/1229 Q3 accepted_values+not_null).

---

## Q4 — Oracle ROWNUM has no Trino equivalent; LIMIT covers simple cases but Oracle used ROWNUM in subqueries for first-row-per-group. Trino equivalent / Nth-row-within-group?

**Score: 4.75** — Acc 5.0 / Clar 4.5 / App 5.0 / Compl 4.5

Responder shape:
- **`ROWNUM <= 10` → `LIMIT 10`** (simple top-N).
- **First-row-per-group** (Trino canonical):
  ```sql
  SELECT *
  FROM (
    SELECT *,
      ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY occurred_at DESC, event_id) AS rn
    FROM events
  )
  WHERE rn = 1;
  ```
- **No ROWNUM pseudo-column in Trino** — parse error if you try `WHERE ROWNUM <= 10`.
- **No QUALIFY in Trino 467** — must wrap subquery + filter rank in WHERE.
- **Stable tiebreaker** in ORDER BY (e.g., `event_id`) for reproducibility across runs when multiple rows tie on the primary order column.

**Load-bearing facts VERIFIED:**

1. **Trino has no ROWNUM pseudo-column** — TRUE (ROWNUM is Oracle-specific; Trino has no equivalent pseudo-column). Translated via ROW_NUMBER window function.
2. **`ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)`** — verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html). Standard ranking window function.
3. **Trino 467 has no QUALIFY** — verified via WebSearch (Trino feature request open on Starburst forum May 2024, no implementation in 467 release notes). Engineer must wrap window-function rank in subquery + filter in outer WHERE.
4. **Stable tiebreaker note** — best practice, prevents non-deterministic results when primary order has ties. Good recall.
5. **Translation of `ROWNUM <= 10` → `LIMIT 10`** — correct for simple top-N; doesn't preserve the `ROWNUM` column itself but Oracle ROWNUM-without-PARTITION-BY use cases are typically just row caps.

**Minor Compl shave (-0.5):** Didn't mention `RANK()` / `DENSE_RANK()` as alternatives when "first" means "all tied first rows" (e.g., latest event including all events with the max timestamp). For most "first-row-per-group" use cases ROW_NUMBER is correct, but the tie-handling nuance is worth a one-liner. Recall ceiling, NO FIX-A.

**Minor Clar shave (-0.5):** "Wrap subquery" phrasing assumes engineer knows that window functions can't appear in WHERE — a one-sentence "Window functions are evaluated AFTER WHERE, so you can't `WHERE row_number() OVER ... = 1` directly; wrap in a subquery and filter outside" would zero-assumption it. Not load-bearing.

Engineer leaves with: one ROW_NUMBER OVER PARTITION BY template + tiebreaker discipline + no-QUALIFY workaround mental model. Cites r27. **Topic routed to "Oracle PL/SQL → dbt + Trino SQL migration"** (Oracle-to-Trino dialect translation, ROWNUM is exactly the Oracle-specific construct that doesn't translate naively).

---

## Topic score updates (this iteration)

| Topic | Q | Score | Update |
|---|---|---|---|
| Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup | Q1 | 4.625 | 4.4387/228 → (1011.96 + 4.625)/229 = 1016.585/229 = **4.4393/229 PASSED** (+0.0006, margin +0.9393) |
| Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL | Q2 | 4.875 | 4.5731/164 → (749.99 + 4.875)/165 = 754.865/165 = **4.5749/165 PASSED** (+0.0018, margin +1.0749) |
| dbt model contracts (custom generic test routing) | Q3 | 3.375 | 4.4979/14 → (62.9706 + 3.375)/15 = 66.3456/15 = **4.4230/15 PASSED** (-0.0749, margin +0.9230, still comfortable) |
| Oracle PL/SQL → dbt + Trino SQL migration | Q4 | 4.75 | 4.4558/197 → (877.79 + 4.75)/198 = 882.54/198 = **4.4573/198 PASSED** (+0.0015, margin +0.9573) |

**FIX-A: LIGHT.** ONE additive card to r27 (or r28) — custom generic test schema.yml-call drop-test_-prefix rule + DO-NOT-WRITE defang of `- test_<name>:` in YAML + modern `{% test %}` block vs legacy `{% macro test_<name> %}` form noting BOTH back-compatible. Watch label `iter1232 r27 custom-generic-test-schema.yml-test_-prefix-drop`; re-probe 4-8 iters with cross-column-compare framing.

**OPEN WATCHES (carried):** iter1231 NEXT_DAY-closing-note-contradicts (soft); iter1230 EXISTS-over-warning; iter1229 @v1-Spark-syntax; iter1215 strpos-3-arg CEILING (no churn); iter1213 session_properties + (+)-mnemonic; iter1208 width_bucket-boundary.

**NEW WATCH iter1232**: r27 custom-generic-test-schema.yml-test_-prefix-drop FIX-A (re-probe 4-8 iters).

**Overall: 4.41 PASS** — all topics still passing healthy margins; Q3 borderline-fail is content-gap-fueled (not recall slip) so a content fix is appropriate, not just per-instance re-probe.
