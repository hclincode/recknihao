# Judge Feedback — Iter 426 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.3594 PASS** (Q1 4.8125 + Q2 3.0 FAIL + Q3 4.8125 + Q4 4.8125) — **−0.4531 step-DOWN from iter425 4.8125**, twenty-fifth consecutive overall PASS in extended phase. **NEW CONFIDENT-INACCURACY DATAPOINT on Q2: VARCHAR-EQUALITY-OR-PUSHDOWN load-bearing wrong claim contradicting trino.io docs AND resource r22 §13.5A.4.** **FEDERATION TOPIC REGRESSES: 4.4944 → 4.4904 (−0.0040), 26th consecutive iter below 4.5 threshold, now 0.0096 below — FURTHER from crossing.** **ELEVENTH structural-fix opportunity per proven recipe.**

---

## Headline

1. **Q2 VARCHAR-EQUALITY-OR-PUSHDOWN CONFIDENT-INACCURACY.** The responder claims that on `SELECT * FROM postgres.public.users WHERE user_id = 123 OR email = 'agent@example.com'`:
   - numeric `user_id = 123` pushes (CORRECT)
   - VARCHAR `email = '...'` does NOT push (**WRONG** — verbatim trino.io/docs/current/connector/postgresql.html: "Equality predicates, such as `IN` or `=`, and inequality predicates, such as `!=` on columns with textual types are pushed down")
   - therefore the full OR does NOT push (**WRONG** — both disjuncts individually push, so the OR pushes as a compound predicate)
   - recommends UNION ALL workaround (NEEDLESS — engineer would split the query for no reason)

   The responder is ALSO **INTERNALLY INCONSISTENT** — says "Postgres DOES push VARCHAR equality" in one breath then later says email equality doesn't push. Resource r22 §13.5A.4's own table says "numeric = OR VARCHAR = (default collation) → PUSHES". This is a load-bearing wrong claim the engineer would act on.

