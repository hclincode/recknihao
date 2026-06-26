# iter1150 Feedback

**Iter average: 3.781 PASS + LIGHT FIX-A** (Q1 second misroute on full-rebuild atomic-swap → findability gap confirmed; Q3 broken-primary BUT correct-alternative; Q2/Q4 clean 5.0/4.875)

**Verdict shape:** PASS by no-per-question-veto rule (margin +0.281, thin). Q1 4-dim = 2.5 (sub-threshold), Q3 4-dim = 3.125 (sub-threshold) but both topics' rolling averages cushion the iter. SECOND consecutive misroute on full-rebuild atomic-swap question class — LIGHT FIX-A warranted.

---

## Per-question scoring

### Q1 — dim_products full rebuild + 24/7 dashboards: how to configure atomic swap?

**Score: 2.500** — Acc 2.5 / Clar 3.5 / App 2.0 / Compl 2.0

**Source-verified correct answer (from docs.getdbt.com/reference/resource-configs/trino-configs):**

dbt-trino's `table` materialization accepts an `on_table_exists` config with four values:
- `rename` (DEFAULT) — builds an intermediate table, renames target→backup, renames intermediate→target (two metadata operations, very narrow swap window)
- `drop` — DROP TABLE then CREATE (this is exactly what causes "table does not exist" — explicit non-existence window)
- `replace` — `CREATE OR REPLACE TABLE` (single atomic Iceberg metadata commit; readers see complete-old or complete-new, never missing/empty — added in dbt-trino 1.7.1; **recommended when underlying connector supports CREATE OR REPLACE**; Trino+Iceberg does)
- `skip` — `CREATE TABLE IF NOT EXISTS` (no-op when table exists)

For the engineer's symptom (table-does-not-exist + brief zero rows from full-refresh `materialized='table'` job) the **direct one-line fix** is:

```sql
{{ config(materialized='table', on_table_exists='replace') }}
```

**Responder behavior — verified misroute (SECOND instance):**

1. PRIMARY RECOMMENDATION: "switch to `materialized='incremental'` with `incremental_strategy='delete+insert'` or `'insert_overwrite'` + `partition_by`, so each partition flips atomically". This is an **ARCHITECTURE CHANGE** the engineer did not ask for. The model is explicitly a full nightly rebuild dim table (not a large partitioned fact). Insert-overwrite by partition does not address a non-partitioned dim_products full rebuild.
2. SECONDARY (at the END): manual `CREATE TABLE dim_products_new AS SELECT ...` + `ALTER TABLE RENAME` pattern. Called this "fragile, requires app-side coordination". **This framing is wrong** — dbt-trino's DEFAULT `on_table_exists='rename'` is exactly this pattern, automated by the adapter, and is the documented atomic-swap default. It is not fragile.
3. `on_table_exists` is **not mentioned anywhere** in the answer.

