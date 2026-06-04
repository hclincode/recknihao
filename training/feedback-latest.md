# Judge Feedback — Iter 443 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.461 PASS** (Q1 4.875 + Q2 3.3125 + Q3 4.78125 + Q4 4.875) — **+0.602 step-UP from iter442 3.859; Q1 EXPLAIN TYPE VALIDATE+TYPE IO REPEAT FAILURE FINALLY RESOLVED after 3 consecutive iters (r22 §3.4 cross-resource findability fix LANDED); Q2 BRANCH DDL fabrications fixed (no fake `(BRANCH 'x')`, no fake `MERGE BRANCH`) BUT TWO NEW CONFIDENT-INACCURACIES emerge on the syntax-detail layer (branch-name/suffix mismatch + fast_forward arg-order REVERSED); Q3 dynamic filtering federation BUFFER STRONG (4.78125, +0.0009 margin expansion → +0.0035 above 4.5 threshold STAYS PASSED); Q4 ANALYZE/CBO canonical STRONG.**

---

## HEADLINE

1. **Q1 EXPLAIN TYPE VALIDATE + TYPE IO — STRONG PASS 4.875 — FINALLY RESOLVED.** Third consecutive iter the canonical content has been probed; the r22 §3.4 cross-resource duplication + DO-NOT-WRITE block landed in iter443. Responder produces: (a) `EXPLAIN (TYPE VALIDATE) <query>` returns boolean `Valid`, no execution, the built-in validator (verified per trino.io/docs/current/sql/explain.html); (b) `EXPLAIN (TYPE DISTRIBUTED)` with `constraint = {...}` annotation INSIDE TableScan = pushed, `Filter` / `ScanFilterProject` operator ABOVE = not pushed (iter441 guardrail held, no Spark PushedFilters); (c) `EXPLAIN (TYPE IO, FORMAT JSON)` returns `inputTableColumnInfos` with per-column `domain.ranges` constraints; (d) `EXPLAIN ANALYZE VERBOSE` for `dynamicFilterSplitsProcessed`; (e) EXPLICITLY rejects LIMIT 0 / LIMIT 1 as "still goes through planner, may execute, not cheap validation"; (f) NO `(ANALYZE false)` fabrication; (g) NO "Trino has no validate-syntax-without-execute command" denial. **Iter441+iter442 REPEAT confident-inaccuracies on TYPE VALIDATE FIXED; iter442 NEW `EXPLAIN ANALYZE (ANALYZE false)` fabrication FIXED.** Query performance regression diagnosis 4.2085 → 4.2596 / 13 (+0.0511, single Q1 4.875 datapoint well above topic avg).

2. **Q2 Branch DDL re-probe — FAIL 3.3125 — iter442 fabrications fixed BUT TWO NEW confident-inaccuracies at syntax-detail layer.** The gross iter442 fabrications (`INSERT INTO t (BRANCH 'x')` parenthesized clause; `MERGE BRANCH x INTO main` non-existent DDL) are GONE — responder correctly uses (i) suffix notation on table identifier OR (ii) WAP session conf for branch writes, AND uses `fast_forward` procedure call NOT `MERGE BRANCH` DDL. **But two new confident-inaccuracies emerge at the next level of detail:**
   - **(2a) Branch-name / suffix-name inconsistency.** Responder declared branch as `staging-branch` (with a hyphen) but wrote suffix `INSERT INTO iceberg.analytics.orders.branch_staging_branch` (with underscores throughout). Per iceberg.apache.org/docs/latest/spark-writes/ the suffix is LITERAL `branch_<name>` — a hyphenated branch name needs the hyphen preserved AND identifier-quoting (`` `branch_staging-branch` `` ). As written, the suffix targets a different branch (`staging_branch` with underscore) than was created (`staging-branch` with hyphen). Engineer copy-pastes → either errors ("branch staging_branch not found") or accidentally creates a separate unrelated branch.
   - **(2b) fast_forward ARG ORDER REVERSED (LOAD-BEARING).** Responder wrote `CALL iceberg.system.fast_forward(table => 'analytics.orders', branch => 'staging-branch', to => 'main')`. **Verified per iceberg.apache.org/docs/latest/spark-procedures/: the signature is `fast_forward(table, branch, to)` where `branch` is the TARGET branch being fast-forwarded and `to` is the SOURCE branch whose tip is taken.** The canonical WAP-publish example is `CALL catalog.system.fast_forward('table', 'main', 'audit-branch')` — publish means moving MAIN's pointer to staging's tip. The responder reversed it: their call would attempt to move staging-branch's pointer up to main's tip (which abandons the staged data instead of publishing it; also typically errors because main is not a descendant of staging-branch in WAP). **LOAD-BEARING WRONG CLAIM — the publish step of WAP is broken if the engineer copy-pastes.**

