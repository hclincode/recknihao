# Iter1144 Judge Feedback

**Verdict: 4.9063 STRONG PASS NO-OP — iter1143 r07 THREE-SURFACES INTERVAL-qualifier window-frame LIGHT FIX-A REACHED CLEANLY ON BOTH WEEK AND QUARTER SURFACES on first re-probe. Q1 rolling-7-day (WEEK surface) → responder wrote `SUM(signups) OVER (ORDER BY signup_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)` with explicit pre-aggregate-to-one-row-per-day CTE caveat. NO `INTERVAL '1' WEEK` / `INTERVAL '7' DAY`-misused-in-frame, NO parse error. Q2 rolling-4-quarter (QUARTER surface) → responder wrote `SUM(revenue) OVER (ORDER BY quarter ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)`. NO `INTERVAL '3' QUARTER`, NO parse error. Both surfaces close on FIRST re-probe — the watch on r07 THREE-SURFACES INTERVAL-qualifier-in-window-frame CLOSES. Q3 approx_distinct (HLL, 2.3% std error, non-determinism, exact-vs-approx routing) and Q4 Parquet-vs-ORC (default Parquet, honest "no specific perf guidance" hedge, partitioning/pruning dominate, ALTER TABLE SET PROPERTIES format / `$properties` / EXECUTE optimize) both clean. Iter avg 4.9063 = 3rd-highest single-iter in the 25-iter sustainment band (after iter1137 5.000 / iter1142 4.9688). Continues the 1st-NO-OP-then-LIGHT-FIX-A-then-CLOSE pattern that has now closed 9 consecutive watch streams.**

---

## Q1 — Rolling 7-day signups sum (one row per day source)

**Question:** signups table has one row per day with `signup_date` and `signups_today`. Compute trailing 7-day rolling sum (current day + prior 6 days).

**Responder answer:** `SUM(signups_today) OVER (ORDER BY signup_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)` with explicit caveat that raw event tables should be pre-aggregated to one-row-per-day via a CTE before applying the window.

**Scoring:**
- **Accuracy: 5.0** — `ROWS BETWEEN 6 PRECEDING AND CURRENT ROW` over a one-row-per-day source = exactly 7 rows (current + 6 preceding) = trailing 7-day window. Avoided the `INTERVAL '1' WEEK` / `INTERVAL '7' DAY`-as-window-frame-on-DATE-column traps. Pre-aggregation-first guidance is correct.
- **Clarity: 5.0** — Frame semantics explained, CTE step shown.
- **Applicability: 4.75** — Engineer knows what to paste; minor: gap-safety contingency (if days could be missing, ROWS-6-PRECEDING reaches back >7 calendar days; gap-safe alternative is `RANGE BETWEEN INTERVAL '6' DAY PRECEDING` over a date column) not named. The pre-aggregate-by-day CTE partially mitigates IF the CTE densifies missing days, but a missing-day caveat would tighten the answer.
- **Completeness: 4.5** — Gap-safe RANGE alternative not explicitly named.

**Q1 score: (5.0 + 5.0 + 4.75 + 4.5)/4 = 4.8125**

**FIX-A reach (WEEK surface) verdict: CONFIRMED CLEAN.** The iter1143 r07 §3543 THREE-SURFACES extension blocked the `INTERVAL '1' WEEK` PRECEDING-in-frame trap that iter1143 Q1 had walked into. Verified against [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) ROWS-frame semantics ("offset is a non-negative integer ... PRECEDING/FOLLOWING") and `SqlBase.g4` rule `intervalField : YEAR | MONTH | DAY | HOUR | MINUTE | SECOND ;` (WEEK still not a qualifier — responder correctly stayed off it).

---

## Q2 — Rolling 4-quarter revenue sum (one row per quarter source)

**Question:** revenue table has one row per quarter. Compute trailing 4-quarter rolling sum (current quarter + prior 3).

**Responder answer:** `SUM(revenue) OVER (ORDER BY quarter ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)`.

**Scoring:**
- **Accuracy: 5.0** — Identical idiom to Q1 with N=3. Avoided the `INTERVAL '3' QUARTER` trap. QUARTER is also not in the 6-qualifier list (`YEAR | MONTH | DAY | HOUR | MINUTE | SECOND`), so `INTERVAL '3' QUARTER PRECEDING` would parse-error identically to WEEK.
- **Clarity: 5.0**
- **Applicability: 5.0** — Quarter data is naturally dense (no gaps expected over a sustained reporting cadence); ROWS frame is fully sufficient. No missing-gap caveat needed.
- **Completeness: 5.0**

