# Judge Feedback — Iter 442 (EXTENDED PHASE — end-of-iteration only)

**Overall: 3.859 PASS** (Q1 4.6875 + Q2 2.4375 + Q3 4.875 + Q4 3.4375) — **+0.093 step-UP from iter441 3.766; federation BUFFER recovers marginally (+0.0020 → +0.0026); Q3 LISTAGG ON OVERFLOW RESOLVED; BUT Q2 EXPLAIN TYPE VALIDATE STILL MISSED with NEW `EXPLAIN ANALYZE (ANALYZE false)` fabrication; Q4 introduces NEW Spark branch DDL fabrications (INSERT INTO ... (BRANCH 'x') + MERGE BRANCH x INTO main are NOT real Iceberg-Spark syntax).**

---

## HEADLINE

1. **Q1 federation CRITICAL re-probe — STRONG PASS 4.6875 — iter441 PushedFilters/PostScanFilters guardrail LANDED.** Responder now uses CORRECT Trino EXPLAIN terminology: `constraint = {...}` annotation INSIDE the `TableScan` (pushed) vs separate `Filter` / `ScanFilterProject` operator ABOVE the scan (not pushed). Did NOT use Spark `PushedFilters` / `PostScanFilters`. Four-predicate categorization correct: integer equality `account_id=12345` pushes; string `IN('active','trial')` pushes; date range `created_at > '2025-01-01'` pushes; function-wrapped `LOWER(email) LIKE '%acme%'` does NOT push (function-wrap + leading-wildcard). Verified per trino.io/docs/current/optimizer/pushdown.html + trino.io/docs/current/connector/postgresql.html. **Federation 4.5020 → 4.5026 / 304 (+0.0006); margin +0.0020 → +0.0026 (+0.0006 expansion). STAYS PASSED.** Margin restoration confirmed but still thin — one more sub-4.5 datapoint puts the topic in danger.

2. **Q2 EXPLAIN re-probe — FAIL 2.4375 — TWO confident-inaccuracies; teacher r18 guardrail did NOT land.** (a) Responder AGAIN claimed "Trino does NOT have a validate-syntax-without-execute command" — VERIFIED FALSE per trino.io/docs/current/sql/explain.html: `EXPLAIN (TYPE VALIDATE) <query>` returns single boolean column `Valid`, validates without executing, detects unknown keywords + invalid object names. **REPEAT confident-inaccuracy across two consecutive iters.** (b) Responder gave `EXPLAIN ANALYZE (ANALYZE false) <query>` claiming it's "plan only, don't execute" — VERIFIED FABRICATED per trino.io/docs/current/sql/explain-analyze.html: the ONLY documented option for `EXPLAIN ANALYZE` is `VERBOSE`; there is NO `(ANALYZE false)` option; `EXPLAIN ANALYZE` ALWAYS executes the query. **NEW confident-inaccuracy with fabricated syntax.** (c) For use-case (a) "what will it scan" the responder gave plain `EXPLAIN` + `$partitions` metadata-table queries instead of the canonical `EXPLAIN (TYPE IO, FORMAT JSON)` (returns `inputTableColumnInfos` with per-column `domain` constraints). (d) Improvement: responder said "never use LIMIT 1" — agrees with iter441 anti-pattern callout — but still suggested `LIMIT 0` (still executes the planner). This is a **REPEAT FAILURE on the SAME topic the teacher guardrailed in iter441**, indicating the r18 §EXPLAIN-TYPE-IO/VALIDATE content is either (i) not being reached by the responder for this question phrasing (findability gap), or (ii) overridden by content in a different resource file (likely r22 if the responder is reading EXPLAIN content from the federation resource).

3. **Q3 LISTAGG re-probe — STRONG PASS 4.875 — RESOLVED.** Responder produced direct 1:1 Trino mapping: `listagg(product_name, ', ' ON OVERFLOW TRUNCATE '...' WITH COUNT) WITHIN GROUP (ORDER BY ...)`. All three overflow variants surfaced: `ON OVERFLOW ERROR` (default), `ON OVERFLOW TRUNCATE '<filler>' WITH COUNT`, `ON OVERFLOW TRUNCATE '<filler>' WITHOUT COUNT`. Trino 1,048,576-byte limit vs Oracle 4,000/32,767-byte limit comparison surfaced correctly. No unnecessary `array_join`/`array_agg` fallback steered to. Verified per trino.io/docs/current/functions/aggregate.html. **Iter441 Q3 guardrail LANDED.**

