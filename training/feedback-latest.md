# Judge Feedback — Iter 430 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.4688 PASS** (Q1 4.125 + Q2 4.1875 + Q3 4.8125 + Q4 4.75) — **−0.140 step-DOWN from iter429 4.609**. Twenty-ninth consecutive overall PASS in extended phase, but **TWO confident inaccuracies persist this iter — one NEW (Q1 CTAS-NOT-NULL-inference) replacing the iter429 SET NOT NULL inaccuracy, and Q2 LIMIT-pushdown terminology STILL primary-labeled as "TopN pushdown" + still cites release 354**. The zero-confident-inaccuracy streak does NOT recover. **Federation topic NUDGES DOWN: 4.4939 → 4.4929 (−0.0010)**, 30th consecutive iter below 4.5 threshold, now 0.0071 below — direction REVERSED (was +0.0002 last iter, now −0.0010 this iter).

---

## Headline

1. **Q1 ADD COLUMN NOT NULL re-probe — iter429 SET NOT NULL slip RESOLVED, but NEW CTAS-NOT-NULL-inference slip emerges (4.125 PASS).** The responder now correctly states **"Trino 467 does NOT support ALTER COLUMN SET NOT NULL (unimplemented)"** and recommends dbt not_null test as the primary workaround — the §13.5A.5/r09/r13 guardrails landed. The "Iceberg columns once added are always nullable by design" nuance is ACCEPTABLE in context (ADD COLUMN does force nullable per Iceberg spec backward compat). **HOWEVER**: the CTAS-swap workaround is described inaccurately — responder says **"CREATE TABLE AS SELECT will have tier as NOT NULL"** which is WRONG. Per Trino docs, CTAS infers column TYPES from the SELECT statement but does NOT preserve/infer NOT NULL constraints. An engineer following this advice gets a new table where `tier` is still nullable. The correct CTAS-swap pattern requires an explicit CREATE TABLE column-list with `tier VARCHAR NOT NULL` declared, then INSERT INTO ... SELECT — NOT a plain CTAS. This is a NEW CONFIDENT INACCURACY on a load-bearing workaround.

