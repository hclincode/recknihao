# Iter 1127 — Judge Feedback

**Iter average: 4.9688 STRONG PASS (margin +1.4688).** All four answers clean and source-verified. **Q1 WATCH VERDICT: CLEARED** — the iter1126 Q2 spurious-`GROUP BY customer_id` slip on a population-percentile question DID NOT RECUR. Responder produced a **bare** `approx_percentile(response_time_ms, ARRAY[0.5, 0.95, 0.99]) FROM api_requests WHERE request_time >= CURRENT_TIMESTAMP - INTERVAL '24' HOUR` with NO GROUP BY, returning one row of three numbers as the whole-population question explicitly asked for. iter1126 first-instance NO-OP-then-re-probe discipline validated (3rd successful watch closure in 4 iters after iter1121 ADD-COLUMN and iter1125 partition-column-COUNT FIX-A reach). **RECOMMENDATION = NO-OP** (commit rubric+feedback only; do not edit resources/ this iter).

---

## Per-question scoring

### Q1 — median + p95 + p99 latency across EVERY API request in last 24h (one row, three numbers, NOT split by endpoint/customer/service) — **5.0**

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5.0 | `approx_percentile(response_time_ms, ARRAY[0.5, 0.95, 0.99]) AS percentiles FROM api_requests WHERE request_time >= CURRENT_TIMESTAMP - INTERVAL '24' HOUR` — **NO GROUP BY**, bare population form, exactly correct for the whole-population question. Verified against trino.io/docs/current/functions/aggregate.html — `approx_percentile(x, percentages)` "Returns approximate percentiles for all input values of x" returns `array<[same as x]>` for the multi-percentile array form. Quantile-digest sketch claim CORRECT and verified — trino.io/docs/current/functions/qdigest.html confirms "Presto implements the approx_percentile function with the quantile digest data structure" (NOT HyperLogLog; HLL is for approx_distinct cardinality, not percentiles — the "not HLL" inoculation is accurate and avoids a common conflation). 1-based array indexing (`percentiles[1]/[2]/[3]` mapping to p50/p95/p99) correct per Trino 467 array element-access semantics. The 24-hour window predicate `request_time >= CURRENT_TIMESTAMP - INTERVAL '24' HOUR` is canonical Trino temporal arithmetic (no `ts - ts` subtraction trap, no INTERVAL '24' QUARTER/WEEK trap — INTERVAL '24' HOUR is a valid INTERVAL DAY-TO-SECOND qualifier per `reference_trino_interval_qualifiers` pin). |
| Beginner clarity | 5.0 | Three-tier delivery: (1) the bare query returning `array(double)`; (2) the extraction wrapper exposing `percentiles[1] AS p50, percentiles[2] AS p95, percentiles[3] AS p99` (1-based) for downstream consumption; (3) the qdigest-not-HLL note preempting the common conflation. An engineer with zero OLAP background reads this and gets the right mental model. |
| Practical applicability | 5.0 | Direct copy-paste. The engineer gets a single-row, three-number result, exactly the question's deliverable. |
| Completeness | 5.0 | Population framing honored (no GROUP BY), array form for three percentiles in one pass, extraction wrapper provided, sketch family correctly identified, INTERVAL syntax safe. Nothing missing. |

**Q1 WATCH VERDICT: CLEARED.** The iter1126 Q2 wrong-shape synthesis miss (spurious `GROUP BY customer_id` on a population-percentile question) did NOT recur on direct re-probe with even sharper framing ("one pool / whole population / NOT per endpoint or customer / one row, three numbers"). First-instance NO-OP discipline correctly scoped the iter1126 slip as responder one-off, NOT a resource-sourced findability gap. r23 §247-§262 dual canonical (bare population + per-group, both explicitly labeled) remains durable; no preemptive FIX-A needed. Same successful watch-closure shape as iter1121 (iter1120 ADD-COLUMN watch clean re-probe) and iter1125 (iter1124 partition-column-COUNT FIX-A reach).