4. **Q4 Iceberg branches / WAP — FAIL 3.4375 — TWO new fabricated Spark branch DDL forms.** The high-level direction is correct (Trino 467 reads branches via `FOR VERSION AS OF 'branch'`; CREATE/write/merge/DROP BRANCH are Spark-only; expire_snapshots cleans abandoned branch snapshots). BUT specific Spark syntax examples are wrong: (a) `INSERT INTO accounts (BRANCH 'staging')` — FABRICATED. Real Iceberg-Spark branch-write SQL is `INSERT INTO prod.db.table.branch_staging` (suffix notation on table identifier) OR `SET spark.wap.branch = staging; INSERT INTO prod.db.table ...` (WAP session config). There is NO `(BRANCH '...')` parenthesized clause in Iceberg-Spark INSERT. (b) `MERGE BRANCH x INTO main` — FABRICATED. Real Iceberg branch fast-forward is `CALL catalog.system.fast_forward('table', 'main', 'audit-branch')` procedure call, NOT a `MERGE BRANCH` DDL statement. (c) `.writeTo().option("branch", ...)` — PARTIAL fabrication: documented forms are `data.writeTo("prod.db.table.branch_audit").overwritePartitions()` (suffix) OR `df.write.format("iceberg").option("branch", "x")...save(...)` (write+option). The `writeTo().option("branch")` cross combination is not the documented form. Verified per iceberg.apache.org/docs/latest/spark-writes/ + iceberg.apache.org/docs/latest/branching/. Engineer who copy-pastes the fabricated SQL gets parse errors. **TWO new confident-inaccuracies on Spark branch DDL.**

---

## Critical confirmations (explicit)

### (a) Q1 federation CRITICAL re-probe — margin recovery + STAYS PASSED

**Q1 score: 4.6875 STRONG PASS.** Scores: TA 4.75 / BC 4.5 / PA 4.75 / Comp 4.75.

**Federation average recompute:**
- Prior: 4.5020 × 303 = 1364.106 (using cleaner precision: new_avg = old_avg + (new − old)/new_count = 4.5020 + (4.6875 − 4.5020)/304 = 4.5020 + 0.000610)
- **New average: 4.5026 / 304**

**Margin above 4.5 threshold:**
- Iter440 margin: +0.00554
- Iter441 margin: +0.00200 (×0.36 contraction)
- **Iter442 margin: +0.00261 (+0.00061 expansion vs iter441)**

**STAYS PASSED?** **YES — Federation buffer marginally recovers.** Margin restored from +0.00200 to +0.00261 (a +0.00061 expansion). Still THIN — at 304 datapoints, the topic now needs roughly 30 consecutive 4.6+ datapoints to climb the buffer back to the iter440 +0.00554 level. **Federation STAYS PASSED but the iter441 buffer compression is only partially undone.**

**Iter441 PushedFilters/PostScanFilters Spark-terminology guardrail LANDED:** Responder correctly named `TableScan[constraint = {...}]` (pushed) vs separate `Filter` / `ScanFilterProject` operator (not pushed); did NOT use any Spark Catalyst field names.

### (b) Q2 EXPLAIN re-probe — TYPE VALIDATE miss + EXPLAIN ANALYZE (ANALYZE false) fabrication verdict

**Q2 score: 2.4375 FAIL.** Scores: TA 2.0 / BC 3.75 / PA 2.0 / Comp 2.0.

**TYPE VALIDATE miss verdict: REPEAT CONFIDENT-INACCURACY.** Responder AGAIN claimed "Trino does NOT have a validate-syntax-without-execute command." This is the SECOND consecutive iter the responder has denied TYPE VALIDATE's existence despite state.json iter441 + iter442 claiming r18 tightened to surface it. Verified per trino.io/docs/current/sql/explain.html: `EXPLAIN (TYPE VALIDATE) <query>` validates statement WITHOUT executing, returns single boolean column `Valid`, detects unknown keywords AND invalid object names.

**EXPLAIN ANALYZE (ANALYZE false) fabrication verdict: NEW CONFIDENT-INACCURACY.** Responder gave `EXPLAIN ANALYZE (ANALYZE false) <query>` claiming "plan only, don't execute." Verified per trino.io/docs/current/sql/explain-analyze.html:
- The ONLY documented option for `EXPLAIN ANALYZE` is `VERBOSE` ("EXPLAIN ANALYZE [VERBOSE] <statement>").
- There is NO `(ANALYZE false)` option.
- The documentation explicitly states `EXPLAIN ANALYZE` "Execute the statement and show the distributed execution plan of the statement along with the cost of each operation" — it ALWAYS executes.
- The fabricated syntax would fail to parse at the Trino prompt.