2. **Q2 plain-LIMIT federation re-probe — terminology STILL PRIMARY-LABELED as "TopN pushdown" + still cites release 354 (4.1875 PASS, DOWN from iter429's 4.5625).** Critical re-probe outcome: PARTIAL RECOVERY ONLY, NOT clean recovery. The responder STILL leads with "TopN pushdown pattern" and "release 354" — both phrasings belong to **Top-N pushdown** (ORDER BY + LIMIT), NOT to plain Limit pushdown. The responder parenthetically adds **"or LIMIT pushdown for the JDBC case"** showing the §13.5A.5 Q-pattern matcher partially landed, but the PRIMARY framing is still the wrong term. Per trino.io/docs/current/optimizer/pushdown.html, plain LIMIT (no ORDER BY) is **Limit pushdown** (a SEPARATE capability from Top-N pushdown). LIMIT pushdown support was added in release 466 (Nov 2024) per release notes — NOT release 354. The behavioral answer (Postgres stops at 500, EXPLAIN shows `limit=500` inside TableScan, separate Limit operator above bare TableScan = failed pushdown) IS correct, but the terminology precision is the dock target. The teacher's iter430 §13.5A.5 Q-pattern matcher + glossary + myth row + DO-NOT-WRITE entries are STRUCTURALLY CORRECT but findability is STILL not landing primary — the responder's default token sequence still pulls "TopN pushdown" first.

3. **Q3 DECODE NULL vs CASE STRONG (4.8125).** All claims verified: Oracle DECODE uniquely treats NULL = NULL as matchable (per docs.oracle.com — "Oracle considers two nulls to be equal when evaluating a DECODE function"), `CASE col WHEN NULL` never matches (NULL=anything → NULL/FALSE), explicit `WHEN col IS NULL` is the canonical fix. Audit-before-find-replace is sound migration guidance. Oracle migration topic continues to be canonical.

4. **Q4 time-travel retention via $snapshots STRONG (4.75).** All claims verified: query `$snapshots ORDER BY committed_at ASC LIMIT 1` for oldest accessible snapshot — CORRECT per Trino Iceberg metadata table docs; `expire_snapshots(retention_threshold)` deletes older snapshots fails time-travel before that — CORRECT; `history.expire.max-snapshot-age-ms` table property — CORRECT; raise threshold for long retention or Spark bypass 7d floor — CORRECT; tags survive expiry with `CREATE TAG ... RETAIN N DAYS` syntax — CORRECT per Iceberg Spark procedures docs.

---

## Critical confirmations (explicit)

### (a) Q1 RESOLVED check + CTAS-NOT-NULL-inference check

**iter429 SET NOT NULL inaccuracy: RESOLVED.** The responder now explicitly states "Trino 467 does NOT support ALTER COLUMN SET NOT NULL (not syntax — unimplemented)" and recommends dbt not_null test (RECOMMENDED) instead of the fabricated ALTER syntax. The §13.5A.5 SCHEMA-EVOLUTION CONSTRAINT-TIGHTENING GUARDRAIL + r09 + r13 placements all landed. The DO-NOT-WRITE banning `ALTER TABLE ... ALTER COLUMN ... SET NOT NULL` did its job — that exact phrase does not appear in the answer.

**The "Iceberg columns once added are always nullable by design" nuance: ACCEPTABLE.** Per Iceberg spec semantics, ADD COLUMN must produce a nullable column for backward-compat reasons (old data files don't have the new column, must read NULL). The broader phrasing is slightly imprecise (Iceberg DOES support NOT NULL at CREATE TABLE time per trino.io/docs/current/connector/iceberg.html), but in context — answering a question about adding/tightening columns — it's defensibly correct. Not a dock.

**CTAS-NOT-NULL-inference check: NEW CONFIDENT INACCURACY CONFIRMED.** The responder's CTAS-swap workaround claims "CREATE TABLE AS SELECT will have tier as NOT NULL" — this is WRONG. Per Trino CREATE TABLE AS docs and verified behavior:
- CTAS infers column TYPES from the SELECT statement (e.g., `VARCHAR`, `BIGINT`).
- CTAS does NOT infer or preserve NOT NULL constraints. Even if the SELECT filters `WHERE tier IS NOT NULL`, the new table's `tier` column is created as NULLABLE.
- To get NOT NULL on a CTAS-swap, you MUST use the explicit form: `CREATE TABLE _new (tier VARCHAR NOT NULL, ...)` then `INSERT INTO _new SELECT ...` — a 2-step pattern, NOT plain CTAS.

An engineer following the responder's advice runs `CREATE TABLE customers_new AS SELECT * FROM customers WHERE tier IS NOT NULL` expecting NOT NULL enforcement, then later inserts a NULL into `tier` and is surprised it succeeds. **This breaks the workaround the answer just recommended.** The intent (CTAS to apply NOT NULL after backfill) is sound; the execution path described does not deliver NOT NULL.

**This is a NEW confident inaccuracy that replaces (does not stack with) the iter429 SET NOT NULL slip.** Net result: one inaccuracy resolved, one new inaccuracy introduced in the workaround documentation.

### (b) Q2 terminology recovery assessment + Q2 score + federation average + direction + crosses 4.5?

**Q2 score: 4.1875 PASS.** TA 3.5 / Clarity 4.5 / Practical 4.5 / Completeness 4.25.

**Terminology recovery assessment: PARTIAL ONLY, NOT CLEAN.** The responder's PRIMARY framing is still the WRONG term:
- "recognizes plain SELECT...LIMIT no ORDER BY/agg as **TopN pushdown pattern**" — WRONG primary label
- "embeds limit=500 in JDBC scan; optimization called **TopN pushdown** (or LIMIT pushdown for the JDBC case)" — primary still TopN, parenthetical secondary is the correct term
- Cites "release 354" — WRONG release. LIMIT pushdown support landed in release 466 (Nov 2024) per release notes. Release 354 belongs to Top-N pushdown (ORDER BY + LIMIT) infrastructure.
- "separate TopN operator above = not fired" — using TopN terminology for what should be the LIMIT operator (the EXPLAIN signal for a NON-pushed plain LIMIT is a separate `Limit[N]` operator above TableScan, NOT TopN).

Per trino.io/docs/current/optimizer/pushdown.html:
- **Limit pushdown**: "Queries with plain LIMIT N or FETCH FIRST N ROWS clauses can be pushed down... significantly reduce the amount of data transferred from the data source to Trino."
- **Top-N pushdown**: "The combination of a LIMIT or FETCH FIRST clause with an **ORDER BY clause**... is therefore quite different to optimize compared to a Limit pushdown."

These are TWO SEPARATE capabilities. The PostgreSQL connector docs list them as TWO SEPARATE capability rows.

**The teacher's iter430 §13.5A.5 fixes are STRUCTURALLY CORRECT — content is verified, doc-quoted, and complete — but findability/primacy is STILL not landing.** The responder is reading the section but the default token-sequence retrieval still pulls "TopN pushdown" first. This is the SECOND consecutive iter where this exact mislabeling occurs (iter429 Q1, iter430 Q2). The parenthetical "or LIMIT pushdown for the JDBC case" addition shows the responder has been nudged toward the correct term — but it is not the primary framing.

**Federation average update:**
- Prior: 4.4939 × 291 = 1307.7249 sum
- + Q2 4.1875 = +4.1875
- New sum: 1311.9124
- New count: 292
- **New average: 1311.9124 / 292 = 4.4929**

Distance to threshold: 4.5000 − 4.4929 = **0.0071 below 4.5**.

Compared to iter429:
- Iter429: 4.4939, 0.0061 below threshold
- Iter430: 4.4929, 0.0071 below threshold
- **Net change: −0.0010 / 0.0010 FURTHER from threshold / 30th consecutive iter below threshold / DIRECTION REVERSED (was +0.0002 last iter, now −0.0010 this iter)**

**Crosses 4.5?** NO. The Q2 4.1875 is well below the threshold itself and dragged the running average further down. The trend direction has now reversed from the 3-iter marginal-up streak (iter427/iter428/iter429 each marginally up) to a net-down move. The terminology imprecision cost roughly 0.66 on this Q2 datapoint vs a clean-recovery 4.85+ ceiling.

### (c) Any NEW confident-inaccuracy across all four

**YES — ONE new confident inaccuracy in Q1.** The CTAS-NOT-NULL-inference slip (described in section (a) above). The iter429 SET NOT NULL slip is resolved but a new failure-mode in the same Q1 area is introduced. Net inaccuracy count this iter: **2 confident issues** (Q1 CTAS-NOT-NULL slip + Q2 LIMIT-pushdown terminology repeat).

Q3 and Q4 are clean — all figures and syntax verified against docs.oracle.com, iceberg.apache.org, and trino.io.

### (d) Q3 DECODE-NULL-equality verification

VERIFIED per docs.oracle.com SQL Language Reference and verified third-party Oracle DECODE references:
- "Oracle considers two nulls to be equal when evaluating a DECODE function" — CORRECT, exact behavior.
- `DECODE(null, null, 1, 2)` returns 1; `CASE NULL WHEN NULL THEN 1 ELSE 2 END` returns 2.
- The responder's fix (`CASE WHEN col IS NULL THEN default WHEN col = 'a' THEN 1 ...`) is the canonical bulletproof translation.
- Audit Oracle DECODEs for NULL-handling before find-replace is correct migration discipline.

All Q3 claims CONFIRMED. No inaccuracy.

### (e) Q4 $snapshots + tag retention verification

VERIFIED per iceberg.apache.org/docs/latest/spark-procedures/ and iceberg.apache.org/docs/latest/maintenance/:
- `$snapshots` metadata table exposes `committed_at` per snapshot — CORRECT.
- `ORDER BY committed_at ASC LIMIT 1` returns the oldest accessible snapshot, which is the time-travel boundary — CORRECT.
- `expire_snapshots(older_than => TIMESTAMP, retain_last => N)` deletes snapshots older than the threshold; time-travel queries to those snapshots fail after — CORRECT.
- `history.expire.max-snapshot-age-ms` table property controls the default retention floor (default 7 days) — CORRECT per Iceberg table properties docs.
- Spark `ALTER TABLE ... CREATE TAG <name> RETAIN N DAYS` syntax — CORRECT (per Spark procedures docs).
- Tags survive expire_snapshots: snapshots referenced by tags are protected from expiry — CORRECT per Iceberg spec.

All Q4 claims CONFIRMED. No inaccuracy.

---

## Per-question scoring

### Q1 — ADD COLUMN tighten to NOT NULL (re-probe of iter429 Q4)

**Scores: 3.5 / 4.75 / 3.75 / 4.5 — avg 4.125 PASS**

What landed (RESOLVED iter429):
- "Trino 467 does NOT support ALTER COLUMN SET NOT NULL (unimplemented)" — CORRECT, RESOLVED
- dbt not_null test recommended as primary workaround — CORRECT canonical
- App-level validation as a fallback — CORRECT
- "Iceberg columns once added are always nullable by design (added cols must read NULL for old rows)" — ACCEPTABLE nuance for ADD COLUMN context
- Cites r09 SCHEMA-EVOLUTION CONSTRAINT-TIGHTENING GUARDRAIL + r13 — teacher's structural fixes landed

What is INACCURATE:
- **"CREATE TABLE AS SELECT will have tier as NOT NULL"** — WRONG. Trino CTAS does NOT preserve or infer NOT NULL constraints. CTAS infers column types only. To get NOT NULL on the new table you need explicit `CREATE TABLE _new (tier VARCHAR NOT NULL, ...)` + `INSERT INTO _new SELECT ...`, not plain CTAS.
- The "deletes snapshots/breaks time-travel" caveat for CTAS is CORRECT (new table = new snapshot history).

**Verdict:** PASS. iter429 SET NOT NULL inaccuracy RESOLVED, but a new CTAS-NOT-NULL-inference inaccuracy emerges in the workaround. TA 3.5 reflects the new inaccuracy; Practical 3.75 reflects that the engineer following the CTAS path still gets a nullable column.

### Q2 — Plain LIMIT pushdown (federation re-probe)

**Scores: 3.5 / 4.5 / 4.5 / 4.25 — avg 4.1875 PASS**

What landed:
- Postgres fetches only 500 rows, ~500 cross the wire — CORRECT BEHAVIOR
- EXPLAIN signature `limit=500` inside TableScan = pushed — CORRECT
- Separate Limit/TopN operator above bare TableScan = failed pushdown — CORRECT (though using "TopN" label here is itself imprecise)
- ORDER BY LIMIT also pushes with sortOrder= annotation — CORRECT (this IS the Top-N case)
- Parenthetical "or LIMIT pushdown for the JDBC case" — partial recovery, secondary mention of correct term

What is IMPRECISE / REPEAT:
- PRIMARY label "TopN pushdown pattern" for plain LIMIT no ORDER BY — WRONG. Should be "Limit pushdown" per trino.io.
- "Release 354" — WRONG. LIMIT pushdown landed in release 466 (Nov 2024). Release 354 is Top-N pushdown infrastructure.
- "separate TopN operator above = not fired" — WRONG operator. For non-pushed plain LIMIT the failure signal is a `Limit[N]` operator (not TopN).
- §13.5A.5 Q-pattern matcher / glossary / myth row partially landed (parenthetical correction exists) but PRIMARY framing still wrong — findability/primacy gap persists.

**Verdict:** PASS but TERMINOLOGY REPEAT. Behavioral guidance is correct, engineer learns right operational behavior, but the Trino-precise vocabulary "Limit pushdown vs Top-N pushdown" STILL did not land as primary on the 2nd consecutive re-probe. TA dock to 3.5 (repeat imprecision on a deliberate re-probe + wrong release number).

### Q3 — DECODE NULL vs CASE (Oracle PL/SQL migration)

**Scores: 5.0 / 4.75 / 4.75 / 4.75 — avg 4.8125 STRONG PASS**

What landed:
- DECODE treats NULL in first arg specially, returns default if col IS NULL (NULL = NULL evaluated as match) — CORRECT, VERIFIED per docs.oracle.com
- CASE col WHEN 'a' doesn't match NULL (NULL = anything → NULL/FALSE) — CORRECT
- Bulletproof CASE translation: explicit `WHEN col IS NULL THEN default WHEN col='new' THEN 1 ...` — CORRECT canonical fix
- Audit Oracle DECODEs for NULL-handling before find-replace — CORRECT migration discipline

**Verdict:** STRONG PASS — Oracle migration topic continues to be canonical.

### Q4 — Time-travel retention boundary via $snapshots (Iceberg maintenance)

**Scores: 4.75 / 4.75 / 4.75 / 4.75 — avg 4.75 STRONG PASS**

What landed:
- No single field — must query $snapshots — CORRECT
- `$snapshots ORDER BY committed_at ASC LIMIT 1` = oldest accessible snapshot = time-travel boundary — CORRECT
- `expire_snapshots(retention_threshold)` deletes older snapshots → fails time-travel before that — CORRECT
- `history.expire.max-snapshot-age-ms` table property — CORRECT
- Raise threshold for long retention or Spark bypass 7d floor — CORRECT
- Tags survive expire_snapshots (Spark `CREATE TAG ... RETAIN N DAYS`) — CORRECT per Iceberg spec

**Verdict:** STRONG PASS — Iceberg maintenance topic canonical, all syntax verified.

---

## Topic-score updates

| Topic | Before | After | Delta | Status |
|---|---|---|---|---|
| Lakehouse schema design | 4.5803 / 7 | 4.5234 / 8 | −0.0569 | PASSED (Q1 CTAS slip dragged down, still above 3.5) |
| Trino federation / cross-source connectors | 4.4939 / 291 | 4.4929 / 292 | −0.0010 | NEEDS WORK (0.0071 below 4.5 raised threshold; 30th consecutive iter below; DIRECTION REVERSED — was +0.0002 last iter, now −0.0010) |
| Oracle PL/SQL → dbt + Trino SQL migration | 4.8125 / 7 | 4.8125 / 8 | 0.0000 | PASSED (held steady at 4.8125) |
| Iceberg table maintenance | 4.4447 / 95 | 4.4479 / 96 | +0.0032 | PASSED |

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.125 | Lakehouse schema design (ADD COLUMN NOT NULL tighten re-probe) | PASS — iter429 SET NOT NULL inaccuracy RESOLVED, but NEW CTAS-NOT-NULL-inference inaccuracy emerges in the workaround |
| Q2 | 4.1875 | Trino federation (plain LIMIT pushdown re-probe) | PASS — terminology STILL PRIMARY-labeled as "TopN pushdown" + STILL cites release 354; PARTIAL recovery only (parenthetical correction landed); 2nd consecutive iter mislabeling |
| Q3 | 4.8125 | Oracle PL/SQL migration (DECODE NULL vs CASE) | STRONG PASS — canonical |
| Q4 | 4.75 | Iceberg table maintenance (time-travel retention via $snapshots) | STRONG PASS — all syntax verified |

**Average 4.4688 PASS — twenty-ninth consecutive overall PASS in extended phase; −0.140 step-DOWN from iter429 4.609.**

**Headline outcomes:**
- Q1 ADD COLUMN re-probe — iter429 SET NOT NULL RESOLVED (CORRECT primary path: dbt not_null test); NEW CTAS-NOT-NULL-inference inaccuracy in workaround
- Q2 LIMIT pushdown re-probe — TERMINOLOGY REPEAT (still "TopN pushdown" primary + release 354); PARTIAL recovery only
- Q3 DECODE NULL vs CASE — STRONG (canonical Oracle migration answer)
- Q4 $snapshots time-travel boundary — STRONG (all syntax verified)
- Federation 4.4939 → 4.4929 (−0.0010 DOWN, direction REVERSED; 30th consecutive iter below threshold)
- Lakehouse schema design 4.5803 → 4.5234 (−0.0569 DOWN due to Q1 CTAS slip)
- Oracle migration 4.8125 → 4.8125 (held steady)
- Iceberg table maintenance 4.4447 → 4.4479 (+0.0032 UP marginal)

**Failure-mode count: 10 of prior 26 iterations** (iter430 introduces 1 new failure-mode class: CTAS-DOES-NOT-INFER-NOT-NULL — the documented CTAS-swap workaround needs an explicit column-list step that the responder collapses into plain CTAS).

---

## Teacher actions next (iter 431)

1. **HIGH — Fix CTAS-NOT-NULL-inference inaccuracy in §13.5A.5 / r09 / r13 CTAS-swap workaround.** The CTAS-swap documented workaround needs the EXPLICIT 2-step form:
   - Step 1: `CREATE TABLE customers_new (id BIGINT, tier VARCHAR NOT NULL, ...) WITH (...)` — explicit column-list with NOT NULL declared
   - Step 2: `INSERT INTO customers_new SELECT id, tier, ... FROM customers WHERE tier IS NOT NULL` (or with backfill default)
   - DO NOT collapse to `CREATE TABLE customers_new AS SELECT ... WHERE tier IS NOT NULL` — that single statement produces a NULLABLE `tier` column because CTAS does not preserve/infer NOT NULL.
   - Add a DO-NOT-WRITE entry banning "CTAS will have <col> as NOT NULL" / "CREATE TABLE AS SELECT ... WHERE col IS NOT NULL gives NOT NULL on new table" — these phrasings are factually wrong. Cite trino.io/docs/current/sql/create-table-as.html (CTAS infers types only) and trino.io/docs/current/connector/iceberg.html (NOT NULL only at explicit CREATE TABLE column-list time).
   - Add a Q-pattern matcher line: "if the question is 'how do I CTAS-swap to apply NOT NULL', the answer is EXPLICIT 2-step CREATE TABLE with column-list + INSERT — NOT plain CTAS."

2. **HIGH — Stronger §13.5A.5 PRIMACY treatment for Limit-vs-TopN.** The iter430 Q-pattern matcher + glossary + myth row are STRUCTURALLY CORRECT but findability primacy is STILL not landing. Two consecutive iters show the responder pulling "TopN pushdown" first and "Limit pushdown" only parenthetically. Consider:
   - **Hard rename / inversion in r22**: every appearance of "TopN pushdown" in §13.5A and §13.5A.5 must be preceded by an explicit "Limit pushdown is plain LIMIT (no ORDER BY); Top-N pushdown is ORDER BY + LIMIT" reminder paragraph, ideally as the FIRST sentence of every Limit/TopN-adjacent section.
   - **DO-NOT-WRITE expansion**: explicit ban on "TopN pushdown pattern for plain LIMIT" / "release 354 for LIMIT pushdown" — the WRONG release number citation. Add the correct citation: "**LIMIT pushdown support landed in release 466 (Nov 2024)** per trino.io/docs/current/release/release-466.html — NOT release 354."
   - **EXPLAIN failure-signal correction**: the non-pushed-LIMIT failure signal is a `Limit[N]` operator above TableScan (NOT a `TopN[...]` operator). Add this verbatim to §13.5A.5.
   - Consider a **leading "FIRST WORD" directive** at the very top of §13.5A.5: "When answering a plain-LIMIT-no-ORDER-BY question, the FIRST term out of your mouth must be 'Limit pushdown' — do not introduce 'Top-N pushdown' until you've established this distinction."

3. **MEDIUM — Carry-forward backlog (mostly unchanged from iter429-430)**:
   - HMS→Nessie write-freeze
   - Snapshot vs serializable phantom-row 3rd-angle
   - Window NULL 2nd-angle
   - Iceberg concurrency 5th-angle (commit.retry exhaustion behavior)
   - OPA-override timeout
   - Schema registry compat
   - JWT+OPA concurrency
   - Federation HAVING pushdown 2nd-angle
   - Federation function-wrapped predicate contrast (LOWER/COALESCE-wrapped column)

4. **LOW — No structural changes needed** to r09/r13 SCHEMA-EVOLUTION GUARDRAIL (Q1 dbt not_null test path landed correctly); to Q3 Oracle DECODE-NULL guidance (canonical); to Q4 $snapshots + tag retention (canonical). The Q1 fix is a precise CTAS-step correction inside the existing workaround block; the Q2 fix is a primacy/findability improvement to existing §13.5A.5 content.

---

## Judge probe targets next (iter 431)

1. **HIGH — Re-probe LIMIT pushdown plain (3rd consecutive iter)** — to verify the strengthened §13.5A.5 primacy lands the "Limit pushdown" terminology as PRIMARY (not parenthetical). A 3rd-angle test framing: "I have `SELECT id, email FROM app_pg.public.users LIMIT 100` against a Postgres table — what does Trino call this optimization and what does EXPLAIN show?" — looking for: (a) "Limit pushdown" as PRIMARY/FIRST term, (b) NO mention of release 354 / topn_pushdown_enabled in this context, (c) correct EXPLAIN signal `limit=100` inside TableScan, (d) failure signal a separate `Limit[100]` operator (NOT TopN). If the responder STILL leads with "TopN pushdown" on a 3rd consecutive iter, the findability fix is structurally inadequate and needs a more radical approach.

2. **HIGH — Re-probe CTAS-swap for NOT NULL** — to verify the new CTAS-NOT-NULL-inference fix lands. A direct question: "Walk me through the CTAS-swap pattern to make `tier` NOT NULL on an existing Iceberg table." — looking for the EXPLICIT 2-step form (CREATE TABLE with column-list + NOT NULL, then INSERT INTO ... SELECT) — NOT plain CTAS.

3. **HIGH — Federation HAVING pushdown 2nd-angle** (carry-forward, still un-asked): "Does `HAVING SUM(amount) > 1000` after a GROUP BY push to Postgres?"

4. **MEDIUM — Federation function-wrapped predicate contrast** (carry-forward): "Does `WHERE LOWER(email) = 'a@b.com'` push?"

5. **MEDIUM — Federation Top-N pushdown** (paired with #1 to test BOTH terms side-by-side): "What about `SELECT ... ORDER BY created_at DESC LIMIT 100`?" — looking for "Top-N pushdown" PRIMARY (and verify release 354/topn_pushdown_enabled citation lands correctly HERE, not on plain LIMIT).

6. **MEDIUM — Iceberg schema evolution column-type widening** (un-probed): INTEGER → BIGINT, REAL → DOUBLE, DECIMAL precision-widen — distinct from NOT NULL tightening.

7. **LOW — Iceberg concurrency 5th-angle** (carry-forward): commit.retry.num-retries exhaustion behavior.

---

## Critical message to teacher for iter 431

Iter430 is a step-DOWN PASS (4.4688 vs iter429's 4.609) driven by two distinct issues:

**Issue 1: Q1 CTAS-swap workaround — NEW CTAS-NOT-NULL-inference inaccuracy.** The iter429 SET NOT NULL slip is RESOLVED (primary path now correctly says "Trino 467 does not support" + recommends dbt not_null test), but the CTAS-swap workaround claim "CTAS will have tier as NOT NULL" is WRONG. Trino CTAS does NOT preserve or infer NOT NULL — only column types. The correct CTAS-swap is a 2-step process: explicit `CREATE TABLE _new (col TYPE NOT NULL, ...)` + `INSERT INTO _new SELECT ...`. **The teacher needs to add an explicit 2-step CTAS-swap example to §13.5A.5 / r09 / r13 and add a DO-NOT-WRITE entry banning "plain CTAS gives NOT NULL".** Cite trino.io/docs/current/sql/create-table-as.html (types only) and trino.io/docs/current/connector/iceberg.html (NOT NULL only at CREATE TABLE column-list time).

**Issue 2: Q2 LIMIT pushdown terminology — 2nd consecutive iter mislabeling.** The teacher's iter430 §13.5A.5 Q-pattern matcher + glossary + myth row are STRUCTURALLY CORRECT (verified verbatim against trino.io/docs/current/optimizer/pushdown.html and the PG connector docs). The responder is now ALSO mentioning "LIMIT pushdown for the JDBC case" parenthetically — showing partial findability success. But the PRIMARY framing is STILL "TopN pushdown pattern" + "release 354", BOTH wrong for plain LIMIT (no ORDER BY). The §13.5A.5 fixes need stronger PRIMACY enforcement — the FIRST term out of the responder's mouth for a plain-LIMIT question must be "Limit pushdown". Suggestions: hard rename inversion (every TopN mention preceded by Limit-vs-TopN disambiguation), DO-NOT-WRITE expansion banning "release 354 for LIMIT pushdown" (correct release is 466), EXPLAIN failure-signal correction (`Limit[N]` operator, not `TopN[...]`), leading "FIRST WORD" directive.

**Note: the zero-confident-inaccuracy streak does NOT recover (broken at 2, now at 0 again for the 2nd consecutive iter).** The 13-instance structural-fix-within-one-iteration recipe still works but iter430 introduces a new failure-mode (CTAS-DOES-NOT-INFER-NOT-NULL) inside the just-fixed area. The answer is to land the 14th GUARDRAIL (CTAS-NOT-NULL-INFERENCE) before iter431's re-probe, plus a stronger §13.5A.5 primacy treatment to break the 2-iter terminology streak.

**Federation topic moved −0.0010 to 4.4929, now 0.0071 below threshold (30th consecutive iter below).** Direction REVERSED from 3-iter marginal-up streak to net-down. The Q2 4.1875 is a deceleration vs the iter428 4.875 / iter429 4.5625 — the terminology imprecision now costs ~0.66 per datapoint vs a clean-recovery ceiling. With a stronger §13.5A.5 primacy fix landing on iter431's federation re-probe (target: "Limit pushdown" as FIRST term, no release 354 citation), recovery can resume.

**Iter431 should focus on:**
(1) Add CTAS-NOT-NULL-INFERENCE guardrail with EXPLICIT 2-step pattern (Q1 CTAS slip fix)
(2) Strengthen §13.5A.5 PRIMACY for Limit-vs-TopN (Q2 terminology fix — hard rename inversion, DO-NOT-WRITE for "release 354 for LIMIT", EXPLAIN signal correction, FIRST-WORD directive)
(3) Re-probe both Q1 CTAS-swap and Q2 plain-LIMIT on dedicated re-asks to verify both fixes land
(4) Continue carry-forward federation HAVING pushdown / function-wrapped predicate angles to grind federation topic toward 4.5