3. **Q3 dynamic filtering federation BUFFER — STRONG PASS 4.78125.** Canonical federation answer: CBO picks small Postgres-region-filtered build / Iceberg events probe; region predicate pushes to Postgres FIRST (planner pushdown); Trino collects customer_id values from build side at runtime as IN-list/range; IN-list/range pushed AS dynamic filter to Iceberg probe scan, prunes Parquet row-groups via min/max + manifest file-skipping; `EXPLAIN ANALYZE VERBOSE` shows `dynamicFilterSplitsProcessed N` where N << M unfiltered; NOT-FIRE cases LEFT/FULL OUTER (only INNER + RIGHT support DF per Trino docs), stale stats so wrong build, VARCHAR-key collation; Trino terminology only — no Spark PushedFilters. All verified per trino.io/docs/current/admin/dynamic-filtering.html. **Federation 4.5026 → 4.5035 / 305 (+0.0009); margin +0.0026 → +0.0035 (+0.0009 expansion). STAYS PASSED — 2nd consecutive iter of margin restoration.**

4. **Q4 ANALYZE / CBO — STRONG PASS 4.875.** Canonical answer: `ANALYZE iceberg.analytics.events` no TABLE keyword (Trino differs from Postgres); `WITH(columns=ARRAY['col1','col2'])` column-targeted; Puffin NDV sketch file written alongside Parquet data files; `join_reordering_strategy=AUTOMATIC` enumerates orders with stats-based cost, fallback to ELIMINATE_CROSS_JOINS if no stats (verified per trino.io/docs/current/optimizer/cost-based-optimizations.html); `EXPLAIN` shows Estimates rows N concrete vs `?` guessing; `SHOW STATS FOR table` displays distinct_values_count; `ALTER TABLE ... EXECUTE drop_extended_stats` procedure BEFORE column-subset re-ANALYZE (otherwise broader pre-existing stats stay cached). All verified.

---

## Critical confirmations (explicit)

### (a) Q1 EXPLAIN re-probe — FINALLY RESOLVED?

**YES — Q1 RESOLVED.** Score 4.875 STRONG PASS. r22 §3.4 cross-resource findability fix LANDED after THIRE consecutive failure. Responder produces:
- `EXPLAIN (TYPE VALIDATE) <query>` returns boolean `Valid`, no execution — CORRECT per trino.io/docs/current/sql/explain.html (the built-in validator).
- Explicit rejection of LIMIT 0 / LIMIT 1: "LIMIT 0 still goes through the planner, may execute distribution — not cheap validation."
- NO "Trino has no syntax-checker" denial (iter441+iter442 REPEAT inaccuracy FIXED).
- NO fabricated `EXPLAIN ANALYZE (ANALYZE false)` form (iter442 NEW fabrication FIXED).
- `EXPLAIN (TYPE DISTRIBUTED)` with `constraint = {...}` INSIDE TableScan = pushed; `Filter`/`ScanFilterProject` ABOVE TableScan = not pushed (iter441 PushedFilters/PostScanFilters guardrail held).
- `EXPLAIN (TYPE IO, FORMAT JSON)` returns `inputTableColumnInfos` with per-column `domain.ranges` for pre-execution constraint preview.
- `EXPLAIN ANALYZE VERBOSE` for `dynamicFilterSplitsProcessed` metric.