**An engineer who copy-pastes this `EXPLAIN ANALYZE (ANALYZE false)` fabrication gets a SQL parse error.** This is a higher-severity confident-inaccuracy than iter441's TYPE VALIDATE denial because the syntax itself is invented.

**TYPE IO miss verdict.** Responder gave plain `EXPLAIN` + `SELECT ... FROM <table>$partitions` queries for use-case (a) "what will it scan" instead of the canonical `EXPLAIN (TYPE IO, FORMAT JSON) <query>` which returns `inputTableColumnInfos` with per-column `domain` constraints. The `$partitions` metadata table approach is useful for browsing actual partitions in storage but is NOT a substitute for `TYPE IO`'s pre-execution constraint-domain analysis.

**LIMIT 0 verdict.** Improvement over iter441's LIMIT 1: responder now says "never use LIMIT 1" — correct anti-pattern. BUT then suggests `LIMIT 0` as cheap validation. `LIMIT 0` still goes through the parser + analyzer + planner (so it catches errors TYPE VALIDATE catches), but it ALSO triggers query distribution and may execute. TYPE VALIDATE is the cleaner answer.

**Findability hypothesis (HIGH-PRIORITY TEACHER ACTION for iter443).** The EXPLAIN guardrail content is in r18 per state.json, but the responder may be reading EXPLAIN-related content from r22 (federation pushdown EXPLAIN signature) for this question type. **Teacher must ensure the TYPE VALIDATE + TYPE IO canonical content is duplicated/cross-referenced into r22 §EXPLAIN-flavors OR into a dedicated EXPLAIN-flavor resource that surfaces FIRST when the responder searches for "validate syntax without execute" / "what will it scan."** This is the second consecutive iter the canonical content has failed to land — the guardrail is not where the responder is looking.

### (c) Q3 LISTAGG ON OVERFLOW — RESOLVED

**Q3 score: 4.875 STRONG PASS.** Scores: TA 5.0 / BC 4.75 / PA 5.0 / Comp 4.75.

**RESOLVED?** **YES.** All three overflow variants surface: `ON OVERFLOW ERROR` (default), `ON OVERFLOW TRUNCATE '...' WITH COUNT`, `ON OVERFLOW TRUNCATE '...' WITHOUT COUNT`. Direct 1:1 mapping to Oracle. Trino 1,048,576-byte limit vs Oracle 4,000/32,767-byte limit comparison correctly stated. No unnecessary `array_join`/`array_agg` workaround steered to. Verified per trino.io/docs/current/functions/aggregate.html. **Iter441 Q3 confident-inaccuracy ("Oracle ON OVERFLOW has no Trino equivalent") FIXED.**

### (d) Q4 Iceberg branches — Spark DDL verification + new confident-inaccuracies

**Q4 score: 3.4375 FAIL.** Scores: TA 2.75 / BC 4.0 / PA 3.0 / Comp 4.0.

**What landed correct (verified per iceberg.apache.org/docs/latest/branching/ + iceberg.apache.org/docs/latest/spark-ddl/ + iceberg.apache.org/docs/latest/spark-writes/):**
- Trino 467 reads branches via `FOR VERSION AS OF 'branch_name'` — CORRECT.
- Trino 467 cannot CREATE / WRITE TO / MERGE / DROP branches — CORRECT (Spark-only).
- Spark `ALTER TABLE ... CREATE BRANCH name [AS OF VERSION snapshot_id] [IF NOT EXISTS]` — CORRECT.
- Spark `ALTER TABLE ... DROP BRANCH name` — CORRECT.
- Abandoned-branch snapshots cleaned by `expire_snapshots` once branch DROPPED — CORRECT.
- Per-op table of Trino-can / Trino-cannot — CORRECT direction.

**Fabricated Spark DDL forms (NEW confident-inaccuracies):**
- **`INSERT INTO accounts (BRANCH 'staging') VALUES (...)`** — FABRICATED. The documented Iceberg-Spark branch-write SQL is:
  - Suffix notation: `INSERT INTO prod.db.table.branch_staging VALUES (...)` (or `UPDATE prod.db.table.branch_audit SET val='c'`, or `DELETE FROM prod.db.table.branch_audit WHERE id=2`).
  - WAP session config: `SET spark.wap.branch = staging; INSERT INTO prod.db.table VALUES (...)`.
  - There is NO `(BRANCH '...')` parenthesized clause in INSERT INTO.
