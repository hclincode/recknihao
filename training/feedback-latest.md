# Iter1131 Feedback — 4.8594 STRONG PASS NO-OP (Q1 iter1130 SELECT-*-EXCEPT watch CLOSES on first re-probe; Q2/Q3/Q4 clean breadth)

## Per-question scores

### Q1 — `SELECT * EXCEPT (rn)` BigQuery shorthand availability in Trino + practical alternative (iter1130 watch re-probe) — 4.8750

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | "Trino 467 does NOT support `SELECT * EXCEPT (col)`; BigQuery/Databricks pattern; parse error" — exactly correct. Verified RAW: trinodb/trino issues #26402 + #26969 (and #23532) all OPEN as feature requests, not implemented as of 467/481. Trino's `EXCEPT` is a SET operator between queries (per trino.io/docs/current/sql/select.html), not a column-exclusion projection. Cross-reference to r23 §3286 is accurate (the iter1130 defang location). |
| Beginner clarity | 5.0 | Plain framing: "this is a BigQuery/Databricks shorthand, not Trino"; engineer immediately understands the dialect-portability issue. DESCRIBE-the-table-then-spell-out path is unambiguous. |
| Practical applicability | 5.0 | Hands the engineer the exact workflow: `DESCRIBE iceberg.schema.table` → copy the column list → strike `rn` → paste into the SELECT/INSERT. One-time friction, queries are correct, no dialect risk. Fits the on-prem Trino 467 production stack exactly. |
| Completeness | 4.5 | Covers the core question and the practical fix. MINOR SHAVE (-0.5): does not mention the experimental `exclude_columns` table function shape (`SELECT * FROM TABLE(exclude_columns(input => TABLE(t), columns => DESCRIPTOR(rn)))`) as a secondary alternative, nor a dbt macro / `dbt_utils.star(except=[...])` approach. The explicit-column-list-via-DESCRIBE is the canonical and most-robust answer; the omission is a per-instance shave, NOT a resource gap. |

**Verification (RAW Trino 467 docs + GitHub):** Confirmed `SELECT * EXCEPT (col)` is genuinely absent from Trino 467 SQL grammar. WebSearch returns trinodb/trino issues #26402 ("Feature Request: Support SELECT * EXCEPT") and #26969 ("Support SELECT * EXCEPT / EXCLUDE") and #23532 — all OPEN, not implemented. The iter1130 verification (open feature requests, foreign-projection pattern) holds.

**iter1130 watch verdict: CLOSED on first re-probe.** This is the 5th successful first-re-probe watch closure in 13 iters (iter1121 ADD-COLUMN / iter1125 partition-COUNT-folklore / iter1127 population-percentile / iter1130 dedup-tied-tuple / iter1131 SELECT-*-EXCEPT). Foreign-projection-shorthand sub-class of the imported-prior family confirmed first-instance responder one-off, not a structural findability gap. NO FIX-A needed.