**Query performance regression diagnosis topic: 4.2085 → 4.2596 / 13 (+0.0511). The two-consecutive sub-3.0 datapoint pattern is BROKEN.**

### (b) Q2 Branch DDL re-probe — RESOLVED on iter442 fabrications BUT fast_forward arg-order REVERSED

**Q2 score: 3.3125 FAIL.** Mixed verdict:
- **RESOLVED (iter442 fabrications):** No `INSERT INTO (BRANCH 'x')` parenthesized clause; no `MERGE BRANCH x INTO main` DDL; no `writeTo + .option("branch")` cross combination. Uses suffix notation OR WAP session conf, AND uses `fast_forward` procedure (not MERGE BRANCH DDL).
- **NEW INACCURACY (2a) — branch name / suffix mismatch:** Branch literally named `staging-branch` (hyphen) but suffix written `branch_staging_branch` (underscore). The hyphen-to-underscore conversion is NOT how Iceberg branch suffix-notation works — per iceberg.apache.org/docs/latest/spark-writes/, the suffix is literal `branch_<exact-name>`. Engineer copy-paste targets a nonexistent branch.
- **NEW INACCURACY (2b) — fast_forward arg order REVERSED — LOAD-BEARING.** Responder wrote `fast_forward(table => 'analytics.orders', branch => 'staging-branch', to => 'main')`. **Verified per iceberg.apache.org/docs/latest/spark-procedures/: signature is `fast_forward(table, branch, to)` where `branch` = target being fast-forwarded, `to` = source whose tip is taken.** Canonical WAP-publish: `fast_forward('table', 'main', 'audit-branch')`. The responder's args are REVERSED — they would attempt to fast-forward STAGING to MAIN's tip (abandons the staged work instead of publishing it; also typically errors since main is not a descendant of staging in a WAP flow). An engineer who copy-pastes this loses the audit work entirely.

**Verdict: Q2 RESOLVED at the gross-DDL level, FAILED at the syntax-detail level. fast_forward arg-order reversal is confirmed.**

### (c) Q3 dynamic filtering — federation BUFFER score + margin + STAYS PASSED

**Q3 score: 4.78125 STRONG PASS.**

**Federation average recompute:**
- Prior: 4.5026 × 304 = 1368.79
- New: (1368.79 + 4.78125) / 305 = 4.50346
- **New average: 4.5035 / 305**

**Margin above 4.5 threshold:**
- Iter441 margin: +0.0020
- Iter442 margin: +0.0026 (+0.0006 expansion)
- **Iter443 margin: +0.0035 (+0.0009 expansion vs iter442)**

**STAYS PASSED?** **YES — Federation buffer continues marginal recovery for 2nd consecutive iter.** Margin restored from +0.0020 → +0.0026 → +0.0035. Still THIN at 305 datapoints; each strong Q3-pair datapoint contributes ~+0.001 to the margin. **Federation STAYS PASSED.**

### (d) Q4 ANALYZE / CBO + drop_extended_stats + join_reordering_strategy

**Q4 score: 4.875 STRONG PASS.** All semantics canonical:
- `ANALYZE iceberg.analytics.events` (no TABLE keyword — Trino syntax). VERIFIED.
- `WITH(columns=ARRAY['col1','col2'])` column-targeted form. VERIFIED.
- Puffin NDV sketch file written alongside Parquet data files. VERIFIED per trino.io/docs/current/optimizer/statistics.html.
- `join_reordering_strategy=AUTOMATIC` enumerates orders, stats-based cost; falls back to `ELIMINATE_CROSS_JOINS` if no stats. VERIFIED per trino.io/docs/current/optimizer/cost-based-optimizations.html verbatim.
- `EXPLAIN` Estimates rows concrete N vs `?` (CBO guessing without stats).
- `SHOW STATS FOR <table>` displays distinct_values_count column.
- `ALTER TABLE ... EXECUTE drop_extended_stats` procedure BEFORE column-subset re-ANALYZE — CORRECT footgun callout.

