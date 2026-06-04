# Judge Feedback — Iter 431 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.625 PASS** (Q1 4.9375 + Q2 4.75 + Q3 4.0 + Q4 4.8125) — **+0.156 step-UP from iter430 4.469**. Thirtieth consecutive overall PASS in extended phase. **TWO of the three deliberate re-probes RESOLVED CLEANLY** (Q1 CTAS NOT NULL + Q2 LIMIT-pushdown terminology); **ONE NEW confident-inaccuracy emerges in Q3** — the Trino session-property name `time_zone` does NOT exist (only the `SET TIME ZONE 'zone'` command form is valid). Zero-confident-inaccuracy streak does NOT recover (broken at 0 for the 3rd consecutive iter).

---

## Headline

1. **Q1 CTAS-NOT-NULL re-probe — FULLY RESOLVED (4.9375 STRONG PASS).** Responder now correctly states "CTAS does NOT carry/preserve NOT NULL — types only" and gives the EXPLICIT 2-step pattern: `CREATE TABLE accounts_new (account_id BIGINT NOT NULL, company_id VARCHAR NOT NULL, ...) WITH (...)` then `INSERT INTO accounts_new SELECT ... FROM accounts` (fails fast on a NULL row), then DROP+RENAME swap. Includes "backfill first via UPDATE + verify zero nulls" prerequisite. Offers the dbt not_null test as the RECOMMENDED no-rewrite alternative (keeps time-travel intact). Cites r09 CTAS-NOT-NULL-INFERENCE GUARDRAIL. The iter430 confident-inaccuracy ("CREATE TABLE AS SELECT will have tier as NOT NULL") is fully absent. **iter431 r09 + r13 + §13.5A.5 14th GUARDRAIL landed precisely on the first re-probe.**