### Q2 — single customer row with region + total_spend; find customers >20% above THEIR OWN region's average; subquery+join vs single-pass — **5.0**

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5.0 | `AVG(total_spend) OVER (PARTITION BY region) AS region_avg_spend` in a subquery + outer `WHERE total_spend > region_avg_spend * 1.2` is the canonical single-pass compare-to-group-average pattern. Verified against trino.io/docs/current/functions/window.html: AVG is a valid window aggregate; PARTITION BY region scopes the average per region without collapsing rows; OVER without ORDER BY uses the entire partition as the frame (correct for a group-wide average, not a running average). The subquery-wrap requirement is correct: window functions can ONLY appear in SELECT or ORDER BY, NOT in WHERE/HAVING/GROUP BY (SQL standard semantics — WHERE is evaluated BEFORE window functions, so `WHERE x > AVG(...) OVER (PARTITION BY region)` is a parse/semantic error in Trino 467). The CTE/subquery wrap puts the comparison in the outer query where the window result is already materialized. `* 1.2` is decimal multiplication (no integer truncation trap — both operands are numeric, not integer-only). No self-join, no `GROUP BY region` collapse-then-rejoin (which would also work but requires an extra pass over the data). |
| Beginner clarity | 5.0 | The "window can't go in WHERE directly so subquery wrap is needed" explanation is the exact mental model an engineer needs to reach for the single-pass form on future similar questions. The "no GROUP BY collapse, no self-join" inoculation defangs the natural-but-slower subquery+join alternative the question explicitly asked about. |
| Practical applicability | 5.0 | Drop-in copy-paste. The single-pass form runs in O(N) over the customers table; the subquery+join alternative would require either a GROUP BY pre-aggregation pass + a hash join (extra shuffle) or a correlated subquery (per-row scan — anti-pattern). Engineer knows which to pick and why. |
| Completeness | 5.0 | Both options compared with the correct verdict; the WHERE-vs-window-clause subtlety explicitly called out; `* 1.2` decimal semantics noted. Nothing missing for the question's scope. |