**No fabricated procedure names, no incorrect property defaults.**

### (e) NEW confident-inaccuracies this iter

**TWO new confident-inaccuracies, BOTH on Q2:**
1. Branch-name vs suffix-name mismatch (`staging-branch` declared but `branch_staging_branch` written in suffix).
2. fast_forward arg order REVERSED (`branch => 'staging-branch', to => 'main'` instead of the correct `branch => 'main', to => 'staging-branch'`).

**Zero-confident-inaccuracy streak BROKEN at 2 iters (iter427 + iter428). New confident-inaccuracy datapoint on iter443.**

---

## Per-question scoring

### Q1 — EXPLAIN TYPE VALIDATE + TYPE IO + DISTRIBUTED (re-probe FINALLY RESOLVED)

**Scores: 5.0 / 4.75 / 4.875 / 4.875 — avg 4.875 STRONG PASS**

What landed correct:
- `EXPLAIN (TYPE VALIDATE) <query>` returns boolean `Valid` no execution — CORRECT
- `EXPLAIN (TYPE DISTRIBUTED)` with `constraint = {...}` INSIDE TableScan = pushed; `Filter`/`ScanFilterProject` ABOVE = not pushed — CORRECT
- `EXPLAIN (TYPE IO, FORMAT JSON)` returns `inputTableColumnInfos` with `domain.ranges` — CORRECT
- `EXPLAIN ANALYZE VERBOSE` for `dynamicFilterSplitsProcessed` — CORRECT
- Explicit rejection of LIMIT 0 / LIMIT 1 as "still executes through planner" — CORRECT anti-pattern
- NO `(ANALYZE false)` fabrication — iter442 NEW fabrication FIXED
- NO "Trino has no syntax-checker" denial — iter441+iter442 REPEAT denial FIXED

Minor docks:
- BC dock 0.25: could give a one-line beginner translation of what `inputTableColumnInfos.columnConstraints.domain.ranges` means in plain English.

**Verdict:** STRONG PASS — iter441+iter442 REPEAT FAILURE FINALLY RESOLVED. Query perf regression diagnosis 4.2085 → 4.2596 / 13 (+0.0511).

### Q2 — Iceberg branch write/audit/publish DDL (re-probe partial RESOLVED + NEW inaccuracies)

**Scores: 3.0 / 3.75 / 2.5 / 4.0 — avg 3.3125 FAIL**

What landed correct:
- CREATE BRANCH via Spark `ALTER TABLE ... CREATE BRANCH name [AS OF VERSION ...] [RETAIN num DAYS]` — CORRECT
- Spark write to branch via suffix notation `INSERT INTO ...table.branch_<name>` OR WAP `SET spark.wap.branch=<name>` — CORRECT structure
- Trino 467 audit-read via `FOR VERSION AS OF '<branch>'` — CORRECT
- Publish via `CALL ...fast_forward(...)` procedure (NOT a `MERGE BRANCH` DDL) — CORRECT direction
- Spark `ALTER TABLE ... DROP BRANCH name` — CORRECT
- No `INSERT INTO t (BRANCH 'x')` fabrication — iter442 inaccuracy FIXED
- No `MERGE BRANCH x INTO main` fabrication — iter442 inaccuracy FIXED

Confident-inaccuracies + docks:
- **TA dock 2.0 (TWO inaccuracies):**
  - Branch-name `staging-branch` (hyphen) vs suffix `branch_staging_branch` (underscore) — mismatch; suffix targets nonexistent branch.
  - `fast_forward(table=>'analytics.orders', branch=>'staging-branch', to=>'main')` — REVERSED. Per iceberg.apache.org/docs/latest/spark-procedures/, signature is `fast_forward(table, branch, to)` where `branch` = target being moved, `to` = source whose tip is taken. WAP-publish staging-to-main should be `branch=>'main', to=>'staging-branch'`.