- **`MERGE BRANCH staging INTO main`** — FABRICATED. The documented Iceberg branch fast-forward is:
  - `CALL catalog.system.fast_forward('table', 'main', 'audit-branch')` procedure call.
  - There is NO `MERGE BRANCH` DDL statement in Iceberg-Spark.
- **`.writeTo("table").option("branch", "x")`** — PARTIAL fabrication. Documented forms:
  - `data.writeTo("prod.db.table.branch_audit").overwritePartitions()` (suffix on writeTo identifier).
  - `df.write.format("iceberg").option("branch", "ML_exp").mode("append").save("glue.test.employees")` (write + option).
  - The `writeTo + .option("branch")` cross combination is not in the docs.

An engineer who copy-pastes any of these fabricated forms gets a SQL parse error. The direction (read-only Trino, Spark for writes, expire_snapshots cleanup) is CORRECT but the concrete syntax examples are WRONG. This is the **third consecutive question (Q2 + Q4) with NEW fabricated syntax** in iter442.

---

## Per-question scoring

### Q1 — Predicate pushdown EXPLAIN (Trino federation CRITICAL re-probe)

**Scores: 4.75 / 4.5 / 4.75 / 4.75 — avg 4.6875 STRONG PASS**

What landed correct:
- `account_id=12345` integer equality pushes to PG — CORRECT
- `status IN('active','trial')` string IN pushes — CORRECT (IN is equality-set per Trino PG connector docs)
- `created_at > '2025-01-01'` date range pushes — CORRECT (temporal types push)
- `LOWER(email) LIKE '%acme%'` does NOT push — CORRECT (function-wrap + leading wildcard)
- VARCHAR equality pushes; VARCHAR range stays unless `postgresql.experimental.enable-string-pushdown-with-collate` flag — CORRECT nuance
- **Trino EXPLAIN signature: `TableScan` with `constraint = {...}` annotation INSIDE = pushed; `Filter` / `ScanFilterProject` operator ABOVE = not pushed — CORRECT** (verified per trino.io/docs/current/optimizer/pushdown.html "If predicate pushdown for a specific clause is successful, the EXPLAIN plan for the query does not include a ScanFilterProject operation for that clause")
- **NO Spark `PushedFilters` / `PostScanFilters` / `PartitionFilters` terms** — iter441 guardrail LANDED

Minor docks:
- BC dock 0.5: could briefly unpack what `ScanFilterProject` vs `Filter` operator difference means for a beginner.

**Verdict:** STRONG PASS — federation BUFFER re-probe restoring margin from +0.0020 to +0.0026 (+0.0006 expansion). 4.5020 → 4.5026 / 304.

### Q2 — EXPLAIN preview + validate (re-probe REPEAT FAILURE)

**Scores: 2.0 / 3.75 / 2.0 / 2.0 — avg 2.4375 FAIL (WORSE than iter441 2.75)**

What landed correct:
- "Never use LIMIT 1" anti-pattern callout — improvement over iter441
- Plain `EXPLAIN <query>` does NOT execute — TRUE for the EXPLAIN form (just not what was asked)

Confident-inaccuracies + docks:
- **TA dock 3.0 (TWO confident-inaccuracies):**
  - REPEAT: "Trino does NOT have a validate-syntax-without-execute command" — WRONG. `EXPLAIN (TYPE VALIDATE)` exists per trino.io/docs/current/sql/explain.html.
  - NEW: `EXPLAIN ANALYZE (ANALYZE false) <query>` — FABRICATED. `EXPLAIN ANALYZE` has only `VERBOSE` option per trino.io/docs/current/sql/explain-analyze.html and ALWAYS executes.
- **Comp dock 3.0**: Missed BOTH canonical tools the question targeted — `EXPLAIN (TYPE IO, FORMAT JSON)` (with `inputTableColumnInfos`) and `EXPLAIN (TYPE VALIDATE)` (boolean `Valid`).
- **PA dock 3.0**: Engineer following the advice would (a) believe no validator exists, (b) try `EXPLAIN ANALYZE (ANALYZE false)` and get a parse error; both block real work.

**Verdict:** FAIL — WORSE than iter441. Query performance regression diagnosis topic drops 4.3695 → 4.2085 / 12 (-0.1610 step-down; still above the 3.5 standard threshold so topic stays PASSED, but second consecutive sub-3.0 datapoint on this topic at only 12 datapoints density means topic-level fragility is increasing).

