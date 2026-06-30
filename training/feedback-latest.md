# Iter 1313 Judge Feedback

**Overall: 4.953 STRONG PASS NO-OP — three open watches CLOSE POSITIVELY on first re-probe**

| Q | Score | Acc | Clar | Prac | Compl | Verdict |
|---|---|---|---|---|---|---|
| Q1 WHEN STALE INLINE post-467 + fall-through default | 4.9375 | 5.0 | 4.75 | 5.0 | 5.0 | STRONG PASS — closes iter1312-Q1 r25 FIX-A reach test |
| Q2 EXPLAIN no-execute vs EXPLAIN ANALYZE executes | 4.9375 | 5.0 | 4.75 | 5.0 | 5.0 | STRONG PASS — closes iter1310-Q2 EXPLAIN-pre-run watch |
| Q3 GREATEST NULL: Trino matches Oracle, Postgres outlier | 4.9375 | 5.0 | 5.0 | 5.0 | 4.75 | STRONG PASS — closes iter1312-Q4 NULL-contrast sub-axis |
| Q4 NULLS LAST default + NULLS FIRST/LAST override | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 | STRONG PASS |

---

## Q1 — WHEN STALE INLINE on Trino 467 / stale-past-grace behavior — 4.9375

**Question:** Engineer hit parse error on `CREATE MATERIALIZED VIEW ... WHEN STALE INLINE` on Trino 467. Is the clause valid on 467? What happens when MV goes stale past the grace period?

**Responder answer summary:** WHEN STALE is post-467 (added ~473+), NOT valid on 467 — omit it. Provided corrected 467 DDL with `GRACE PERIOD + WITH` only. Explained that on 467 the **default behavior** when MV is stale + past grace is automatic fall-through to executing the underlying SELECT against the live source (= the "INLINE" semantic in newer Trino, just no explicit clause). WHEN STALE FAIL would be the error-out variant on newer Trino. Recommended scheduling REFRESH before grace expires.