### Q2 — Per-signup-month cohort 30/60/90-day retention in one pass — 4.5625

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | CTE structure correct: `first_events` collapses earliest signup per user → cohort_month bucket; `cohort_sizes` counts users per cohort; `returns` counts windowed retention via `COUNT(DISTINCT CASE WHEN date_diff('day', first_signup_at, login_at) BETWEEN 1 AND N THEN user_id END)` per window. The cumulative semantics (30d ⊆ 60d ⊆ 90d, since `BETWEEN 1 AND 30` ⊆ `BETWEEN 1 AND 60` ⊆ `BETWEEN 1 AND 90`) is correct for "% who logged in WITHIN N days". `COUNT(DISTINCT user_id)` correctly dedups users with multiple logins in-window (the responder's own SUM(CASE)-overcounts note is right). date_diff verified per trino.io/docs/current/functions/datetime.html (day unit). |
| Beginner clarity | 4.5 | Three CTEs labeled with intent; per-window CASE explained; the SUM-vs-COUNT-DISTINCT dedup distinction is explicitly called out (good inoculation against overcounting). |
| Practical applicability | 5.0 | Engineer can paste this into a dbt model as-is; the incomplete-cohort filter `WHERE date_diff('day', cohort_month, current_date) >= 90` keeps the dashboard honest. One pass, no three-separate-queries trap. |
| Completeness | 3.75 | **MINOR COMPLETENESS GAP (-1.25):** the responder used `JOIN returns r ON cohort_month` (inner join) between `cohort_sizes` and `returns`. Because `returns` is derived from `first_events JOIN login_events`, a cohort where ZERO users ever logged in vanishes from `returns` and the inner join drops it from the output entirely — so the cohort-size dashboard silently omits zero-retention cohorts. Correct shape is `LEFT JOIN returns ... COALESCE(returned_30d, 0)` so 0% cohorts appear as 0% not as missing rows. Real-world hit rate is low (most cohorts will have some retention), but the dashboard correctness gap is real. **Defect classification: RESPONDER ONE-OFF, NOT resource-sourced** — r07/r23 cohort canonicals correctly use LEFT JOIN; this is a per-instance synthesis slip, NOT a canonical defect. No FIX-A. |

**Verification:** date_diff('day', ts1, ts2) returns integer day count, BETWEEN N AND M is inclusive, CASE returns NULL outside the range so COUNT(DISTINCT) excludes the NULLs correctly. All-correct per trino.io/docs/current/functions/datetime.html.

### Q3 — `arbitrary` / `any_value` aggregate for 1:1 functionally-dependent column — 5.0000

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | "`arbitrary(account_name)` or `any_value(account_name)` — identical" verified against trino.io/docs/current/functions/aggregate.html: "`arbitrary(x)` — Returns an arbitrary non-null value of x, if one exists. Alias for any_value." Both exist in Trino 467. "Faster than MIN/MAX (no comparison)" correct — `arbitrary` short-circuits on first non-null, no ordering scan. The `max_by(account_name, updated_at)` recommendation for "as-of-latest" semantics on non-strictly-1:1 columns is the standard pattern (verified `max_by(x, y)` exists in Trino 467 aggregates). |
| Beginner clarity | 5.0 | Plain explanation of "functionally dependent" via 1:1 wording. Names the failure mode of arbitrary when column ISN'T truly 1:1 (could return different name per query). |
| Practical applicability | 5.0 | Engineer knows exactly what to type. Two-line decision tree: 1:1 → `arbitrary`/`any_value`; not 1:1 → `max_by(account_name, updated_at)`. |
| Completeness | 5.0 | Covers idiomatic choice, the alias relationship, the perf vs MIN/MAX nuance, AND the safety caveat. No padding, no foreign-dialect functions, no broken secondary alternative. |

**Verification:** `arbitrary` ↔ `any_value` alias relationship confirmed in Trino 427/467/478/481 aggregate docs. `max_by(x, y)` for "x corresponding to the maximum value of y" confirmed.

### Q4 — CBO + ANALYZE + join_distribution_type for slow 3-4 table dbt joins — 5.0000

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | All-correct, source-verified: (a) Trino has a CBO but needs stats — verified trino.io/docs/current/optimizer/statistics.html: "Trino calculates NDV statistics during analyzing table and writes NDV statistics to the Iceberg puffin file"; (b) bare `ANALYZE iceberg.schema.table` syntax (NO TABLE keyword) — verified against trino.io/docs/current/sql/analyze.html; "ANALYZE TABLE is Spark/Hive parse error" inoculation correct (this is a recurring imported-prior trap); (c) Puffin NDV stats consumed by CBO for join order + broadcast/partitioned choice — verified per the optimizer docs; (d) "stats don't auto-update, re-run after big ingest" correct — confirmed in the Trino statistics doc; (e) `SET SESSION join_distribution_type = PARTITIONED/BROADCAST/AUTOMATIC` — `join_distribution_type` is a real session property in Trino 467 with those three values. |
| Beginner clarity | 5.0 | Names the root cause ("guesses without stats → backwards order") and the fix in one breath. Plain analogy for ANALYZE-as-statistics-population. |
| Practical applicability | 5.0 | Engineer leaves with a concrete checklist: (1) run ANALYZE on each large Iceberg table, (2) verify EXPLAIN now picks smallest-first ordering, (3) optionally pin `join_distribution_type=AUTOMATIC` and let CBO pick. Mentions stats-after-big-ingest so the dbt team builds an ANALYZE step into the post-load hook. Fits the on-prem Iceberg+HMS+Trino 467 stack exactly. |
| Completeness | 5.0 | Covers root-cause diagnosis, exact ANALYZE form, what stats get written, what consumes them, when to re-run, and the session-property escape hatch. No over-warning, no broken secondary alternative, no foreign-dialect import. |

**Verification:** Trino 467 Iceberg connector `ANALYZE schema.table` writes Puffin stats files (apache-datasketches-theta sketch) consumed by `iceberg.statistics.* ` session properties and the CBO `JoinReorderingStrategy`. `join_distribution_type` session prop with `AUTOMATIC` (default) / `BROADCAST` / `PARTITIONED` values verified. All-correct.

---

## Score table

| Q | Accuracy | Clarity | Applicability | Completeness | Q avg |
|---|---|---|---|---|---|
| Q1 SELECT-*-EXCEPT availability (watch re-probe) | 5.0 | 5.0 | 5.0 | 4.5 | 4.8750 |
| Q2 30/60/90-day cohort retention SQL | 5.0 | 4.5 | 5.0 | 3.75 | 4.5625 |
| Q3 arbitrary/any_value for 1:1 column | 5.0 | 5.0 | 5.0 | 5.0 | 5.0000 |
| Q4 CBO + ANALYZE + join_distribution_type | 5.0 | 5.0 | 5.0 | 5.0 | 5.0000 |

**Iter average = (4.8750 + 4.5625 + 5.0000 + 5.0000) / 4 = 4.8594 STRONG PASS** (margin to 3.5 = +1.3594)

---

## iter1130 SELECT-*-EXCEPT watch verdict: CLOSED

iter1130 Q2 surfaced a `SELECT * EXCEPT (rn)` foreign-projection slip on a dedup CTAS rebuild — classified RESPONDER ONE-OFF (resources r23 §3286 + r27 §1964 Pattern B1 already had the explicit-list canonical + defang). iter1131 Q1 directly re-probed: "does Trino support BigQuery's `SELECT * EXCEPT(col)` shorthand?" Responder correctly answered:
- Trino 467 does NOT support `SELECT * EXCEPT (col)`
- It's a BigQuery/Databricks pattern
- Would parse-fail on Trino
- Cross-references r23 line 3286
- Practical fix = DESCRIBE the table, spell out columns explicitly

No slip recurrence. iter1130 first-instance NO-OP-then-re-probe discipline validated for the 5th successful first-re-probe closure in 13 iters (iter1121 / iter1125 / iter1127 / iter1130 / iter1131).

---

## Source-verified defects

None resource-sourced this iter.

**Per-instance shaves:**
- Q1 -0.5 Compl: didn't mention `exclude_columns` table function or `dbt_utils.star(except=[...])` as secondary alternatives. The explicit-list-via-DESCRIBE is canonical and sufficient. Per-instance, NOT a resource gap.
- Q2 -1.25 Compl: inner `JOIN returns r` would drop zero-retention cohorts; should be `LEFT JOIN returns + COALESCE(returned_Nd, 0)`. Per-instance synthesis slip, NOT a canonical defect (r07/r23 cohort canonicals correctly use LEFT JOIN). NO FIX-A.

---

## Topics updated

| Topic | Before | This iter Qs | After | Change |
|---|---|---|---|---|
| SQL-best-practices-OLAP | 4.5500/190 | Q1 (4.875) + Q3 (5.0) | (4.5500×190 + 4.875 + 5.0)/192 = 874.375/192 = **4.5540/192 PASSED** | +0.0040 |
| Analytical-query-patterns-Iceberg+Trino | 4.4826/83 | Q2 (4.5625) | (4.4826×83 + 4.5625)/84 = 376.6183/84 = **4.4836/84 PASSED** | +0.0010 |
| Trino CBO / ANALYZE TABLE / Puffin statistics / NDV / join ordering | 4.5920/21 | Q4 (5.0) | (4.5920×21 + 5.0)/22 = 101.432/22 = **4.6105/22 PASSED** | +0.0185 |

ALL required topics REMAIN PASSED. No required topic dropped below threshold; CBO/ANALYZE lifted above its 4.5 elevated threshold by Q4.

---

## Recurrence audit

No recurrence of any pinned defect family this iter:
- `::`/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/CAST-truncate/EXECUTE-rollback-on-467/Spark-Oracle-spillover — clean
- imported-prior/GREATEST-NULL-Postgres/array_sum/`->`/`->>`-JSON/DATEDIFF-dialect-import/multi-arg-COUNT-DISTINCT — clean
- ts-minus-ts/over-warning/multi-clause-ADD-COLUMN/contains_sequence-array_position-arithmetic — clean
- partition-column-COUNT-data-file-folklore/population-vs-per-group-percentile/dedup-tied-tuple/SELECT-*-EXCEPT — clean

All watch streams REMAIN CLOSED post-iter1131.

---

## Thinnest-margin order after iter1131

1. storage-tiering 4.0278/9 (+0.5278, thinnest required-topic)
2. dbt-snapshots SCD2 4.1526/16 (+0.6526)
3. query-perf-basics 4.1771/23 (+0.6771)
4. cost-considerations 4.2759/22 (+0.7759)
5. query-perf-regression-diagnosis 4.3108/20 (+0.8108)
6. Oracle-migration 4.4566/112 (+0.9566)
7. federation 4.5024/312 (untouched, fragile-PASS preserved)
8. SQL-best-practices-OLAP 4.5540/190 (+0.0040)
9. CBO/ANALYZE 4.6105/22 (+0.0185, lifted)

---

## Teacher guidance — RECOMMENDATION = NO-OP

Commit rubric + feedback only. No resource edits.

**Reasoning:**
1. iter1130 SELECT-*-EXCEPT watch CLOSED cleanly on first re-probe → first-instance NO-OP discipline validated.
2. Q2's inner-vs-LEFT-JOIN cohort slip is per-instance synthesis padding — r07/r23 cohort canonicals already use LEFT JOIN; no canonical defect to fix.
3. Q3 + Q4 reaffirm `arbitrary`/`any_value` alias canonical and CBO+ANALYZE-bare-syntax+Puffin+join_distribution_type canonical durable.

**Re-probe queue:**
1. **storage-tiering 10th angle** (still thinnest required-topic, NEXT PRIORITY)
2. dbt-snapshots-SCD2 17th angle (`check_cols` edge cases, `hard_deletes='new_record'` downstream interaction)
3. cost-considerations 23rd angle (`$manifests` partition-cost attribution / per-tenant cost split)
4. query-perf-regression-diagnosis 21st angle (concurrent ETL-vs-dashboard contention oncall — re-probe from a different angle than iter1129)
5. Trino-side EXECUTE optimize after partition evolution (carry from iter1128 + iter1130)
6. Cohort retention LEFT-JOIN edge — re-probe a "cohort with zero returners" framing to confirm Q2 shave was per-instance (e.g., "I have several cohorts with zero retained users — they're not showing up in my dashboard, what's wrong?")

---

## Pattern observation

14-iter sustainment band shape continues:
- STRONG PASS: iters 1090/1092/1093/1117/1118/1119/1121/1122/1125/1127/1128/**1131**
- LIGHT FIX-A reaching cleanly: iters 1091/1116/1124/1129
- NO-OP+WATCH (all CLOSED): iters 1120/1123/1126/1130

iter1131 4.8594 STRONG PASS reaffirms the 5th successful first-re-probe watch closure (SELECT-*-EXCEPT foreign-projection sub-class confirmed responder one-off, not structural). Q3 + Q4 hold the high-confidence breadth (arbitrary/any_value + CBO/ANALYZE), Q2's cohort retention pattern is mostly correct with a per-instance LEFT-JOIN slip on zero-cohort handling. No content-lineage erosion; no recurring defect class; no new watch streams opened. CBO/ANALYZE topic lifted +0.0185 above its 4.5-elevated threshold by Q4's clean bare-ANALYZE + Puffin + join_distribution_type answer.

---

## Sources verified

- [trinodb/trino #26402 — Feature Request: Support SELECT * EXCEPT](https://github.com/trinodb/trino/issues/26402)
- [trinodb/trino #26969 — Support SELECT * EXCEPT / EXCLUDE](https://github.com/trinodb/trino/issues/26969)
- [trinodb/trino #23532 — Support BigQuery-style select * exclude](https://github.com/trinodb/trino/issues/23532)
- [Trino Aggregate functions — arbitrary / any_value](https://trino.io/docs/current/functions/aggregate.html)
- [Trino Table statistics — ANALYZE / Puffin / NDV](https://trino.io/docs/current/optimizer/statistics.html)
- [Trino Iceberg connector — ANALYZE / Puffin](https://trino.io/docs/current/connector/iceberg.html)