**Re iter1149 Q3 (FIRST misroute):** the responder also misrouted that question to snapshot-isolation + "switch to incremental MERGE" framing instead of `on_table_exists` / `CREATE OR REPLACE TABLE`. Two distinct phrasings of the same question class (iter1149 "nightly full rebuild + 24/7 dashboards / Iceberg snapshot isolation safe?" vs iter1150 "configure how dbt does the swap, atomic OLD→NEW") both miss the dbt-trino config canonical. This is a **findability gap** (the canonical does not exist in resources/, AND the question's natural keywords route to incremental-materialization sections instead).

**LIGHT FIX-A WARRANTED — recommendation:**

The on_table_exists canonical does not exist in any resource (grep'd 0 hits for `on_table_exists`). Add an additive canonical card.

- **Primary placement: r28 [new section, near §930 where `CREATE OR REPLACE TABLE` already appears in a dbt-trino atomicity context].** Title something like "Configuring atomic swap for a dbt `table`-materialization full rebuild — the `on_table_exists` config". Cover all four values (rename / drop / replace / skip), name `replace` as the recommended option for concurrent-read workloads on Trino+Iceberg (CREATE OR REPLACE is supported on the Iceberg connector), name `drop` as the source of the engineer's symptom (explicit non-existence window), and contrast with `rename` (narrow but non-zero rename window — two metadata commits not one). Mention dbt-trino default is `rename`. Cite docs.getdbt.com/reference/resource-configs/trino-configs verbatim.

- **Secondary placement: r27 §6 materialization decision tree (lines 287-298).** Currently the `table` row says "CREATE OR REPLACE TABLE ... AS SELECT — full CTAS each run; Iceberg snapshot replaces prior data atomically". Add one sentence/footnote: "When concurrent readers must never see a missing/empty table during a dbt full refresh, set `on_table_exists='replace'` — emits CREATE OR REPLACE TABLE = single atomic Iceberg metadata commit. See r28 §[ref]." This is the spot the responder's keyword path actually lands.

- **Tertiary placement: r17 §163 (Iceberg CREATE OR REPLACE TABLE area).** Add a one-liner cross-ref from the Trino-side CREATE OR REPLACE TABLE canonical TO the dbt-trino `on_table_exists='replace'` knob, so an engineer who lands on the Iceberg side from "atomic table replace" anchors gets routed to the dbt config.

**Keyword anchors the canonical must include (to fix findability):**

- "dbt table rebuild swap atomic"
- "table does not exist briefly during dbt build"
- "BI dashboards see zero rows during dbt full refresh"
- "concurrent readers during dbt model rebuild"
- "on_table_exists replace rename drop"
- "is there a way to configure how dbt does the final swap"
- "full refresh with live dashboards"
- "nightly rebuild reader-safe"
- "atomic OLD→NEW swap"

**DO-NOT-WRITE entries (to defang the misroute):**

- "Switch to `materialized='incremental'` to get atomic swaps" — wrong framing; incremental is for delta efficiency on big facts, not for atomic full-rebuild reader safety. Use `on_table_exists='replace'` first; incremental is orthogonal.
- "Manual CREATE TABLE _new + ALTER TABLE RENAME is fragile" — wrong; `on_table_exists='rename'` (dbt-trino default) automates exactly this and IS the documented atomic-swap default.

**Note for teacher:** the iter1149 Q3 watch classified this as "responder-side broken-secondary-alternative family, no resource fix". iter1150 is the second instance, on a different phrasing — that classification was wrong. The canonical is genuinely missing from resources/ AND the question's natural keywords route to incremental-materialization sections. Add the on_table_exists canonical.

**Verifications performed:**

- docs.getdbt.com/reference/resource-configs/trino-configs — confirmed all four `on_table_exists` values + default `rename` + `replace` added in dbt-trino 1.7.1 + "recommended when CREATE OR REPLACE is supported in underlying connector" phrasing.
- trino.io/docs/current/connector/iceberg.html — confirmed Iceberg connector supports CREATE OR REPLACE TABLE as an atomic operation (Iceberg metadata-pointer swap).
- Grep'd resources/ for `on_table_exists` → 0 hits across all 30+ resource files. For "atomic.*swap|table does not exist|CREATE OR REPLACE TABLE" → 10 files but no on_table_exists canonical anywhere.

---

### Q2 — Left-pad integer IDs to 10 chars with zeros (built-in or CASE?)

**Score: 5.000** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Verifications performed:**

- trino.io/docs/467/functions/string.html: `lpad(string, size, padstring)` — "If size is less than the length of string, the result is truncated to size characters." Confirmed responder's lpad-truncation warning is correct (e.g., `lpad('12345678901', 10, '0')` → `'1234567890'`, silent data loss).
- trino.io/docs/467/functions/conversion.html `format(format_string, args...)` — uses Java printf semantics (Java Formatter docs linked). `%010d` is a min-width specifier (width 10, zero-padded); Java Formatter rule: min width does not truncate; wider numbers print in full. Documented example `format('%03d', 8)` → `'008'`. Confirmed responder's claim that `format('%010d', 12345678901)` returns `'12345678901'` without truncation.

Both built-ins exist; both work for the 10-char ID case. Responder correctly led with `format('%010d', n)` for "IDs that may grow past 10 chars" because lpad would silently truncate. This is exactly the right routing — format() is the safer default for variable-width numeric padding; lpad is the safer default for known-width text padding. Citation r23 §3.1F appropriate.

---

### Q3 — Third event per session (Nth row of a window)

**Score: 3.125** — Acc 2.5 / Clar 3.5 / App 3.0 / Compl 3.5

**Verifications performed:**

- trino.io/docs/467/functions/window.html: `nth_value(x, offset)` exists; "Returns the value at the specified offset from the beginning of the window. Offsets start at 1." Default frame for value functions (per SQL standard) is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`; for nth_value to return the Nth row of the full partition, explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` is required. Responder's default-frame caveat is correct.
- Window functions cannot appear in WHERE: SQL execution order is WHERE → GROUP BY → HAVING → window functions → ORDER BY. Window functions are computed AFTER WHERE filtering, so `WHERE nth_value(...) OVER (...) IS NOT NULL` is a parse/semantic error in Trino — the planner will reject a window function in WHERE. Engineer must wrap the window expression in a CTE/subquery and filter the alias in the outer WHERE.

**Defect — broken-primary:** Responder's primary `nth_value(event_name, 3) OVER (PARTITION BY session_id ORDER BY event_occurred_at ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)` with `WHERE NTH_VALUE(...) OVER (...) IS NOT NULL` — the WHERE clause containing the window function is **invalid in Trino**. Engineer copy-pastes the primary and hits an error before any filtering happens.

**Mitigation — correct alternative present:** The ROW_NUMBER subquery alternative (CTE with `ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY event_occurred_at) AS event_position` then outer `WHERE event_position = 3`) is correct and runnable. Engineer reading the alternative gets to a correct query.

This is the classic **"broken-secondary-alternative" pattern in INVERTED shape** — usually the primary is correct and the secondary is broken padding; here the primary is broken AND the secondary works. The fact that one of the two given paths runs cleanly rescues this from being a hard FAIL, but the engineer who skims the primary first will hit a confusing error.

**Recommendation:** No resource fix. r07 ROW_NUMBER-then-WHERE-rank=N canonical exists and is the correct general idiom for "Nth row per group" (more robust than nth_value because ROW_NUMBER naturally exposes a filterable rank column). This is responder slip on construction, not a resource gap. One instance — re-probe, don't churn. If the slip recurs ("second-most-recent login per user", "fifth purchase per customer"), then consider an additive r07 defang card naming WHERE-with-window-function as illegal and showing the wrap-in-subquery shape.

---

### Q4 — Trino spill auto or explicit? Downsides?

**Score: 4.875** — Acc 5.0 / Clar 4.5 / App 5.0 / Compl 5.0

**Verifications performed (trino.io/docs/467/admin/properties-spilling.html):**

- `spill-enabled` (config) and `spill_enabled` (session) — both exist; default false. Confirmed responder's "must enable explicitly" + `SET SESSION spill_enabled = true` syntax.
- `spiller-spill-path` config required — confirmed responder's prereq framing (cluster config must set `spill-enabled=true` + `spiller-spill-path` else session toggle does nothing).
- Spill applies to: "aggregations, joins (inner and outer), sorting, and window functions" — verbatim. Responder's "hash aggregations, hash joins, ORDER BY, window funcs" is correct.
- `max-spill-per-node` default **100GB** — CONFIRMED from trino.io/docs/467/admin/properties-spilling.html.
- Fabrication defangs: `spill_aggregations_enabled`, `memory_revoking_enabled`, `spill_order_by_enabled`, `task_max_memory` — none exist in Trino 467 spilling documentation. Correctly defanged as fabrications.

**Minor shave (-0.5 Clar):** "spill_enabled is THE only session lever" is slightly oversimplified — there are operator-level memory-limit session properties (e.g., `aggregation_operator_unspill_memory_limit`) that fine-tune spill behavior, though they are rarely-touched. Not load-bearing for the engineer's question (turn-spill-on vs leave-off). Recall ceiling.

Tradeoffs (~5-20% slower from disk I/O, 100GB disk-space default) correctly named. Engineer knows exactly what to do: check cluster config for `spill-enabled=true` + `spiller-spill-path`, then `SET SESSION spill_enabled = true` per-query.

---

## Topics touched and rubric updates

- **Q1 — Iceberg table maintenance** (2.500). Following iter1149 Q3 footnote precedent (full-rebuild reader-safety routing scored under Iceberg-maintenance). 4.47648/184 → (823.27232 + 2.500)/185 = **4.4501/185 PASSED** (-0.0264, margin +0.9501, still safely above 3.5).
- **Q2 — SQL query best practices for OLAP** (5.000). 4.5693/215 → (982.3995 + 5.0)/216 = **4.5722/216 PASSED** (+0.0029).
- **Q3 — Analytical query patterns on Iceberg+Trino** (3.125). 4.58545/102 → (467.7159 + 3.125)/103 = **4.5326/103 PASSED** (-0.0528, margin still +1.0326).
- **Q4 — Query performance basics** (4.875). 4.16288/25 → (104.072 + 4.875)/26 = **4.1893/26 PASSED** (+0.0264).

All required topics REMAIN PASSED.

---

## Recommendation

**LIGHT FIX-A** for Q1 (second misroute on full-rebuild atomic-swap → findability gap confirmed):

- Add on_table_exists canonical at r28 (primary placement, near §930)
- Cross-ref from r27 §6 materialization decision tree (where responder's keyword path lands)
- Cross-ref from r17 §163 CREATE OR REPLACE TABLE area
- Use the keyword anchors and DO-NOT-WRITE entries listed above.

**WATCH:** r28 on_table_exists canonical iter1150. Re-probe in next sweep with a third phrasing of the full-rebuild atomic-swap question class to confirm the new canonical reaches:
- e.g., "Nightly dim_users dbt model rebuilds the whole table. Dashboard users sometimes refresh during the build and see weird intermediate states — is there a dbt config for this?"
- e.g., "Can my dbt table-materialization do a CREATE OR REPLACE atomically without going through DROP+CREATE?"
- e.g., "Want the table swap at the end of `dbt run` to be transactional for live readers."

If the third phrasing reaches the canonical → watch CLOSED. If it misroutes again → escalate to a stronger anchor (TL;DR or top-of-file callout in r28).

**No fix on Q3.** Responder slip (window-function-in-WHERE invalid in the primary) with correct alternative present. One instance; don't churn. Re-probe with "Nth row per group" question variant in future sweep.

---

## Sources verified

- [dbt-trino on_table_exists config (docs.getdbt.com)](https://docs.getdbt.com/reference/resource-configs/trino-configs)
- [Trino 467 Iceberg connector — CREATE OR REPLACE TABLE atomicity](https://trino.io/docs/current/connector/iceberg.html)
- [Trino 467 String functions — lpad truncation behavior](https://trino.io/docs/467/functions/string.html)
- [Trino 467 Conversion functions — format() Java Formatter semantics](https://trino.io/docs/467/functions/conversion.html)
- [Trino 467 Window functions — nth_value + frames](https://trino.io/docs/467/functions/window.html)
- [Trino 467 Spilling properties — spill-enabled / max-spill-per-node 100GB default](https://trino.io/docs/467/admin/properties-spilling.html)
- [Trino 467 Spill to disk overview](https://trino.io/docs/467/admin/spill.html)
- [dbt-trino issue #479 on_table_exists=skip](https://github.com/starburstdata/dbt-trino/issues/479)
