# Judge Feedback — Iter 445 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.823 STRONG PASS** (Q1 4.90625 + Q2 4.8125 + Q3 4.78125 + Q4 4.8125) — **+0.745 step-UP from iter444 4.078**. **FEDERATION RESTORE SUCCESS (RAZOR-THIN): topic crosses back above 4.5 threshold from 4.4977/306 to 4.50005/308; margin -0.0023 → +0.00005 (+0.0024 swing).** Iter444 3-confident-inaccuracy cluster on Q2 plain-LIMIT pushdown FULLY RESOLVED via iter445 r22 §13.5 leading-position canonical worked example. Iter431 → iter440 → iter444 → iter445 4-cycle Limit-vs-TopN regression FINALLY BROKEN. Zero new confident-inaccuracies this iter.

---

## HEADLINE

1. **Q1 Plain LIMIT pushdown federation CRITICAL restore — STRONG PASS 4.90625 — iter444 3-confident-inaccuracy cluster FULLY RESOLVED.** The iter445 teacher consolidation in r22 §13.5 leading worked example landed all three iter444 fixes simultaneously:
   - **(1a) Limit-vs-TopN mislabel FIXED.** Answer LEADS with the canonical verbatim phrasing: "This is Limit pushdown (NOT Top-N pushdown), and it DOES push to Postgres." Per **trino.io/docs/current/optimizer/pushdown.html**: "Limit pushdown enables a connector to push processing of such queries of unsorted record" — plain LIMIT calls `applyLimit`; Top-N pushdown is the SEPARATE capability for `ORDER BY + LIMIT` calling `applyTopN`.
   - **(1b) Self-contradiction FIXED.** No "DOES push" + "does NOT push" both in same answer. Single coherent claim: plain LIMIT DOES push.
   - **(1c) Fabricated EXPLAIN operators FIXED.** Zero occurrences of `RemoteOffset`, `LimitPartial`, `OffsetPartial`, `RemoteLimit` in the answer. Real operators only: `Limit[100]` (above TableScan = NOT pushed) and `limit=100` annotation folded INTO TableScan (= pushed).

2. **Q2 Predicate pushdown which-filters-push federation BUFFER — STRONG PASS 4.8125.** Per-case correctness verified against trino.io PostgreSQL docs:
   - Numeric equality `account_id = 12345` PUSHES — CORRECT.
   - IN-list `status IN (...)` PUSHES — CORRECT.
   - Numeric range `revenue > 1000` PUSHES — CORRECT.
   - VARCHAR equality `name = 'foo'` PUSHES — CORRECT (PostgreSQL docs: "equality predicates ... on columns with textual types are pushed down").
   - VARCHAR range `name > 'm'` does NOT push by default — CORRECT (docs: "does not support pushdown of range predicates ... on columns with character string types").
   - IS NULL PUSHES — CORRECT.
   - EXPLAIN signature: `constraint=...` inside TableScan = pushed vs separate `Filter` operator above = Trino-side — CORRECT.
   - Combined predicate `account_id = 12345 AND status IN (...) OR revenue > 1000` written verbatim per question echo — not penalized for precedence per judge directive.

3. **Q3 Oracle DECODE → CASE WHEN — STRONG PASS 4.78125.** Migration semantics canonical:
   - Trino has NO DECODE — must use CASE WHEN.
   - Positional 1:1 mechanical mapping `DECODE(col, k1, v1, k2, v2, default)` → `CASE WHEN col = k1 THEN v1 WHEN col = k2 THEN v2 ELSE default END`.
   - NULL gotcha — Oracle DECODE treats NULL as matchable (`DECODE(NULL, NULL, 1, 2) = 1`); Trino CASE simple form `CASE col WHEN NULL THEN 1 ELSE 2 END` returns 2 because `NULL = NULL` is UNKNOWN — must rewrite as searched CASE `WHEN col IS NULL` — CORRECT per sqlines.com / cleverence.com Oracle DECODE NULL docs.
   - Strict type coercion in Trino — DECODE allowed mixed numeric/string via Oracle implicit coercion; CASE WHEN in Trino requires explicit CAST.
   - Oracle empty-string-is-NULL quirk flagged with `NULLIF(col, '')` guard pattern.

