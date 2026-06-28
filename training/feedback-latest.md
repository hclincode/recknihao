# Iteration 1206 — Judge Feedback

## Verdict: 4.53 PASS + LIGHT-DEFECT Q1 (LIKE-on-ROW recall slip) + Q3 WATCH CLOSES

| Q | Topic | Acc | Clar | App | Compl | Score |
|---|---|---|---|---|---|---|
| Q1 | Iceberg partition design (per-partition file inspection via `$files`) | 4.0 | 4.5 | 3.5 | 3.5 | **3.875** |
| Q2 | SQL best practices for OLAP (no QUALIFY / window-in-WHERE / dedup) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** |
| Q3 (WATCH) | Oracle PL/SQL -> dbt+Trino (dbt `generate_schema_name` macro) | 5.0 | 5.0 | 5.0 | 4.5 | **4.875** |
| Q4 | Oracle PL/SQL -> dbt+Trino (`NVL` -> `COALESCE` migration) | 4.0 | 5.0 | 4.5 | 4.0 | **4.375** |

**Average: (3.875 + 5.0 + 4.875 + 4.375) / 4 = 18.125 / 4 = 4.53 PASS**

**WATCH STATUS:** `iter1203 r27 §6.7M generate_schema_name findability` — **CLOSES ON 1st RE-PROBE.** Responder reached the §6.7M canonical cleanly from the dev-vs-shared-Trino keyword path; named the macro, the surprising PREFIX default, the override file path, both env_var + target.name options, and the schema-vs-catalog distinction — all matching docs.getdbt.com.

**Defect / FIX-A status:** Q1 has a load-bearing SQL slip — `WHERE partition LIKE '%event_date=2026-06-25%'` would type-error because `$files.partition` is a ROW struct, not varchar. Resources already teach the CORRECT struct-field-access form at r17 L1532 (`WHERE partition.event_date = DATE '2026-05-28'`) and r05 L3572 (`WHERE partition.tenant_id = 'acme'`), and r10 L441 already has the `$partitions` table cited. **This is a responder recall slip, NOT a resource gap → NO FIX-A.** Re-probe in 4-8 iters under structurally different metadata-table framing.

---

## Q1 — Iceberg `$files` / `$partitions` for per-partition skew diagnosis (3.875)

**Core canonical reached but with two recall-ceiling slips.**

VERIFIED CORRECT (load-bearing primary axis):
1. `$files` metadata table exposes per-file rows with columns `file_path, file_size_in_bytes, record_count, content` — VERIFIED at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) (full column list: `content, file_path, record_count, file_format, file_size_in_bytes, column_sizes, value_counts, null_value_counts, nan_value_counts, lower_bounds, upper_bounds, key_metadata, split_offsets, equality_ids, sort_order_id, readable_metrics, partition`).
2. `content` integer enum `0 = DATA, 1 = POSITION_DELETES, 2 = EQUALITY_DELETES` — VERIFIED (matches r13 §3070 canonical and Iceberg spec).
3. Full-qualified one-token quoting `"events$files"` (whole table-name+metadata-name inside ONE pair of double quotes, not `events."$files"`) — VERIFIED in the connector docs verbatim "use the table name and the metadata table name separated by a `$`" with example `example.testdb."customer_orders$snapshots"`.
4. Remediation `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` — VERIFIED at the same connector docs page.
5. Routing skewed-customer heavy-partition slowness back to physical-layout inspection is the correct mental move (file count + size distribution + delete-file count).

DEFECT — LIKE-on-ROW (Acc -1.0, App -1.5):
- Responder's example `WHERE partition LIKE '%event_date=2026-06-25%' ORDER BY file_size_in_bytes DESC` would TYPE ERROR. **VERIFIED via WebFetch of trino.io/docs/467/connector/iceberg.html**: the `$files.partition` column is "A row that contains the mapping of the partition column names to the partition column values" — a ROW/struct type, NOT a varchar; `LIKE` on a ROW is a parse-time `Cannot apply operator: row(...) LIKE varchar` error.
- The CORRECT struct-field-access form is `WHERE partition.event_date = DATE '2026-06-25'` — already taught in resources at r17 §1532 verbatim `WHERE partition.event_date = DATE '2026-05-28'` and r05 §3572 (`WHERE partition.tenant_id = 'acme'`).
- Engineer copy-pastes the snippet, hits a type error in their session, then has to figure out struct-field-access on their own. Recoverable but a real friction-bump.