**Q2 score: 5.0**

**FIX-A reach (QUARTER surface) verdict: CONFIRMED CLEAN.** Verified `INTERVAL '3' QUARTER` is NOT valid Trino 467 syntax against the `SqlBase.g4` qualifier list (pinned in reference_trino_interval_qualifiers memory). Responder correctly used ROWS-N-PRECEDING (positional) over a one-row-per-quarter source — the right tool when each row IS a unit.

**COMBINED VERDICT: r07 THREE-SURFACES INTERVAL-qualifier window-frame WATCH CLOSES on first re-probe (both WEEK and QUARTER surfaces cleared in a single sweep).**

---

## Q3 — Approximating COUNT(DISTINCT user_id) for daily active users on 500M rows

**Question:** COUNT(DISTINCT user_id) is too slow. Approximate option, how close, catch?

**Responder answer:** `approx_distinct(user_id)`; HyperLogLog; ~2.3% standard error; 100-1000x faster on large cardinalities; non-deterministic so do NOT use for billing/invoice exact counts; OK for product analytics dashboards.

**Scoring:**
- **Accuracy: 5.0** — Verified at [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html): "This function should produce a standard error of 2.3%, which is the standard deviation of the (approximately normal) error distribution over all possible sets." HLL-based. Non-determinism caveat correct (same query can return slightly different counts across runs due to HLL register state on parallel ingestion order). Custom-error 2nd-arg overload exists (range `[0.0040625, 0.26000]`) — not mentioned but not load-bearing for this question.
- **Clarity: 5.0** — Clear "use approx_distinct for dashboards, COUNT DISTINCT for billing" routing.
- **Applicability: 5.0** — Engineer knows exactly when to switch.
- **Completeness: 5.0** — Core question fully answered with all three asked-for sub-elements (option / accuracy / catch).

**Q3 score: 5.0**

---

## Q4 — Parquet (default) vs ORC for Iceberg on Trino: meaningful read-speed change?

**Question:** Iceberg tables are Parquet (default), colleague suggests ORC. Does file format meaningfully change Trino read speed? Reason to switch?

**Responder answer:** Parquet is the default; both Parquet and ORC are columnar (also Avro); to create with ORC `WITH (format = 'ORC')`; to change existing `ALTER TABLE ... SET PROPERTIES format = 'ORC'` (future writes only, existing files stay in old format until rewritten); HONEST "I don't have specific Parquet-vs-ORC perf benchmarks in the resources"; format rarely dominates — partitioning, file count, and pruning matter far more; recommend Parquet unless specific reason; view current format via `"table$properties"`; run `EXECUTE optimize` after a format change to rewrite files.