4. **Q4 Iceberg rollback_to_snapshot — STRONG PASS 4.8125.** All semantics canonical for Trino 467:
   - `CALL iceberg.system.rollback_to_snapshot('analytics', 'event_table', snap_id)` positional 3-arg — CORRECT per starburst.io blog + trino.io/docs/current/connector/iceberg.html (note: deprecated in newer Trino in favor of table procedure form, but canonical for 467 production).
   - Find pre-bad snapshot via `SELECT snapshot_id, committed_at FROM "iceberg.analytics.event_table$snapshots" WHERE committed_at < TIMESTAMP '2026-06-04 01:00:00' ORDER BY committed_at DESC LIMIT 1` — CORRECT.
   - Rollback moves snapshot pointer atomically — no data file deletion, bad snapshot remains accessible until expired — CORRECT.
   - `expire_snapshots(retention_threshold => '7d')` Trino 7-day floor for cleanup — CORRECT default.
   - Spark `CALL system.expire_snapshots(table => '...', older_than => TIMESTAMP '...')` for sub-7d immediate cleanup — CORRECT escape hatch.

---

## Critical confirmations (explicit)

### (a) Q1 plain-LIMIT re-probe — Limit-vs-TopN re-regression FIXED?

**YES — Q1 STRONG PASS 4.90625.** All three iter444 confident-inaccuracies resolved in a single iter445 teacher consolidation at r22 §13.5 leading worked example:
- LEADS with "This is Limit pushdown (NOT Top-N pushdown), and it DOES push to Postgres" — verbatim per the FIRST-WORD directive.
- `limit=100` folded-into-TableScan SUCCESS signature given; separate `Limit[100]` operator above = not-pushed FAILURE signature given as the contrast.
- NO self-contradiction — single coherent "DOES push" claim throughout.
- NO fabricated operators — zero occurrences of `RemoteOffset`, `LimitPartial`, `OffsetPartial`, `RemoteLimit`.

**Iter431 → iter440 → iter444 → iter445 4-cycle Limit-vs-TopN regression FINALLY BROKEN.** The teacher consolidation strategy that worked on Q1 Iceberg branches (single comprehensive leading worked example + FIRST-WORD directive + DO-NOT-WRITE block) was successfully applied to federation pushdown vocabulary. The fix is durable to the degree that this iteration's probe passed at the highest score of the 4-cycle — needs iter448-450 durability re-probe with varied connector (MySQL/SQL Server) to confirm generalization.

### (b) Federation average after Q1 + Q2 — CROSSES BACK ABOVE 4.5?

**YES — FEDERATION RESTORED to PASSED (razor-thin).**

Arithmetic:
- Prior: 4.4977 × 306 = 1376.2962
- + Q1 4.90625 → 1381.20245, count 307
- + Q2 4.8125 → 1386.01495, count 308
- **New average: 1386.01495 / 308 = 4.50005**
- Margin: **+0.00005 above 4.5 threshold**
- Swing from iter444: **+0.0024 (margin -0.0023 → +0.00005)**

**FEDERATION CROSSES BACK ABOVE 4.5 THRESHOLD — flipped from FAIL to PASSED, BARELY.** This is the second consecutive flip on federation (iter441 → iter442/443 PASSED → iter444 FAIL → iter445 PASSED). The +0.00005 margin is so razor-thin that a single sub-4.5 federation datapoint in iter446 would flip federation back to FAIL. Federation needs 2-3 more strong federation datapoints at 4.75+ avg to compound the margin to a safe +0.005+ range.

### (c) New confident-inaccuracies — any?

**NONE this iter.** All four answers are canonical against verified official docs:
- Q1: trino.io/docs/current/optimizer/pushdown.html Limit pushdown vs Top-N pushdown distinction VERIFIED.
- Q2: trino.io/docs/current/connector/postgresql.html VARCHAR range non-pushdown + equality/IN/numeric range/numeric eq pushdown VERIFIED.
- Q3: sqlines.com Oracle-to-SQL-Server DECODE NULL handling note + cleverence.com Oracle DECODE docs CONFIRM DECODE(NULL,NULL,1,2)=1 vs CASE simple WHEN NULL never matches → searched CASE with IS NULL required.
- Q4: starburst.io Iceberg rollback/expire blog + iceberg.apache.org/docs/latest/maintenance/ CONFIRM positional 3-arg syntax + pointer-only-no-file-delete semantics + expire_snapshots 7d Trino floor.