RECALL CEILING — `$partitions` omission (Compl -1.5):
- The MORE DIRECT tool for the engineer's literal ask ("how many files in a partition, sizes") is **`$partitions`** — exposes `partition, record_count, file_count, total_size, data` per docs (verified via WebFetch); no GROUP BY needed. Responder went `$files` + GROUP BY route which is the long-way-round equivalent.
- Resources at r10 L441 already pair the two: *"For per-partition counts, `SELECT partition, file_count FROM tbl$partitions`."* — findability path "files in a partition, sizes" didn't reach r10 L441 from the responder's keyword set.
- Same omission pattern as iter1196 Q1 (4.375) — recall ceiling, not a resource defect.

**SLIP CATEGORIZATION:** (1) LIKE-on-ROW = standalone responder slip, NOT source-anchored (resources teach the right form); per `feedback_responder_broken_secondary_alternative.md` adjacent family — the lead identification ($files) was right, the example SQL was the broken element. (2) `$partitions` omission = pure recall ceiling, same as iter1196.

**NO FIX-A.** Both axes recoverable from the engineer's session; no resource defect to repair. Re-probe in 4-8 iters under physical-layout framing to monitor whether either slip recurs.

## Q2 — No QUALIFY / window-in-WHERE forbidden / CTE-wrap dedup (5.0)

**Pin-perfect Trino-dialect dedup canonical with correct alternative-form routing.**

VERIFIED CORRECT:
1. Trino 467 does NOT support `QUALIFY` — VERIFIED (no QUALIFY in [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) synopsis or anywhere in the 467 docs). Snowflake/BigQuery-style `... QUALIFY ROW_NUMBER() OVER (...) = 1` is a parse error.
2. Window functions cannot appear in the `WHERE` clause directly — standard SQL execution-order restriction; WHERE evaluates BEFORE window functions per [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) ("Window functions are calculated after WHERE, GROUP BY, and HAVING").
3. Correct dedup pattern via CTE + outer filter `WHERE rn = 1` is canonical:
   ```sql
   WITH deduped AS (
     SELECT *, ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY ingested_at DESC) AS rn
     FROM raw_events
   )
   SELECT ... FROM deduped WHERE rn = 1
   ```
4. ROW_NUMBER on hundreds of millions of rows: correctly framed as "parallelized" — Trino hash-partitions by the OVER PARTITION BY key (event_id) and sorts within partition; single pass after the hash shuffle, no quadratic blow-up.
5. `max_by(payload, ingested_at) GROUP BY event_id` as the single-column alternative is CORRECT and well-routed — VERIFIED at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) (`max_by(x, y)` returns x at the row with the max y). For full-row dedup ROW_NUMBER stays the right answer; `max_by` shines when only one column is needed (avoids carrying full rows through the shuffle).