- **PA dock 2.5**: Engineer who copy-pastes the publish step either errors (branch suffix mismatch / FF direction error) or abandons their staging work entirely.
- **BC 3.75**: Structure is clear and well-organized; problem is wrong details inside otherwise clear instructions.
- **Comp 4.0**: Direction-wise complete (create/write/audit/publish/drop all covered) but specific publish syntax inverted.

**Verdict:** FAIL — Iceberg table maintenance 4.4582 → 4.4459 / 106 (-0.0123). Iter442 gross fabrications RESOLVED but new syntax-detail inaccuracies introduced. The pattern is the same as iter441+iter442 — fixed fabrications surface new ones at the next level of detail.

### Q3 — Dynamic filtering on Postgres-Iceberg federation (BUFFER probe)

**Scores: 5.0 / 4.5 / 4.875 / 4.75 — avg 4.78125 STRONG PASS**

What landed correct:
- CBO picks small Postgres-region-filtered build / Iceberg events probe — CORRECT
- Region predicate pushes to Postgres FIRST (planner pushdown) — CORRECT
- DF collects customer_id values at runtime as IN-list/range — CORRECT
- IN-list/range pushed AS DF to Iceberg probe scan, prunes Parquet row-groups via min/max + manifest file-skipping — CORRECT
- `EXPLAIN ANALYZE VERBOSE` shows `dynamicFilterSplitsProcessed N` where N << total — CORRECT per trino.io/docs/current/admin/dynamic-filtering.html
- NOT-FIRE cases: LEFT/FULL OUTER (only INNER + RIGHT support DF), stale stats so wrong build, VARCHAR-key collation — CORRECT exhaustive list
- Correct Trino terminology — NO Spark PushedFilters/PushedDynamicFilters (iter441 guardrail held)

Minor docks:
- BC dock 0.5: could briefly explain that the "probe side" is the larger table and "build side" is the smaller table in beginner terms.

**Verdict:** STRONG PASS — federation BUFFER expansion 4.5026 → 4.5035 / 305, margin +0.0026 → +0.0035 (+0.0009).

### Q4 — ANALYZE TABLE / CBO / NDV / Puffin / join_reordering_strategy

**Scores: 5.0 / 4.75 / 4.875 / 4.875 — avg 4.875 STRONG PASS**

What landed correct:
- `ANALYZE iceberg.analytics.events` (no TABLE keyword — differs from Postgres) — CORRECT
- `WITH(columns=ARRAY['user_id','region','event_type'])` column-targeted — CORRECT
- Puffin NDV sketch file written alongside Parquet data files; holds HLL/NDV sketches CBO uses for join cardinality — CORRECT per trino.io/docs/current/optimizer/statistics.html
- `join_reordering_strategy=AUTOMATIC` enumerates orders + stats-based cost; fallback ELIMINATE_CROSS_JOINS if no stats — CORRECT verbatim per trino.io/docs/current/optimizer/cost-based-optimizations.html
- `EXPLAIN <query>` Estimates rows concrete N vs `?` guessing — CORRECT
- `SHOW STATS FOR <table>` displays distinct_values_count — CORRECT
- `ALTER TABLE ... EXECUTE drop_extended_stats` procedure BEFORE column-subset re-ANALYZE — CORRECT footgun callout

Minor docks:
- BC dock 0.25: solid; could spell out the cadence recommendation (nightly for high-churn, weekly for stable).

**Verdict:** STRONG PASS — Trino CBO/ANALYZE 4.7184 → 4.7341 / 10 (+0.0157).

---

## Topic-score updates

| Topic | Before | After | Delta | Status |
|---|---|---|---|---|
| Query performance regression diagnosis | 4.2085 / 12 | **4.2596 / 13** | **+0.0511** | PASSED — REPEAT FAILURE RESOLVED |
| Iceberg table maintenance | 4.4582 / 105 | **4.4459 / 106** | -0.0123 | PASSED (above 3.5 standard threshold; new syntax-detail inaccuracies drag down) |
| Trino federation / cross-source connectors | 4.5026 / 304 | **4.5035 / 305** | **+0.0009** | **PASSED — margin +0.0026 → +0.0035 (+0.0009 expansion)** |
| Trino CBO / ANALYZE TABLE / NDV / join ordering | 4.7184 / 9 | **4.7341 / 10** | +0.0157 | PASSED |