Zero-confident-inaccuracy streak (broken at iter443+iter444 with 5 total inaccuracies) RE-STARTS at 1 iter. Iter444 cluster of 3 inaccuracies on Q2 federation Limit-vs-TopN ALL RESOLVED.

### (d) Verified-claim spot checks

- **Limit pushdown vs Top-N pushdown separate capabilities** — VERIFIED per trino.io/docs/current/optimizer/pushdown.html: "When the query plan contains a Sort and Limit operations, the engine tries to push down the limit into the connector by calling the applyTopN method. If there's no Sort operation, but only a Limit, the applyLimit method is called instead."
- **PostgreSQL connector VARCHAR range non-pushdown** — VERIFIED per trino.io/docs/current/connector/postgresql.html: "The connector does not support pushdown of range predicates, such as >, <, or BETWEEN, on columns with character string types like CHAR or VARCHAR. However, equality predicates, such as IN or =, and inequality predicates, such as != on columns with textual types are pushed down."
- **Oracle DECODE NULL semantics** — VERIFIED per sqlines.com/oracle-to-sql-server/decode: "In a DECODE function, Oracle considers two nulls to be equivalent" + "When you convert DECODE to CASE expression, and there is NULL condition, you have to use searched CASE form."
- **rollback_to_snapshot positional Trino 467 syntax** — VERIFIED per starburst.io blog: `CALL iceberg.system.rollback_to_snapshot('demo_tpch', 'customer_iceberg', 5043425904354141100)` (3 positional args: schema, table, snapshot_id).
- **expire_snapshots 7d Trino floor** — VERIFIED per Starburst forum + trino.io: `iceberg.expire-snapshots.min-retention` default 7d; retention_threshold must be ≥ this floor.

---

## Per-question scoring

### Q1 — Plain LIMIT pushdown (federation CRITICAL restore re-probe)

**Scores: 5.0 / 4.75 / 5.0 / 4.875 — avg 4.90625 STRONG PASS**

What landed correct:
- LEADS with verbatim canonical: "This is Limit pushdown (NOT Top-N pushdown), and it DOES push to Postgres."
- EXPLAIN SUCCESS signature: `TableScan[catalog=postgresql, table=users, ..., limit=100]` — `limit=100` folded INTO TableScan, no separate Limit operator above — CORRECT.
- EXPLAIN FAILURE signature: separate `Limit[100]` operator ABOVE TableScan — CORRECT.
- Scope explicit: applies only to plain LIMIT no ORDER BY/GROUP BY/join, unsorted record.
- ZERO fabricated EXPLAIN operators (`RemoteOffset`, `LimitPartial`, `OffsetPartial`, `RemoteLimit` all absent).
- ZERO self-contradiction.

Minor docks:
- BC dock 0.25: could add 1-line `applyLimit` vs `applyTopN` connector-method aside (minor; the explicit naming was reserved for r22 cite).
- Comp dock 0.125: could mention that LIMIT pushdown for PostgreSQL has been default since Trino 354.

**Verdict:** STRONG PASS — iter444 3-confident-inaccuracy cluster FULLY RESOLVED; 4-cycle Limit-vs-TopN regression FINALLY BROKEN.

### Q2 — Predicate pushdown which-filters-push (federation BUFFER)

**Scores: 5.0 / 4.75 / 4.75 / 4.75 — avg 4.8125 STRONG PASS**

What landed correct:
- Numeric equality `account_id = 12345` PUSHES — CORRECT.
- IN-list `status IN (...)` PUSHES — CORRECT.
- Numeric range `revenue > 1000` PUSHES — CORRECT.
- VARCHAR equality PUSHES default — CORRECT per trino.io PostgreSQL docs.
- VARCHAR range does NOT push by default — CORRECT (Trino docs explicit on this).
- IS NULL PUSHES — CORRECT.
- EXPLAIN `constraint=...` inside TableScan = pushed vs separate `Filter` above = Trino-side — CORRECT canonical signature.

Minor docks:
- BC dock 0.25: per-case enumeration is dense; could compact into a 6-row table for faster scanning.
- PA dock 0.25: could add a 1-line "how to verify with EXPLAIN" walkthrough on the combined predicate.
- Comp dock 0.25: could mention the empirical aggregate-needs-all-predicates-push ordering caveat more explicitly.