### Q3 — LISTAGG ON OVERFLOW (re-probe RESOLVED)

**Scores: 5.0 / 4.75 / 5.0 / 4.75 — avg 4.875 STRONG PASS**

What landed correct:
- `listagg(product_name, ', ' ON OVERFLOW TRUNCATE '...' WITH COUNT) WITHIN GROUP (ORDER BY ...)` direct 1:1 — CORRECT
- All three variants: `ON OVERFLOW ERROR` (default), `ON OVERFLOW TRUNCATE '...' WITH COUNT`, `ON OVERFLOW TRUNCATE '...' WITHOUT COUNT` — CORRECT per trino.io/docs/current/functions/aggregate.html
- Trino 1,048,576-byte limit — CORRECT
- Oracle 4,000/32,767-byte limit comparison — CORRECT (Oracle 4000 chars without MAX_STRING_SIZE=EXTENDED; 32,767 with EXTENDED)
- No unnecessary `array_join`/`array_agg` workaround — CORRECT

Minor docks:
- BC dock 0.25: solid clarity.
- Comp dock 0.25: could mention NULL-skip semantics like Oracle.

**Verdict:** STRONG PASS — iter441 confident-inaccuracy ("Oracle ON OVERFLOW has no Trino equivalent") FIXED. Oracle PL/SQL migration 4.6103 → 4.6242 / 19 (+0.0139 step-UP).

### Q4 — Iceberg branches / WAP

**Scores: 2.75 / 4.0 / 3.0 / 4.0 — avg 3.4375 FAIL**

What landed correct:
- Trino 467 reads branches via `FOR VERSION AS OF 'branch'` — CORRECT
- Trino 467 cannot CREATE / WRITE / MERGE / DROP branches — CORRECT
- Spark `ALTER TABLE ... CREATE BRANCH name [AS OF VERSION snapshot_id]` — CORRECT
- Spark `ALTER TABLE ... DROP BRANCH name` — CORRECT
- `expire_snapshots` cleans abandoned-branch snapshots once branch dropped — CORRECT
- Per-op table direction (what Trino can / cannot do) — CORRECT

Confident-inaccuracies + docks:
- **TA dock 2.25 (TWO new fabrications):**
  - `INSERT INTO accounts (BRANCH 'staging') VALUES (...)` — FABRICATED. Real Iceberg-Spark forms: `INSERT INTO prod.db.table.branch_staging VALUES (...)` suffix notation, OR `SET spark.wap.branch=staging; INSERT INTO ...` WAP config.
  - `MERGE BRANCH staging INTO main` — FABRICATED. Real Iceberg branch fast-forward: `CALL catalog.system.fast_forward('table', 'main', 'audit-branch')` procedure.
  - `.writeTo("table").option("branch", "x")` — partial fabrication; documented forms are `writeTo("table.branch_x")` OR `df.write.option("branch","x")...save(...)`.
- **PA dock 2.0**: Engineer who copy-pastes fabricated SQL gets parse errors.
- **Comp dock 1.0**: Branch retention properties (min-snapshots-to-keep, max-snapshot-age-ms) not mentioned; tag-vs-branch distinction not surfaced (relevant for WAP workflow).

**Verdict:** FAIL — Iceberg table maintenance 4.4680 → 4.4582 / 105 (-0.0098 step-down; still well above 3.5 standard threshold). Direction was correct but specific Spark syntax examples were fabricated.

---

## Topic-score updates

| Topic | Before | After | Delta | Status |
|---|---|---|---|---|
| Trino federation / cross-source connectors | 4.5020 / 303 | **4.5026 / 304** | **+0.0006** | **PASSED — margin recovers +0.0020 → +0.0026 (+0.0006 expansion)** |
| Query performance regression diagnosis | 4.3695 / 11 | **4.2085 / 12** | -0.1610 | PASSED (above 3.5 standard threshold; second consecutive sub-3.0 datapoint) |
| Oracle PL/SQL → dbt + Trino migration | 4.6103 / 18 | **4.6242 / 19** | +0.0139 | PASSED — RESOLVED |
| Iceberg table maintenance | 4.4680 / 104 | **4.4582 / 105** | -0.0098 | PASSED (above 3.5 standard threshold) |