**Verification:** WebFetch of [trino.io/docs/467/sql/create-materialized-view.html](https://trino.io/docs/467/sql/create-materialized-view.html) returned the 467 grammar verbatim — `CREATE [OR REPLACE] MATERIALIZED VIEW [IF NOT EXISTS] view_name [GRACE PERIOD interval] [COMMENT string] [WITH properties] AS query` — **no WHEN STALE clause**. Confirmed against iter1312 note (post-467 PRs #27356/#27502, lands well after 467) and pin `reference_trino_compression_codec_477.md` family pattern (verify exact version cutoff against git-tag source).

**HARD WATCH `iter1312-Q1 WHEN-STALE-INLINE r25 resource-sourced 467-fabrication` CLOSES POSITIVELY.** The iter1312 reconcile FIX-A applied to r25 §2.1 synopsis + §2.2 worked example + §4.3 quick-ref was the right fix — responder no longer emits WHEN STALE INLINE on 467 on the first re-probe under the EXPLICIT-clause framing. Matches the recent 1st-re-probe-close streak (iter1272 bloom-CREATE-467, iter1305-Q1 dbt-compile, iter1308-Q1 dbt-select-exclude). The behavioral semantics responder taught (467 default = automatic fall-through to live SELECT when stale + past grace) are also correct and match the iter1312 pin guidance.

**No imported-prior, no broken-secondary, no over-warning, no fabrication.** Minor Clar shave only because the "added ~Trino 473+" version-floor is approximate (actual lands well after 467 but the exact release-N cutoff isn't named) — not load-bearing for the engineer.

**REMAINING WATCH ITEM (LOW)**: state.json mentioned r25 §4.3 WHEN STALE table (L223-251) + glossary L386 + myth-table L28/L34 still frame WHEN STALE as a clause — those are behavioral references not copy-pasteable DDL, lower risk, but should be reconciled to "the explicit WHEN STALE clause is post-467; on 467 the same INLINE behavior is the default with no clause to control it" the next time the teacher touches r25. Defer until a re-probe surfaces a behavioral framing miss.

---

## Q2 — EXPLAIN no-execute vs EXPLAIN ANALYZE executes — 4.9375

**Question:** Engineer wants to check partition pruning / scan estimate BEFORE running an expensive 800M-row Iceberg query (Postgres EXPLAIN equivalent). Does Trino EXPLAIN show plan+estimate without executing, or is EXPLAIN ANALYZE needed (which executes)?

**Responder answer summary:** EXPLAIN (no ANALYZE) does NOT execute — shows plan + pushdown + estimates. EXPLAIN ANALYZE EXECUTES the full query. Recommended `EXPLAIN (TYPE DISTRIBUTED)` for everyday plan/pruning check, `EXPLAIN (TYPE IO, FORMAT JSON)` for detailed scan audit. Look at TableScan estimated rows / constraint to see if pruning worked.

**Verification:** WebFetch of [trino.io/docs/467/sql/explain.html](https://trino.io/docs/467/sql/explain.html) confirms EXPLAIN (no ANALYZE) does NOT execute the query, and that TYPE IO returns JSON with `inputTableColumnInfos.columnConstraints` (which predicates pushed down) + planner cost estimates without execution. WebFetch of [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/467/sql/explain-analyze.html) confirms EXPLAIN ANALYZE executes the statement. Matches the iter1310-Q2 verification.

**SOFT WATCH `iter1310-Q2 EXPLAIN ANALYZE recommended when engineer asks for PRE-RUN scan estimate` CLOSES POSITIVELY** on first re-probe under the explicit "Postgres EXPLAIN equivalent" / "BEFORE running" framing. iter1310-Q2 had routed to EXPLAIN ANALYZE (execute) when the engineer wanted pre-run; this iter responder correctly routes to plain EXPLAIN + TYPE IO. The iter1310 LIGHT FIX-A (keyword-magnet routing block near r23 §2487 EXPLAIN-variant table and/or r18 §831 with "BEFORE running / ahead of time / dry run / preview the scan" anchors) appears to have landed — responder's three-way EXPLAIN vs EXPLAIN(TYPE DISTRIBUTED) vs EXPLAIN(TYPE IO, FORMAT JSON) framing is now the lead.

Minor Clar shave only because EXPLAIN(TYPE IO, FORMAT JSON) is a heavier diagnostic than most engineers need for the first check — could surface plain `EXPLAIN <query>` (default TYPE LOGICAL/DISTRIBUTED) as the easiest first step before bringing out TYPE IO. Not load-bearing.

**No imported-prior, no broken-secondary, no over-warning, no fabrication.**

---

## Q3 — GREATEST NULL behavior: Trino vs Oracle vs Postgres — 4.9375

**Question:** Oracle migration: `GREATEST(ts1,ts2,ts3)`; in Oracle GREATEST returns NULL if any arg NULL so engineer wrapped each in NVL. Colleague claims Trino handles NULLs differently. Does Trino match Oracle or differ?

**Responder answer summary:** Colleague is WRONG. Trino GREATEST behaves IDENTICALLY to Oracle — both return NULL if ANY argument is NULL. PostgreSQL is the outlier (ignores NULLs, returns NULL only if all args NULL). No COALESCE/NVL needed in Trino; can drop the wrappers.

**Verification:** WebFetch of [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html) returned verbatim: *"Like most other functions in Trino, they return null if any argument is null. Note that in some other databases, such as PostgreSQL, they only return null if all arguments are null."* Matches pin `reference_trino_greatest_least_null.md` and r27 §4.4D L1733 canonical ("Oracle MATCHES Trino here, but engineers coming from Postgres muscle memory get bitten").

**SOFT WATCH `iter1312-Q4 GREATEST NULL-contrast names-Oracle-instead-of-Postgres` CLOSES POSITIVELY** on first re-probe — responder correctly identifies Postgres as the outlier (not Oracle). iter1312-Q4's reversed contrast did not recur; the r27 §4.4D canonical was findable under the explicit Oracle-migration framing.

**The sibling sub-axis (`GREATEST-must-CAST over-claim`) is NOT exercised** by this scenario (no mixed numeric-type GREATEST in the question — all 3 args are timestamp). Carry forward un-probed; re-probe under mixed numeric framings in 4-8 iters.

Minor Compl shave only because responder could mention that if you DO want to skip NULL args (Postgres semantics), use per-arg `COALESCE(ts_i, sentinel)` wrapping; for the engineer's "drop the wrappers since Trino matches Oracle" use case this is unnecessary, but worth noting as the migration-from-Postgres conversion. Not load-bearing for the asked Oracle-to-Trino migration scenario.

**No imported-prior, no broken-secondary, no over-warning, no fabrication.**

---

## Q4 — NULL ordering default + NULLS FIRST/LAST override — 5.0

**Question:** Oracle `ORDER BY paid_at DESC` puts NULLs first (NULL=highest). Trino put NULLs last regardless of ASC/DESC. Is Trino always nulls-last, and can NULLS FIRST/LAST control it?

**Responder answer summary:** YES, Trino defaults to NULLS LAST regardless of direction (differs from Oracle DESC). Provided Oracle-vs-Trino truth table. NULLS FIRST / NULLS LAST keywords work on both top-level ORDER BY and OVER(...ORDER BY...). To match Oracle DESC, use `ORDER BY paid_at DESC NULLS FIRST`. Best practice: always write NULLS FIRST/LAST explicitly when migrating.

**Verification:** WebFetch of [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) returned verbatim: *"The default null ordering is NULLS LAST, regardless of the ordering direction."* Matches pin `reference_trino_null_ordering_default.md` (iter707 origin: Trino 467 default NULL ordering is NULLS LAST regardless of ASC/DESC; NOT the NULL-as-largest ASC→last/DESC→first rule). Matches iter1308-Q4 prior verification.

NULLS FIRST/LAST on OVER ORDER BY is also valid per the same docs page — supported across all order-by contexts including window functions.

**Perfect 5.0 across all dimensions.** Truth table format gives engineer a one-glance migration cheat sheet; OVER clause coverage is the durable safety net; "always explicit on migration" best-practice rule covers ASC + DESC + future column additions in one durable habit.

**No imported-prior, no broken-secondary, no over-warning, no fabrication.**

---

## Topic routing

| Q | Topic | Δ |
|---|---|---|
| Q1 | Query performance regression diagnosis (continuing iter1312-Q1's r25 MV routing) | 31→32 |
| Q2 | Query performance regression diagnosis (per iter1310-Q2 prior routing for the same EXPLAIN-pre-run thread) | 32→33 |
| Q3 | Oracle PL/SQL → dbt + Trino SQL migration (Oracle GREATEST migration question) | 290→291 |
| Q4 | Oracle PL/SQL → dbt + Trino SQL migration (Oracle ORDER BY NULL migration question, matches iter1308-Q4 routing) | 291→292 |

**query-perf-regression** (THINNEST required topic): 3.96565/31 → (3.96565*31 + 4.9375 + 4.9375)/33 = (122.9352 + 9.875)/33 = 132.8102/33 = **4.0246/33 PASSED** (+0.0589, margin +0.5246). Recovers from iter1310-Q2 + iter1311-Q1 + iter1312-Q1 sub-4 drag streak; lifts back above 4.0 watermark.

**Oracle PL/SQL → dbt+Trino**: 4.50273/290 → (4.50273*290 + 4.9375 + 5.0)/292 = (1305.7917 + 9.9375)/292 = 1315.7292/292 = **4.50592/292 PASSED** (+0.00319, margin +1.00592).

---

## Pattern summary

Three open soft/hard watches CLOSE POSITIVELY on first re-probe this iter:
1. **iter1312-Q1 WHEN-STALE-INLINE r25 467-fabrication HARD WATCH** — r25 §2.1 + §2.2 + §4.3 quick-ref reconcile FIX-A reached cleanly; responder correctly states WHEN STALE is post-467 and gives 467 DDL without it.
2. **iter1310-Q2 EXPLAIN-pre-run SOFT WATCH** — keyword-magnet routing block FIX-A reached; responder correctly routes to plain EXPLAIN + TYPE IO for the no-execute pre-check.
3. **iter1312-Q4 GREATEST NULL-contrast Oracle-vs-Postgres SOFT WATCH** (NULL-contrast sub-axis) — responder correctly names Postgres as outlier on first re-probe; the must-CAST over-claim sub-axis was not exercised by this scenario, carry un-probed.

The 1st-re-probe-close streak continues to be the dominant pattern (iter1272 bloom-CREATE-467, iter1290 ephemeral-basics, iter1295 perf-triage-recall, iter1305-Q1 dbt-compile, iter1308-Q1 dbt-select-exclude, iter1313 ×3) — when teacher applies a precise reconcile FIX-A under the keyword-magnet that the engineer's framing reaches, Haiku finds it on the first probe.

**All four answers technically clean; zero defects (resource-sourced, findability, or per-instance responder slip).** No FIX-A needed this iter. Single highest iteration average (4.953) since the carry-watch streak started building.

No new watches opened. Carried watches remaining un-probed this iter:
- iter1278-Q1 Scheduled-vs-CPU-as-I/O-wait imprecision (route to Blocked time explicitly) — soft, re-probe under "is it I/O bottleneck" framings
- iter1308-Q4 false-premise-endorsement-light on ASC-direction Oracle-vs-Trino NULL-ordering — low, this iter's Q4 was DESC-direction so doesn't probe the ASC-symptom premise
- iter1311-Q1 salted-two-level-GROUP-BY collapsed-to-one-CTE form — low, requires skew-fix scenario
- iter1312-Q4 GREATEST-must-CAST over-claim (sub-axis) — low, requires mixed-numeric-type GREATEST scenario
- iter1310-Q1 Postgres-md5-lowercase-vs-Trino-to_hex-uppercase parity — low, requires md5/hash-migration scenario
- iter1305-Q3 two-queries-same-WHERE columnar-projection primary cause — hard, requires same-WHERE-differential-scan scenario

All required topics PASSED. query-perf-regression thinnest at 4.0246/33 (margin +0.5246); next probe sweep should continue targeting it.

Sources verified:
- [trino.io/docs/467/sql/create-materialized-view.html](https://trino.io/docs/467/sql/create-materialized-view.html) — 467 grammar has no WHEN STALE clause
- [trino.io/docs/467/sql/explain.html](https://trino.io/docs/467/sql/explain.html) — EXPLAIN does NOT execute; TYPE IO returns static estimates+constraints
- [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/467/sql/explain-analyze.html) — EXPLAIN ANALYZE executes the statement
- [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html) — GREATEST/LEAST return null if any arg is null (Postgres is outlier)
- [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) — default null ordering is NULLS LAST regardless of direction