(Q1 EXPLAIN re-probe RESOLVED; Q2 branch DDL partial RESOLVED + new fast_forward arg-order inaccuracy; Q3 federation BUFFER expansion; Q4 ANALYZE/CBO strong.)

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.875 | Query perf regression (EXPLAIN TYPE VALIDATE + TYPE IO) | STRONG PASS — RESOLVED after 3 consecutive iters of failure |
| Q2 | 3.3125 | Iceberg table maintenance (branch WAP write/audit/publish) | FAIL — gross fabrications RESOLVED, syntax-detail inaccuracies NEW |
| Q3 | 4.78125 | Federation (dynamic filtering Postgres-Iceberg) | STRONG PASS — buffer expands |
| Q4 | 4.875 | Trino CBO / ANALYZE / NDV | STRONG PASS — canonical |

**Average 4.461 PASS — +0.602 step-UP from iter442 3.859. Major recovery on Q1 EXPLAIN (3-iter chronic failure RESOLVED); Q2 partial — iter442 fabrications fixed but introduces TWO new inaccuracies at the syntax-detail layer; Q3 federation buffer continues marginal recovery; Q4 canonical.**

**Headline outcomes:**
- TWO new confident-inaccuracies this iter (both on Q2: branch name/suffix mismatch + fast_forward arg order reversed) — zero-confident-inaccuracy streak STILL BROKEN at 2 iters (iter427+iter428).
- Federation 4.5026 → 4.5035 / 305 (+0.0009; margin +0.0026 → +0.0035 — 2nd consecutive iter of margin restoration).
- Query perf regression diagnosis 4.2085 → 4.2596 / 13 (+0.0511, Q1 4.875 well above topic avg — REPEAT FAILURE RESOLVED).
- Iceberg table maintenance 4.4459 / 106 (-0.0123, Q2 3.3125 below topic avg).
- Trino CBO 4.7341 / 10 (+0.0157, Q4 4.875 above topic avg).
- ALL REQUIRED TOPICS REMAIN PASSED on aggregate.

**Failure-mode pattern observation:** iter441 → iter442 → iter443 shows a recurring "fabrication-at-current-layer fixed, new-inaccuracy-at-next-detail-layer appears" pattern on Iceberg branch DDL. Iter441 had gross Spark-vs-Trino confusion; iter442 had fabricated SQL forms (`(BRANCH 'x')`, `MERGE BRANCH`); iter443 has correct SQL forms but wrong argument values inside the right procedure. The teacher's fixes are landing one layer at a time. Suggest a SINGLE comprehensive canonical example (named branch `audit_branch` with underscore for safety; complete CREATE→write→fast_forward→DROP sequence with exact arg names and values) to break this pattern.

---

## Teacher actions next (iter 444) — HIGH PRIORITY

1. **HIGH — FIX Q2 fast_forward arg-order canonical example.** Add or update the Iceberg branch resource (r17 per state.json) with an EXPLICIT canonical WAP-publish example using the exact arg names from iceberg.apache.org/docs/latest/spark-procedures/:
   - **Signature:** `CALL catalog.system.fast_forward(table, branch, to)` where `branch` = TARGET (being fast-forwarded), `to` = SOURCE (whose tip is taken).
   - **WAP-publish canonical pattern:** `CALL catalog.system.fast_forward(table => 'analytics.orders', branch => 'main', to => 'audit_branch')` — publish means moving MAIN to audit's tip.
   - **DO-NOT-WRITE block:** "Do NOT write `branch => 'audit_branch', to => 'main'` — this is REVERSED and would attempt to fast-forward audit's pointer to main (the wrong direction; abandons the staged work)."
   - **Mnemonic:** "branch = the one that MOVES; to = the one being MOVED TO. Publish staging to main means MAIN moves; staging stays where it is."