2. **Q2 plain-LIMIT terminology re-probe — TERMINOLOGY NOW CLEAN (4.75 STRONG PASS).** PRIMARY framing is now "Limit pushdown (distinct from TopN pushdown)" — leads with the correct term per trino.io/docs/current/optimizer/pushdown.html. Distinguishes Limit pushdown (plain LIMIT, no ORDER BY, "unsorted record" capability) vs Top-N pushdown (ORDER BY + LIMIT). EXPLAIN success signal: `limit=200` folded inside TableScan with no separate Limit operator above (CORRECT). EXPLAIN failure signal: separate `Limit[200]` operator above TableScan (CORRECT — not `TopN[...]` as iter430 had). No release-number assertion (responder follows the teacher's iter431 directive to stop at "supported by default in Trino 467" since neither release 354 nor 466 are verified for PG-connector LIMIT pushdown). **The 2-iter terminology streak is BROKEN; primacy fix landed.**

3. **Q3 SYSDATE/SYSTIMESTAMP timezone — STRONG content + ONE NEW confident-inaccuracy (4.0 PASS).** The function-mapping core is CORRECT: SYSDATE → current_timestamp or localtimestamp (NOT current_date which drops the time component); SYSTIMESTAMP → current_timestamp; Oracle SYSDATE returns server-local time (no TZ) per docs.oracle.com (VERIFIED); Trino current_timestamp is session-TZ-aware (VERIFIED per trino.io/docs/current/functions/datetime.html). Excellent TRUNC(SYSDATE) ET vs CAST(current_timestamp AS DATE) UTC date-boundary gotcha. **HOWEVER**: cites `SET SESSION time_zone='America/New_York'` as a fix. **This session-property name does NOT exist in Trino.** Per trino.io/docs/current/sql/set-time-zone.html, the syntax is the dedicated `SET TIME ZONE 'America/New_York'` COMMAND (a separate statement form), not a session-property assignment. An engineer running `SET SESSION time_zone='...'` will get "Session property time_zone does not exist" / "Unknown session property". The correct fix line should be either `SET TIME ZONE 'America/New_York'` (command) or `sql.forced-session-time-zone` (server config property). Also: `localtimestamp` and `AT TIME ZONE 'UTC'` citations are CORRECT.

4. **Q4 $files small-file diagnosis — STRONG PASS (4.8125).** All claims verified: `content=0` filters to DATA files (CORRECT per trino.io/docs/current/connector/iceberg.html: `DATA(0)/POSITION_DELETES(1)/EQUALITY_DELETES(2)`); columns `file_size_in_bytes` and `record_count` (CORRECT); tiny-file query with size brackets; threshold heuristics (10k+ files median <5MB = urgent / <1000 files median >256MB = healthy); per-file open overhead ~1-5ms framing; fix `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` (VERIFIED syntax); `expire_snapshots(retention_threshold)` with Trino 7d floor (VERIFIED `iceberg.expire-snapshots.min-retention` default 7d) or Spark for sub-7d; weekly schedule.

---

## Critical confirmations (explicit)

### (a) Q1 CTAS NOT NULL RE-PROBE — RESOLVED?

**YES — FULLY RESOLVED.** The iter430 confident-inaccuracy "CREATE TABLE AS SELECT will have tier as NOT NULL" is absent. The answer correctly leads with "CTAS carries column types ONLY, not NOT NULL — newly-created columns are NULLABLE by default; an INSERT of NULL into the CTAS-result table will SUCCEED." Provides the explicit 2-step form `CREATE TABLE <new> (col TYPE NOT NULL, ...) WITH (...)` + `INSERT INTO <new> SELECT ... FROM <old>` (which fails fast if any row has NULL). Includes backfill-first UPDATE + verify-zero-nulls prerequisite. Mentions dbt not_null test as the RECOMMENDED no-rewrite alternative (preserves snapshot lineage / time-travel). Cites r09 CTAS-NOT-NULL-INFERENCE GUARDRAIL inline. **Per trino.io/docs/current/sql/create-table-as.html, CTAS has no column-list position for constraints — confirmed.** Verdict: iter430 inaccuracy fully resolved on first re-probe.

### (b) Q2 LIMIT pushdown TERMINOLOGY — CLEAN NOW? + federation average + direction + crosses 4.5?

**YES — TERMINOLOGY NOW CLEAN.** PRIMARY label is "Limit pushdown (distinct from TopN pushdown)" — the FIRST term out of the responder's mouth is "Limit pushdown", per the iter431 §13.5A.5 FIRST-WORD DIRECTIVE. The Limit-vs-TopN distinction is explicit: Limit pushdown = plain LIMIT N (no ORDER BY), "unsorted record" per optimizer/pushdown.html; Top-N pushdown = ORDER BY + LIMIT separate capability. EXPLAIN signals correct: success = `limit=200` inside TableScan, no separate Limit operator above (folded); failure = separate `Limit[200]` operator above TableScan (NOT `TopN[...]` — that would be the Top-N pushdown failure signal). No wrong release number cited — answer correctly stops at "supported by default on the PostgreSQL connector in Trino 467". The teacher's iter431 PRIMACY fix (hard rename inversion + FIRST-WORD directive + EXPLAIN signal correction + DO-NOT-WRITE banning "release 354 for LIMIT") landed.

**Federation average update:**
- Prior: 4.4929 × 292 = 1311.9268 sum
- + Q2 4.75 = +4.75
- New sum: 1316.6768
- New count: 293
- **New average: 1316.6768 / 293 = 4.4937**

Distance to threshold: 4.5000 − 4.4937 = **0.0063 below 4.5**.

Compared to iter430:
- Iter430: 4.4929, 0.0071 below threshold (DIRECTION DOWN −0.0010)
- Iter431: 4.4937, 0.0063 below threshold (DIRECTION UP +0.0008)
- **Net change: +0.0008 / 0.0008 CLOSER to threshold / 31st consecutive iter below threshold / DIRECTION REVERSED back to UP after iter430's reversal**

**Crosses 4.5?** NO — still 0.0063 below threshold. But the Q2 4.75 datapoint pushes the average UP after iter430's −0.0010 down move; the 2-iter terminology-mislabel streak (iter429+iter430) is broken; direction back to UP. At this density (293 datapoints) each Q2 datapoint moves the average ~+0.0009 per 0.25-point delta-above-topic-avg, so sustained 4.75+ federation answers would cross 4.5 in roughly 7-8 iters.

### (c) Any NEW confident-inaccuracy across all four

**YES — ONE new confident inaccuracy in Q3.** The `SET SESSION time_zone='America/New_York'` syntax is INVALID. Per trino.io/docs/current/sql/set-time-zone.html (verified via WebFetch), the only valid Trino syntax is:
- Command form: `SET TIME ZONE 'America/New_York'` (or `SET TIME ZONE LOCAL` / `SET TIME ZONE INTERVAL '10' HOUR`)
- Server config: `sql.forced-session-time-zone` (config property, not session property)

There is NO `time_zone` session property — an engineer running `SET SESSION time_zone='America/New_York'` will get "Session property time_zone does not exist" or similar error. This is a load-bearing PA penalty because the engineer will paste this line into a dbt pre_hook or a session-init script and the query will fail at runtime.

**The other Q3 claims are CORRECT and verified:**
- SYSDATE → current_timestamp / localtimestamp (NOT current_date) — CORRECT (current_date returns DATE only, no time component)
- current_timestamp is session-TZ-aware — CORRECT per trino.io/docs/current/functions/datetime.html
- Oracle SYSDATE = OS server local time (no TZ, cannot be changed per session) — CORRECT per docs.oracle.com / juliandontcheff.wordpress.com Autonomous Database article
- Oracle SYSTIMESTAMP = TZ-aware version of SYSDATE (TIMESTAMP WITH TIME ZONE) — CORRECT
- TRUNC(SYSDATE) ET vs CAST(current_timestamp AS DATE) in UTC/PT can return different "today" — CORRECT date-boundary gotcha
- localtimestamp / AT TIME ZONE 'UTC' usage — CORRECT
- On-prem vs Trino timezone disagreement audit — CORRECT migration discipline

**Net inaccuracy count this iter: 1 confident issue** (Q3 `SET SESSION time_zone` invalid syntax). Q1, Q2, Q4 all CLEAN.

### (d) Q4 $files columns + optimize syntax verification

VERIFIED per trino.io/docs/current/connector/iceberg.html (via WebFetch):
- `$files` content column = "Type of content stored in the file" with `DATA(0) / POSITION_DELETES(1) / EQUALITY_DELETES(2)` — responder's `content=0` filter for data files is CORRECT.
- `file_size_in_bytes` and `record_count` columns present — CORRECT.
- `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` syntax — VERIFIED (named-arg rocket assignment, default 100MB).
- `expire_snapshots(retention_threshold => '7d')` with `iceberg.expire-snapshots.min-retention` floor default 7d — VERIFIED.
- Spark bypass for sub-7d retention — CORRECT (Spark Iceberg has no min-retention floor).

All Q4 claims CONFIRMED. No inaccuracy.

---

## Per-question scoring

### Q1 — CTAS NOT NULL re-probe (Lakehouse schema design)

**Scores: 5.0 / 4.75 / 5.0 / 5.0 — avg 4.9375 STRONG PASS**

What landed:
- "CTAS does NOT carry/preserve NOT NULL — types only" — CORRECT, RESOLVED iter430
- "New columns are NULLABLE; INSERT NULL into the CTAS result will SUCCEED" — CORRECT
- Explicit 2-step pattern: `CREATE TABLE accounts_new (account_id BIGINT NOT NULL, company_id VARCHAR NOT NULL, ...) WITH (...)` + `INSERT INTO accounts_new SELECT ... FROM accounts` — CORRECT canonical
- INSERT fails fast on a NULL row — CORRECT
- DROP + RENAME swap — CORRECT
- Backfill first via UPDATE + verify zero nulls before INSERT — CORRECT prerequisite
- dbt not_null test as RECOMMENDED no-rewrite alternative (keeps time-travel) — CORRECT canonical workaround
- Cites r09 CTAS-NOT-NULL-INFERENCE GUARDRAIL — teacher's 14th GUARDRAIL landed

**Verdict:** STRONG PASS — full clean recovery on first re-probe. iter430 confident-inaccuracy fully absent.

### Q2 — Plain LIMIT pushdown (Trino federation re-probe)

**Scores: 4.75 / 4.75 / 4.75 / 4.75 — avg 4.75 STRONG PASS**

What landed:
- PRIMARY framing "Limit pushdown (distinct from TopN pushdown)" — CORRECT, FIRST-WORD DIRECTIVE landed
- Limit pushdown = plain LIMIT N (no ORDER BY) per optimizer/pushdown.html — CORRECT
- Top-N pushdown = ORDER BY + LIMIT, separate capability — CORRECT distinction
- Postgres returns only 200 rows (not all 5M) — CORRECT behavior
- EXPLAIN success: `limit=200` folded inside TableScan, no separate Limit operator above — CORRECT
- EXPLAIN failure: separate `Limit[200]` operator above TableScan (NOT `TopN[...]`) — CORRECT
- No release-number assertion (correctly omitted per iter431 directive — neither 354 nor 466 verified for PG-connector LIMIT pushdown) — CORRECT discipline
- ORDER BY LIMIT also pushes (Top-N) but with sortOrder= annotation, different capability — CORRECT distinction

**Verdict:** STRONG PASS — terminology now CLEAN, 2-iter mislabel streak broken.

### Q3 — SYSDATE/SYSTIMESTAMP timezone (Oracle PL/SQL migration)

**Scores: 3.25 / 4.75 / 3.5 / 4.5 — avg 4.0 PASS**

What landed:
- SYSDATE → current_timestamp or localtimestamp (NOT current_date which drops time) — CORRECT
- SYSTIMESTAMP → current_timestamp — CORRECT (both TZ-aware in Trino)
- Oracle SYSDATE returns OS server local time (no TZ, cannot change per session) — CORRECT per docs.oracle.com
- Oracle SYSTIMESTAMP is TIMESTAMP WITH TIME ZONE (TZ-aware) — CORRECT
- Trino current_timestamp is session-TZ-aware — CORRECT per trino.io/docs/current/functions/datetime.html
- TRUNC(SYSDATE) ET vs CAST(current_timestamp AS DATE) UTC date-boundary gotcha — CORRECT mental model
- localtimestamp + AT TIME ZONE 'UTC' usage — CORRECT
- Audit every SYSDATE/TRUNC(SYSDATE) before migration — CORRECT discipline
- On-prem servers have no canonical TZ; Spark vs Trino may disagree — CORRECT prod-env nuance

What is INACCURATE:
- **`SET SESSION time_zone='America/New_York'`** — WRONG. There is NO `time_zone` session property in Trino. Per trino.io/docs/current/sql/set-time-zone.html (verified via WebFetch), the only valid forms are: (1) `SET TIME ZONE 'America/New_York'` command form (a dedicated statement), or (2) `sql.forced-session-time-zone` server config property. An engineer running `SET SESSION time_zone='...'` will get an error.

**Verdict:** PASS but with new confident-inaccuracy. TA dock to 3.25; PA dock to 3.5 because the engineer following this line breaks at runtime. The function-mapping core (SYSDATE/SYSTIMESTAMP → current_timestamp/localtimestamp + TZ-awareness gotcha) is CORRECT — only the session-property invocation is wrong.

### Q4 — $files small-file diagnosis (Iceberg table maintenance)

**Scores: 5.0 / 4.75 / 4.75 / 4.75 — avg 4.8125 STRONG PASS**

What landed:
- `$files content=0` filter for DATA files — CORRECT per trino.io/docs/current/connector/iceberg.html (DATA(0)/POSITION_DELETES(1)/EQUALITY_DELETES(2))
- `file_size_in_bytes`, `record_count` columns — CORRECT
- Tiny-file query (e.g., file_size_in_bytes < 10MB) — CORRECT diagnostic
- Size-bracket distribution query — CORRECT remediation prep
- Threshold heuristics 10k+ files median <5MB urgent / <1000 files median >256MB healthy — REASONABLE rule of thumb
- Per-file open overhead ~1-5ms framing — CORRECT magnitude
- Fix: `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` — VERIFIED named-arg syntax (default 100MB)
- Then `expire_snapshots(retention_threshold)` with Trino 7d floor via `iceberg.expire-snapshots.min-retention` — CORRECT
- Spark bypass for sub-7d retention — CORRECT
- Weekly cadence — CORRECT operational cadence

**Verdict:** STRONG PASS — all syntax verified, $files columns canonical.

---

## Topic-score updates

| Topic | Before | After | Delta | Status |
|---|---|---|---|---|
| Lakehouse schema design | 4.5234 / 8 | 4.5694 / 9 | +0.0460 | PASSED (Q1 4.9375 above topic avg) |
| Trino federation / cross-source connectors | 4.4929 / 292 | 4.4937 / 293 | +0.0008 | NEEDS WORK (0.0063 below 4.5 raised threshold; 31st consecutive iter below; DIRECTION REVERSED back to UP after iter430 down) |
| Oracle PL/SQL → dbt + Trino SQL migration | 4.8125 / 8 | 4.7222 / 9 | −0.0903 | PASSED (Q3 4.0 below topic avg drags down; still well above 3.5) |
| Iceberg table maintenance | 4.4479 / 96 | 4.4517 / 97 | +0.0038 | PASSED |

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.9375 | Lakehouse schema design (CTAS NOT NULL re-probe) | STRONG PASS — iter430 confident-inaccuracy FULLY RESOLVED; explicit 2-step + dbt not_null alternative + r09 guardrail cited |
| Q2 | 4.75 | Trino federation (plain LIMIT pushdown re-probe) | STRONG PASS — TERMINOLOGY CLEAN; "Limit pushdown" PRIMARY; correct EXPLAIN signals; no wrong release |
| Q3 | 4.0 | Oracle PL/SQL migration (SYSDATE/SYSTIMESTAMP TZ) | PASS — function mapping CORRECT; NEW confident-inaccuracy: `SET SESSION time_zone=...` is invalid syntax |
| Q4 | 4.8125 | Iceberg table maintenance ($files small-file) | STRONG PASS — all syntax verified, $files columns canonical |

**Average 4.625 PASS — thirtieth consecutive overall PASS in extended phase; +0.156 step-UP from iter430 4.469.**

**Headline outcomes:**
- Q1 CTAS NOT NULL re-probe — RESOLVED on first re-probe (4.9375 STRONG); iter430 confident-inaccuracy absent; 14th GUARDRAIL landed
- Q2 LIMIT pushdown re-probe — TERMINOLOGY CLEAN (4.75 STRONG); FIRST-WORD DIRECTIVE landed; 2-iter mislabel streak broken
- Q3 SYSDATE/SYSTIMESTAMP — STRONG content but NEW confident-inaccuracy (`SET SESSION time_zone=...` invalid Trino syntax); zero-confident-inaccuracy streak does NOT recover
- Q4 $files small-file diagnosis — STRONG (canonical); all syntax verified
- Federation 4.4929 → 4.4937 (+0.0008 UP, direction REVERSED back to UP after iter430 reversal; 31st consecutive iter below threshold; 0.0063 below)
- Lakehouse schema design 4.5234 → 4.5694 (+0.0460 UP, Q1 4.9375 well above topic avg)
- Oracle migration 4.8125 → 4.7222 (−0.0903 DOWN due to Q3 4.0 dragging)
- Iceberg table maintenance 4.4479 → 4.4517 (+0.0038 UP marginal)

**Failure-mode count: 11 of prior 27 iterations** (iter431 introduces 1 new failure-mode class: TRINO-SESSION-PROPERTY-NAME-INVENTION — the `time_zone` session-property assignment form is fabricated; only `SET TIME ZONE 'zone'` command + `sql.forced-session-time-zone` config exist).

---

## Teacher actions next (iter 432)

1. **HIGH — Fix Q3 `SET SESSION time_zone` invalid syntax inaccuracy.** Install in r25 (Oracle migration) or r07 (Trino dialect) following the proven structural-fix pattern:
   - Add a TRINO-SESSION-TIMEZONE GUARDRAIL: correct syntax is `SET TIME ZONE 'America/New_York'` (a dedicated COMMAND, not a session-property assignment) — cite trino.io/docs/current/sql/set-time-zone.html.
   - DO-NOT-WRITE entry banning the phrasing `SET SESSION time_zone='...'` / `SET SESSION timezone='...'` — these session-property names DO NOT EXIST. The runtime error would be "Session property time_zone does not exist".
   - Note the server-config alternative: `sql.forced-session-time-zone` (a server config property, not a per-session toggle).
   - Add a Q-pattern matcher line: "if the question is 'how do I change Trino's session timezone', the answer is the command `SET TIME ZONE 'zone'` — NOT a SET SESSION property assignment."
   - Cross-reference from r25 Oracle SYSDATE/SYSTIMESTAMP migration section so the next SYSDATE re-probe doesn't re-introduce the wrong syntax.

2. **LOW — Q1 CTAS-NOT-NULL-INFERENCE GUARDRAIL landed precisely.** No structural changes needed. Re-probe at +3-5 iter horizon to confirm durability.

3. **LOW — Q2 §13.5A.5 LIMIT-vs-TopN PRIMACY landed precisely.** No structural changes needed. The FIRST-WORD DIRECTIVE + hard rename inversion + DO-NOT-WRITE for release 354 all held on the first re-probe.

4. **MEDIUM — Federation topic** at 4.4937 / 0.0063 below threshold; 31st consecutive iter below. Direction REVERSED back to UP after iter430 dip. Sustained 4.75+ federation answers would cross 4.5 in roughly 7-8 iters at this density. Carry-forward angles still un-asked: HAVING pushdown 2nd-angle, function-wrapped predicate, 4-way cross-catalog join.

5. **LOW — Carry-forward backlog (mostly unchanged from iter430-431)**:
   - HMS→Nessie write-freeze
   - Snapshot vs serializable phantom-row 3rd-angle
   - Window NULL 2nd-angle
   - Iceberg concurrency 5th-angle (commit.retry exhaustion behavior)
   - OPA-override timeout
   - Schema registry compat
   - JWT+OPA concurrency
   - Federation HAVING pushdown 2nd-angle
   - Federation function-wrapped predicate contrast (LOWER/COALESCE-wrapped column)

---

## Judge probe targets next (iter 432)

1. **HIGH — Re-probe Trino session timezone change syntax** — to verify the new GUARDRAIL lands. A direct question: "How do I change my Trino session's timezone to America/Los_Angeles so SYSDATE-equivalent queries use the right wall clock?" — looking for: (a) `SET TIME ZONE 'America/Los_Angeles'` command form as PRIMARY, (b) explicit "this is a dedicated statement, NOT a `SET SESSION property=value` form" callout, (c) NO mention of a `time_zone` or `timezone` session property, (d) optional mention of `sql.forced-session-time-zone` server config alternative.

2. **HIGH — Federation HAVING pushdown 2nd-angle** (carry-forward, still un-asked): "Does `HAVING SUM(amount) > 1000` after a GROUP BY push to Postgres?"

3. **HIGH — Federation function-wrapped predicate contrast** (carry-forward): "Does `WHERE LOWER(email) = 'a@b.com'` push?"

4. **MEDIUM — Federation 4-way cross-catalog join execution location** (extends the iter426 3-way angle): "Postgres dim + Iceberg fact + Iceberg dim + Postgres lookup — where does the join run, and what does EXPLAIN show for each TableScan?"

5. **MEDIUM — CTAS NOT NULL durability re-probe** (+3 iter horizon): "I want to add a strict UNIQUE-ish constraint via CTAS-swap — walk me through the exact SQL."

6. **MEDIUM — Iceberg schema evolution column-type widening** (un-probed): INTEGER → BIGINT, REAL → DOUBLE, DECIMAL precision-widen — distinct from NOT NULL tightening.

7. **LOW — Iceberg concurrency 5th-angle** (carry-forward): commit.retry.num-retries exhaustion behavior.

---

## Critical message to teacher for iter 432

Iter431 is a strong step-UP PASS (4.625 vs iter430's 4.469) with two of three deliberate re-probes fully resolved (Q1 CTAS NOT NULL + Q2 LIMIT-pushdown terminology). The teacher's iter431 plan — adding the 14th GUARDRAIL (CTAS-NOT-NULL-INFERENCE) and strengthening §13.5A.5 PRIMACY with the FIRST-WORD DIRECTIVE + hard rename inversion + EXPLAIN signal correction + DO-NOT-WRITE for "release 354 for LIMIT" — landed precisely on the first re-probe. The proven structural-fix-within-one-iteration recipe extends to 14 instances.

**However, the zero-confident-inaccuracy streak does NOT recover.** A new failure-mode class emerges in Q3: the responder invents a `time_zone` Trino session property and recommends `SET SESSION time_zone='America/New_York'` — a syntactically valid-looking line that does NOT exist in Trino. Per trino.io/docs/current/sql/set-time-zone.html, the only valid forms are the `SET TIME ZONE 'zone'` COMMAND (a dedicated statement, NOT a session-property assignment) and the `sql.forced-session-time-zone` SERVER CONFIG property. The function-mapping core (SYSDATE → current_timestamp / localtimestamp / TZ-aware gotchas) is CORRECT — only the session-invocation line is wrong. **The teacher needs to install a TRINO-SESSION-TIMEZONE GUARDRAIL in r25 (or r07) banning `SET SESSION time_zone=...` and recommending the correct `SET TIME ZONE 'zone'` command form.**

**Federation topic moved +0.0008 UP to 4.4937**, now 0.0063 below threshold (31st consecutive iter below). Direction REVERSED back to UP after iter430's dip. The Q2 4.75 datapoint is well above topic avg and resumes the closing pace. With sustained 4.75+ federation answers, the topic could cross 4.5 in ~7-8 iters at this density.

**Iter432 should focus on:**
(1) Add TRINO-SESSION-TIMEZONE GUARDRAIL with explicit command-form recommendation + DO-NOT-WRITE for `SET SESSION time_zone=...` (Q3 fix)
(2) Re-probe Trino session timezone change syntax to verify the fix lands
(3) Continue carry-forward federation HAVING pushdown / function-wrapped predicate angles to grind federation topic toward 4.5
(4) CTAS NOT NULL and LIMIT pushdown both held; +3-iter horizon durability re-probes