**Verdict:** STRONG PASS — federation BUFFER datapoint canonical.

### Q3 — Oracle DECODE → CASE WHEN migration

**Scores: 5.0 / 4.75 / 4.75 / 4.625 — avg 4.78125 STRONG PASS**

What landed correct:
- Trino has NO DECODE — must use CASE WHEN.
- Positional 1:1 mechanical mapping correct.
- NULL gotcha — DECODE(NULL,NULL,1,2)=1 vs CASE simple form `WHEN NULL` never matches → use searched CASE `WHEN x IS NULL` — CORRECT per sqlines.com.
- Strict type coercion — Trino requires explicit CAST where Oracle DECODE accepted implicit coercion — CORRECT.
- Oracle empty-string-is-NULL quirk — `NULLIF(col, '')` guard pattern — CORRECT canonical migration pattern.

Minor docks:
- Comp dock 0.375: could mention DECODE allows fall-through ordering matters (first match wins) — CORRECT translation must preserve order; not explicit in this answer.

**Verdict:** STRONG PASS — Oracle migration topic +0.0071 nudge.

### Q4 — Iceberg rollback_to_snapshot

**Scores: 5.0 / 4.75 / 4.875 / 4.625 — avg 4.8125 STRONG PASS**

What landed correct:
- `CALL iceberg.system.rollback_to_snapshot('analytics', 'event_table', snap_id)` positional 3-arg Trino 467 — CORRECT per starburst.io.
- `$snapshots` lookup via `committed_at < TIMESTAMP '...'` window — CORRECT canonical pattern.
- Pointer-only no-file-delete semantics — CORRECT.
- `expire_snapshots(retention_threshold => '7d')` Trino 7-day floor — CORRECT default.
- Spark `older_than` escape hatch for sub-7d immediate cleanup — CORRECT.
- Snapshots retained by default — rollback as far back as files exist — CORRECT.

Minor docks:
- Comp dock 0.375: could add a brief note on the deprecated-in-newer-Trino path (rollback_to_snapshot table procedure replacement) for forward-compat — but for Trino 467 the system procedure form is the canonical answer, so this is a minor nice-to-have.

**Verdict:** STRONG PASS — Iceberg maintenance topic +0.0028 nudge.

---

## Topic-score updates

| Topic | Before | After | Delta | Status |
|---|---|---|---|---|
| Trino federation / cross-source connectors | 4.4977 / 306 | **4.50005 / 308** | **+0.00235** | **PASSED — RESTORED from FAIL; margin -0.0023 → +0.00005 (razor-thin, +0.0024 swing); Q1 4.90625 + Q2 4.8125 both above 4.5 threshold** |
| Iceberg table maintenance | 4.5048 / 108 | **4.5076 / 109** | +0.0028 | PASSED — Q4 4.8125 above topic avg |
| Oracle PL/SQL → dbt + Trino SQL migration | 4.6314 / 20 | **4.6385 / 21** | +0.0071 | PASSED — Q3 4.78125 above topic avg |

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.90625 | Trino federation (plain LIMIT pushdown CRITICAL restore) | STRONG PASS — iter444 3-confident-inaccuracy cluster RESOLVED |
| Q2 | 4.8125 | Trino federation (predicate pushdown BUFFER) | STRONG PASS — per-case correctness verified |
| Q3 | 4.78125 | Oracle migration (DECODE → CASE) | STRONG PASS — NULL gotcha + type coercion canonical |
| Q4 | 4.8125 | Iceberg maintenance (rollback_to_snapshot) | STRONG PASS — positional syntax + pointer-only semantics canonical |

**Average 4.823 STRONG PASS — +0.745 step-UP from iter444 4.078.** Iter445 is a clean restore iteration: the iter444 federation Q2 3-inaccuracy cluster is fully resolved, federation crosses back above threshold (razor-thin), Iceberg maintenance and Oracle migration both nudge up from above-topic-avg Q3/Q4 datapoints, and ZERO new confident-inaccuracies anywhere.

