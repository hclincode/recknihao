# Judge Feedback — Iter 429 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.609 PASS** (Q1 4.5625 + Q2 4.875 + Q3 4.8125 + Q4 4.1875) — **−0.250 step-DOWN from iter428 4.859**. Twenty-eighth consecutive overall PASS in extended phase, but the **zero-confident-inaccuracy streak BREAKS at 2 iters**. **One NEW confident inaccuracy in Q4** (Trino does not support `ALTER COLUMN SET NOT NULL`). **One terminology imprecision in Q1** (LIMIT pushdown mislabeled as Top-N pushdown; the new §13.5A.5 guardrail did not surface). **Federation topic NUDGES UP a hair: 4.4937 → 4.4939 (+0.0002)**, 29th consecutive iter below 4.5 threshold, still 0.0061 below.

---

## Headline

1. **Q1 LIMIT pushdown — TERMINOLOGY IMPRECISION (4.5625 PASS but DOWN from iter428's 4.875 ceiling).** Behavioral answer is CORRECT: LIMIT pushes to Postgres, Postgres stops at 1000 rows, ~1000 rows cross the JDBC wire, Trino does NOT pull 200M rows; keyset-pagination guidance is sound; EXPLAIN signature `limit=1000` inside TableScan is correct for LIMIT pushdown. BUT the responder labeled this as **"TopN pushdown"** and claimed **"fires by default since release 354"** — these phrasings belong to **Top-N pushdown** (ORDER BY + LIMIT), which is a DIFFERENT capability per trino.io/docs/current/optimizer/pushdown.html. The PostgreSQL connector docs list Limit pushdown and Top-N pushdown as TWO SEPARATE capabilities. The teacher's new r22 §13.5A.5 LIMIT-WITHOUT-ORDER-BY GUARDRAIL exists precisely to prevent this conflation — and it did NOT surface in the responder's answer. **Not a behavioral error, not a fabrication, but the precise term is "Limit pushdown" not "TopN pushdown" for the question's plain `LIMIT 1000` shape with no ORDER BY.** Engineer still learns correct behavior; this is a TA precision dock only.

2. **Q2 ROWNUM → OFFSET/keyset pagination CLEAN (4.875 STRONG).** OFFSET 50 LIMIT 50 direct translation, OFFSET-pushdown-limited caveat, keyset/cursor pattern `WHERE event_id > :last_seen ORDER BY event_id LIMIT 50` correctly identified as the scale pattern (uses index, no O(N) skip). All verified per Trino SQL + Postgres docs. Oracle PL/SQL migration topic continues to be canonical.

3. **Q3 COUNT(DISTINCT) → approx_distinct STRONG (4.8125).** All technical figures verified: **2.3% standard error VERIFIED** per trino.io/docs/current/functions/aggregate.html — exact quote "This function should produce a standard error of 2.3%". `approx_set` / `merge` / `cardinality` HyperLogLog functions VERIFIED per trino.io/docs/current/functions/hyperloglog.html. `CAST(approx_set(user_id) AS varbinary)` for sketch-table storage VERIFIED per docs ("Data sketches can be serialized to and deserialized from `varbinary`"). 10-50x faster claim is reasonable industry rule of thumb. COUNT(DISTINCT) multi-shuffle cost reasoning correct. Sketch table pattern (varbinary on write / HyperLogLog on read because Iceberg has no HLL type) correct.

4. **Q4 ADD COLUMN — NEW CONFIDENT INACCURACY (4.1875 PASS, but failure-mode iter).** ADD COLUMN metadata-only, NULL for old rows, no rewrite, field-IDs-not-name-matching all CORRECT (Iceberg spec). **BUT: the responder recommends `ALTER COLUMN SET NOT NULL` as the final step in the nullable→backfill→tighten pattern. Trino does NOT support `ALTER COLUMN SET NOT NULL`.** Per trino.io/docs/current/sql/alter-table.html, the supported ALTER COLUMN ops are: `SET DEFAULT`, `DROP DEFAULT`, `SET DATA TYPE`, `DROP NOT NULL`. There is no `SET NOT NULL`. An engineer following this advice would hit a SQL parser/semantic error on Trino 467. The MERGE INTO self-referencing backfill is sound; the safety-gate gist is correct conceptually; but the precise syntax recommended does not exist in Trino. **This is a NEW confident inaccuracy that breaks the 2-iter zero-inaccuracy streak.**

---

## Critical confirmations (explicit)

### (a) Q1 score + Limit-vs-TopN terminology assessment + federation average + direction + crosses 4.5?

**Q1 score: 4.5625 PASS.** TA 4.25 / Clarity 4.75 / Practical 4.75 / Completeness 4.5.

**Limit-vs-TopN terminology assessment:** The responder's answer mislabeled the operation as "TopN pushdown" and dated the default-on to "release 354" — both phrasings actually describe Top-N pushdown (ORDER BY + LIMIT), not Limit pushdown (plain LIMIT, no ORDER BY). Per the verified docs:
- trino.io/docs/current/optimizer/pushdown.html: "Limit pushdown enables a connector to push processing of such queries of **unsorted record** to the underlying data source." vs "The combination of a LIMIT or FETCH FIRST clause with an **ORDER BY clause**" for Top-N pushdown.
- trino.io/docs/current/connector/postgresql.html lists Limit pushdown and Top-N pushdown as TWO SEPARATE capabilities.
- The release-354 default-on actually refers to Top-N pushdown (`topn-pushdown.enabled` config; release notes about ORDER BY + LIMIT with char/varchar correctness fix).

**This is a terminology imprecision, NOT a behavioral error and NOT a fabrication.** The behavioral answer (Postgres stops at 1000, only 1000 rows cross the wire, Trino does not pull the full table) is fully correct. The EXPLAIN signature `limit=1000` inside TableScan is the right success signal for LIMIT pushdown. Keyset pagination guidance is sound.

**However**: the teacher's iter429 §13.5A.5 LIMIT-WITHOUT-ORDER-BY GUARDRAIL — added precisely to prevent the Limit-pushdown-vs-Top-N-pushdown conflation — did NOT surface in this answer. The responder still defaulted to the older "TopN pushdown" labeling. **This is a findability/discoverability issue, not a structural-correctness issue** in §13.5A.5 itself — the section content is correct; the responder just didn't find it.

**Federation average after Q1 4.5625 datapoint:**
- Prior: 4.4937 × 290 = 1303.173 sum
- + Q1 4.5625 = +4.5625
- New sum: 1307.7355
- New count: 291
- **New average: 1307.7355 / 291 = 4.4939**

Distance to threshold: 4.5000 − 4.4939 = **0.0061 below 4.5**.

Compared to iter428:
- Iter428: 4.4937, 0.0063 below threshold
- Iter429: 4.4939, 0.0061 below threshold
- **Net change: +0.0002 / 0.0002 closer to threshold / 29th consecutive iter below threshold / DIRECTION marginally UP for 3rd consecutive iter but DECELERATING (+0.0020 last iter, +0.0002 this iter)**

**Crosses 4.5?** NO. The Q1 4.5625 is below the threshold itself, so it dragged the running average down toward the 4.5 line rather than pushing it up. To cross 4.5 the federation answers need to consistently land 4.85+. The terminology imprecision cost roughly 0.31 on this Q1 datapoint vs the iter428 4.875 benchmark.

### (b) Any NEW confident-inaccuracy / new failure mode?

**YES — ONE new confident inaccuracy in Q4. Zero-inaccuracy streak BREAKS at 2 iters.**

**Q4 NEW INACCURACY — `ALTER COLUMN SET NOT NULL` is NOT supported on Trino 467.**
- Per trino.io/docs/current/sql/alter-table.html, supported ALTER COLUMN ops are: `SET DEFAULT`, `DROP DEFAULT`, `SET DATA TYPE`, `DROP NOT NULL`. **There is NO `SET NOT NULL` operation in Trino.**
- The Iceberg connector docs (trino.io/docs/current/connector/iceberg.html) confirm `NOT NULL` can only be set "while creating tables by using the CREATE TABLE syntax" — not via ALTER.
- An engineer following the responder's advice would hit a parser/semantic error trying to run `ALTER TABLE ... ALTER COLUMN ... SET NOT NULL` on Trino 467.
- The conceptual safety-gate intent (validate no nulls before tightening) is sound, but the precise SQL syntax recommended does not exist.
- The MERGE INTO self-referencing backfill (`MERGE INTO t USING t ...` or with a derived source) is broadly supported on Trino Iceberg, though a simpler `UPDATE t SET col='unknown' WHERE col IS NULL` would be cleaner.

**No other new failure modes** — Q2 and Q3 are clean.

**This is a SCHEMA-EVOLUTION-CONSTRAINT-TIGHTENING gap** — a new failure-mode class to add to the bulletproofing recipe.

### (c) Q3 figure verification

- **2.3% standard error**: VERIFIED per trino.io/docs/current/functions/aggregate.html exact quote "This function should produce a standard error of 2.3%, which is the standard deviation of the (approximately normal) error distribution over all possible sets."
- **approx_set / merge / cardinality**: VERIFIED per trino.io/docs/current/functions/hyperloglog.html — all three functions documented exactly as described.
- **CAST to varbinary on write / HyperLogLog on read for sketch tables**: VERIFIED per trino.io/docs/current/functions/hyperloglog.html quote "Data sketches can be serialized to and deserialized from `varbinary`" + example `cast(approx_set(user_id) AS varbinary)`.
- **10-50x faster than COUNT(DISTINCT)**: industry rule of thumb, not in official docs, not fabricated.
- **COUNT(DISTINCT) multi-shuffle cost**: correct conceptually (per-distinct-column shuffle + per-group memory).

All Q3 figures CONFIRMED. No inaccuracy.

### (d) Q2 keyset pagination verification

- **OFFSET N LIMIT M direct translation**: works on Trino but OFFSET is generally NOT pushed down to Postgres reliably (workers fetch + discard). CORRECT.
- **Keyset/cursor `WHERE event_id > :last_seen ORDER BY event_id LIMIT N`**: scales because the predicate pushes down (b-tree index seek on Postgres), the LIMIT pushes down, no O(N) skip. CORRECT canonical pattern.
- **Tradeoff: track cursor not row offset**: CORRECT — clients must persist the last seen ID instead of the page number.

All Q2 claims CONFIRMED.

---

## Per-question scoring

### Q1 — LIMIT-without-ORDER-BY pushdown (Trino federation)

**Scores: 4.25 / 4.75 / 4.75 / 4.5 — avg 4.5625 PASS**

What landed:
- Trino pushes LIMIT to Postgres, Postgres stops at 1000, ~1000 cross the wire — CORRECT BEHAVIOR
- EXPLAIN signature `limit=1000` inside TableScan = pushed — CORRECT
- Separate Limit operator above bare TableScan = failed pushdown — CORRECT
- Exceptions (ORDER BY computed expr, multi-table, OFFSET, non-default collation) — CORRECT
- Keyset pagination `WHERE created_at < :ts ORDER BY ... LIMIT` — sound

What was imprecise:
- Labeled as "TopN pushdown" — should be "Limit pushdown" per trino.io (Top-N = ORDER BY + LIMIT, distinct capability)
- "Fires by default since release 354" — release 354 is the Top-N pushdown default-on milestone, not Limit pushdown
- New r22 §13.5A.5 LIMIT-WITHOUT-ORDER-BY guardrail did NOT surface (findability issue)
- Mention of "any ORDER BY pushed" conflates the question's plain LIMIT shape with the Top-N case

**Verdict:** PASS with terminology imprecision. Behavioral guidance is correct, engineer still learns the right thing operationally, but the Trino-precise vocabulary "Limit pushdown vs Top-N pushdown" did not land. TA dock from 5.0 to 4.25.

### Q2 — ROWNUM → keyset pagination (Oracle PL/SQL migration)

**Scores: 5.0 / 4.75 / 4.75 / 5.0 — avg 4.875 STRONG PASS**

What landed:
- Trino has no direct ROWNUM equivalent — CORRECT
- OFFSET N LIMIT M direct translation, OFFSET less reliable for pushdown (scans+discards on Trino workers) — CORRECT
- Keyset pagination `WHERE event_id > :last_seen ORDER BY event_id LIMIT 50` pushes predicate + limit, uses b-tree index, scales any offset, no O(N) skip — CORRECT canonical
- Client tradeoff: track cursor not row offset — CORRECT

**Verdict:** STRONG PASS — Oracle migration topic continues to be canonical.

### Q3 — COUNT(DISTINCT) → approx_distinct (SQL best practices for OLAP)

**Scores: 4.75 / 4.75 / 4.75 / 5.0 — avg 4.8125 STRONG PASS**

What landed:
- COUNT(DISTINCT) slow because of per-distinct-column shuffle + per-group memory + multiple-distincts multiplying shuffles — CORRECT
- approx_distinct() HyperLogLog ~2.3% std error — VERIFIED per trino.io aggregate functions docs
- 10-50x faster — reasonable industry rule of thumb, not fabricated
- Dashboards fine, exact only for billing — CORRECT trade-off framing
- Nightly sketch table approx_set + merge + cardinality — VERIFIED per trino.io HyperLogLog functions
- CAST to varbinary on write / HyperLogLog on read because Iceberg has no HLL type — VERIFIED
- All technical figures accurate, no fabrication

**Verdict:** STRONG PASS — sketch-table pattern is the canonical advanced answer.

### Q4 — ADD COLUMN schema evolution (Lakehouse schema design)

**Scores: 3.5 / 4.75 / 3.75 / 4.75 — avg 4.1875 PASS (lowest of iter)**

What landed:
- ADD COLUMN returns NULL on old rows, no error, no rewrite — CORRECT
- Metadata-only, ms even on 10TB — CORRECT
- Field-IDs not name-matching (Iceberg schema-evolution semantics) — CORRECT
- Cannot add NOT NULL in one step (must do nullable + backfill + tighten) — CORRECT INTENT
- Backfill via MERGE INTO self-join with 'unknown' default — sound conceptually

What is INACCURATE:
- **Recommended `ALTER COLUMN SET NOT NULL` as the final tightening step — Trino does NOT support `SET NOT NULL`**. Per trino.io/docs/current/sql/alter-table.html supported ALTER COLUMN ops are: `SET DEFAULT`, `DROP DEFAULT`, `SET DATA TYPE`, `DROP NOT NULL`. There is NO `SET NOT NULL`. The Iceberg connector docs confirm NOT NULL can only be set at CREATE TABLE time.
- An engineer following this advice runs into a SQL parser/semantic error on Trino 467.
- The simpler MERGE backfill could be `UPDATE t SET col='unknown' WHERE col IS NULL` — also sound.

**Verdict:** PASS but failure-mode iter. The Iceberg schema-evolution metadata-only / NULL-on-old-rows / field-ID core is correct, but the final tightening step recommends a syntax Trino does not support. TA 3.5 reflects a confident inaccuracy on a load-bearing syntax claim; Practical 3.75 reflects that the engineer hits an error.

---

## Topic-score updates

| Topic | Before | After | Delta | Status |
|---|---|---|---|---|
| Trino federation / cross-source connectors | 4.4937 / 290 | 4.4939 / 291 | +0.0002 | NEEDS WORK (0.0061 below 4.5 raised threshold; 29th consecutive iter below; direction marginally UP 3rd consecutive iter but decelerating) |
| Oracle PL/SQL → dbt + Trino SQL migration | 4.8021 / 6 | 4.8125 / 7 | +0.0104 | PASSED |
| SQL query best practices for OLAP | 4.5286 / 33 | 4.5369 / 34 | +0.0083 | PASSED |
| Lakehouse schema design | 4.6458 / 6 | 4.5803 / 7 | −0.0655 | PASSED (Q4 dragged it down meaningfully but still above 3.5 threshold) |

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.5625 | Trino federation (LIMIT pushdown / plain LIMIT no ORDER BY) | PASS — behavioral answer correct, terminology imprecision (Limit pushdown mislabeled as TopN pushdown); new r22 §13.5A.5 guardrail did NOT surface |
| Q2 | 4.875 | Oracle PL/SQL migration (ROWNUM → OFFSET / keyset pagination) | STRONG PASS — canonical |
| Q3 | 4.8125 | SQL best practices for OLAP (COUNT DISTINCT → approx_distinct, sketch tables) | STRONG PASS — all figures verified, sketch-table pattern canonical |
| Q4 | 4.1875 | Lakehouse schema design (ADD COLUMN schema evolution) | PASS — NEW CONFIDENT INACCURACY: `ALTER COLUMN SET NOT NULL` not supported on Trino 467 |

**Average 4.609 PASS — twenty-eighth consecutive overall PASS in extended phase; −0.250 step-DOWN from iter428 4.859.**

**Headline outcomes:**
- Q1 LIMIT pushdown — TERMINOLOGY IMPRECISION (Limit mislabeled as TopN); behavioral answer correct
- Q4 ADD COLUMN — NEW CONFIDENT INACCURACY (`SET NOT NULL` not supported on Trino 467); breaks 2-iter zero-inaccuracy streak
- Federation 4.4937 → 4.4939 (+0.0002 marginal UP, but Q1 4.5625 deceleration; 29th consecutive iter below threshold)
- Oracle migration 4.8021/6 → 4.8125/7 (+0.0104 UP)
- SQL best practices for OLAP 4.5286/33 → 4.5369/34 (+0.0083 UP)
- Lakehouse schema design 4.6458/6 → 4.5803/7 (−0.0655 DOWN, Q4 inaccuracy)

**Failure-mode count: 9 of prior 25 iterations** (iter429 introduces 1 new failure-mode class: SCHEMA-EVOLUTION-CONSTRAINT-TIGHTENING — `SET NOT NULL` is not Trino SQL).

---

## Teacher actions next (iter 430)

1. **HIGH — Add new SCHEMA-EVOLUTION-CONSTRAINT-TIGHTENING GUARDRAIL.** Document explicitly in the Iceberg schema evolution resource (likely resources/14 or wherever ADD COLUMN is covered) the precise list of Trino ALTER COLUMN operations: `SET DEFAULT` / `DROP DEFAULT` / `SET DATA TYPE` / `DROP NOT NULL`. State explicitly: **Trino 467 does NOT support `ALTER COLUMN ... SET NOT NULL`** — you cannot tighten an existing nullable column to NOT NULL via ALTER. The only way to get a NOT NULL constraint is at CREATE TABLE time. Workarounds for the "tighten after backfill" pattern: (a) CTAS new table with NOT NULL in CREATE TABLE then swap, or (b) accept nullable in Iceberg and enforce non-null via dbt test / app-layer validation. Cite trino.io/docs/current/sql/alter-table.html (operation list) and trino.io/docs/current/connector/iceberg.html (NOT NULL only at CREATE TABLE). DO-NOT-WRITE entry: `ALTER TABLE ... ALTER COLUMN ... SET NOT NULL` (does not exist in Trino).

2. **HIGH — Improve findability of r22 §13.5A.5 LIMIT-WITHOUT-ORDER-BY GUARDRAIL.** The section content is correct, but the responder did not surface it for a plain `SELECT ... LIMIT 1000` question. Consider:
   - Add an explicit Q-pattern matcher at the top of §13.5A.5: "If the user asks about plain `SELECT ... LIMIT N` with NO ORDER BY, the answer is **Limit pushdown** — NOT Top-N pushdown."
   - Add a leading "When to cite this section" decision-tree row to the §13.5A header.
   - Consider promoting the Limit-pushdown-vs-Top-N-pushdown distinction to a top-of-r22 canonical glossary entry so the responder hits it before defaulting to "TopN pushdown."

3. **LOW — Carry-forward backlog (mostly unchanged from iter428)**:
   - HMS→Nessie write-freeze
   - Snapshot vs serializable phantom-row 3rd-angle
   - Window NULL 2nd-angle
   - Iceberg concurrency 5th-angle (commit.retry exhaustion behavior)
   - OPA-override timeout
   - Schema registry compat
   - JWT+OPA concurrency
   - Federation HAVING pushdown 2nd-angle
   - Federation function-wrapped predicate contrast (LOWER/COALESCE-wrapped column)

4. **LOW — No structural changes needed** to r27 §7A.3.1 (CONCAT/||), §13.5A.4 (VARCHAR-equality), §13.5A.5 (Limit-vs-TopN content). The structural fixes are correct — the §13.5A.5 findability issue is a navigation/discoverability problem, not a content problem.

---

## Judge probe targets next (iter 430)

1. **HIGH — Re-probe LIMIT pushdown plain (no ORDER BY) on a different question framing** — to verify the new §13.5A.5 findability improvements actually land the "Limit pushdown" terminology over "TopN pushdown". A 2nd-angle test: "If I run `SELECT * FROM app_pg.public.events LIMIT 500` with no ORDER BY, what does EXPLAIN show and what gets called?" — looking for the responder to say "Limit pushdown" not "Top-N pushdown" + cite trino.io's two-distinct-capabilities list.

2. **HIGH — Re-probe ADD COLUMN NOT NULL tightening** — to verify the new SCHEMA-EVOLUTION-CONSTRAINT-TIGHTENING GUARDRAIL lands. A re-ask of the iter429 Q4 angle: "How do I add a NOT NULL column to an Iceberg table?" — looking for the responder to say "you can't tighten via ALTER; either CTAS-swap or enforce via dbt test."

3. **HIGH — Federation HAVING pushdown 2nd-angle** (carry-forward, still un-asked): "Does `HAVING SUM(amount) > 1000` after a GROUP BY push to Postgres?"

4. **MEDIUM — Federation function-wrapped predicate contrast** (carry-forward): "Does `WHERE LOWER(email) = 'a@b.com'` push?"

5. **MEDIUM — Iceberg schema evolution column-type widening** — INTEGER→BIGINT, REAL→DOUBLE, DECIMAL precision-widen — distinct from NOT NULL tightening, also a schema-evolution sub-topic.

6. **MEDIUM — Iceberg concurrency 5th-angle** (carry-forward): commit.retry.num-retries exhaustion behavior.

7. **LOW — Federation TOP-N pushdown with ORDER BY** — pair Q1 with an actual TopN question to test both terms side-by-side, e.g., "What about `SELECT ... ORDER BY created_at DESC LIMIT 100`?"

---

## Critical message to teacher for iter 430

Iter429 is a step-DOWN PASS (4.609 vs iter428's 4.859) driven by two distinct issues:

**Issue 1: Q4 ALTER COLUMN SET NOT NULL — confident inaccuracy on Trino syntax.** This is a NEW failure-mode class (SCHEMA-EVOLUTION-CONSTRAINT-TIGHTENING). Trino 467 does NOT support `ALTER COLUMN ... SET NOT NULL` — only `DROP NOT NULL` is supported per trino.io/docs/current/sql/alter-table.html. NOT NULL constraints can only be set at CREATE TABLE time on Iceberg per trino.io/docs/current/connector/iceberg.html. The conceptual intent (nullable + backfill + tighten) is sound, but the recommended SQL syntax does not exist on Trino. An engineer following this advice hits a parser/semantic error. **The teacher needs to add a guardrail listing the four supported ALTER COLUMN ops (`SET DEFAULT` / `DROP DEFAULT` / `SET DATA TYPE` / `DROP NOT NULL`) and explicitly DO-NOT-WRITE `SET NOT NULL`, with CTAS-swap or dbt-test-enforcement as the documented workarounds.**

**Issue 2: Q1 LIMIT pushdown terminology — new §13.5A.5 didn't surface.** The teacher's iter429 §13.5A.5 LIMIT-WITHOUT-ORDER-BY GUARDRAIL is structurally correct (verified verbatim against trino.io/docs/current/optimizer/pushdown.html and the PG connector docs). But the responder still defaulted to "TopN pushdown" labeling and the release-354 phrasing that belongs to Top-N pushdown. **This is a findability problem, not a content problem.** The teacher needs to make §13.5A.5 more discoverable from a plain-LIMIT question pattern — maybe via a top-of-section Q-pattern matcher or a top-of-r22 canonical glossary entry distinguishing Limit pushdown vs Top-N pushdown.

**Note: the zero-confident-inaccuracy streak breaks at 2 iters.** The 12-instance structural-fix-within-one-iteration recipe still works; the answer is to land the 13th GUARDRAIL (SCHEMA-EVOLUTION-CONSTRAINT-TIGHTENING) before iter430's re-probe, plus a findability improvement on §13.5A.5.

**Federation topic moved +0.0002 to 4.4939, still 0.0061 below threshold.** The Q1 4.5625 is a deceleration vs the iter428 4.875 — the terminology imprecision cost roughly 0.31 on this datapoint. With improved §13.5A.5 findability + the Limit-vs-TopN distinction surfacing on the next federation question, recovery can resume at the iter427/iter428 rate.

**Iter430 should focus on:**
(1) Add SCHEMA-EVOLUTION-CONSTRAINT-TIGHTENING GUARDRAIL (Q4 inaccuracy fix)
(2) Improve r22 §13.5A.5 findability for plain-LIMIT questions (Q1 terminology fix)
(3) Re-probe both Q1 LIMIT-pushdown and Q4 ADD-COLUMN-NOT-NULL on dedicated re-asks to verify both fixes land
(4) Continue carry-forward federation HAVING pushdown / function-wrapped predicate angles to grind federation topic toward 4.5
