# Judge Feedback — Iteration 1297

**Overall: 4.547 — PASS. Pure breadth round. Q1 (COUNT(*) FILTER (WHERE event_type='error') single-pass conditional aggregation) 4.9375 STRONG; Q2 (CALL iceberg.system.rollback_to_snapshot('analytics','events',<id>) metadata-only revert via $snapshots lookup) 4.75 STRONG, matches pinned `reference_trino_rollback_snapshot_form` 3-arg CALL form for 467 (ALTER TABLE EXECUTE form is 469+); Q3 (dbt build = run+test+seed+snapshot in DAG order; dbt run = models only; test failure exits non-zero + skips downstream) 4.875 STRONG; Q4 (Oracle GROUP BY leniency → Trino strictness) 3.625 PASS with substantial FALSE-PREMISE drag — responder ACCEPTED + ENDORSED the engineer's incorrect claim that "Oracle is lenient" about non-grouped non-aggregated columns, then hedged on "why Oracle is lenient." Oracle is actually STRICT here (ORA-00979 "not a GROUP BY expression" — verified at [docs.oracle.com/en/error-help/db/ora-00979](https://docs.oracle.com/en/error-help/db/ora-00979/) + [databasestar.com/ora-00979-error](https://www.databasestar.com/ora-00979-error/)); MySQL with ONLY_FULL_GROUP_BY disabled is the lenient one (Oracle has no functional-dependency relaxation). This is the INVERSE of iter1291-Q4 where the responder correctly corrected a false COUNT-NULL premise. The Trino remedies themselves (DROP stray col / WRAP in arbitrary()/min()/max() / ADD to GROUP BY) are CORRECT + resource-faithful (r23 §2699-2738) — the false-premise endorsement is RESPONDER-ADDED, NOT resource-sourced. Per-instance responder slip, NO FIX-A (r23 doesn't claim Oracle is lenient — adding an "Oracle is strict too" defang in r27 §Oracle-vs-Trino-dialect could be considered as LIGHT FIX-A if pattern recurs). No FAILs. Continuous PASS-loop holds (iter1296 4.578 → iter1297 4.547, -0.031). All required topics REMAIN PASSED.**

| Q | Score | Acc | Clar | Prac | Compl | Topic | Result |
|---|---|---|---|---|---|---|---|
| 1 | 4.9375 | 5.0 | 5.0 | 5.0 | 4.75 | SQL query best practices for OLAP | STRONG PASS |
| 2 | 4.75 | 5.0 | 4.75 | 4.75 | 4.5 | Iceberg table maintenance | STRONG PASS |
| 3 | 4.875 | 5.0 | 4.75 | 5.0 | 4.75 | Improving complex SQL performance on Trino with dbt | STRONG PASS |
| 4 | 3.625 | 2.5 | 4.0 | 4.5 | 3.5 | Oracle PL/SQL → dbt + Trino SQL migration | PASS (false-premise endorsement) |

## Q1 — COUNT(*) FILTER (WHERE event_type='error') — 4.9375 STRONG PASS

**Responder gave the canonical conditional-aggregation form:**
```sql
SELECT customer_id,
       COUNT(*) AS total_count,
       COUNT(*) FILTER (WHERE event_type = 'error') AS error_count
FROM events
GROUP BY customer_id;
```

**Verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html)**: "The FILTER keyword can be used to remove rows from aggregation processing with a condition expressed using a WHERE clause. This is evaluated for each row before it is used in the aggregation and is supported for all aggregate functions." COUNT(*) FILTER (WHERE ...) is the canonical Trino 467 single-pass conditional-aggregation form — one table scan, no subquery JOIN, no UNION. Responder correctly noted both FILTER and SUM(CASE WHEN cond THEN 1 ELSE 0 END) work and are equivalent, but FILTER is cleaner + more readable + standard-SQL idiomatic. 500M-row scale: one pass, no skew, no extra shuffle.