2. **HIGH — FIX Q2 branch-name vs suffix-name consistency.** Add or update the branch resource:
   - **Suffix is LITERAL.** A branch named `audit-branch` (with hyphen) requires suffix `` `branch_audit-branch` `` (with backticks because of the hyphen identifier rule). A branch named `audit_branch` (with underscore) requires suffix `branch_audit_branch` (no backticks needed).
   - **RECOMMENDED CONVENTION:** Use underscore-only branch names (e.g., `audit_branch`, `staging`, `wap_2026_01_01`) to avoid identifier-quoting complications.
   - **DO-NOT-WRITE block:** "Do NOT silently convert hyphens to underscores in the suffix — a branch named `staging-branch` is a DIFFERENT branch from `staging_branch`. If the engineer wants to reuse the canonical suffix `branch_staging_branch`, name the branch `staging_branch` from the start."

3. **MEDIUM — RETAIN Q1 EXPLAIN findability fix.** r22 §3.4 cross-resource duplication LANDED in iter443. Re-probe in iter446 or iter447 from a slightly different question phrasing (e.g., "what's the cheapest way to confirm my DBT MERGE compiles in Trino without running it?") to confirm durability.

4. **MEDIUM — RETAIN Q3 federation buffer.** Q3 4.78125 contributes +0.0009 to margin. Federation buffer is on 2-iter expansion streak (+0.0006 + 0.0009). Continue Q3-pair re-probes at current cadence to compound the buffer recovery.

5. **STRATEGIC — Loop posture: iter443 PASSES (4.461) with major recovery on Q1 (3-iter chronic failure RESOLVED) but introduces TWO new confident-inaccuracies on Q2 syntax-detail layer.** The recurring "fix the gross issue, surface the next-detail issue" pattern on Iceberg branches suggests the teacher's fixes are one detail layer at a time. The remedy is a SINGLE comprehensive end-to-end canonical example (named branch, suffix form, fast_forward args, DROP) with explicit DO-NOT-WRITE blocks at each detail level.

---

## Judge probe targets next (iter 444) — MANDATORY DIRECT RE-PROBES

1. **HIGH — Q2 Iceberg branch fast_forward arg-order direct re-probe.** Ask "how do I promote my Spark audit branch to main using fast_forward?" — expected answer: `CALL catalog.system.fast_forward('table', 'main', 'audit-branch')` where `'main'` is the BRANCH arg (target being moved) and `'audit-branch'` is the TO arg (source whose tip is taken). Confirm responder does NOT reverse the args.

2. **HIGH — Q2 Iceberg branch-name vs suffix-name consistency direct re-probe.** Ask "I created a branch called `monthly-audit-2026` — show me the exact INSERT INTO suffix" — expected answer: suffix `` `branch_monthly-audit-2026` `` with backticks (because of hyphens) OR a recommendation to rename the branch to `monthly_audit_2026` for simplicity.

3. **MEDIUM — Q1 EXPLAIN findability durability** (3-5 iters out) — confirm r22 §3.4 fix durable against slightly different question phrasing (e.g., "validate this dbt model SQL without running it" / "preview what tables a query touches without execution").

4. **MEDIUM — Q3 federation BUFFER continuation** — continue Q3-pair re-probes (CBO subtleties / runtime DF / pushdown corner cases) to compound federation margin recovery beyond +0.0035.

5. **LOW — Carry forward backlog**: pushdown corner cases (CAST-wrapped col, LIKE prefix, OR-of-equality); isolation-level write props; Iceberg identity-column durability; partition-spec-evolution different-angle.

---

## Critical message to teacher for iter 444

**Iter443 is a 4.461 PASS — +0.602 major recovery from iter442 3.859 — with the 3-iter chronic Q1 EXPLAIN failure FINALLY RESOLVED (iter441+iter442 REPEAT TYPE VALIDATE denial + iter442 NEW `(ANALYZE false)` fabrication ALL FIXED).** The r22 §3.4 cross-resource findability fix LANDED.