**Headline outcomes:**
- ZERO new confident-inaccuracies this iter (iter443 + iter444 had 5 total; iter445 has 0).
- FEDERATION RESTORE 4.4977 → 4.50005 / 308 (+0.0024 swing; margin -0.0023 → +0.00005 RAZOR-THIN).
- Iceberg table maintenance 4.5048 → 4.5076 / 109 (+0.0028).
- Oracle migration 4.6314 → 4.6385 / 21 (+0.0071).
- Iter431 → iter440 → iter444 → iter445 4-cycle Limit-vs-TopN regression FINALLY BROKEN.

**Strategic observation:** The teacher-consolidation strategy that worked on Q1 Iceberg branches at iter444 (single comprehensive leading worked example + FIRST-WORD directive + DO-NOT-WRITE block) was successfully applied at iter445 to federation Limit-vs-TopN. Same recipe, different topic, same successful outcome. This validates the consolidation-into-leading-position pattern for resolving chronic recurring regressions.

---

## Teacher actions next (iter 446)

1. **HIGH — HOLD r22 §13.5 leading worked example.** Do NOT touch the canonical leading block — let it bake. Federation margin is razor-thin (+0.00005), so any unrelated edit that accidentally weakens the leading worked example will tip federation back below threshold.

2. **HIGH — Plan iter448-450 durability re-probe with VARIED connector.** The r22 §13.5 leading example uses PostgreSQL. Judge will probe in iter448-450 with MySQL or SQL Server connector variant to confirm the canonical "Limit pushdown (NOT Top-N pushdown), and it DOES push" phrasing generalizes beyond Postgres. Teacher should pre-emptively add a one-line aside in r22 §13.5 noting "applies equally to MySQL, SQL Server, and other JDBC connectors that implement applyLimit."

3. **MEDIUM — Federation margin compounding via Q3-pair re-probes.** Federation passes by only +0.00005. Need 2-3 more strong federation datapoints at 4.75+ avg to compound the margin to a safe +0.005+ range. Continue federation re-probes (Postgres pushdown corner cases, CBO / runtime DF cross-source, federated-join cost, when-to-federate-vs-ingest) at higher cadence next 2-3 iters.

4. **MEDIUM — Carry forward backlog probes.** Pushdown corner cases not yet covered:
   - CAST-wrapped column (e.g. `CAST(id AS VARCHAR) = '123'`) breaks pushdown — canonical anti-pattern.
   - LIKE prefix `name LIKE 'foo%'` — push behavior varies by connector.
   - OR-of-equality `id = 1 OR id = 2` — may decompose to IN list or not.
   - Aggregate pushdown ordering — empirical caveat that ALL predicates must push for aggregate to push.

5. **STRATEGIC — Loop posture: iter445 strong restore.** Aggregate PASSED stays + federation FLIPS BACK to PASSED (razor-thin). 4-cycle Limit-vs-TopN regression resolved via consolidation-into-leading-position strategy. Apply the same pattern proactively to any future chronic regression: identify recurring failure mode, write ONE leading worked example at top of relevant resource section, add FIRST-WORD directive + DO-NOT-WRITE block listing the specific wrong phrasings.

---

## Judge probe targets next (iter 446) — RECOMMENDED

1. **HIGH — Limit-vs-TopN durability re-probe with VARIED connector.** Ask "does `SELECT * FROM mysql.app.orders LIMIT 50` push the LIMIT to MySQL?" or "does SQL Server connector push plain LIMIT?" — expected answer should follow the same canonical phrasing: "This is Limit pushdown (NOT Top-N pushdown), and it DOES push." Confirm r22 §13.5 worked example generalizes beyond Postgres.

2. **HIGH — Fabricated EXPLAIN operator direct re-probe.** Ask "I see an operator called `RemoteLimit` in my EXPLAIN — what does it mean?" or "is `OffsetPartial` a real Trino operator?" — expected answer: "There is no such operator in Trino EXPLAIN output. Real operators are TableScan, Filter, ScanFilterProject, Project, Limit, TopN, TopNPartial, Aggregate (partial/final), LocalExchange, RemoteExchange, RemoteSource, Output. For limit pushdown the signature is `limit=N` annotation folded INTO TableScan, not a separate operator."

3. **MEDIUM — Federation buffer compound: federated-join cost / when-to-federate-vs-ingest.** Ask "I have a 10M-row Postgres `users` table and a 500M-row Iceberg `events` table — should I federate or ingest users into Iceberg?" — expected answer: build-side / probe-side reasoning + broadcast vs partitioned join + Trino cross-catalog join limits + ingest-when-Postgres-table-grows-large reasoning.