2. **Q1/Q3/Q4 all 4.8125 STRONG.** 3-way cross-catalog JOIN execution location (join always on Trino workers, no cross-catalog join pushdown, each table's predicates push independently to own engine, WHERE event_date pushes to Iceberg partition pruning, EXPLAIN constraint INSIDE TableScan vs Filter above), TO_CHAR/TO_DATE format-mask migration (Joda for format_datetime, MySQL %d/%b/%Y for date_parse, MON→%b, HH24→%H, CAST AS DATE for ISO), and small-file compaction (EXECUTE optimize file_size_threshold, expire_snapshots 30d/7d Trino floor, remove_orphan_files 7d, rewrite_manifests Spark-only in Trino 467 since optimize_manifests landed in Trino 470) — all canonical and verified against trino.io / iceberg.apache.org / docs.getdbt.com.

3. **FEDERATION TOPIC REGRESSES — 4.4944 → 4.4904 (−0.0040).** Q1 4.8125 + Q2 3.0 federation pair averages 3.91, well below topic avg 4.4944, dragging topic DOWN. 26th consecutive iter below 4.5 threshold; now 0.0096 below (vs iter425's 0.0056 below) — FURTHER from crossing. Iter426 erased ~7 iters of prior progress; recovery now requires multiple iters of sustained 4.85+ federation pairs.

4. **NEW failure-mode datapoint — myth-buster zero-confident-inaccuracy streak BREAKS at 1 iter** after iter425's resumed streak. Failure-mode count: 8 of prior 22 iterations.

---

## Critical confirmations (explicit)

### (a) Is Q2 a confident-inaccuracy? + Q2 score

**YES — Q2 IS a confident-inaccuracy. Score: 3.0 FAIL.**

Verification trace:

1. **trino.io/docs/current/connector/postgresql.html (verified 2026-06-04 via WebFetch)** — verbatim text: "Equality predicates, such as `IN` or `=`, and inequality predicates, such as `!=` on columns with textual types are pushed down." VARCHAR EQUALITY IS PUSHED BY DEFAULT.

2. **What does NOT push by default on VARCHAR**: Range predicates (`>`, `<`, `BETWEEN`) and leading-wildcard LIKE. Controlled by experimental flag `postgresql.experimental.enable-string-pushdown-with-collate`. The responder confused VARCHAR EQUALITY (which pushes) with VARCHAR RANGE (which doesn't push).

3. **Resource r22 §13.5A.4's own table** says "numeric = OR VARCHAR = (default collation) → PUSHES". The responder is contradicting BOTH the trino.io docs AND the resource.

4. **CORRECT answer**: Both disjuncts are equality predicates that individually push → the OR PUSHES DOWN to Postgres as a compound predicate (assuming default collation). Postgres receives `WHERE user_id = 123 OR email = 'agent@example.com'` and runs it natively. NO UNION ALL workaround needed.

5. **Internal contradiction**: Responder says "Postgres DOES push VARCHAR equality" in one breath then later says email equality doesn't push. This indicates uncertainty/confused reasoning rather than confident knowledge.

6. **Practical penalty**: Recommended UNION ALL workaround would mislead the SaaS engineer into splitting `WHERE a OR b` queries unnecessarily across many real federation queries — bloating query count, adding latency, and creating maintenance burden.

**Q2 score: 3.0 FAIL (TA 2.0 / BC 4.0 / PA 2.5 / Comp 3.5).** TA 2.0 for the wrong central fact. PA 2.5 for the needless workaround recommendation.

### (b) Federation average after Q1 + Q2 — direction?

**FEDERATION TOPIC REGRESSES.** Math:
- Prior: 4.4944 × 286 datapoints = 1285.4098 sum
- + Q1 4.8125 + Q2 3.0 = +7.8125
- New sum: 1285.4098 + 7.8125 = 1293.2223
- New count: 288
- **New average: 1293.2223 / 288 = 4.4904**

Distance to threshold: 4.5000 − 4.4904 = **0.0096 below 4.5**.

Compared to iter425:
- Iter425: 4.4944, 0.0056 below threshold
- Iter426: 4.4904, 0.0096 below threshold
- **Net change: −0.0040 / FURTHER from crossing by 0.0040 / 26th consecutive iter below threshold / REGRESSES**

This erases ~7 iters of progress at iter425's +0.0022/iter pace. Recovery now requires multiple iters of sustained 4.85+ federation pairs.

### (c) Any other NEW confident-inaccuracy / fabrication / self-contradiction?

**Q2 introduces TWO new failure modes:**

1. **Confident-inaccuracy** — VARCHAR-EQUALITY-OR-PUSHDOWN load-bearing wrong claim (detailed above).

2. **Internal self-contradiction within Q2** — "Postgres DOES push VARCHAR equality" said in one breath, "email equality doesn't push" said later. This mirrors the iter420 TopN-CONFUSION and iter423 SELF-CONTRADICTION patterns.

**Q1/Q3/Q4 contain ZERO new failure modes** — all three answers are canonical and verified accurate:
- Q1: 3-way cross-catalog JOIN — canonical "join always on Trino workers" framing, correct EXPLAIN constraint-INSIDE-TableScan vs Filter-above pattern, no fabrication.
- Q3: TO_CHAR/TO_DATE format-mask — Joda for format_datetime + MySQL for date_parse verified against trino.io/docs/current/functions/datetime.html.
- Q4: small-file compaction — optimize file_size_threshold + 7d Trino floor + rewrite_manifests Spark-only-on-Trino-467 (verified: optimize_manifests landed Trino 470, production is Trino 467) all accurate.

---

## Per-question scoring

### Q1 — 3-way cross-catalog JOIN execution location (Trino federation)

**Scores: 5.0 / 4.75 / 4.75 / 4.75 — avg 4.8125 STRONG PASS**

What landed:
- Join always executes on Trino WORKERS — CORRECT (cross-catalog joins cannot push to either source)
- Postgres connector cannot see Iceberg tables + vice versa — CORRECT (each catalog isolated to own connector API)
- Cross-catalog join pushdown does NOT exist — VERIFIED against trino.io/docs/current/optimizer/pushdown.html "the tables in the join must be from the same catalog"
- Each table's predicates push to its own engine independently — CORRECT (predicate pushdown is per-TableScan)
- WHERE event_date>=... pushes to Iceberg partition pruning / file-skipping — CORRECT
- EXPLAIN constraint INSIDE TableScan = pushed to source, Filter/ScanFilterProject above TableScan = stayed in Trino — CORRECT canonical EXPLAIN signature
- Annotated EXPLAIN tree explanation — CORRECT diagnostic walkthrough

**Verdict:** STRONG PASS — canonical 3-way federation answer.

### Q2 — OR-with-mixed-types predicate pushdown (Trino federation) [CONFIDENT-INACCURACY]

**Scores: 2.0 / 4.0 / 2.5 / 3.5 — avg 3.0 FAIL**

What failed:
- **WRONG**: claims VARCHAR `email = '...'` equality does NOT push to Postgres → therefore the full OR does NOT push → recommends UNION ALL workaround
- **CORRECT FACT**: trino.io/docs/current/connector/postgresql.html "Equality predicates, such as IN or =, and inequality predicates, such as != on columns with textual types are pushed down" — VARCHAR EQUALITY PUSHES BY DEFAULT
- **CORRECT FACT**: only VARCHAR RANGE (`<`, `>`, `BETWEEN`) and leading-wildcard LIKE do NOT push by default (controlled by postgresql.experimental.enable-string-pushdown-with-collate)
- **CORRECT FACT**: Resource r22 §13.5A.4's own table line shows "numeric = OR VARCHAR = (default collation) → PUSHES"
- **CORRECT ANSWER**: Both disjuncts are equality predicates that individually push → the OR PUSHES DOWN to Postgres as a compound predicate (assuming default collation). NO UNION ALL workaround needed.
- **INTERNAL CONTRADICTION**: "Postgres DOES push VARCHAR equality" said in one breath, "email equality doesn't push" later

**TA penalty 2.0** for getting the central fact wrong against both docs AND resource. **PA penalty 2.5** for needless UNION ALL workaround recommendation. BC 4.0 for clear explanation despite wrong conclusion. Comp 3.5 covers the surface area but core conclusion is wrong.

**Verdict:** FAIL — LOAD-BEARING WRONG CLAIM the engineer would act on; ELEVENTH structural-fix opportunity.

### Q3 — Oracle TO_CHAR/TO_DATE format-mask migration (Oracle PL/SQL → dbt+Trino migration 4th angle)

**Scores: 5.0 / 4.75 / 4.75 / 4.75 — avg 4.8125 STRONG PASS**

What landed:
- Oracle and Trino format strings DIFFER, must rewrite at translation time — CORRECT
- TO_CHAR(ts, 'YYYY-MM-DD HH24:MI:SS') → format_datetime(ts, 'yyyy-MM-dd HH:mm:ss') Joda — VERIFIED against trino.io/docs/current/functions/datetime.html "The functions in this section use a format string that is compatible with JodaTime's DateTimeFormat pattern format"
- TO_DATE('10/JAN/2026', 'DD/MON/YYYY') → date_parse('10/Jan/2026', '%d/%b/%Y') MySQL — VERIFIED "compatible with the MySQL date_parse and str_to_date functions"
- Oracle YYYY→yyyy, MM→MM, DD→dd, HH24→HH, MI→mm, SS→ss (Joda for format_datetime) — CORRECT
- Oracle YYYY→%Y, MM→%m, DD→%d, HH24→%H, MI→%i, SS→%s, MON→%b (MySQL for date_parse) — CORRECT
- MON→%b abbreviated month name — CORRECT
- CAST(s AS DATE) for ISO-format string '2026-05-30' — CORRECT
- Concrete before/after rewrites with examples — CORRECT

**Verdict:** STRONG PASS — comprehensive format-mask migration coverage with both function families and pattern syntaxes correctly enumerated.

### Q4 — Iceberg small-file compaction (Iceberg table maintenance)

**Scores: 5.0 / 4.75 / 4.75 / 4.75 — avg 4.8125 STRONG PASS**

What landed:
- Tiny-file buildup is real — CORRECT (impacts planning latency + query latency + storage overhead)
- ALTER TABLE EXECUTE optimize(file_size_threshold=>'128MB') — VERIFIED against trino.io/docs/current/connector/iceberg.html "All files with a size below the optional file_size_threshold parameter (default value 100MB) are merged"
- expire_snapshots(retention_threshold=>'30d') with Trino 7d minimum-retention floor via iceberg.expire-snapshots.min-retention — VERIFIED
- remove_orphan_files(retention_threshold=>'7d') — CORRECT
- **rewrite_manifests Spark-only in Trino 467** — VERIFIED (Trino's optimize_manifests landed in Trino 470 per release-470.html 5 Feb 2025; production is Trino 467 → manifest rewrite remains Spark-only)
- Recommended ORDER: optimize → expire_snapshots → remove_orphan_files → rewrite_manifests — CORRECT
- ATOMIC commit semantics — readers see old snapshot during compaction, no offline window — CORRECT (Iceberg atomic metadata swap)
- ZERO data loss — CORRECT
- Cadence nightly compact / weekly expire+orphan, manifests-if-needed — CORRECT

**Verdict:** STRONG PASS — canonical small-file compaction workflow with accurate Trino 467 engine-version disambiguation.

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.8125 | Trino federation (3-way cross-catalog JOIN execution location) | STRONG PASS — join always on Trino workers, no cross-catalog join pushdown, each table's predicates push independently, EXPLAIN constraint-INSIDE vs Filter-above |
| Q2 | **3.0** | Trino federation (OR-with-mixed-types pushdown) | **FAIL — VARCHAR-EQUALITY-OR-PUSHDOWN confident-inaccuracy contradicting trino.io docs AND resource r22 §13.5A.4 + internal contradiction + needless UNION ALL workaround** |
| Q3 | 4.8125 | Oracle PL/SQL → dbt+Trino migration (TO_CHAR/TO_DATE 4th angle) | STRONG PASS — Joda for format_datetime, MySQL %d/%b/%Y for date_parse, MON→%b, HH24→%H, CAST AS DATE for ISO |
| Q4 | 4.8125 | Iceberg table maintenance (small-file compaction) | STRONG PASS — EXECUTE optimize file_size_threshold, expire_snapshots 30d/7d floor, remove_orphan_files 7d, rewrite_manifests Spark-only-on-Trino-467 |

**Average 4.3594 PASS — twenty-fifth consecutive overall PASS in extended phase but −0.4531 step-DOWN from iter425 4.8125 driven entirely by Q2 FAIL.**

**Headline outcomes:**
- Q2 VARCHAR-EQUALITY-OR-PUSHDOWN CONFIDENT-INACCURACY — first federation confident-inaccuracy since iter424; ELEVENTH structural-fix opportunity per proven recipe.
- Q2 INTERNAL CONTRADICTION mirrors iter420 TopN-CONFUSION and iter423 SELF-CONTRADICTION patterns.
- FEDERATION TOPIC REGRESSES 4.4944 → 4.4904 (−0.0040); 26th consecutive iter below threshold; now 0.0096 below — FURTHER from crossing; erased ~7 iters of iter425 progress.
- Q1/Q3/Q4 all 4.8125 STRONG — solid showing on 3-way cross-catalog JOIN + TO_CHAR/TO_DATE + small-file compaction.
- Oracle PL/SQL migration topic 4.7917/3 → 4.7969/4 STRONG sustains 4th-angle reinforcement.
- Iceberg table maintenance 4.4320/92 → 4.4361/93 (+0.0041 nudge UP).

**Failure-mode count: 8 of prior 22 iterations** (iter426 introduces a new confident-inaccuracy datapoint — VARCHAR-equality-OR-pushdown).

---

## Teacher actions next (iter 427)

1. **HIGH — r22 §13.5A.4 VARCHAR-EQUALITY-OR-PUSHDOWN GUARDRAIL.** Install following the proven iter418/420/421/422/424/425 structural-fix pattern:
   - **(a) DO-NOT-WRITE table** banning the claim "VARCHAR equality does NOT push down to PostgreSQL". The correct rule is: VARCHAR EQUALITY PUSHES BY DEFAULT — verbatim trino.io/docs/current/connector/postgresql.html "Equality predicates, such as IN or =, and inequality predicates, such as != on columns with textual types are pushed down". Only VARCHAR RANGE (`<`, `>`, `BETWEEN`) and leading-wildcard LIKE do NOT push by default (controlled by `postgresql.experimental.enable-string-pushdown-with-collate`).
   - **(b) DO-NOT-WRITE callout** banning the "OR of mixed-type equalities does not push" claim — both disjuncts individually push → the OR pushes as a compound predicate to Postgres.
   - **(c) DO-NOT-RECOMMEND callout** banning the UNION ALL workaround as a default — only recommend UNION ALL split when one side is genuinely non-pushdownable (e.g., range on VARCHAR or function-wrapped column like `LOWER(email) = '...'`).
   - **(d) Explicit example**: `WHERE user_id = 123 OR email = 'a@b.com'` → BOTH push to Postgres → single TableScan with composite filter, NO UNION ALL needed.
   - **(e) Self-contradiction guard**: r22 §13.5A.4 should open with a one-line answer template that forces the responder to commit BEFORE elaborating — banning the "DOES push... doesn't push" oscillation pattern.
   - **(f) Name iter426 Q2 failure mode explicitly** in the GUARDRAIL block to make the fix sticky.

2. **LOW — Q1/Q3/Q4 content sustained STRONG.** No structural changes needed for 3-way cross-catalog JOIN, TO_CHAR/TO_DATE, or small-file compaction.

3. **HIGH — Federation topic** at 4.4904 / 0.0096 below threshold; 26th consecutive iter below. Recovery now requires multiple iters of sustained 4.85+ federation pairs to recover from the −0.0040 regression; iter426 lost ~7 iters of prior progress.

4. **LOW — Carry-forward backlog**: HMS→Nessie write-freeze; Snapshot vs serializable phantom-row 3rd-angle; Window NULL 2nd-angle; Iceberg concurrency 4th-angle commit.retry exhaustion; OPA-override timeout; schema registry compat; JWT+OPA concurrency.

---

## Judge probe targets next (iter 427)

1. **HIGH — Federation OR-with-mixed-types 2nd-angle RE-PROBE** (validate iter427 VARCHAR-EQUALITY-OR-PUSHDOWN GUARDRAIL fix lands): "Does `WHERE category = 'A' OR order_id = 12345` push down to Postgres? Walk me through what each disjunct does and what the EXPLAIN should show." (Forces correct VARCHAR-equality-pushes framing).

2. **HIGH — Federation HAVING pushdown 2nd-angle** (most underexplored federation angle, still needed to push topic toward 4.5): "Does `HAVING SUM(amount) > 1000` after a GROUP BY push to Postgres? When does Trino keep HAVING in the engine vs send it to the source?"

3. **MEDIUM — Federation function-wrapped predicate** carry-forward contrast: "Does `WHERE LOWER(email) = 'a@b.com'` push?" — to contrast with naked equality so the responder explicitly distinguishes naked-VARCHAR-equality (pushes) from function-wrapped (doesn't push).

4. **MEDIUM — Iceberg branches-tag-expire 4th-angle / concurrency commit.retry exhaustion** carry-forward.

5. **MEDIUM — SQL best practices** (window function NULL handling 2nd-angle, QUALIFY rewrite).

---

## Critical message to teacher for iter 427: VARCHAR-equality-OR-pushdown structural fix

The iter426 result is a **PASS with a load-bearing confident-inaccuracy on Q2** that contradicts BOTH the trino.io connector docs AND the resource's own §13.5A.4 table. The fix recipe is well-established — iter418/420/421/422/424/425 GUARDRAILS all landed via the same DO-NOT-WRITE + DO-NOT-RECOMMEND + explicit-example structure.

**The proven structural-fix recipe has now had ELEVEN failure-mode classes:**
- iter407→408 (?)
- iter411→412 (?)
- iter413→414 (?)
- iter414→415 (?)
- iter418 ENGINE-CONFUSION GUARDRAIL
- iter420 API-CONFUSION GUARDRAIL
- iter421 TopN-CONFUSION GUARDRAIL
- iter422 LIKE-CONFUSION GUARDRAIL
- iter424 AGGREGATION-PUSHDOWN GUARDRAIL
- iter425 FABRICATED-RULE-NAMES + PARTITION-FILTER-TERMINOLOGY GUARDRAIL
- iter426 **VARCHAR-EQUALITY-OR-PUSHDOWN GUARDRAIL** (this iteration's TODO fix)

**Federation topic at 4.4904 / 0.0096 below threshold — FURTHER from crossing in 4 iters.** The 26-iter below-threshold streak continues. Path to crossing: 3+ iters of sustained 4.85+ federation pairs to recover the −0.0040 regression plus the original 0.0056 gap.

**Iter427 should focus on:**
(1) Installing the VARCHAR-EQUALITY-OR-PUSHDOWN GUARDRAIL in r22 §13.5A.4 — high priority structural fix
(2) Re-probing OR-with-mixed-types 2nd-angle to validate the fix lands
(3) HAVING pushdown 2nd-angle to push federation topic toward 4.5

The teacher should focus on the §13.5A.4 GUARDRAIL with both DO-NOT-WRITE (banning the wrong claims) and explicit-example (the canonical correct answer). The internal-contradiction pattern (responder oscillating between "DOES push" and "doesn't push") suggests adding a self-contradiction guard at the section open.

**The pattern across iter402-426:**
- Bulletproofed content delivers 4.75+ on the targeted angle (Q1/Q3/Q4 all 4.8125 this iter validate this)
- Recovery within one iteration via structural fix is the durable strategy
- New failure modes appear in unexplored angles — iter426 found OR-with-mixed-types
- Federation topic now 0.0096 below the 4.5 threshold; the density wall remains real at 288 datapoints and the trend regresses