**BUT Q2 branch DDL re-probe introduces TWO NEW confident-inaccuracies at the syntax-detail layer:**
1. **Branch-name `staging-branch` (hyphen) declared but suffix `branch_staging_branch` (underscore) written.** Per iceberg.apache.org/docs/latest/spark-writes/, suffix is literal `branch_<exact-name>`. Engineer copy-paste targets nonexistent branch.
2. **fast_forward arg order REVERSED.** Responder wrote `branch => 'staging-branch', to => 'main'`. Per iceberg.apache.org/docs/latest/spark-procedures/, signature is `fast_forward(table, branch, to)` where `branch` = TARGET being fast-forwarded, `to` = SOURCE whose tip is taken. WAP-publish staging→main should be `branch => 'main', to => 'staging-branch'`. The responder's args are inverted — they would either error or move staging's pointer up to main's tip (abandoning the staging work instead of publishing it).

**Pattern observation across iter441-442-443 on Iceberg branches:** The teacher's fixes are landing one detail layer at a time — iter441 fixed Spark-vs-Trino confusion, iter442 fixed fabricated SQL forms `(BRANCH 'x')`/`MERGE BRANCH`, iter443 surfaces wrong args inside the right procedure. The remedy is a SINGLE comprehensive end-to-end canonical example in r17 (or wherever the branch DDL content lives) with EXPLICIT arg-name mnemonic and DO-NOT-WRITE blocks at each detail level. Concrete teacher action items in §"Teacher actions next" above.

**Q3 federation BUFFER: STRONG PASS 4.78125.** Continues marginal recovery — margin +0.0026 → +0.0035 (+0.0009). 2nd consecutive iter of buffer expansion after the iter441 contraction.

**Q4 ANALYZE/CBO: STRONG PASS 4.875.** Canonical answer — `ANALYZE iceberg.analytics.events` no TABLE keyword + `WITH(columns=ARRAY[...])` + Puffin NDV + `join_reordering_strategy=AUTOMATIC` + `drop_extended_stats` EXECUTE procedure before column-subset re-analyze. All verified per trino.io.

**Loop status:** PASSED stays on aggregate (all required topics still above thresholds), federation margin marginally restored for 2nd consecutive iter, Q1 chronic-failure RESOLVED, BUT new confident-inaccuracy datapoint on Q2 syntax-detail layer. state.json `passed: true` stays.

**Other key verifications this iter:**
- `EXPLAIN (TYPE VALIDATE)` returns boolean `Valid`, no execution — verified per trino.io/docs/current/sql/explain.html
- `EXPLAIN (TYPE IO, FORMAT JSON)` returns `inputTableColumnInfos` with `domain.ranges` — verified per trino.io/docs/current/sql/explain.html
- `EXPLAIN ANALYZE` has ONLY `VERBOSE` option; ALWAYS executes — verified per trino.io/docs/current/sql/explain-analyze.html (no fabricated options surfaced this iter)
- Iceberg `fast_forward(table, branch, to)` signature with `branch` = target, `to` = source — VERIFIED per iceberg.apache.org/docs/latest/spark-procedures/ (responder REVERSED — LOAD-BEARING inaccuracy)
- Iceberg branch suffix is literal `branch_<exact-name>` — VERIFIED per iceberg.apache.org/docs/latest/spark-writes/ (responder silently converted hyphen to underscore)
- Trino dynamic filtering INNER + RIGHT joins only; `dynamicFilterSplitsProcessed` in EXPLAIN ANALYZE — verified per trino.io/docs/current/admin/dynamic-filtering.html
- Trino `join_reordering_strategy=AUTOMATIC` enumerates orders + stats-based cost, fallback ELIMINATE_CROSS_JOINS — verified per trino.io/docs/current/optimizer/cost-based-optimizations.html
- Trino `ANALYZE <table>` no TABLE keyword + `WITH(columns=ARRAY[...])` — verified per trino.io/docs/current/sql/analyze.html
- Puffin NDV sketch storage — verified per trino.io/docs/current/optimizer/statistics.html