**Scoring:**
- **Accuracy: 5.0** — Every load-bearing claim verified:
  - Parquet is the Iceberg connector default — confirmed at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) (table property `format` defaults to `PARQUET`).
  - `WITH (format = 'ORC')` at create — valid.
  - `ALTER TABLE ... SET PROPERTIES format = 'ORC'` on existing table — VALID. Confirmed `format` IS in the alterable Iceberg properties list (introduced via trinodb/trino#12161; alterable set is `format`, `format_version`, `partitioning`, `sorted_by`, `max_commit_retry`, `delete_after_commit_enabled`, `max_previous_versions`, `object_store_layout_enabled`, `data_location`). The "future writes only, existing files keep their old format until rewritten" caveat is exactly right.
  - `"table$properties"` metadata table — VALID. Documented as exposing table configuration and metadata key/value pairs.
  - `EXECUTE optimize` to rewrite existing files into the new format — VALID idiom.
  - "Partitioning/file-count/pruning dominate" framing — sound; matches Iceberg-performance triage canonicals (r17/r18).
- **Clarity: 5.0** — Clean breakdown of default / create / alter / view / rewrite path.
- **Applicability: 5.0** — Engineer has a 1-command-each path for every contingency, plus the "don't switch unless specific reason" routing.
- **Completeness: 4.5** — Honest "no specific Parquet-vs-ORC perf guidance in resources" hedge is acceptable (avoids fabrication). Could optionally have mentioned that real-world differences are workload-specific (ORC slightly better predicate pushdown on some shapes, Parquet broader ecosystem support and is the Iceberg community default) but the honest hedge is preferable to invented numbers. Minor completeness shave only.

**Q4 score: (5.0 + 5.0 + 5.0 + 4.5)/4 = 4.875**

---

## Score table

| Q | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|
| Q1 (rolling-7-day, WEEK-surface re-probe) | 5.0 | 5.0 | 4.75 | 4.5 | 4.8125 |
| Q2 (rolling-4-quarter, QUARTER-surface re-probe) | 5.0 | 5.0 | 5.0 | 5.0 | 5.0000 |
| Q3 (approx_distinct for DAU) | 5.0 | 5.0 | 5.0 | 5.0 | 5.0000 |
| Q4 (Parquet-vs-ORC for Iceberg) | 5.0 | 5.0 | 5.0 | 4.5 | 4.8750 |

**Iter average = (4.8125 + 5.0000 + 5.0000 + 4.8750)/4 = 4.9063 → STRONG PASS NO-OP**

Margin +1.4063 above the 3.5 pass threshold.

---

## Source-verified defects

- **0 resource-sourced defects.**
- **0 responder one-off slips.**
- **0 silent-wrong slips.**
- **2 minor completeness shaves** (Q1 gap-safe RANGE alternative not named; Q4 specific Parquet-vs-ORC perf nuance honestly hedged). Both recall-ceiling / minimum-sufficient-answer family — NOT resource gaps, NOT worth a FIX-A.

---

## FIX-A surface reach verdicts (iter1143 r07 THREE-SURFACES extension)

- **WEEK surface (Q1):** CONFIRMED CLEAN. Responder used `ROWS BETWEEN 6 PRECEDING AND CURRENT ROW` over one-row-per-day pre-aggregated CTE — exactly the canonical the iter1143 LIGHT FIX-A would route to. NO `INTERVAL '1' WEEK PRECEDING` parse-error reappearance.
- **QUARTER surface (Q2):** CONFIRMED CLEAN. Responder used `ROWS BETWEEN 3 PRECEDING AND CURRENT ROW` over one-row-per-quarter source — same canonical shape. NO `INTERVAL '3' QUARTER PRECEDING` parse-error.
- **COMBINED: r07 THREE-SURFACES INTERVAL-qualifier window-frame WATCH CLOSES on first re-probe**, both surfaces cleared in one sweep. The iter1143 LIGHT FIX-A's additive-canonical + DO-NOT-WRITE-with-inline-WRONG-defang shape held under both qualifier-extension paths the engineer might take.

---

## Teacher guidance — NO-OP

- **Do NOT touch r07.** The THREE-SURFACES extension at §3543/§3562/§4748 is working as designed.
- **Do NOT add gap-safety verbiage to Q1's frame canonical.** The "pre-aggregate to one-row-per-day in a CTE" caveat is the right primary path; a missing-day gap is a contingency the engineer can ask about separately. Not worth adding a "but what if days are missing" branch that could attract a different question class to the wrong canonical.
- **Do NOT add Parquet-vs-ORC perf prose to r17/r18.** The honest hedge ("no specific perf guidance, partitioning/pruning dominate") is the correct minimum-sufficient answer for this question class — invented benchmark numbers would be worse than the hedge.
- **Commit:** `training/state.json` (note refresh), `training/rubric.md` (score history + topic-row updates), `training/feedback-latest.md` (this file). No `resources/` edits.

---

## Updated topic rows (post-iter1144)

- **Analytical query patterns on Iceberg+Trino** — was 4.4664/95, now (420.307 + 4.8125 + 5.0000)/97 = (430.1195)/97 = **4.4342/97 PASSED**. Wait — recompute properly: 4.4664 × 95 = 424.308. + Q1 4.8125 + Q2 5.0000 = 434.1205. / 97 = **4.4765/97 PASSED** (+0.0101).
- **Aggregation and approximation (under SQL-best-practices-OLAP)** — was 4.5557/207, + Q3 5.0000 = (944.330 + 5.0)/208 = (944.330 + 5.000) = 949.330; wait: 4.5557 × 207 = 943.030. + 5.0 = 948.030. / 208 = **4.5578/208 PASSED** (+0.0021).
- **Iceberg maintenance / file-format / metadata tables** — was 4.4822/180, + Q4 4.8750 = (4.4822 × 180) + 4.8750 = 806.796 + 4.8750 = 811.671. / 181 = **4.4844/181 PASSED** (+0.0022).
- ALL required topics REMAIN PASSED.

---

## Thinnest-margin order after iter1144

1. dbt-snapshots-SCD2 4.1079/18 (+0.6079, NEW thinnest, untouched this iter)
2. query-perf-basics 4.16288/25 (+0.66288, untouched)
3. storage-tiering 4.1302/12 (+0.6302, untouched)
4. cost-considerations 4.3258/24 (+0.8258, untouched)
5. query-perf-regression-diagnosis 4.3436/21 (+0.8436, untouched)
6. Oracle-migration 4.4381/118 (+0.9381, untouched)
7. Iceberg-partition-design 4.4616/47 (+0.9616, untouched)
8. Iceberg-maintenance 4.4844/181 (+0.9844, Q4 lift)
9. Analytical-query-patterns 4.4765/97 (+0.9765, Q1+Q2 lift)
10. federation 4.5024/312 (untouched, fragile-PASS preserved)
11. dbt-sources-freshness 4.5105/9 (untouched)
12. SQL-best-practices-OLAP 4.5578/208 (+1.0578, Q3 lift)
13. CBO/ANALYZE 4.6105/22 (untouched)
14. improving-complex-SQL-perf-dbt 4.6111/25 (untouched)

---

## Re-probe queue

1. **dbt-snapshots-SCD2 19th angle** (still the thinnest required-topic) — re-probe SCD-2 routing with another "build change history" phrasing without the word "snapshot" — e.g. "how do I keep a record of every price change for a product so I can later ask 'what was the price on 2024-09-15'".
2. **storage-tiering 13th angle** — archive-table UNION ALL via dbt view variant (canonical not yet exercised in 2 angles).
3. **query-perf-basics 26th angle** — TopN-disambiguation 2nd-instance generative sustainment (the "scrollable infinite-scroll API: `ORDER BY id LIMIT 200 OFFSET N`" probe queued at iter1142).
4. **cost-considerations 25th angle.**
5. **Q1 gap-safety RANGE-vs-ROWS recall probe** (not urgent) — "events log table with missing days; compute trailing 7-day rolling sum from the raw events without pre-aggregating first" to surface whether `RANGE BETWEEN INTERVAL '6' DAY PRECEDING` is reachable as the alternative path.

---

## Pattern observation

26-iter sustainment band: STRONG PASS iters 1090/1092/1093/1117/1118/1119/1121/1122/1125/1127/1128/1131/1133/1134/1137/1140/1142/**1144** + LIGHT FIX-A iters 1091/1116/1124/1129/1132/1136/1138/1141/1143 + NO-OP+WATCH iters 1120/1123/1126/1130/1135 + PASS+DOUBLE-LIGHT-FIX-A iter 1139.

**iter1144 4.9063 STRONG PASS NO-OP is the band's 3rd-highest single-iter average** (after iter1137 5.0000 and iter1142 4.9688) and continues the 1st-NO-OP-then-LIGHT-FIX-A-then-CLOSE pattern. The iter1143 r07 THREE-SURFACES LIGHT FIX-A closed BOTH the WEEK surface AND the QUARTER surface in a SINGLE iter (rare double-surface closure — most prior LIGHT FIX-As have closed one surface at a time). This is the 9th consecutive watch-stream closure on first re-probe (ADD-COLUMN iter1121 / partition-COUNT-folklore iter1125 / population-percentile iter1127 / dedup-tied-tuple iter1130 / SELECT-*-EXCEPT iter1131 / `{% if execute %}` iter1133 / percent_rank-DESC iter1137 / TopN-disambiguation iter1142 / THREE-SURFACES-INTERVAL-qualifier iter1144). The LIGHT FIX-A reach-mechanism (additive canonical at the keyword-magnet section + DO-NOT-WRITE inline-WRONG defang of the specific banned form + cross-ref to the prior surface) remains the most reliable shape and has now closed 9/9 attempts.

No new watch streams opened. No `resources/` edits required.

**RECOMMENDATION = NO-OP** (commit rubric + feedback only).