Acc 5.0 (FILTER syntax correct + valid Trino 467, single-pass mechanics correct, SUM(CASE) equivalence correct), Clar 5.0 (clear single-query answer, contrasts both approaches), Prac 5.0 (copy-paste ready, scale-appropriate), Compl 4.75 (could have surfaced FILTER works with any aggregate including SUM/AVG/array_agg — not just COUNT — useful for the engineer's likely follow-up questions; minor recall ceiling, not load-bearing).

No imported-prior, no broken-secondary, no over-warning, no fabrication. SQL best practices for OLAP topic 4.5891/309 → (4.5891×309 + 4.9375)/310 = (1418.0319 + 4.9375)/310 = 1422.9694/310 = **4.5902/310 PASSED** (+0.0011, margin +1.0902).

## Q2 — CALL iceberg.system.rollback_to_snapshot('analytics','events',<id>) — 4.75 STRONG PASS

**Responder gave the canonical Trino 467 rollback workflow:**
```sql
-- 1) Find the pre-bad-run snapshot
SELECT snapshot_id, committed_at, parent_id, summary
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC;

-- 2) Roll back (positional args, NOT named)
CALL iceberg.system.rollback_to_snapshot('analytics', 'events', 1234567890123456789);
```

**Verified against pinned `reference_trino_rollback_snapshot_form` + [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html)**: the 3-arg CALL form (`schema_name`, `table_name`, `snapshot_id`) is the Trino 467 canonical; the table-procedure form `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id => ...)` deprecated `system.rollback_to_snapshot` and lands in **469+** (per [trinodb/trino #24580](https://github.com/trinodb/trino/pull/24580)). For 467 stack, the 3-arg CALL form is the ONLY option. `events$snapshots` metadata table for snapshot lookup is correct. Responder correctly framed it as "metadata-only, atomic, rewrites only the table-pointer in HMS — does NOT touch the 400M rows of underlying Parquet files" — accurate (rollback just repoints `current-snapshot-id` in the metadata.json + commits a new HMS pointer; data files unaffected). Time-to-execute is seconds regardless of table size.

Acc 5.0 (3-arg CALL form correct, positional-not-named correct, metadata-only mechanism correct, $snapshots metadata table correct, all matches the pin), Clar 4.75 (clean 2-step workflow), Prac 4.75 (copy-pasteable), Compl 4.5 (**minor caveat omitted**: rollback DISCARDS ALL writes committed after the chosen snapshot — including any legitimate concurrent writes that may have happened after the bad run. For this engineer's scenario the bad run was the only write so it's harmless, but the engineer should know that on a busier table they'd need to identify the snapshot IMMEDIATELY before the bad run + plan to replay any legitimate writes afterward. Minor recall ceiling, not load-bearing for the question as posed).

No imported-prior, no broken-secondary, no over-warning, no fabrication. Iceberg table maintenance topic 4.4568/248 → (4.4568×248 + 4.75)/249 = (1105.2864 + 4.75)/249 = 1110.0364/249 = **4.4580/249 PASSED** (+0.0012, margin +0.9580).

## Q3 — dbt build vs dbt run (CI switch) — 4.875 STRONG PASS

**Responder gave the canonical comparison + CI recommendation:**

- `dbt run` = **models ONLY** (no tests, no seeds, no snapshots; tests need separate `dbt test` step)
- `dbt build` = **models + seeds + snapshots AND tests** orchestrated in DAG order; per-node: unit tests BEFORE materialization, data tests AFTER; failing test (severity error default) **exits non-zero + skips downstream models** (subgraph isolation)
- Recommended switching CI from `dbt run` → `dbt build`: tests run automatically (no separate `dbt test` step needed), bad data fails build, downstream skipped, single command for CI

**Verified at [docs.getdbt.com/reference/commands/build](https://docs.getdbt.com/reference/commands/build)** + WebSearch: "dbt build begins by building the selected models, seeds, and snapshots in DAG order, then automatically runs associated unit, schema and data tests. In contrast, dbt run performs no validation: no tests are executed." DAG-order test ordering: unit tests BEFORE the model is materialized (catches bad SQL before bad output gets written), data tests AFTER the model is materialized (validates the actual output rows). Failing test with severity=error causes downstream models to be SKIPPED (not failed) — preserves partial progress + clean error surface.

Acc 5.0 (run/build scope difference correct, DAG-order test execution correct, severity/exit-code/skip-downstream behavior correct), Clar 4.75 (cleanly contrasted both commands + CI recommendation), Prac 5.0 (engineer knows exactly to swap `dbt run` for `dbt build` in CI; no separate `dbt test` step needed), Compl 4.75 (could have surfaced `dbt build --fail-fast` for fail-on-first-error CI behavior + `--store-failures` for diagnosing which rows failed, but minor recall ceiling).

No imported-prior, no broken-secondary, no over-warning, no fabrication. Improving complex SQL performance on Trino with dbt topic 4.4557/92 → (4.4557×92 + 4.875)/93 = (409.9244 + 4.875)/93 = 414.7994/93 = **4.4602/93 PASSED** (+0.0045, margin +0.9602).

## Q4 — Oracle GROUP BY "leniency" → Trino — 3.625 PASS (false-premise endorsement)

**The DEFECT — responder ACCEPTED + ENDORSED a FALSE engineer premise.**

Engineer claimed "Oracle never complained" about `SELECT customer_id, customer_name, email, signup_date FROM customers GROUP BY customer_id` (non-grouped non-aggregated columns). Responder accepted this premise and tried to explain WHY Oracle is lenient, eventually hedging "I don't have enough information to explain why Oracle is lenient about this."

**Oracle is NOT lenient about this. Verified at [docs.oracle.com/en/error-help/db/ora-00979](https://docs.oracle.com/en/error-help/db/ora-00979/) + [databasestar.com/ora-00979-error](https://www.databasestar.com/ora-00979-error/) + [techonthenet.com/oracle/errors/ora00979.php](https://www.techonthenet.com/oracle/errors/ora00979.php)**: Oracle throws **ORA-00979 "not a GROUP BY expression"** for any non-grouped non-aggregated column in the SELECT list. Oracle does NOT have the functional-dependency relaxation that MySQL (with `ONLY_FULL_GROUP_BY` disabled) or PostgreSQL (when GROUP BY includes the PK) have. **Oracle is just as strict as Trino on this rule.**

What the engineer likely encountered:
- Confused Oracle with **MySQL** (with `ONLY_FULL_GROUP_BY` disabled — the historical default before MySQL 5.7 — picks an arbitrary value for ungrouped columns, no error). This is the most common source of "DB never complained about my GROUP BY" folklore.
- OR the original Oracle query was actually different (e.g., the non-grouped columns WERE in the GROUP BY, or were wrapped in `MAX()`/`MIN()`, or the table was actually grouped by all selected columns).

**The IDEAL answer would CORRECT the false premise**: "Oracle is actually strict here too — it throws ORA-00979 for the same construct. You may be thinking of MySQL with ONLY_FULL_GROUP_BY disabled, which IS lenient. Check the Oracle SQL again — likely the original had different GROUP BY columns or wrapped the extra columns in MAX()."

**This is the INVERSE of iter1291-Q4**, where the responder CORRECTLY corrected a false COUNT-NULL premise. Here the responder failed the same false-premise-correction test.

**The Trino remedies themselves are CORRECT + resource-faithful** (cited r23 §2699-2738):
1. **DROP the stray column** if not needed in output
2. **WRAP in arbitrary()** (or `min()`/`max()`) — picks one value per group, no semantic guarantee
3. **ADD to GROUP BY** — changes grain to per-(customer_id, customer_name, email, signup_date)

These three remedies are accurate Trino 467 + standard-SQL canonical, and r23 §2699-2738 (responder-cited) covers ONLY Trino's strictness + the three remedies — **r23 makes NO "Oracle is lenient" claim**. The false premise is RESPONDER-ADDED, NOT resource-sourced. Resource is clean.

**Classification**: per-instance responder slip in the explanation portion (failed to identify + correct a false premise about Oracle behavior); Trino remedies (the load-bearing actionable content) are correct. Engineer following the Trino remedies will get a working Trino query; the misattribution to Oracle "leniency" leaves them with a wrong mental model but doesn't break their migration.

**NO FIX-A** on first occurrence. Per pinned `feedback_responder_overwarning_folklore.md` + `feedback_responder_broken_secondary_alternative.md` family — recall ceiling, no resource fix unless pattern recurs. If a 2nd false-premise-Oracle-leniency endorsement appears in 4-8 iters, escalate to LIGHT FIX-A: short defang card at r27 Oracle-vs-Trino-dialect intro ("Oracle is JUST AS STRICT as Trino on GROUP BY — throws ORA-00979 for non-grouped non-aggregated columns. The 'lenient' database the user may be thinking of is MySQL with ONLY_FULL_GROUP_BY disabled, NOT Oracle."). Add to DO-NOT-WRITE: "Oracle is lenient about GROUP BY" (WRONG — Oracle throws ORA-00979).

Acc 2.5 (Trino remedies correct, but Oracle-is-lenient endorsement is flat false + load-bearing for the question framing), Clar 4.0 (remedies clearly stated, but the false-premise hedge "I don't have enough information" is confusing because the premise itself is wrong), Prac 4.5 (the 3 Trino remedies are actionable, engineer gets working Trino SQL), Compl 3.5 (failed to identify the false premise — the question's framing was the core completeness ask, and the responder missed it).

**NEW SOFT WATCH `iter1297-Q4 Oracle-GROUP-BY-leniency false-premise endorsement`**: re-probe in 4-8 iters under varied "Oracle was lenient, Trino is strict" framings; if 2+ recurrences, escalate to LIGHT FIX-A (additive r27 defang card + DO-NOT-WRITE).

No imported-prior in the strict sense (responder didn't fabricate dialect facts — it endorsed an engineer's wrong premise about a non-Trino dialect's behavior). No broken-secondary, no over-warning, no fabrication. Oracle PL/SQL → dbt + Trino topic 4.5014/270 → (4.5014×270 + 3.625)/271 = (1215.378 + 3.625)/271 = 1219.003/271 = **4.4982/271 PASSED** (-0.0032, margin +0.9982).

## Carries / Watches

- **NEW SOFT WATCH `iter1297-Q4 Oracle-GROUP-BY-leniency false-premise endorsement`**: re-probe 4-8 iters; LIGHT FIX-A at 2nd recurrence.
- CARRY iter1296-Q1 CONTAINS+GROUP-BY-no-bool_or secondary (broken-secondary family, ~10th instance, NO resource fix).
- CARRY iter1296-Q3 singular-test-omitted (completeness gap; re-probe under "one-off model rule" framings).
- CARRY iter1295-Q2 FIRST_VALUE-priming.
- CARRY iter1294-Q4 ROWNUM-per-group.
- CARRY iter1290-Q3 small-files-routing.
- CARRY iter1289-Q2 position-delete-Spark-vs-Trino.
- CARRY iter1289-Q4 LPAD-RPAD-false-divergence.

All required topics REMAIN PASSED. Continuous PASS-loop holds.
