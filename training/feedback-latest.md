# Iteration 1225 — Judge Feedback

**Verdict: 4.875 STRONG PASS — iter1219 format-%08d WATCH CLOSES on first re-probe (15th consecutive 1st-re-probe-close).** Q4 surfaces BOTH the `format('%08d', account_id)` minimum-width sub-canonical AND the `lpad` pads-OR-truncates hazard that iter1219 missed. Q2 (FILTER vs SUM CASE) and Q3 (dbt vars CLI override) are clean 5.0s. Q1 (Iceberg row-level diff) is a 4.5 — the time-travel + FULL OUTER JOIN + IS DISTINCT FROM pattern is CORRECT and is the right tool for the engineer's MoR-with-delete-files scenario, but the responder absolutely denies "Trino 467 has NO native changelog/diff table" when in fact Trino 467 HAS the `table_changes()` table function (see verification below). Practical impact bounded because `table_changes()` itself has documented limitations precisely in the engineer's scenario (no support for snapshots that include delete files), so routing to FULL OUTER JOIN is the right ACTION; but the existence-denial is a factual slip on a non-load-bearing axis.

Per-question summary:
- Q1 4.5 — Time-travel via `FOR VERSION AS OF` both snapshots + FULL OUTER JOIN on PK + `IS DISTINCT FROM` (NULL-safe) classify-INSERT/DELETE/UPDATE pattern correct; `$snapshots` discovery correct; `IS DISTINCT FROM` valid Trino 467; **SLIP: denies existence of `table_changes()` table function** (Trino 467 DOES have it — though it has limitations precisely in this scenario so the FULL OUTER JOIN routing is correct)
- Q2 5.0 — `COUNT(*) FILTER (WHERE priority='low')` per priority correct + SUM(CASE) Oracle-form still valid + no native PIVOT
- Q3 5.0 — Top-level `vars:` in `dbt_project.yml` + `{{ var('lookback_days', 90) }}` + `dbt run --vars '{lookback_days: 7}'` + precedence CLI > project > default + `--vars` plural
- Q4 5.0 — **WATCH CLOSES**: `lpad(varchar, bigint, varchar)` signature + numeric-CAST-first + **PADS-OR-TRUNCATES** hazard + `format('%08d', account_id)` minimum-width Java Formatter alternative

Iter average: (4.5 + 5.0 + 5.0 + 5.0) / 4 = **4.875** STRONG PASS, margin +1.375.

---

## Q1 — Iceberg row-level diff between Monday-night snapshot and now (Spark MERGE INTO every 15min CDC)

**Score: 4.5** — Acc 4.0 / Clar 5.0 / App 5.0 / Compl 4.0

**Scenario.** `accounts` Iceberg table on MoR; Spark `MERGE INTO` every 15min from CDC pipeline. Billing escalation wants row-level diff: inserted / deleted / field-value-changed between Monday-night snapshot and current state. Engineer asks whether Iceberg supports row-level diff or self-join of two snapshot states.

**Load-bearing facts CORRECT (VERIFIED):**

1. **Time-travel both snapshots** — `WITH old_state AS (SELECT ... FROM iceberg.<schema>.accounts FOR VERSION AS OF <old_snapshot_id>), new_state AS (... FOR VERSION AS OF <new_snapshot_id>)`. VERIFIED at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) verbatim: `SELECT * FROM example.testdb.customer_orders FOR VERSION AS OF 8954597067493422955`. `FOR TIMESTAMP AS OF TIMESTAMP '...'` alternative also valid for time-based pinning.
2. **`$snapshots` discovery** — `SELECT snapshot_id, committed_at, operation, summary FROM iceberg.<schema>."accounts$snapshots" ORDER BY committed_at` to find IDs. Columns match docs verbatim.
3. **FULL OUTER JOIN classify pattern** — `CASE WHEN o.account_id IS NULL THEN 'INSERTED' WHEN n.account_id IS NULL THEN 'DELETED' WHEN o.col IS DISTINCT FROM n.col OR ... THEN 'UPDATED' ELSE 'UNCHANGED' END` + `COALESCE(o.account_id, n.account_id)` for the key + filter `WHERE <any col> IS DISTINCT FROM <other col> OR <one side> IS NULL`. Standard analytical diff pattern.
4. **`IS DISTINCT FROM` is NULL-safe** — VERIFIED at [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html) verbatim: "both operators guarantee either a true or false outcome even in the presence of `NULL` input." `NULL IS DISTINCT FROM NULL` evaluates to `FALSE` (they are not distinct).
5. **Two full scans tradeoff** — correctly named as the cost; acceptable for small-medium accounts table; large/wide tables benefit from partition-pruning predicate (e.g., last-N-days `updated_at`) inside each CTE.

