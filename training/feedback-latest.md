# Judge Feedback — Iter 453 → Teacher Actions for Iter 454

## Iter 453 verdict

**Overall: 4.53125 PASS** (52nd consecutive PASS in extended phase).
- Q1 dbt-trino incremental RE-PROBE: **4.8125 STRONG** — iter452 both confident-inaccuracies RESOLVED.
- Q2 Oracle DECODE → Trino: **4.5 PASS** — minor NULL-matching nuance gap.
- Q3 snapshot rollback via $snapshots: **4.0 PASS-WITH-BUG** — load-bearing copy-paste defect on metadata-table FROM clause.
- Q4 ANALYZE on Iceberg: **4.8125 STRONG** — pedagogically excellent 3-layer framing.

## Per-question scoring

### Q1 (dbt incremental RE-PROBE) — avg 4.8125 STRONG PASS
- Accuracy 5.0: `{% if is_incremental() %}` canonical guard + `partitioned_by` canonical dbt-trino key + `incremental_strategy='merge'` + `unique_key` + `on_schema_change='append_new_columns'` + `sorted_by` + `format_version=2` + COALESCE-watermark — ALL verified against docs.getdbt.com.
- Clarity 4.75: DO-NOT callouts pedagogically strong.
- Actionability 4.75: paste-ready canonical block.
- Completeness 4.75: covers config + body + late-arrival + anti-patterns.

### Q2 (Oracle DECODE → Trino) — avg 4.5 PASS
- Accuracy 4.75: Trino 467 has NO DECODE CORRECT; CASE rewrite syntactically valid.
- Clarity 4.75: simple substitution explained cleanly.
- Actionability 4.5: paste-ready for non-NULL inputs.
- Completeness 4.0: Oracle DECODE NULL-matching nuance MISSING (DECODE treats NULL=NULL as TRUE, simple CASE does NOT — silent migration bug for NULL-bearing columns).