(Q1 federation CRITICAL re-probe; Q2 query-perf-regression REPEAT FAILURE; Q3 Oracle migration RESOLVED; Q4 Iceberg table maintenance NEW fabrications.)

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.6875 | Federation CRITICAL (predicate pushdown EXPLAIN signature) | STRONG PASS — Spark-term guardrail LANDED |
| Q2 | 2.4375 | Query perf regression (EXPLAIN TYPE IO / VALIDATE) | FAIL — REPEAT TYPE VALIDATE miss + NEW EXPLAIN ANALYZE (ANALYZE false) fabrication |
| Q3 | 4.875 | Oracle migration (LISTAGG ON OVERFLOW) | STRONG PASS — RESOLVED |
| Q4 | 3.4375 | Iceberg branches / WAP | FAIL — NEW Spark branch DDL fabrications (INSERT INTO (BRANCH 'x') + MERGE BRANCH INTO main) |

**Average 3.859 PASS — +0.093 step-UP from iter441 3.766. Federation margin recovers marginally; Q3 RESOLVED; BUT TWO new confident-inaccuracies on Q2 + Q4 + a REPEAT confident-inaccuracy on Q2.**

**Headline outcomes:**
- THREE confident-inaccuracies this iter (Q2 REPEAT TYPE VALIDATE denial + Q2 NEW EXPLAIN ANALYZE (ANALYZE false) fabrication + Q4 NEW Spark branch DDL fabrications) — zero-confident-inaccuracy streak STILL BROKEN (now 2 consecutive iters with confident-inaccuracies).
- Federation 4.5020 → 4.5026 / 304 (+0.0006; margin +0.0020 → +0.0026 — +0.0006 expansion; restoration partial).
- Query perf regression diagnosis 4.3695 → 4.2085 / 12 (Q2 2.4375 well below topic avg AND below iter441 2.75; topic drops further but stays above 3.5 standard threshold).
- Oracle PL/SQL migration 4.6103 → 4.6242 / 19 (Q3 4.875 well above topic avg; RESOLVED).
- Iceberg table maintenance 4.4680 → 4.4582 / 105 (Q4 3.4375 below topic avg; nudges down but well above 3.5 standard).
- ALL REQUIRED TOPICS REMAIN PASSED on aggregate.

**Failure-mode count: 16+1=17 of prior 41 extended-phase iterations with FAIL or confident-inaccuracy; iter441 broke the 40-iter zero-fail streak; iter442 PASSES overall but introduces NEW fabrications on a different topic (Q4) while REPEATING the iter441 Q2 inaccuracy and adding a NEW Q2 fabrication.**

---

## Teacher actions next (iter 443) — HIGH PRIORITY

1. **CRITICAL — FIX Q2 EXPLAIN-TYPE-IO/VALIDATE findability problem.** The teacher tightened r18 §EXPLAIN-TYPE-IO/VALIDATE in iter441 per state.json, but the canonical content has now FAILED TO LAND for TWO consecutive iterations. Hypothesis: the responder is reading EXPLAIN-related content from a DIFFERENT resource (most likely r22 if the question phrasing trips federation/pushdown content) and never reaching r18. Action items:
   - **(a) DUPLICATE the canonical TYPE VALIDATE + TYPE IO content into every resource that mentions EXPLAIN** (especially r22 federation + any SQL-best-practices resource + any query-perf-diagnosis resource). Use a §EXPLAIN-FLAVORS-MASTER-TABLE shared block.
   - **(b) ADD an explicit anti-claim block: "Do NOT say Trino has no validate-syntax-without-execute command. TYPE VALIDATE IS that command. Do NOT invent EXPLAIN ANALYZE options like `(ANALYZE false)` — the ONLY documented option is VERBOSE; EXPLAIN ANALYZE always executes."**
   - **(c) ADD a "fabricated-syntax-detector" anti-pattern: list `EXPLAIN ANALYZE (ANALYZE false)`, `EXPLAIN (EXECUTE false)`, and similar invented forms as DO-NOT-WRITE patterns.**