**SLIP — `table_changes()` denial** (Acc -1, Compl -1):

Responder said: "Trino 467 has NO native changelog/diff table for row-level comparison between snapshots." **FACTUALLY WRONG**. Trino 467 has an Iceberg `table_changes()` table function — see [trinodb/trino#21227](https://github.com/trinodb/trino/issues/21227) (documentation tracker) + Trino 467 release notes (the breaking change in 467 removed deprecated schema/table args and renamed to `schema_name`/`table_name`). Returns rows with special columns `_change_type` (e.g., `insert`), `_change_version_id`, `_change_timestamp`, `_change_ordinal`. Usage: `SELECT * FROM TABLE(iceberg.system.table_changes(schema_name => 'analytics', table_name => 'accounts', start_snapshot_id => <id>, end_snapshot_id => <id>))`.

**HOWEVER** — `table_changes()` has KNOWN LIMITATIONS that hit the engineer's specific scenario:
- Only reports per-snapshot insert/delete events; does NOT compute net effect across multiple snapshots (a row deleted then reinserted within the range returns BOTH events).
- **Does NOT support snapshots that include delete files** — i.e., MoR position-delete snapshots produced by Spark `MERGE INTO` updates/deletes. The engineer's accounts table getting MERGE INTO every 15min IS exactly this case.

So routing the engineer to **FOR VERSION AS OF + FULL OUTER JOIN + IS DISTINCT FROM is the correct action** for this scenario (table_changes wouldn't help due to delete-file limitation). The slip is the absolute denial of table_changes() existence — a better framing is "Trino 467 HAS `table_changes()` but it doesn't support snapshots containing delete files, which is what your MoR + Spark MERGE pipeline produces — so the workhorse pattern for your case is two time-travel reads + FULL OUTER JOIN diff."

**Resource-source check.** Grep `table_changes` in resources/ for findability gap test (recommended for teacher follow-up). If 0 hits, this is a knowledge gap; could warrant a 5-7 line additive card under r17 / r10 / r28 snapshot-comparison section: "Trino 467 has `iceberg.system.table_changes()` for snapshot-range CDC reading, BUT it does not work on snapshots containing delete files (MoR position-deletes) — for MoR tables use FOR VERSION AS OF + FULL OUTER JOIN + IS DISTINCT FROM diff pattern instead."

**NEW soft watch** `iter1225 Q1 table_changes() existence + delete-file limitation`: re-probe in 4-8 iters under framing like "Iceberg CDC diff between two versions / Iceberg snapshot-to-snapshot change feed" to test whether table_changes() existence + limitation surfaces. If recurs as denial, light additive card. If lands correctly with limitation, recall ceiling (no fix).

**Production-stack fit.** Trino 467 + Iceberg MoR + Spark MERGE writers + HMS — all matches prod_info.md exactly. The recommended FULL OUTER JOIN pattern works on this stack with no Spark dependency for the read (Spark is on the write path only).

Engineer leaves with a working query + correct mental model (Iceberg snapshots persist, `FOR VERSION AS OF` pins both, IS DISTINCT FROM handles NULLs, full-outer-join classifies in/out/changed) but a slightly inflated view of what's NOT available (table_changes() exists with limits).

Cites r10/r17.

---

## Q2 — Per-customer counts per priority (low/medium/high/critical); Oracle SUM(CASE) translation

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Scenario.** `tickets(customer_id, created_at, priority)` where priority is `low|medium|high|critical`. Want one row per customer with `low_count / medium_count / high_count / critical_count`. Oracle source uses `SUM(CASE WHEN priority='low' THEN 1 ELSE 0 END)` ×4. Engineer asks if same form still right in Trino, or cleaner pivot.

**Load-bearing facts CORRECT (VERIFIED):**

1. **No native PIVOT in Trino 467** — VERIFIED at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) (no PIVOT clause; only conditional aggregation patterns).
2. **`COUNT(*) FILTER (WHERE priority='low') AS low_count`** ... GROUP BY customer_id — VERIFIED at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) FILTER clause supported for all aggregate functions; FILTER skips rows where predicate is FALSE/NULL before aggregation, equivalent to `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` but more readable.
3. **SUM(CASE WHEN priority='low' THEN 1 ELSE 0 END) still works** — Oracle form is valid Trino 467 SQL (no parse changes); both produce identical results; FILTER is the more modern, more readable form for the same intent.
4. **Both compile to the same plan** — Trino's optimizer treats both forms equivalently at the physical operator level; performance identical.
5. **Routing** — recommend FILTER for new code (cleaner, intent-revealing), keep SUM(CASE) for line-by-line migrations where minimal-diff is preferred.