### Q3 — Postgres 7/2=3 integer division; does Trino do the same; CAST one operand for decimal result; idiomatic form — **5.0**

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5.0 | "Yes Trino 7/2=3 (truncates)" CORRECT — verified per trino.io/docs/current/functions/math.html operator semantics: integer ÷ integer in Trino 467 returns integer with truncation toward zero (same Postgres behavior, distinct from Spark's default-to-double per trinodb/trino issue #1381). `CAST(7 AS DOUBLE)/2 = 3.5` and `7/CAST(2 AS DOUBLE) = 3.5` correct — single-operand DOUBLE coercion promotes the division to DOUBLE arithmetic. `CAST(7 AS DECIMAL(18,4))/2 = 3.5000` correct — DECIMAL ÷ INTEGER returns DECIMAL with precision/scale per Trino DECIMAL arithmetic rules. `*1.0` multiplication trick correct — `1.0` is a `DECIMAL(2,1)` literal, so `x * 1.0` promotes x's type and the subsequent division uses DECIMAL semantics. "DECIMAL cast rounds HALF_UP" CORRECT — Trino 467 DECIMAL rounding is HALF_UP for CAST and division (verified per `reference_trino_cast_to_integer_rounds` pin family extended to DECIMAL casts; also per trino.io decimal-functions docs). Idiomatic recommendation (cast numerator to DOUBLE for general, DECIMAL for money) matches established Trino style. |
| Beginner clarity | 5.0 | Postgres-vs-Trino parity explicitly stated, fix options enumerated (DOUBLE / DECIMAL / `*1.0`), and the "CAST signals intent" framing is exactly the readability argument a senior engineer would make. |
| Practical applicability | 5.0 | Engineer gets three drop-in forms with type rationale — picks DOUBLE for ratios, DECIMAL for money, knows `*1.0` is a working shortcut. |
| Completeness | 5.0 | Postgres parity confirmed, three fix patterns, idiomatic recommendation, HALF_UP rounding caveat for DECIMAL. Nothing missing. |

### Q4 — hourly dbt append → ~720 small files/month; hurts query perf; schedule compaction or automatic — **4.875**

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 4.5 | (a) "Iceberg does NOT auto-compact" CORRECT — verified per trino.io/docs/current/connector/iceberg.html; the Trino Iceberg connector exposes manual `EXECUTE optimize` only, no background auto-compaction (distinct from some managed platforms like Tabular/Polaris that layer auto-optimize on top). (b) `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')` syntax CORRECT — verified verbatim against docs: `ALTER TABLE test_table EXECUTE optimize(file_size_threshold => '128MB')` is the official example shape; the `=>` named-argument syntax and `'256MB'` string-with-unit literal both valid (default threshold is 100MB; bumping to 256MB to align with target file size is reasonable). The "merges small files, applies deletes, new snapshot" semantics correct. (c) `EXECUTE expire_snapshots(retention_threshold => '7d')` and `EXECUTE remove_orphan_files(retention_threshold => '7d')` syntax CORRECT — both verified per docs verbatim. Reminder: `iceberg.expire-snapshots.min-retention` catalog property must be ≤ the value passed, else the procedure fails — not flagged but a per-instance shave, not a content gap. (d) "optimize scans but doesn't lock reads/writes" — **MOSTLY CORRECT but slightly optimistic on the write side**: Iceberg uses optimistic concurrency (snapshot isolation), so reads are NEVER blocked (every query gets a consistent snapshot view), and writes do NOT take an exclusive lock either. HOWEVER, concurrent writes during optimize CAN produce commit conflicts on overlapping partitions/files, requiring retry (one writer wins the snapshot commit, the other must re-attempt against the new snapshot). The "doesn't lock writes" phrasing is technically correct in the literal-lock sense but glosses over the commit-conflict possibility. **Minor shave (−0.5) per the watch-prompt's "doesn't lock writes may be slightly optimistic" hint.** |
| Beginner clarity | 5.0 | Nightly + weekly schedule split (optimize daily, expire+orphan weekly) is the canonical operations cadence. |
| Practical applicability | 5.0 | Three drop-in DDL statements with cadence guidance. Engineer can put these in a scheduled dbt operation or k8s CronJob immediately. |
| Completeness | 4.75 | All three procedures covered with retention thresholds; the no-lock-on-reads claim is fine; the no-lock-on-writes claim could have one-line "concurrent writes during optimize may need retry on snapshot commit conflict" for full completeness. Per-instance shave (−0.25), NOT a resource gap. |

**Defect classification (Q4 minor shave): per-instance phrasing optimism, NOT resource-sourced.** r17 §198+ correctly describes Iceberg optimistic concurrency; this Q's "doesn't lock writes" is an over-confident truncation of the nuanced "no exclusive lock, but commit conflicts possible" reality. NO FIX-A needed; this would only matter if a follow-up question explicitly probed the concurrent-write-during-optimize behavior.

---

## Score table

| Q | Topic touched | Acc | Clar | App | Compl | Avg |
|---|---|---|---|---|---|---|
| Q1 | SQL best practices for OLAP (approx_percentile bare-population, ARRAY form, qdigest sketch) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** |
| Q2 | Analytical query patterns on Iceberg+Trino (window function compare-to-group-average single-pass) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** |
| Q3 | SQL best practices for OLAP (integer division truncation, CAST-to-DOUBLE/DECIMAL idioms) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** |
| Q4 | Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup | 4.5 | 5.0 | 5.0 | 4.75 | **4.875** |

**Iter average = (5.0 + 5.0 + 5.0 + 4.875) / 4 = 4.96875 STRONG PASS** (margin to 3.5 = **+1.46875**).

---

## Source-verified defects

None. All four answers source-verified clean against trino.io/docs/current (aggregate.html, qdigest.html, window.html, math.html, decimal.html, connector/iceberg.html). Q4 minor "doesn't lock writes" phrasing optimism is per-instance only (no resource defect).

---

## Q1 watch verdict — CLEARED

| Watch | Status | Verification |
|---|---|---|
| iter1126 Q2 population-vs-per-group percentile entity-GROUP-BY adjacency-attraction | **CLEARED** | Direct re-probe with explicit "one pool / whole population / NOT per endpoint or customer / one row, three numbers" framing → responder produced `approx_percentile(response_time_ms, ARRAY[0.5,0.95,0.99]) FROM api_requests WHERE request_time >= CURRENT_TIMESTAMP - INTERVAL '24' HOUR` with **NO GROUP BY**. Whole-population shape honored; sketch identification (qdigest, not HLL) accurate; 1-based array indexing for extraction wrapper correct. iter1126 slip confirmed as first-instance responder one-off — adjacency-attraction did NOT generalize to a structural findability gap on direct re-probe at the next opportunity. No FIX-A needed; r23 §247-§262 dual canonical (bare population + per-group, both labeled) remains durable. |

---

## Recurring-defect surface check

No recurrence of: `::` cast / `QUALIFY` / false-semi-join / fabricated function / regex backslash / `INTERVAL` quarter-week / `OFFSET` before `LIMIT` / `CAST(... AS integer)` truncate folklore / `ALTER TABLE EXECUTE rollback_to_snapshot` on 467 / Spark-Oracle dialect spillover / imported-prior single-arg `COUNT(DISTINCT)` / `GREATEST/LEAST` Postgres-NULL / `array_sum` / `->`/`->>` JSON / `DATEDIFF` dialect import / multi-arg `COUNT(DISTINCT)` / `ts - ts` subtraction / over-warning folklore / multi-clause `ADD COLUMN` / `contains_sequence` `array_position` arithmetic / partition-column-COUNT data-file folklore / population-vs-per-group percentile entity-GROUP-BY (iter1126 Q2 watch CLEARED iter1127).

No new watch streams opened.

---

## Topic updates (PASS → updated values)

| Topic | Before | Q | Q score | Updated | Δ | Status |
|---|---|---|---|---|---|---|
| SQL best practices for OLAP | 4.5355/184 | Q1+Q3 | 5.0 + 5.0 | (834.5320 + 5.0 + 5.0)/186 = **4.5405/186** | +0.0050 | PASSED |
| Analytical query patterns on Iceberg+Trino | 4.4711/81 | Q2 | 5.0 | (362.0591 + 5.0)/82 = **4.4763/82** | +0.0052 | PASSED |
| Iceberg table maintenance | 4.4754/176 | Q4 | 4.875 | (787.6704 + 4.875)/177 = **4.4777/177** | +0.0023 | PASSED |

ALL required topics REMAIN PASSED. iter1126 Q2 drag fully recovered on the analytical-query-patterns row (+0.0052 vs prior −0.0168), restoring the row's upward trajectory. iter1126 Q1 minor completeness shave fully recovered on the SQL-best-practices row (+0.0050).

---

## Thinnest-margin order after iter1127 (unchanged ordering)

1. storage-tiering 3.9219/8 (+0.4219, thinnest required-topic)
2. dbt-snapshots SCD2 4.1526/16 (+0.6526)
3. query-perf-basics 4.1771/23 (+0.6771)
4. cost-considerations 4.2504/21 (+0.7504)
5. query-perf-regression-diagnosis 4.3108/20 (+0.8108)

Federation 4.5024/312 untouched (fragile-PASS preserved). CBO/ANALYZE 4.5920/21 untouched.

---

## Teacher guidance

**RECOMMENDATION = NO-OP** (commit rubric+feedback only; do not edit resources/ this iter).

**Why NO-OP:** All four answers clean and source-verified. iter1126 Q2 watch CLEARED on direct re-probe. No new defects observed. Continue verify-first against trino.io 467 RAW source for dialect facts.

**Re-probe queue (priorities unchanged):**
1. storage-tiering 9th angle (still thinnest required-topic row at +0.4219; lift opportunity).
2. dbt-snapshots-SCD2 17th angle (e.g. check_cols edge cases, hard_deletes='new_record' interaction with downstream joins).
3. cost-considerations 22nd angle ($manifests partition-cost attribution / per-tenant cost split).
4. query-perf-regression-diagnosis 21st angle (concurrent ETL-vs-dashboard contention oncall).

---

## Pattern observation

10-iter sustainment band shape: STRONG PASS iters 1090/1092/1093/1117/1118/1119/1121/1122/1125/**1127** with LIGHT FIX-A iters 1091/1116/1124 reaching cleanly between and NO-OP+WATCH iters 1120/1123/1126 with all watches CLOSED on first re-probe opportunity. iter1127 4.96875 STRONG PASS is the highest of the recent band, driven by clean Q1 watch closure + three clean breadth angles.

**Three consecutive successful watch closures (iter1121 ADD-COLUMN, iter1125 partition-column-COUNT FIX-A reach, iter1127 population-vs-per-group percentile) validate the first-instance NO-OP-then-re-probe discipline** matching iter1116 ts-minus-ts and iter1120 ADD-COLUMN early-closure shape. Continue first-instance NO-OP discipline; reserve LIGHT FIX-A for confirmed 2nd-instance recurrence on direct re-probe (iter1124 partition-column-COUNT shape).

Q1's bare `approx_percentile` + qdigest-not-HLL inoculation demonstrates r23 §247-§262 dual canonical durable. Q2's `AVG OVER (PARTITION BY region)` + subquery-wrap demonstrates window-function-in-WHERE inoculation durable. Q3's integer-division CAST idioms reaffirm Trino-vs-Postgres parity content lineage. Q4's three-procedure maintenance schedule reaffirms Iceberg maintenance discipline durable; minor concurrent-write phrasing optimism is per-instance only.

No content-lineage erosion; no recurring defect class; no new watch streams opened. Strong sustainment band continues.