2. **HIGH — FIX Q4 Iceberg branch SQL syntax (Iceberg table maintenance resource).** Add explicit Spark DDL section:
   - SQL CREATE/DROP: `ALTER TABLE prod.db.t CREATE BRANCH name [AS OF VERSION snapshot_id] [RETAIN num {DAYS|HOURS|MINUTES}] [WITH SNAPSHOT RETENTION min_snapshots SNAPSHOTS]`; `ALTER TABLE prod.db.t REPLACE BRANCH name AS OF VERSION snapshot_id`; `ALTER TABLE prod.db.t DROP BRANCH name`.
   - SQL writes to branch (TWO documented forms): **(i)** suffix on table identifier: `INSERT INTO prod.db.t.branch_staging VALUES (...)`, `UPDATE prod.db.t.branch_staging SET ...`, `DELETE FROM prod.db.t.branch_staging WHERE ...`; **(ii)** WAP session config: `SET spark.wap.branch = staging; INSERT INTO prod.db.t VALUES (...)`.
   - DataFrame writes (TWO documented forms): **(i)** `df.writeTo("prod.db.t.branch_audit").overwritePartitions()` (suffix on writeTo identifier); **(ii)** `df.write.format("iceberg").option("branch", "ML_exp").mode("append").save("glue.test.employees")`.
   - Fast-forward (NOT MERGE BRANCH DDL): `CALL catalog.system.fast_forward('table', 'main', 'audit-branch')` procedure call.
   - Explicit anti-claim: "Do NOT write `INSERT INTO t (BRANCH 'x')` or `MERGE BRANCH x INTO main` — neither is real Iceberg-Spark syntax."

3. **MEDIUM — RETAIN Q3 LISTAGG RESOLVED.** Re-probe LISTAGG ON OVERFLOW from a different angle (e.g., 32K-byte truncation policy on a customer-name list) 3-5 iters out to confirm durability.

4. **STRATEGIC — Loop posture: iter442 PASSES (3.859) but contains THREE confident-inaccuracies and a REPEAT of iter441 Q2 inaccuracy.** The pattern indicates the teacher's r18 guardrail is failing the findability test. Confident-inaccuracy clusters are now spanning consecutive iterations (iter441 + iter442 each have 3+ confident-inaccuracies). Federation buffer recovers only +0.0006 of the iter441 -0.0035 contraction. Teacher must prioritize CROSS-RESOURCE DUPLICATION of canonical EXPLAIN content + fabricated-syntax anti-pattern block.

---

## Judge probe targets next (iter 443) — MANDATORY DIRECT RE-PROBES

1. **CRITICAL — Q2 EXPLAIN TYPE VALIDATE + TYPE IO direct re-probe (THIRD consecutive iter).** Ask "How can I cheaply validate a Trino SQL statement without executing it?" AND separately "How can I see what tables and columns Trino will scan for a query, with the constraint ranges?" — confirm TYPE VALIDATE (single boolean `Valid` column) and TYPE IO + FORMAT JSON (`inputTableColumnInfos` / `columnConstraints` / `domain` structure) both surface canonically. **MUST land cleanly to repair the topic.** Also probe specifically against the `EXPLAIN ANALYZE (ANALYZE false)` fabrication by asking "does EXPLAIN ANALYZE have any option to skip execution?" — expected answer: NO; only VERBOSE; EXPLAIN ANALYZE always executes; use TYPE VALIDATE for syntax-only.

2. **HIGH — Q4 Iceberg branch DDL direct re-probe.** Ask "show me the exact Iceberg-Spark SQL to insert rows into a 'staging' branch of prod.db.accounts" AND "how do I promote the staging branch to main?" — confirm responder uses suffix-notation `INSERT INTO prod.db.accounts.branch_staging` OR WAP `SET spark.wap.branch=staging` form; confirm responder uses `CALL catalog.system.fast_forward('table','main','staging')` for promotion, NOT `MERGE BRANCH x INTO main` DDL.

3. **MEDIUM — Q1 federation EXPLAIN signature durability** (3-5 iters out) — confirm guardrail durable against different question phrasings (e.g., "WHERE customer_id IN (...) AND created_at > ...").

4. **MEDIUM — Q3 LISTAGG ON OVERFLOW durability** (3-5 iters out) — confirm guardrail durable from a different angle (different overflow filler / byte limit context).

5. **LOW — Carry forward backlog**: iter440 Q1/Q2 guardrail durability (federation pushdown corner cases CAST-wrapped col, LIKE prefix, OR-of-equality); isolation-level write props; Iceberg identity-column durability; iter441 Q4 partition-spec-evolution different-angle (e.g., add tier column).

---

## Critical message to teacher for iter 443

**Iter442 is a 3.859 PASS — +0.093 recovery from iter441 3.766 FAIL — BUT contains THREE confident-inaccuracies including a REPEAT of the iter441 Q2 TYPE VALIDATE denial and a NEW fabricated `EXPLAIN ANALYZE (ANALYZE false)` syntax that does not exist.**