No broken-secondary slip, no imported-prior (didn't reach for QUALIFY or `Postgres-style WHERE rn = 1` directly), no over-warning. The "ROW_NUMBER is more efficient than window on hundreds of millions" framing was accurate (vs the naive self-join alternative).

## Q3 (WATCH) — dbt `generate_schema_name` macro per-developer schemas (4.875)

**WATCH `iter1203 r27 §6.7M generate_schema_name findability` CLOSES ON 1st RE-PROBE.**

**Background:** iter1203 Q3 (same generate_schema_name framing, dev/staging/prod target) scored 4.75 with the responder META-DISCLAIMING "resources don't cover this" then falling back to general-knowledge. iter1203 LIGHT FIX-A added r27 §6.7M canonical card (verified accurate against docs.getdbt.com) with findability anchors for the dev/staging/prod keyword path. Today's re-probe under structurally different framing ("8 devs run dbt locally vs shared Trino dev, all land in same `analytics` schema, want per-developer schemas WITHOUT editing profiles.yml each") reaches the §6.7M canonical CLEANLY — no meta-disclaimer, the macro name + default surprise + override-path + both env_var and target.name options all named directly.

VERIFIED CORRECT (against [docs.getdbt.com/docs/build/custom-schemas](https://docs.getdbt.com/docs/build/custom-schemas), WebFetched this iter):

| Specific claim | Verification |
|---|---|
| Macro `generate_schema_name(custom_schema_name, node)` controls the schema each model builds into | VERIFIED — default macro returns the per-model schema; called once per model node by dbt |
| Default behavior PREFIXES `{{ target.schema }}` to the custom schema name | VERIFIED VERBATIM: default macro returns `{{ default_schema }}_{{ custom_schema_name \| trim }}` when custom set, else `{{ default_schema }}` — yes the literal mechanic is APPEND in jinja text but the effect is target.schema-as-prefix on every custom schema, which is exactly the engineer's surprise (every `+schema:` config produces a weird `analytics_<x>` instead of `<x>`) |
| Override file location: `macros/generate_schema_name.sql` | VERIFIED — dbt auto-discovers the override at this path |
| `target.name`-based switching pattern (Option A: prod -> default_schema; else `analytics_<env>`) | VERIFIED — docs-blessed "Standard Pattern" |
| `env_var()`-based per-dev switching (Option B: `DBT_DEV_USER=alice && dbt run --target dev` -> `analytics_alice`) | VERIFIED — `env_var()` is documented for both profiles.yml and inside macros; reading env vars at parse time per [docs.getdbt.com/reference/dbt-jinja-functions/env_var](https://docs.getdbt.com/reference/dbt-jinja-functions/env_var) |
| Controls the SCHEMA only, NOT the catalog (still `iceberg` catalog) | VERIFIED — docs note catalog/database control is a separate `generate_database_name` macro |
| `target.name` comes from `--target dev` / `--target prod` invocation | VERIFIED — standard dbt CLI flag |

Engineer leaves with: one macro file to ship to git + 8 devs export `DBT_DEV_USER=<name>` once + every `dbt run --target dev` auto-routes to `analytics_<name>` without editing profiles.yml — directly answers the literal "WITHOUT editing profiles.yml each" ask.

Minor Compl shave (-0.5): didn't mention dbt's built-in `generate_schema_name_for_env` helper (prod=custom-or-target, non-prod=target.schema-only) which is a one-line alternative to a hand-rolled macro. Recall ceiling, not load-bearing.

**WATCH CLOSED.** §6.7M findability anchor working as designed. (11th+ consecutive watch closure on 1st re-probe pattern.)

## Q4 — Oracle `NVL` -> Trino `COALESCE` (4.375)

**Core canonical correct; mildly over-stated "no behavioral differences" claim misses one Oracle-NVL implicit-type-coercion edge case.**

VERIFIED CORRECT:
1. Trino 467 has NO `NVL` function — VERIFIED at [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html) (only COALESCE, NULLIF, CASE, IF, TRY are listed). `NVL(...)` parses as a user function call and resolves to "Function 'nvl' not registered."
2. `COALESCE(arg1, ..., argN)` accepts N args, returns first non-NULL — VERIFIED at same docs page.
3. Nested `NVL(a, NVL(b, NVL(c, 'd')))` flattens to `COALESCE(a, b, c, 'd')` — readability win, semantically equivalent. CORRECT.
4. Drop-in replacement for the common varchar-default case (e.g., `NVL(plan_name, 'free')` -> `COALESCE(plan_name, 'free')`) — works without ceremony.

OVER-STATED claim (Acc -1.0, Compl -1.0):
- Responder said *"No behavioral differences — COALESCE handles NULL-checking identically to Oracle NVL"*. This misses a real edge case the engineer will hit migrating hundreds of NVL calls:
  - **Oracle NVL implicitly converts arg2 to arg1's type** — e.g., `NVL(numeric_col, '0')` silently converts the varchar `'0'` to NUMBER. This is standard Oracle implicit-conversion behavior on NVL's 2nd argument.
  - **Trino COALESCE requires all args share a common supertype** — `COALESCE(numeric_col, '0')` throws *"All COALESCE operands must be the same type or coercible to a common type. Cannot find common type between integer and varchar(2)"* per [trinodb/trino#24017](https://github.com/trinodb/trino/issues/24017) + [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) verbatim "Trino will not convert between character and numeric types".
  - Migrating hundreds of NVL calls almost certainly includes some `NVL(numeric, '0')` or `NVL(date_col, 'unknown')` mixed-type forms — those need explicit `CAST(... AS <numeric_col_type>)` on the default (`COALESCE(numeric_col, CAST('0' AS BIGINT))` or just `COALESCE(numeric_col, 0)`).
- **Mitigating factors:** the responder DID call out "edge cases differing from Oracle NVL" in the framing, and the core drop-in advice for the common varchar->varchar case IS correct. Engineer with mixed-type NVL calls will hit the type-mismatch error at compile time, recognize it, and add the CAST — not silent corruption.

RESOURCE COVERAGE CHECK: grep'd r27 + r23 + r28 — current canonical at r27 §366 says only *"COALESCE accepts N args; NVL only 2. Always prefer COALESCE going forward."* — does NOT teach the implicit-coercion edge case. **SOFT WATCH** label `iter1206 r27 NVL-COALESCE type-coercion edge case` — re-probe in 5-10 iters under "Oracle NVL on a numeric column with a string default" framing to test whether responder warns about the type-mismatch error. **No FIX-A this iter** — the load-bearing varchar case is right, the edge case is mild, and adding a card risks over-attracting simple NVL questions to the type-coercion warning (per `feedback_new_card_over_attracts_adjacent.md`).

---

## Patterns across the four answers

- **Q3 WATCH CLOSURE** is the headline event — the iter1203 §6.7M FIX-A's findability anchor reaches the responder cleanly on structurally different framing (8 devs / "WITHOUT editing profiles.yml each" vs iter1203's dev/staging/prod target framing). Generate_schema_name macro canonical now stable.
- **Q1 LIKE-on-ROW slip** is a one-off responder construction error in the example SQL — resources already teach the right `partition.event_date` struct-access form (r17 + r05); no resource fix needed. Same minor `$partitions`-omission recall pattern as iter1196.
- **Q4 over-claim** (the "no behavioral differences" line) is mild over-confidence on a peripheral aside — engineer will hit the type-error at compile-time, recognize it, and CAST. Soft-watch the type-coercion edge case but no card to write.
- **No imported-prior slip** — Q2 navigated the QUALIFY trap (Snowflake/BigQuery import) cleanly; Q3 navigated the iter1197 macro-omission gap.
- **No fabrication** across all four answers — Q1 metadata-table names + column lists + content enum + EXECUTE optimize syntax all real; Q2 max_by + ROW_NUMBER + CTE-wrap all real; Q3 generate_schema_name + env_var + macros/generate_schema_name.sql all real; Q4 COALESCE all real.

## Open watches (carry-forward — no re-probe this iter)

1. **iter1206 r27 NVL-COALESCE type-coercion edge case (NEW soft watch)** — re-probe in 5-10 iters under `NVL(numeric_col, '0')` mixed-type framing.
2. **iter1199 r17 position-delete adjacent (light-monitor)** — re-probe in 1-7 iters.
3. **iter1204 dbt `--full-refresh` on_table_exists atomicity framing (light-monitor)** — re-probe in 1-9 iters.
4. **iter1206 Q1 LIKE-on-ROW + $partitions-omission (soft watch)** — re-probe in 4-8 iters under physical-layout / per-partition-file-count framing to confirm Q1 slips don't recur.

Watch `iter1203 r27 §6.7M generate_schema_name findability`: **CLOSED.**

## Topic score updates

| Topic | Before | After | Delta |
|---|---|---|---|
| Iceberg partition design for SaaS | 4.4583 / 56 | 4.4480 / 57 | -0.0103 |
| SQL query best practices for OLAP | 4.5898 / 274 | 4.5913 / 275 | +0.0015 |
| Oracle PL/SQL -> dbt + Trino (Q3 then Q4) | 4.4719 / 167 | 4.4737 / 169 | +0.0018 net |

All required topics remain PASSED with healthy margins. Iceberg partition design still margin +0.948; SQL best practices still margin +1.091; Oracle PL/SQL still margin +0.974. Thinnest required topic remains Query performance basics at 4.2161 (untouched this iter).

**NEXT iter1207: BREADTH.** Soft-watches above are all 4-10 iters out. Consider re-probing the thinnest topic (Query-perf-basics) or the iter1187 lever-#1-min/max-on-unsorted-VARCHAR latent framing slip. Avoid generate_schema_name re-probes (just closed) and avoid metadata-table re-probes for 4+ iters (let Q1 slips age).

## Sources

- [trino.io/docs/467/connector/iceberg.html — $files and $partitions metadata tables](https://trino.io/docs/467/connector/iceberg.html) — confirmed `partition` column is ROW type, `$partitions` exposes per-partition file_count/total_size, EXECUTE optimize syntax
- [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) — no QUALIFY in synopsis; ORDER BY / OFFSET / LIMIT clause order
- [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) — window-function execution order (after WHERE)
- [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) — `max_by(x, y)` signature
- [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html) — COALESCE listed, NVL not listed
- [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) — "Trino will not convert between character and numeric types"
- [trinodb/trino#24017](https://github.com/trinodb/trino/issues/24017) — COALESCE type-mismatch error verbatim
- [docs.getdbt.com/docs/build/custom-schemas](https://docs.getdbt.com/docs/build/custom-schemas) — generate_schema_name default macro behavior (PREFIX with target.schema), override file at `macros/generate_schema_name.sql`
- [docs.getdbt.com/reference/dbt-jinja-functions/env_var](https://docs.getdbt.com/reference/dbt-jinja-functions/env_var) — `env_var()` parse-time evaluation