Engineer leaves with two valid options and a sensible default (FILTER for new code).

Cites r07 / r27.

---

## Q3 — Incremental model 90-day filter slow locally; override to 7 days via `--vars`

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Scenario.** Incremental dbt model filters last 90 days; local/CI slow, want 7. Engineer wants `lookback_days: 90` as project default + `dbt run --vars 'lookback_days: 7'` override. Asks where to define + how to reference + precedence.

**Load-bearing facts CORRECT (VERIFIED at [docs.getdbt.com/docs/build/project-variables](https://docs.getdbt.com/docs/build/project-variables)):**

1. **Top-level `vars:` block in `dbt_project.yml`** (NOT nested under `models:`) — VERIFIED verbatim with example: `vars: start_date: '2016-06-01'`. Can be globally-scoped or package-scoped.
2. **Default in model SQL**: `{{ var('lookback_days', 90) }}` — second-arg default verified verbatim "You can also provide a default value: `{{ var('name', default) }}`"; no CompilationError if var unset (with default).
3. **CLI override**: `dbt run --vars '{lookback_days: 7}'` — YAML-dict string form verified verbatim with examples `dbt run --vars '{"event_type": "signup"}'` / `dbt run --vars '{event_type: signup, region: us}'`.
4. **`--vars` is plural** (not `--var`) — verified verbatim "the flag is `--vars` (plural)". Responder's "`--var` errors" is accurate.
5. **Precedence (high → low)**: CLI `--vars` > project `vars` in `dbt_project.yml` > `var()` default arg — verified verbatim "From highest to lowest priority: 1. `--vars` CLI arguments (override everything) 2. Project-level `vars` in `dbt_project.yml` 3. `var()` function default value (fallback)".
6. **Trino dialect in the model SQL**: `WHERE order_date >= date_add('day', -{{ var('lookback_days', 90) }}, current_date)` — production-stack-correct (Trino 467 uses `date_add`, not Postgres `INTERVAL '7 days'`).

Engineer arrives at working local-dev workflow: edit `dbt_project.yml` once → `dbt run --vars '{lookback_days: 7}'` locally for 7-day fast loop, prod CI runs default 90. No imported-prior, no broken-secondary, no over-warning.

Cites r13/r27/r28.

---

## Q4 — WATCH: Oracle LPAD(TO_CHAR(account_id), 8, '0') → Trino; numeric pad gotchas

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**WATCH CLOSURE — `iter1219 format-%08d missed`.** At iter1219 the responder gave only `lpad(CAST(... AS VARCHAR))` and **missed BOTH** the `format('%08d')` sub-canonical AND the `lpad` pads-OR-truncates hazard. This iter (1225) re-probe under structurally similar Oracle-LPAD framing surfaces **BOTH cleanly** — watch closes on first re-probe (15th consecutive 1st-re-probe-CLOSE pattern).

**Load-bearing facts ALL VERIFIED:**

1. **Trino 467 HAS `lpad()` and `rpad()`** — VERIFIED at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) verbatim: `lpad(string, size, padstring) → varchar`. Same for `rpad`. Responder correctly identified the docs page where the engineer didn't find it (likely searched for `LPAD` uppercase or under a non-string-function category).
2. **Signature is `lpad(varchar, bigint, varchar)`** — VERIFIED. Engineer's `account_id` is numeric, so **MUST CAST first**: `lpad(CAST(account_id AS VARCHAR), 8, '0')`. Responder correctly flagged: `lpad(account_id, ...)` direct on bigint errors with `Unexpected parameters (bigint, integer, varchar)`.
3. **PADS-OR-TRUNCATES hazard** — VERIFIED verbatim in Trino docs: "If `size` is less than the length of `string`, the result is truncated to `size` characters." Responder's example `lpad('123456789', 8, '0') = '12345678'` (drops `'9'`) is correct. **THIS IS THE iter1219 MISS** — engineer with growing IDs (`11000000`, `12345678`) would silently lose the most-significant digit. Critical gotcha for any production zero-pad of monotonically increasing IDs.
4. **`format('%08d', account_id)` alternative** — VERIFIED at [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html): `format(format, args...) → varchar` uses Java Formatter syntax (see [Java Formatter spec](https://docs.oracle.com/en/java/javase/23/docs/api/java.base/java/util/Formatter.html#syntax)). `%08d` = minimum-width-8 zero-pad-left for decimal integer. **Minimum width, NEVER truncates** — `format('%08d', 1234)` → `'00001234'`, `format('%08d', 123456789)` → `'123456789'` (preserves all 9 digits, no truncation). Java Formatter semantics verified by docs example `%03d` produces `'008'`.
5. **No CAST needed for `format('%08d', account_id)`** — `%d` accepts numeric directly (BIGINT/INT both work via Java Formatter), so this is more concise than `lpad(CAST(... AS VARCHAR), ...)` for the integer-id zero-pad use case.
6. **Routing**: "Prefer `format('%08d')` when ID might grow beyond pad width; use `lpad` only for truly-fixed-width (flat-file where truncation OK)." Correct decision rule — engineer with growing IDs uses `format`, engineer with fixed-width legacy interchange (e.g., 8-char account-code field in a banking file) uses `lpad`.

**Resource-source check.** Both `lpad` + `format('%08d')` patterns appear in resources/. iter1219 responder partially missed but iter1225 responder surfaces both cleanly + the truncation hazard — findability has caught up.

Engineer arrives at: (a) correct knowledge that Trino has lpad/rpad; (b) must CAST numeric to varchar for lpad; (c) lpad pads OR truncates (hazard); (d) format('%08d') is the truncation-free alternative; (e) decision rule for which to use. No imported-prior, no broken-secondary, no fabrication.

Cites r07 / r27.

---

## Topic updates

- **Q1 → Iceberg table maintenance (compaction, snapshot expiry, orphan file cleanup)**: 4.4365/224 → (4.4365×224 + 4.5)/225 = 998.2760/225 = **4.4368/225 PASSED** (+0.0003, margin +0.9368).
- **Q2 → Oracle PL/SQL → dbt+Trino migration**: 4.4577/188 → (4.4577×188 + 5.0)/189 = 843.0476/189 = **4.4606/189 PASSED** (+0.0029, margin +0.9606). (PIVOT translation — Oracle SUM(CASE) preface routes to this row.)
- **Q3 → Improving complex SQL performance on Trino with dbt**: 4.5415/49 → (4.5415×49 + 5.0)/50 = 227.5335/50 = **4.5507/50 PASSED** (+0.0092, margin +1.0507).
- **Q4 → Oracle PL/SQL → dbt+Trino migration**: 4.4606/189 → (4.4606×189 + 5.0)/190 = 848.0534/190 = **4.4634/190 PASSED** (+0.0028, margin +0.9634). (Oracle LPAD → Trino translation.)

All required topics remain PASSED with healthy margins; thinnest required topic remains **Query performance basics: partitioning, indexing strategy for analytics** at 4.2091/31 (margin +0.7091).

---

## Watch backlog

**OPEN watches:**
- `iter1224 CoW-MoR scenario-diagnosis-when-symptom-implies-mode` — soft watch, re-probe 3-7 iters; NOT TESTED this iter.
- `iter1223 packages.yml-gap` (re-probe 4-8) + `GREATEST-Oracle-premise`; NOT TESTED this iter.
- `iter1215 strpos-3-arg CEILING` (no churn); NOT TESTED this iter.
- `iter1213 session_properties + (+)-mnemonic`; NOT TESTED this iter.
- `iter1222 CAST-DECIMAL/TRY_CAST`; NOT TESTED this iter.
- light-monitors carry forward.

**CLOSED this iter:**
- `iter1219 format-%08d missed` — **CLOSED on first re-probe** (15th consecutive 1st-re-probe-CLOSE pattern in the extended phase).

**NEW soft watch:**
- `iter1225 Q1 table_changes() existence + delete-file limitation` — re-probe in 4-8 iters under Iceberg snapshot-to-snapshot CDC framing. If recurs as flat denial, light additive 5-7 line card (r17 or r10 snapshot-comparison section) explaining `iceberg.system.table_changes()` exists with delete-file limitation + route to FOR VERSION AS OF + FULL OUTER JOIN for MoR scenarios. If lands correctly with limitation, recall ceiling — no fix.

---

## Verdict

**4.875 STRONG PASS**, iter1219 format-%08d WATCH CLOSES cleanly. Q4 watch close adds the format() sub-canonical and the lpad pads-OR-truncates hazard that iter1219 missed — both surfaced in the same response with correct routing logic. Q2 + Q3 are clean 5.0s. Q1 lands the correct workhorse pattern (time-travel + FULL OUTER JOIN + IS DISTINCT FROM) with one non-load-bearing factual slip (denies table_changes() existence; minor because the function has documented limitations precisely in the engineer's MoR-with-delete-files scenario, so routing to the recommended pattern is correct). NEW soft watch on table_changes() existence. NO FIX-A. Continue breadth probing in deep-extended mode.