4. **MEDIUM — Iceberg branch WAP durability (3-5 iters out).** Confirm iter444 r17 consolidated worked example holds against slightly different phrasing (e.g. "I want to publish my audit branch tomorrow — exact Spark calls?" or "I'm hitting 'not a fast-forward' during WAP publish").

5. **LOW — Carry forward backlog**: CAST-wrapped predicate pushdown break; LIKE prefix pushdown; OR-of-equality decomposition; isolation-level write props; Iceberg identity-column durability; partition-spec-evolution different-angle.

---

## Critical message to teacher for iter 446

**Iter445 is a 4.823 STRONG PASS overall — +0.745 step-UP from iter444 4.078 — with FEDERATION RESTORED to PASSED (razor-thin +0.00005 margin) and ZERO new confident-inaccuracies anywhere.** The iter445 teacher consolidation strategy at r22 §13.5 (leading worked example with FIRST-WORD directive + DO-NOT-WRITE block listing fabricated operator names) SUCCESSFULLY broke the iter431 → iter440 → iter444 4-cycle Limit-vs-TopN regression. Same consolidation recipe that fixed Q1 Iceberg branches at iter444 worked for Q2 federation Limit-vs-TopN at iter445.

**KEY iter446 PRIORITY: HOLD r22 §13.5 leading worked example untouched.** Federation passes by only +0.00005. Any unintended weakening of the leading block will tip federation back below threshold. Plan iter448-450 durability probes with varied connectors (MySQL, SQL Server) to confirm generalization beyond the Postgres example; add a one-line connector-agnostic aside in r22 §13.5 to pre-empt connector-variant probes.

**Q1 plain LIMIT pushdown federation CRITICAL: STRONG PASS 4.90625.** First-word verbatim "This is Limit pushdown (NOT Top-N pushdown), and it DOES push to Postgres" landed exactly; EXPLAIN success/failure signatures both canonical; zero fabricated operators; zero self-contradiction. 4-cycle regression FINALLY RESOLVED.

**Q2 predicate pushdown federation BUFFER: STRONG PASS 4.8125.** Per-case correctness on numeric eq/range/IN/VARCHAR-eq PUSH + VARCHAR range NO-push all verified against trino.io PostgreSQL docs.

**Q3 Oracle DECODE → CASE: STRONG PASS 4.78125.** NULL gotcha (DECODE(NULL,NULL,1,2)=1 vs CASE simple WHEN NULL never matches → searched CASE with IS NULL) + type coercion + empty-string-is-NULL all canonical.

**Q4 Iceberg rollback_to_snapshot: STRONG PASS 4.8125.** Trino 467 positional 3-arg + $snapshots committed_at lookup + pointer-only-no-file-delete + 7d Trino expire floor + Spark sub-7d escape hatch all canonical.

**Loop status:** Aggregate PASSED stays + FEDERATION FLIPS BACK to PASSED (razor-thin). 44th consecutive overall PASS in extended phase. Iter445 is the cleanest single-iter result in 4 iters — zero new confident-inaccuracies + chronic 4-cycle regression resolved + federation restored. Iter446 priority is buffer compounding (federation margin from +0.00005 to a safer +0.005+ via 2-3 more strong federation datapoints) plus iter448-450 durability re-probe planning.

**Other key verifications this iter:**
- Trino Limit pushdown vs Top-N pushdown separate capabilities (`applyLimit` vs `applyTopN`) — VERIFIED per trino.io/docs/current/optimizer/pushdown.html.
- PostgreSQL connector VARCHAR range non-pushdown + equality/IN/numeric-range PUSH — VERIFIED per trino.io/docs/current/connector/postgresql.html.
- Oracle DECODE NULL=NULL matchable vs CASE simple WHEN NULL never matches → searched CASE IS NULL — VERIFIED per sqlines.com / cleverence.com.
- Trino 467 `CALL iceberg.system.rollback_to_snapshot('schema', 'table', snap_id)` positional 3-arg — VERIFIED per starburst.io blog + trino.io docs.
- `iceberg.expire-snapshots.min-retention` default 7d floor — VERIFIED per Starburst forum + trino.io docs.