### Q3 (undo bad 200k-row load via Iceberg snapshots) — avg 4.0 PASS-WITH-BUG
- Accuracy 3.5: `CALL iceberg.system.rollback_to_snapshot('analytics','events_table',<id>)` 3-arg positional CORRECT for Trino 467 (per Starburst blog + trinodb/trino #12353 + PR #9921; PR #24580 deprecates for later versions). Metadata-only/atomic CORRECT. expire_snapshots/remove_orphan_files CORRECT. **BUT: the snapshot-lookup query comment says "Query the $snapshots metadata table" but FROM clause is `FROM iceberg.analytics.events_table` (the BASE table), NOT `FROM iceberg.analytics."events_table$snapshots"`** — base table has no snapshot_id/committed_at/operation/summary columns, that query will fail with `Column 'snapshot_id' cannot be resolved`.
- Clarity 4.25: explanation otherwise clean.
- Actionability 3.75: engineer pastes lookup query, hits parse error, must self-correct.
- Completeness 4.5: rollback + cleanup + warnings all present.

### Q4 (ANALYZE on Iceberg) — avg 4.8125 STRONG PASS
- Accuracy 5.0: bare `ANALYZE table WITH (columns = ARRAY[...])` no-TABLE-keyword CORRECT per trino.io/docs/current/sql/analyze.html; SHOW STATS FOR CORRECT; CBO/NDV claim CORRECT; Puffin-backed stats CORRECT.
- Clarity 4.75: 3-layer model (partition pruning / file skipping / CBO join ordering — ANALYZE only affects layer 3) is pedagogically EXCELLENT.
- Actionability 4.75: EXPLAIN (TYPE DISTRIBUTED) before/after verification pattern.
- Completeness 4.75: scan vs join perf distinction made explicitly.

## Q1 confirmation — DID iter453 restore dbt-trino syntax?

**YES, both iter452 confident-inaccuracies are fully resolved on the responder side:**

| iter452 defect | iter453 responder produced | Status |
|---|---|---|
| `{% if execute %}` as incremental guard | `{% if is_incremental() %}` | RESOLVED — canonical per docs.getdbt.com/docs/build/incremental-models |
| `properties={'partitioning': "ARRAY[...]"}` dbt-trino key | `properties={'partitioned_by': "ARRAY['day(event_timestamp)']", ...}` | RESOLVED — canonical per docs.getdbt.com/reference/resource-configs/trino-configs |

Plus the responder added explicit DO-NOT-WRITE callouts against `{% if execute %}`, bare `MAX(...)` in WHERE, and `IN (SELECT id FROM {{this}})`. The iter453 teacher reconciliation (new leading canonical worked example in r28, 5 config-block + 2 prose fixes across r27/r28) **LANDED CLEAN**. Citation-hygiene streak RESTORED on this topic.

## New defect this iter — Q3 $snapshots FROM-clause bug

**Real accuracy error**: the responder's snapshot-lookup query has a comment `Query the $snapshots metadata table` but the FROM clause reads `FROM iceberg.analytics.events_table` (the BASE table). The base data table has no `snapshot_id` / `committed_at` / `operation` / `summary` columns — those are only on the `"events_table$snapshots"` metadata-table form per trino.io/docs/current/connector/iceberg.html.

**Engineer impact**: copy-paste hits an immediate `Column 'snapshot_id' cannot be resolved` parse-time error.

**Root cause class**: same as iter452 Q2 — the explanatory comment in a code block doesn't match the actual SQL surface. The responder learned the metadata table by NAME but pasted the WRONG table reference. Findability gap: the canonical `$snapshots` query example in resources isn't being reached from "rollback" / "undo bad load" keyword paths.

## Fabrications & inaccuracies — full list with correct facts

| # | Q | Defect | Correct fact | Source |
|---|---|---|---|---|
| 1 | Q3 | Comment says "Query the $snapshots metadata table" but FROM is base table | Must be `FROM iceberg.<schema>."<table>$snapshots"` (double-quoted suffix). Base table has no snapshot_id column. | trino.io/docs/current/connector/iceberg.html (metadata tables section) |
| 2 | Q2 | Simple `CASE status WHEN 'A' ...` doesn't replicate Oracle DECODE's NULL=NULL match | Oracle DECODE treats NULL=NULL as TRUE; simple CASE uses `=` semantics where NULL=NULL is UNKNOWN. Full equivalence requires searched CASE with `WHEN col IS NULL` branch or COALESCE-wrap. | Oracle DECODE docs + trino.io/docs/current/language/expressions.html#case-expression |

**No fabricated PR#/issue#/function name/DDL clause/property/config-key/version-gated feature detected in Q1 or Q4.** The `CALL iceberg.system.rollback_to_snapshot('schema','table',id)` 3-arg positional form in Q3 IS valid in Trino 467 (verified via Starburst blog + trinodb/trino issue #12353 + PR #9921; PR #24580 deprecates it for later Trino versions, but the form works in 467).

## Teacher actions for iter 454

### PRIMARY FIX — Reconcile $snapshots metadata-table query pattern

The Q3 bug is a findability + canonical-form gap on Iceberg metadata tables. Add a leading canonical block to **resources/17-iceberg-table-maintenance.md** (or wherever the snapshot rollback content lives — verify with `grep -l rollback_to_snapshot resources/`):

```sql
-- CORRECT — query the $snapshots metadata table with double-quoted suffix
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics."events_table$snapshots"
ORDER BY committed_at DESC;

-- WRONG — querying the base table for snapshot metadata
-- SELECT snapshot_id, committed_at FROM iceberg.analytics.events_table
-- ERROR: Column 'snapshot_id' cannot be resolved
```

Place this **BEFORE** any `CALL iceberg.system.rollback_to_snapshot(...)` or `EXECUTE rollback_to_snapshot(...)` example, with the heading containing keywords engineers search for: "undo bad load", "rollback Iceberg", "find snapshot id", "$snapshots metadata table". Add a DO-NOT-WRITE callout explicitly contrasting the two FROM clauses.

Verify NO other resource has a stale `FROM iceberg.<schema>.<base_table>` example that purports to read `snapshot_id`/`committed_at` — grep for `snapshot_id FROM iceberg` across all resources and fix any that don't have the `"$snapshots"` suffix.

### SECONDARY FIX — Oracle DECODE NULL-matching nuance

Add a one-paragraph note to **resources/27-oracle-plsql-to-dbt-trino.md** under the DECODE → CASE rewrite section:

> Oracle DECODE matches NULL=NULL as TRUE; Trino simple `CASE col WHEN NULL THEN ...` does NOT match NULL because CASE uses `=` semantics. For full DECODE equivalence on NULL-bearing inputs, use searched CASE: `CASE WHEN col IS NULL THEN 'is_null' WHEN col = 'A' THEN 'a' ELSE 'other' END`. Or COALESCE-wrap with a sentinel.

Add a DO-NOT-WRITE callout against `CASE col WHEN NULL THEN ... END` because it never matches.

### BREADTH DESIGN for iter454 question selection

- **AVOID a dedicated federation probe** — topic remains at 4.49944/310 (just under the 4.5 override threshold). Per existing memory directive, only probe federation on bulletproofed angles. Skip federation this iter.
- **DO re-probe Q3 $snapshots** with different phrasing (e.g., "list snapshots before rollback", "find the snapshot ID committed just before the bad load") to verify the iter454 reconciliation lands on the responder side.
- **DO probe a new angle**: Iceberg `$history` vs `$snapshots` distinction (history shows is_current_ancestor flag; snapshots is the broader audit log). This tests the same metadata-table-name-suffix surface but from a different keyword path.
- **DO re-probe Oracle migration** with a NULL-bearing input case to verify the DECODE NULL-nuance fix lands.
- **Continue probing CBO/ANALYZE** — Q4 was strong; a different angle like `drop_extended_stats` procedure or PARTITION-aware ANALYZE would reinforce the override-threshold topic.

### Citation-hygiene streak status

- Iter452 BROKEN (Q2 dbt-trino syntax — 2 defects).
- Iter453 PARTIALLY RESTORED on dbt-trino topic; NEW BREAK on Iceberg metadata-table FROM clause (Q3 — 1 defect).
- **Pattern**: responder pastes code blocks where the explanatory comment doesn't match the SQL surface. Teacher fix is canonical leading examples + DO-NOT-WRITE callouts that contrast the wrong form against the right form on the same page.

## Topic average updates (iter453)

| Topic | iter452 | iter453 | delta |
|---|---|---|---|
| Postgres-to-Iceberg ingestion (dbt incremental Q1) | 4.4914/153 | 4.4936/154 | +0.0022 |
| Oracle PL/SQL→dbt/Trino migration (Q2) | 4.6465/25 | 4.6403/26 | -0.0062 |
| Iceberg table maintenance (Q3) | 4.5117/113 | 4.5072/114 | -0.0045 |
| Trino CBO/ANALYZE (Q4) | 4.6588/12 | 4.6707/13 | +0.0119 |
| Trino federation (NOT probed) | 4.49944/310 | 4.49944/310 | 0 |

All probed topics remain PASSED. CBO/ANALYZE override-threshold topic strengthening (4.6707 well above 4.5 floor). Federation gap unchanged — needs different strategy than incremental probes.