**The r18 §EXPLAIN-TYPE-IO/VALIDATE guardrail you tightened in iter441 did NOT land in iter442.** The responder once again said "Trino does NOT have a validate-syntax-without-execute command" — the EXACT confident-inaccuracy iter441 flagged. Worse, the responder ALSO invented a syntax `EXPLAIN ANALYZE (ANALYZE false) <query>` claiming "plan only, don't execute" — this is NOT real Trino; `EXPLAIN ANALYZE` has only `VERBOSE` option per trino.io/docs/current/sql/explain-analyze.html and ALWAYS executes.

**Findability hypothesis (act on this in iter443):** the canonical TYPE VALIDATE / TYPE IO content lives in r18, but the responder is likely reaching for EXPLAIN content via r22 (federation EXPLAIN) or another SQL-best-practices resource for this question phrasing. The fix is to DUPLICATE the canonical content into every resource that mentions EXPLAIN + add a "fabricated-syntax-detector" anti-pattern block listing `EXPLAIN ANALYZE (ANALYZE false)`, `EXPLAIN (EXECUTE false)` as DO-NOT-WRITE forms.

**Q1 federation BUFFER:** Iter441 PushedFilters/PostScanFilters Spark-term guardrail LANDED. Responder correctly used `TableScan[constraint = {...}]` (pushed) vs `Filter` / `ScanFilterProject` operator (not pushed). Federation 4.5020 → 4.5026 / 304; margin +0.0020 → +0.0026 (+0.0006 expansion — partial restoration of iter441 -0.0035 contraction).

**Q3 LISTAGG ON OVERFLOW: RESOLVED.** Responder produced direct 1:1 Trino mapping with all three overflow variants. Iter441 Q3 confident-inaccuracy FIXED.

**Q4 Iceberg branches:** Direction correct (Trino reads via FOR VERSION AS OF; Spark for writes; expire_snapshots cleans dropped-branch snapshots) but SPECIFIC SPARK DDL FORMS FABRICATED — `INSERT INTO t (BRANCH 'x')` and `MERGE BRANCH x INTO main` are NOT real Iceberg-Spark syntax. Real forms (per iceberg.apache.org/docs/latest/spark-writes/): suffix-on-identifier `INSERT INTO prod.db.t.branch_staging VALUES (...)` OR WAP config `SET spark.wap.branch=staging; INSERT INTO prod.db.t VALUES (...)`; fast-forward via `CALL catalog.system.fast_forward('table', 'main', 'audit-branch')` procedure NOT a `MERGE BRANCH` DDL.

**Loop status:** PASSED stays on aggregate (all required topics still above their thresholds), federation margin marginally restored, BUT cluster of confident-inaccuracies persists across two consecutive iters. The r18 guardrail findability problem is the SINGLE HIGHEST-PRIORITY teacher action for iter443. state.json `passed: true` stays.

**Other key verifications this iter:**
- Trino EXPLAIN pushdown signature: `constraint = {...}` inside `TableScan` (pushed) vs `Filter` / `ScanFilterProject` operator above (not pushed) — verified per trino.io/docs/current/optimizer/pushdown.html
- `EXPLAIN ANALYZE` has ONLY `VERBOSE` option; ALWAYS executes — verified per trino.io/docs/current/sql/explain-analyze.html (FABRICATION of `(ANALYZE false)` confirmed)
- `EXPLAIN (TYPE VALIDATE)` returns single boolean column `Valid`, validates without executing — verified per trino.io/docs/current/sql/explain.html
- `EXPLAIN (TYPE IO, FORMAT JSON)` returns `inputTableColumnInfos` with `domain` constraints — verified per trino.io/docs/current/sql/explain.html
- Trino `listagg` supports `ON OVERFLOW ERROR` (default; 1,048,576-byte limit) and `ON OVERFLOW TRUNCATE '<filler>' WITH | WITHOUT COUNT` — verified per trino.io/docs/current/functions/aggregate.html
- Iceberg-Spark branch DDL: `ALTER TABLE ... CREATE BRANCH name [AS OF VERSION snapshot_id]` / `DROP BRANCH name` — verified per iceberg.apache.org/docs/latest/spark-ddl/
- Iceberg-Spark branch writes: suffix on table identifier `INSERT INTO t.branch_x` OR WAP session config `SET spark.wap.branch=x` — verified per iceberg.apache.org/docs/latest/spark-writes/
- Iceberg-Spark branch fast-forward: `CALL catalog.system.fast_forward('table', 'main', 'audit-branch')` procedure — verified per iceberg.apache.org/docs/latest/branching/
- Trino `FOR VERSION AS OF 'branch_name'` for branch-time-travel reads — verified per trino.io/docs/current/connector/iceberg.html
