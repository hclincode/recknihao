# Judge Feedback — Iteration 1295

**Overall: 4.4375 — PASS. Q1 RE-PROBE of the iter1281-1284 perf-triage recall-ceiling FULLY REACHES (perfect 5.0): system.runtime.queries JOIN system.runtime.tasks ON query_id, physical_input_bytes + split_cpu_time_ms, both-tables-needed, `"user"` reserved-quoting, ~15-min ring-buffer caveat — every load-bearing element of r18 §"Finding expensive queries on Trino 467" lifted cleanly. The iter1282-1283 affirmative-first HOIST at r18 §404 + L127 land-point pointer + r05 §3833 reconcile FIX-A landed = `iter1281-1284 perf-triage system.runtime.queries-JOIN-tasks recall-ceiling` SOFT WATCH CLOSES POSITIVELY (full reach on 1st post-hoist re-probe). Q2 is the iter's outlier (3.375): caveats CORRECT but worked query OVERCOMPLICATED + MISSING DEDUP — returns one row per EVENT not one row per ACCOUNT (engineer asked for "one output row" per customer). Q3/Q4 clean (4.5 / 4.875). No FAILs. No FIX-A this iter — Q2 slip is the keyword-priming-overrides-canonical-routing pattern under "Responder Broken Secondary Alternative" / synthesis-ceiling family, not a resource gap (r07 §3917 DECISION INOCULATION for "one row per entity, first AND last value" is fully anchored with min_by/max_by routing).**

| Q | Score | Acc | Clar | Prac | Compl | Topic | Result |
|---|---|---|---|---|---|---|---|
| Q1 (perf-triage RE-PROBE — queries JOIN tasks on query_id) | **5.000** | 5.0 | 5.0 | 5.0 | 5.0 | Query performance regression diagnosis | RECALL-CEILING WATCH CLOSES POSITIVELY |
| Q2 (FIRST_VALUE/LAST_VALUE first/last per account in one row) | **3.375** | 3.0 | 4.0 | 3.0 | 3.5 | Analytical query patterns on Iceberg+Trino | Caveats OK, worked query overcomplicated + missing dedup |
| Q3 (dbt on-run-start/on-run-end semantics + session_properties routing) | **4.500** | 4.5 | 4.5 | 4.5 | 4.5 | Improving complex SQL performance on Trino with dbt | Clean, minor register_table wart |
| Q4 (Oracle DATE='string' → Trino DATE literal / no implicit coerce) | **4.875** | 5.0 | 4.75 | 5.0 | 4.75 | Oracle PL/SQL → dbt+Trino | Clean |

---

## Q1 — Perf-triage recipe FULLY REACHES (perfect 5.0); recall-ceiling WATCH CLOSES POSITIVELY

**Recipe verified correct Trino 467.** WebFetch of [raw.githubusercontent.com/trinodb/trino/467/.../TaskSystemTable.java](https://raw.githubusercontent.com/trinodb/trino/467/core/trino-main/src/main/java/io/trino/connector/system/TaskSystemTable.java) confirms `system.runtime.tasks` columns include both `physical_input_bytes` (BIGINT) AND `split_cpu_time_ms` (BIGINT) + `query_id` column for the JOIN. Per the file's full column list:

```
node_id, task_id, stage_id, query_id, state, splits, queued_splits, running_splits, completed_splits,
split_scheduled_time_ms, split_cpu_time_ms, split_blocked_time_ms,
raw_input_bytes, raw_input_rows, processed_input_bytes, processed_input_rows,
output_bytes, output_rows, physical_input_bytes, physical_written_bytes,
created, start, last_heartbeat, end
```

Per the iter1283 verification of `QuerySystemTable.java`@467: `system.runtime.queries` has `query_id` (matching `tasks.query_id`), `"user"` (the reserved-word quoted column), `source`, `query`, `state`, `created`, `end` — matches the responder's SELECT list exactly. Both tables expose the JOIN key (`query_id`); the SUM aggregation is required because `tasks` is per-task per-stage per-worker (one query → many tasks).

**Every load-bearing element reached:**
- ✅ JOIN both tables on `query_id` (the "both-tables-needed" recipe shape — queries has SQL text/identity, tasks has counters)
- ✅ `tasks.physical_input_bytes` (storage-layer bytes, not logical `processed_input_bytes`)
- ✅ `tasks.split_cpu_time_ms` (not the invented `cpu_time_ms`)
- ✅ `q."user"` double-quoted (unquoted = `current_user` builtin silently returns session user on every row — Trino reserved-word trap)
- ✅ `q.state IN ('RUNNING','FINISHED')` for running + just-finished window
- ✅ `SUM(...) / 1e9 AS gb_scanned` + `SUM(...) / 1000.0 AS cpu_seconds` GROUP BY q.query_id + identity cols
- ✅ ~15-min ring buffer / 100-query history caveat with `query.max-history` / `query.min-expire-age` named
- ✅ Event listener routed for windows longer than the ring buffer

**RECALL-CEILING WATCH CLOSES POSITIVELY.** This recipe NON-REACHED 4 consecutive times (iter1281-1284 — responder kept stopping at "queries doesn't have those columns" / "use event listener" without reaching the tasks JOIN). The iter1282-1283 affirmative-first HOIST at r18 §404 + L127 land-point pointer in §"DO-NOT-WRITE" + r05 §3833 reconcile FIX-A is what FINALLY routed it. iter1284 escalation note declared this a periodic SOFT re-probe expecting occasional misses; this iter shows the FIX-A reached on the 1st post-iter1284 re-probe at a perfect 5.0. **The recall-ceiling watch closes positively** — pattern matches iter1272 bloom-CREATE-467 hard-watch close (1st re-probe full reach after r17 §713 reconcile).

**No imported-prior, no broken-secondary, no over-warning, no fabrication. Topic 4.0923/24 → (98.2152 + 5.0)/25 = 103.2152/25 = 4.1286/25 PASSED (+0.0363, margin +0.6286, lifts thinnest required topic).**

---

## Q2 — FIRST_VALUE/LAST_VALUE: caveats correct, worked query DEFECTIVE (overcomplicated + missing dedup)

**The CONCEPT-LEVEL caveats are correct + valuable.** Both load-bearing FIRST_VALUE/LAST_VALUE traps named:
- ✅ `IGNORE NULLS` placement: **OUTSIDE** the closing OVER paren — `FIRST_VALUE(status) IGNORE NULLS OVER (...)`, NOT `FIRST_VALUE(status IGNORE NULLS) OVER (...)`. Matches r07 §1657-1664 verbatim.
- ✅ LAST_VALUE default-frame footgun: default is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, so without an explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` frame the function silently returns the current row's value, NOT the partition's true last. Matches r07 §3865-3873 verbatim.
- ✅ Bonus mention: `LAG IGNORE NULLS` for prev-non-null (depth signal).

**BUT the worked query is wrong-shaped for the engineer's stated goal.** Two defects:

**(a) The INTERVAL RANGE frames on top of a `WHERE event_timestamp IN [month-start, month-end)` filter are pointlessly complicated.** The responder wrote:

```sql
FIRST_VALUE(status) OVER (PARTITION BY account_id ORDER BY event_timestamp
                          RANGE BETWEEN INTERVAL '1' MONTH PRECEDING AND CURRENT ROW) AS status_at_month_start
LAST_VALUE(status)  OVER (PARTITION BY account_id ORDER BY event_timestamp
                          RANGE BETWEEN CURRENT ROW AND INTERVAL '1' MONTH FOLLOWING) AS status_at_month_end
WHERE event_timestamp >= <month_start> AND event_timestamp < <month_end>
```

Trino 467 DOES support RANGE BETWEEN INTERVAL '1' MONTH frames on timestamp ORDER BY columns (verified at [trino.io/blog/2021/03/10/introducing-new-window-features.html](https://trino.io/blog/2021/03/10/introducing-new-window-features.html) — RANGE-with-offset since release 346: *"`RANGE BETWEEN interval '1' month PRECEDING AND CURRENT ROW`"* canonical example). So the syntax compiles. But it's the wrong tool here. Once `WHERE` has already filtered to one month, the right move is the partition-wide full frame:

```sql
-- ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING — full partition
FIRST_VALUE(status) OVER (PARTITION BY account_id ORDER BY event_timestamp
                          ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
```

…or, simpler still, just `FIRST_VALUE` with the default frame (which IS partition-start-safe per r07 §3871) + `LAST_VALUE` with the explicit UNBOUNDED-PRECEDING-AND-UNBOUNDED-FOLLOWING frame. The INTERVAL-RANGE-frames-on-top-of-WHERE shape is over-engineered.

**(b) MISSING dedup — output is one row per EVENT, not one row per ACCOUNT.** The engineer asked for "subscription status at month START and month END **in one output row**" (i.e. one row per customer/account). FIRST_VALUE/LAST_VALUE are WINDOW functions that return one value per INPUT row — without `SELECT DISTINCT` (or wrapping in a `ROW_NUMBER() = 1` filter), the SQL emits one row per event-in-the-month per account, with the same status_at_month_start / status_at_month_end repeated on every event row. Engineer paste-runs this and gets thousands of duplicate rows. r07 §3917 (the iter658 DECISION INOCULATION) explicitly calls this out:

> *"`first_value` / `last_value` are WINDOW functions … they return one value per input row, not per group … the window form yields one row per INPUT ROW (per event); SELECT DISTINCT collapses to one-per-id. Cheaper to just use min_by/max_by aggregates."*

**The CLEAN forms (preferred → fallback):**

1. **PREFERRED (r07 §3917 LEADING CANONICAL)**: aggregate `min_by` / `max_by` with `GROUP BY` — one pass, one row per account directly, no DISTINCT cost:
   ```sql
   SELECT account_id,
          min_by(status, event_timestamp) AS status_at_month_start,
          max_by(status, event_timestamp) AS status_at_month_end
   FROM iceberg.analytics.events
   WHERE event_timestamp >= DATE '2026-06-01'
     AND event_timestamp <  DATE '2026-07-01'
   GROUP BY account_id;
   ```

2. **FALLBACK (still valid, worse cost — explicit in r07 §3946)**: window form + `SELECT DISTINCT`:
   ```sql
   SELECT DISTINCT account_id,
          FIRST_VALUE(status) OVER (PARTITION BY account_id ORDER BY event_timestamp) AS status_at_month_start,
          LAST_VALUE(status)  OVER (PARTITION BY account_id ORDER BY event_timestamp
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS status_at_month_end
   FROM iceberg.analytics.events
   WHERE event_timestamp >= DATE '2026-06-01' AND event_timestamp < DATE '2026-07-01';
   ```

**Is this a per-instance synthesis slip or a resource gap? — Per-instance slip; do NOT FIX-A.** I grepped r07 for the FIRST_VALUE/LAST_VALUE first/last-in-group canonical:

- r07 §3917 ("Pattern B3 LEADING CANONICAL — `first_value` / `last_value` / `nth_value` default-frame footgun") + the iter658 DECISION INOCULATION block at §3917-3958 contain the EXACT canonical the engineer needed, with extensive keyword anchors: *"first and last value per group, first and latest status per user, earliest and most recent status per entity, first_value last_value with GROUP BY, one row per entity first and last, first and current value per id, first and last STATE per ID, opening and closing value per entity, status of first login and status of last login per user, first and current plan tier per subscriber"* — and the PREFERRED block (`min_by` + `max_by` + `GROUP BY`) is the very first answer shown.

The canonical IS anchored. The responder failed to route to §3917 — almost certainly because the engineer's Q2 wording PRIMED the surface ("Self-join was messy; **window functions for first/last in a group**; anything tricky?") with FIRST_VALUE/LAST_VALUE specifically. The responder landed on Pattern B3 (the default-frame footgun H3 right above §3917) and lifted FIRST_VALUE/LAST_VALUE in good faith — but it missed the §3917 DECISION INOCULATION explicitly *redirecting* "one output row per entity" framings to `min_by`/`max_by`.

This is the same shape as the iter936 / iter943 / iter954 / iter1013 / iter1019 / iter1020 broken-secondary-alternative slips (pinned at `feedback_responder_broken_secondary_alternative.md`) but RAISED to "the WHOLE worked query is the wrong shape" because the engineer primed the response surface with FIRST_VALUE/LAST_VALUE specifically — not a SECONDARY for-completeness aside that's broken, but the PRIMARY worked query priming-locked to a wrong shape. The SAFETY caveats (IGNORE NULLS placement + LAST_VALUE default-frame footgun) ARE correct + load-bearing — the responder's recall on those is solid.

**No FIX-A** per `feedback_synthesis_ceiling_stop_churning.md` + `feedback_new_card_over_attracts_adjacent.md`:
- The §3917 DECISION INOCULATION already routes "one row per entity, first AND last value of a column" to `min_by`/`max_by` with extensive keyword anchors.
- Adding more keyword anchors risks over-attracting other FIRST_VALUE/LAST_VALUE questions that DO want the window form (the Pattern B3 default-frame footgun lands cleanly on its own canon, see iter1131-area).
- The responder's recall ceiling is "engineer-mentions-FIRST_VALUE → I deliver FIRST_VALUE" (priming dominates dedup-shape recognition) — characteristic Haiku synthesis ceiling, not a resource gap.

**Topic 4.4842/209 → (937.2978 + 3.375)/210 = 940.6728/210 = 4.4794/210 PASSED (-0.0048, margin +0.9794).** Topic stays comfortably above threshold; 1 weak datapoint on 210 doesn't move much.

**NEW SOFT WATCH `iter1295-Q2 FIRST_VALUE-keyword-priming-overrides-one-row-per-entity-routing-to-min_by/max_by`**: re-probe 4-8 iters under varied framings that include both (a) the FIRST_VALUE/LAST_VALUE keyword AND (b) "one output row per entity" framing; if 2+ recurrences across distinct framings, consider a LIGHT FIX-A at r07 §3861 (Pattern B3 LEADING CANONICAL opening paragraph) adding a "**STOP — if you want ONE ROW PER ENTITY, jump to §3917 NOW**" callout — but ONLY if it recurs (don't churn).

---

## Q3 — dbt on-run-start / on-run-end semantics: clean (4.5)

**Load-bearing facts correct + verified:**
- ✅ **Once per dbt invocation, not per model.** WebFetch of [docs.getdbt.com/reference/project-configs/on-run-start-on-run-end](https://docs.getdbt.com/reference/project-configs/on-run-start-on-run-end) confirms hooks run during `dbt build / compile / docs generate / run / seed / snapshot / test` at the project-command level (not the model level). The astronomer/cosmos issue (#1443) explicitly calls out the edge case where Cosmos splits a project into multiple dbt-run commands and each one re-fires the hooks — confirming the "once-per-invocation-of-the-dbt-command" semantics.
- ✅ **Separate connection from models.** dbt runs hooks on a "master" connection (visible in the elementary-data #1712 issue: *"Tried to commit transaction on connection 'master'"*); models run on per-thread worker connections from the connection pool. on-run-start fires BEFORE the worker pool spins up; on-run-end fires AFTER all worker threads have completed and been released.
- ✅ **SET SESSION in on-run-start does NOT persist to model connections.** Connection-scoped — when the master connection closes (or is returned to the pool), Trino session-property state is gone. Subsequent model connections are fresh from the JDBC pool with default session state.
- ✅ **Correct routing for cross-model session settings**: `profiles.yml` session_properties block (dbt-trino-specific config that applies to every connection the adapter opens). The responder correctly named this as the right tool for `query_max_memory_per_node` etc.
- ✅ **on-run-end + `results` Jinja variable** for failure-count audit row matches the [docs.getdbt.com/reference/dbt-jinja-functions/on-run-end-context](https://docs.getdbt.com/reference/dbt-jinja-functions/on-run-end-context) page — `results` exposes per-node status for the just-completed run.

**Minor wart (-0.5 Compl):** The `register_table` CALL inclusion in the on-run-start example is odd — `register_table` is for adopting an existing Iceberg metadata file into the Hive Metastore catalog (one-time table-bootstrap pattern), not for creating an empty audit table. Engineer might paste it and get confused. Better to use `CREATE TABLE IF NOT EXISTS iceberg.audit.run_log (...)` for the audit-table bootstrap. Not load-bearing — the load-bearing parts (once-per-invocation + separate connection + SET-SESSION-doesn't-persist + use profiles.yml session_properties + results-var-for-failures) are all correct.

**Topic 4.4561/90 → (401.049 + 4.5)/91 = 405.549/91 = 4.4566/91 PASSED (+0.0005, margin +0.9566).**

---

## Q4 — Oracle DATE='string' → Trino: clean (4.875)

**Load-bearing facts correct + verified:**
- ✅ **Oracle implicitly coerces VARCHAR to DATE; Trino does NOT.** Verified via Trino 467 type-coercion behavior — Trino's [comparison.html](https://trino.io/docs/current/functions/comparison.html) + [conversion.html](https://trino.io/docs/current/functions/conversion.html) require explicit cast between VARCHAR and DATE for comparison. The exact failure mode the engineer hit: `WHERE order_date = '2024-01-15'` on a DATE column throws *"Cannot apply operator: date = varchar(10)"* type-mismatch error (or returns zero rows on lenient compatibility paths if any).
- ✅ **Fix: typed DATE literal**: `WHERE order_date = DATE '2024-01-15'` (preferred — ANSI SQL typed-literal form, no function call, predicate cleanly pushes to the connector). CAST form: `WHERE order_date = CAST('2024-01-15' AS DATE)` (also fine but slightly noisier).
- ✅ **Range form**: `WHERE order_date >= DATE '2024-01-01' AND order_date < DATE '2024-02-01'` — the bare-column-comparison-to-date-literal form that's safest for partition pruning per `reference_trino_unwrap_temporal_predicates.md` + r10 predicate-pushdown rules.
- ✅ **TO_DATE doesn't exist in Trino.** Correct — `TO_DATE` is Oracle-specific (Trino 467 has `date_parse(s, format)` Oracle-Java-style + `CAST(date_parse(...) AS DATE)` for non-ISO strings, plus the typed-literal `DATE '...'` form for ISO `YYYY-MM-DD`).
- ✅ **Non-ISO string parsing**: `CAST(date_parse('03/15/2024','%m/%d/%Y') AS DATE)` — correct two-step (date_parse → timestamp, CAST → date).

**Minor shaves (-0.25 Clar, -0.25 Compl):**
- Didn't explicitly call out that the `DATE '...'` form has STRICT ISO YYYY-MM-DD requirement (parse fails on `DATE '01/15/2024'`); the engineer would discover this on a non-ISO source string, but the responder DID cover non-ISO with the `date_parse` route so it's just a clarity-of-flow shave.
- Didn't mention the `from_iso8601_date('2024-01-15')` alternative (rarely needed since `DATE '...'` covers ISO directly).

**Topic 4.4990/268 → (1205.732 + 4.875)/269 = 1210.607/269 = 4.5005/269 PASSED (+0.0015, margin +1.0005).**

---

## Summary of patterns + watch state

- **Q1 perf-triage recipe RECALL-CEILING SOFT WATCH (iter1281-1284) — CLOSES POSITIVELY.** Recipe fully reached on 1st post-iter1284 re-probe at perfect 5.0. The iter1282-1283 affirmative-first HOIST + L127 land-point pointer + r05 reconcile FIX-A landed cleanly. Same close-shape as iter1272 bloom-CREATE-467 (1st re-probe full reach after r17 reconcile).
- **Q2 first/last-per-entity routing — NEW SOFT WATCH (iter1295-Q2).** Engineer-mentions-FIRST_VALUE-keyword priming locked the responder onto Pattern B3 (default-frame footgun, FIRST_VALUE/LAST_VALUE window form) when the canonical for "one output row per entity" is `min_by`/`max_by` aggregates at r07 §3917. Caveats (IGNORE-NULLS-outside-paren + LAST_VALUE-default-frame) correct + load-bearing — slip is in the worked query shape, not the safety facts. Per `feedback_responder_broken_secondary_alternative.md` + synthesis-ceiling memory, NO FIX-A this iter — re-probe 4-8 iters, escalate to LIGHT FIX-A only if 2+ recurrences across distinct framings. Adding more keyword anchors at §3917 risks over-attracting Pattern B3 questions that DO want the window form.
- **Q3 dbt on-run-start/on-run-end** — clean, well-anchored, minor register_table wart.
- **Q4 Oracle DATE-string** — clean, all four fixes (DATE literal / CAST / range form / date_parse) reached.
- **Carries from prior iters:** iter1290-Q3 small-files-routing / iter1289-Q2 position-delete-Spark-vs-Trino / iter1289-Q4 LPAD-RPAD-false-divergence / iter1294-Q4 Oracle-ROWNUM-per-group-qualifier-drop — all periodic SOFT, re-probe when natural framing arises.
- **iter1281-1284 perf-triage-recall-ceiling periodic SOFT — CLOSES POSITIVELY this iter.**

**Iteration 1295 average 4.4375 — PASS, no FIX-A. Continue extended-phase breadth probing. Recall-ceiling FIX-A close-out is the standout positive signal.**
