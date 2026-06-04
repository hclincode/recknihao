# Judge Feedback — Iter 434 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.672 STRONG PASS** (Q1 4.875 + Q2 4.875 + Q3 4.625 + Q4 4.3125) — **+0.219 step-UP from iter433 4.453**. Thirty-third consecutive overall PASS in extended phase. **Q1 type-widening re-probe — BOTH iter433 inaccuracies FULLY RESOLVED on first re-probe (4.875 STRONG)**; **Q2 federation HAVING + cross-catalog aggregation pushdown STRONG (4.875)**; **Q3 ROWS vs RANGE window framing PASS (4.625) with a minor INTERVAL '0' DAY redundancy nit**; **Q4 partition evolution PASS (4.3125) but introduces ONE confident-inaccuracy: file-count-vs-partition-count conflation**. Zero-confident-inaccuracy streak STILL does NOT recover (broken at 0 for 6th consecutive iter — Q4 file-count claim).

---

## Headline

1. **Q1 type-widening re-probe — BOTH iter433 inaccuracies FULLY RESOLVED on FIRST re-probe (4.875 STRONG PASS).** Responder now correctly states (a) Trino 467 DOES support `ALTER TABLE ... ALTER COLUMN ... SET DATA TYPE bigint` for Iceberg (added in Trino release 406, 25 Jan 2023, PR #15515), and (b) Iceberg-Spark canonical syntax is `ALTER TABLE t ALTER COLUMN c TYPE bigint` (NOT `MODIFY COLUMN ... BIGINT` which is MySQL/Hive). The "must use Spark" claim is fully absent. Two-engine syntax table memorable. Safe widenings (int→bigint, real→double, decimal precision-widen-same-scale) + unsafe set (narrowing, scale change, cross-family) intact. **Verified against trino.io/docs/current/sql/alter-table.html + trino.io/docs/current/release/release-406.html + iceberg.apache.org/docs/latest/spark-ddl/.** Iter434 r09 + r13 SCHEMA-EVOLUTION-COLUMN-TYPE-CHANGE GUARDRAIL landed precisely — proven structural-fix-within-one-iteration recipe extends to 17 instances.

2. **Q2 federation HAVING + cross-catalog aggregation pushdown — STRONG PASS (4.875).** Responder cleanly explains: (a) cross-catalog JOIN does NOT push (join executes on Trino workers; verified per trino.io/docs/current/optimizer/pushdown.html — joins must be same catalog); (b) GROUP BY + HAVING aggregation pushes to Postgres ONLY if WHERE pushes first + supported aggregate fn + no ROLLUP/CUBE/GROUPING SETS (verified per Trino pushdown docs); (c) in cross-catalog-join case, aggregation stays on Trino (pulls joined rows + groups in memory); (d) EXPLAIN signature: Aggregate + Filter operators above InnerJoin = Trino-side (canonical); (e) PG-to-PG-only join could push; (f) fix patterns: materialize joined result to Iceberg / reduce data pre-join. No fabricated detail. EXPLAIN signature accurate.

3. **Q3 ROWS vs RANGE window framing with ties — PASS (4.625) with minor INTERVAL '0' DAY redundancy nit.** Responder correctly explains: (a) Trino syntax identical to Oracle; (b) ROWS = positional (separate frame per tied row), RANGE = value-based (tied rows are peers, same frame); (c) example table 2026-05-01 ×2 ROWS 100/150 vs RANGE 150/150 — accurate; (d) mismatch from ROWS-vs-Oracle-tie-handling or non-unique ORDER BY; (e) Trino default frame = RANGE UNBOUNDED PRECEDING TO CURRENT ROW when ORDER BY present (verified per trino.io/blog/2021/03/10/introducing-new-window-features.html). **MINOR NIT:** Responder's suggested fix `RANGE BETWEEN INTERVAL '0' DAY PRECEDING AND CURRENT ROW` is syntactically valid (Trino has supported RANGE INTERVAL since v346, verified) but semantically REDUNDANT — Trino's default RANGE frame already groups peers (same ORDER BY value) into the same frame. The cleaner fix is either (a) omit the frame entirely (default RANGE behavior covers it) or (b) add a unique tiebreaker `event_id` to ORDER BY. Not a confident-inaccuracy (the SQL would execute and produce the documented result), but it's a suboptimal pattern worth flagging.

4. **Q4 partition evolution month→day — PASS (4.3125) BUT contains ONE confident-inaccuracy: file-count-vs-partition-count conflation.** Core mechanics CORRECT: (a) `ALTER TABLE SET PROPERTIES partitioning=ARRAY['day(event_ts)']` in Trino is metadata-only (verified per trino.io/docs/current/connector/iceberg.html); (b) old files keep old spec, queries still correct, but old data NOT pruned by new spec (verified); (c) Spark `rewrite_data_files` with `rewrite-all=true` + target-file-size to rewrite historical data into the new spec; (d) `$files GROUP BY spec_id` verification (old spec_id=0 → new spec_id=1); (e) `expire_snapshots` cleanup; (f) storage temporarily doubles during rewrite. **INACCURACY:** Claims monthly partitioning of 500M rows / 18 months = "~18 files at most (one per month)" and daily = "~547 files". This conflates PARTITIONS with FILES. A monthly partition holding ~27M rows is typically several GB and will contain MANY data files (often dozens to hundreds depending on target file size, ingestion cadence, parallelism). The correct framing is "18 month-partitions vs 547 day-partitions" — file count per partition is a separate concern driven by target-file-size and write cadence. An engineer using this oversimplified mental model might be surprised by the actual file count and mis-tune compaction thresholds.

---

## Critical confirmations (explicit)

### (a) Q1 type widening — BOTH iter433 inaccuracies RESOLVED?

**YES — BOTH FULLY RESOLVED on FIRST re-probe.**

- **Iter433 Inaccuracy A (Trino can't change column types, must use Spark) — RESOLVED.** Responder now leads with `ALTER TABLE iceberg.analytics.events ALTER COLUMN row_count SET DATA TYPE bigint` (Trino 467 syntax, supported since Trino release 406). The "must use Spark" claim is fully absent. The two-engine syntax table memorializes the difference. Verified per trino.io/docs/current/sql/alter-table.html + Trino 406 release notes.

- **Iter433 Inaccuracy B (Spark `MODIFY COLUMN ... BIGINT`) — RESOLVED.** Responder now uses `ALTER TABLE local.analytics.events ALTER COLUMN row_count TYPE bigint` (Iceberg-Spark canonical syntax). Explicit DO-NOT-WRITE entry bans `MODIFY COLUMN` as MySQL/Hive only. Verified per iceberg.apache.org/docs/latest/spark-ddl/.

- **Safe-widening set** (int→bigint, REAL→double, decimal precision-widen-same-scale) — CORRECT per Iceberg spec.
- **Unsafe set** (narrowing, scale change, cross-family) — CORRECT.
- **Read-time promotion** (32-bit float files transparently read as 64-bit double, no rewrite) — CORRECT.

**Verdict:** iter434 r09 + r13 SCHEMA-EVOLUTION-COLUMN-TYPE-CHANGE GUARDRAIL landed precisely on first re-probe. 17th structural-fix-within-one-iteration instance.

### (b) Q2 federation score + federation average + direction + crosses 4.5?

**Q2 score: 4.875 STRONG PASS** — fourth-consecutive iter of 4.75+ federation answer (iter431 4.75 → iter432 4.875 → iter433 4.875 → iter434 4.875).

**Federation average update:**
- Prior: 4.4963 × 295 = 1326.4085 sum
- + Q2 4.875 = +4.875
- New sum: 1331.2835
- New count: 296
- **New average: 1331.2835 / 296 = 4.4976**

Distance to threshold: 4.5000 − 4.4976 = **0.0024 below 4.5**.

Compared to iter433:
- Iter433: 4.4963, 0.0037 below threshold
- Iter434: 4.4976, 0.0024 below threshold
- **Net change: +0.0013 / 0.0013 CLOSER to threshold / 34th consecutive iter below threshold / DIRECTION SUSTAINS UP for FOURTH consecutive iter (iter431 +0.0008 → iter432 +0.0013 → iter433 +0.0013 → iter434 +0.0013)**

**Crosses 4.5?** **NO — still 0.0024 below threshold.** But the closing pace SUSTAINS at +0.0013 for 3rd consecutive iter. At this density (296 datapoints), sustained 4.75+ federation answers would cross 4.5 in roughly **2 more iters** at current pace. Q2 4.875 is the fourth consecutive 4.75+ federation datapoint. EXPLAIN signature (Aggregate + Filter above InnerJoin = Trino-side) canonical and VERIFIED. HAVING-secondary-to-aggregate rule CORRECT. ROLLUP/CUBE/GROUPING SETS never push — VERIFIED.

### (c) New confident-inaccuracies across all four

**ONE new confident-inaccuracy: Q4 file-count-vs-partition-count conflation.** 

Q4 responder claims "monthly partitioning of 500M/18mo = ~18 files at most (one per month)" and "day = ~547 files". This conflates **partitions** with **data files**. A partition typically contains MANY data files (driven by target-file-size, ingestion batch size, parallelism, compaction policy). For 500M rows / 18 months at typical Iceberg target-file-size of 128MB-512MB, a monthly partition would hold dozens to hundreds of files, not one. The "~18 files" claim is FALSE and misleading for compaction planning. An engineer using this mental model would mis-size compaction thresholds and be confused when `$files` shows file counts an order of magnitude higher than the partition count.

**One minor nit (not a confident-inaccuracy): Q3 INTERVAL '0' DAY redundancy.** Responder's fix `RANGE BETWEEN INTERVAL '0' DAY PRECEDING AND CURRENT ROW` is syntactically valid in Trino (RANGE INTERVAL supported since v346) but semantically REDUNDANT — Trino's default RANGE frame already includes peers (same ORDER BY value). The cleaner fix is either omit the frame entirely or add a unique tiebreaker. The SQL works; it's just a suboptimal pattern.

**Q1, Q2 CLEAN. Q3 minor nit but no confident-inaccuracy. Q4 has one confident-inaccuracy (file-count claim).**

---

## Per-question scoring

### Q1 — Type widening re-probe (Lakehouse schema design)

**Scores: 5.0 / 4.75 / 5.0 / 4.75 — avg 4.875 STRONG PASS**

What landed:
- Trino 467: `ALTER TABLE ... ALTER COLUMN ... SET DATA TYPE bigint` — VERIFIED canonical syntax
- Trino release 406 (25 Jan 2023, PR #15515) introduced the capability — CORRECT
- Spark/Iceberg: `ALTER TABLE ... ALTER COLUMN ... TYPE bigint` — CORRECT
- Explicit ban on `MODIFY COLUMN ... BIGINT` (MySQL/Hive syntax) — CORRECT
- Safe widenings (int→bigint, real→double, decimal precision-widen-same-scale) — CORRECT per Iceberg spec
- Unsafe set (narrowing, scale change, cross-family) — CORRECT
- Read-time promotion no-rewrite — CORRECT
- No "must use Spark" claim — RESOLVED

**Verdict:** STRONG PASS — full clean recovery on first re-probe. iter433 dual inaccuracy fully absent.

### Q2 — Federation HAVING + cross-catalog aggregation pushdown

**Scores: 5.0 / 4.75 / 4.75 / 5.0 — avg 4.875 STRONG PASS**

What landed:
- Cross-catalog JOIN doesn't push (must be same catalog) — VERIFIED per trino.io/docs/current/optimizer/pushdown.html
- HAVING pushes ONLY if aggregate pushes (secondary, transitive) — CORRECT
- ROLLUP/CUBE/GROUPING SETS NEVER push — VERIFIED
- EXPLAIN signature: Aggregate + Filter above InnerJoin = Trino-side — canonical
- PG-to-PG-only join COULD push — CORRECT
- Fix: materialize joined result to Iceberg / reduce data pre-join — actionable

**Verdict:** STRONG PASS — 4th consecutive 4.75+ federation datapoint; technical density without fabrication.

### Q3 — ROWS vs RANGE window framing with ties (Analytical query patterns + SQL best practices)

**Scores: 4.5 / 4.75 / 4.5 / 4.75 — avg 4.625 PASS (with minor nit)**

What landed:
- Trino syntax identical to Oracle — CORRECT
- ROWS = positional (per-tied-row separate frame), RANGE = value-based (peers same frame) — CORRECT
- Example table 2026-05-01 ×2: ROWS 100/150 vs RANGE 150/150 — CORRECT
- Trino default frame = RANGE UNBOUNDED PRECEDING TO CURRENT ROW when ORDER BY present — VERIFIED
- Fix: add unique tiebreaker to ORDER BY — CORRECT
- Mismatch diagnosis (ROWS vs Oracle tie handling, non-unique ORDER BY) — CORRECT

Minor nit:
- `RANGE BETWEEN INTERVAL '0' DAY PRECEDING AND CURRENT ROW` is syntactically valid (Trino RANGE INTERVAL supported since v346, verified) but SEMANTICALLY REDUNDANT — Trino's default RANGE frame already groups peers into the same frame. The idiomatic fix is to either omit the frame (default RANGE behavior covers it) or add a unique tiebreaker. The INTERVAL '0' DAY example is verbose/suboptimal but produces the correct result.

**Verdict:** PASS — core ROWS-vs-RANGE semantics canonical; INTERVAL '0' DAY fix is suboptimal-but-not-wrong; TA dock to 4.5 for the redundant pattern.

### Q4 — Partition evolution month→day (Iceberg partition design)

**Scores: 4.0 / 4.5 / 4.25 / 4.5 — avg 4.3125 PASS (with one confident-inaccuracy)**

What landed (CORRECT):
- `ALTER TABLE SET PROPERTIES partitioning=ARRAY['day(event_ts)']` (Trino) is metadata-only — VERIFIED
- New data day-partitioned, old data keeps month spec — VERIFIED
- Queries correct but old data not pruned by new spec until rewrite — VERIFIED
- Spark `rewrite_data_files` with `rewrite-all=true` + target-file-size to rewrite historical — CORRECT
- `$files GROUP BY spec_id` verification (old spec_id=0 → new spec_id=1) — CORRECT
- `expire_snapshots` cleanup — CORRECT
- Storage temporarily doubles during rewrite — CORRECT

What is INACCURATE (ONE confident-inaccuracy):
- **File-count vs partition-count conflation.** Claim: "monthly partitioning of 500M/18mo = ~18 files at most" and "day = ~547 files". WRONG — this conflates PARTITIONS with FILES. Each partition typically contains many data files (driven by target-file-size, ingestion cadence, parallelism). The correct framing is "18 month-partitions vs 547 day-partitions"; file count per partition is a separate downstream concern. An engineer using this oversimplified mental model would mis-size compaction thresholds.

**Verdict:** PASS but TA dock to 4.0 for the file-count conflation. The mechanics (ALTER, rewrite, verify, cleanup) are otherwise canonical.

---

## Topic-score updates

| Topic | Before | After | Delta | Status |
|---|---|---|---|---|
| Lakehouse schema design | 4.4375 / 10 | 4.4773 / 11 | +0.0398 | PASSED (Q1 4.875 well above topic avg) |
| Trino federation / cross-source connectors | 4.4963 / 295 | 4.4976 / 296 | +0.0013 | NEEDS WORK (0.0024 below 4.5 raised threshold; 34th consecutive iter below; DIRECTION UP for 4th straight iter; sustained pace) |
| Analytical query patterns on Iceberg+Trino | 4.4471 / 13 | 4.4598 / 14 | +0.0127 | PASSED (Q3 4.625 above topic avg) |
| SQL query best practices for OLAP | 4.5450 / 35 | 4.5472 / 36 | +0.0022 | PASSED (Q3 4.625 above topic avg) |
| Iceberg partition design for SaaS | 4.503 / 25 | 4.4957 / 26 | −0.0073 | PASSED but slightly DOWN (Q4 4.3125 below topic avg; still above threshold) |

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.875 | Type widening re-probe | STRONG PASS — BOTH iter433 inaccuracies FULLY RESOLVED on first re-probe; r09 + r13 SCHEMA-EVOLUTION-COLUMN-TYPE-CHANGE GUARDRAIL landed; 17th structural-fix-within-one-iteration instance |
| Q2 | 4.875 | Federation HAVING + cross-catalog aggregation pushdown | STRONG PASS — 4th consecutive 4.75+ federation datapoint; cross-catalog join blocks pushdown verified; ROLLUP/CUBE/GROUPING SETS never push verified; EXPLAIN signature canonical |
| Q3 | 4.625 | ROWS vs RANGE window framing with ties | PASS — canonical ROWS-vs-RANGE peer semantics; Trino default RANGE frame correct; minor nit: INTERVAL '0' DAY fix is suboptimal-but-valid (default RANGE already groups peers) |
| Q4 | 4.3125 | Partition evolution month→day | PASS — ALTER mechanics + rewrite_data_files + $files spec_id verification + expire_snapshots all canonical; ONE confident-inaccuracy: file-count-vs-partition-count conflation ("~18 files monthly / ~547 daily" mistakes partitions for files) |

**Average 4.672 STRONG PASS — thirty-third consecutive overall PASS in extended phase; +0.219 step-UP from iter433 4.453.**

**Headline outcomes:**
- Q1 type-widening re-probe — BOTH iter433 inaccuracies RESOLVED on first re-probe (4.875 STRONG); 17th structural-fix instance
- Q2 federation HAVING + cross-catalog pushdown — STRONG (4.875); 4th consecutive 4.75+ datapoint
- Q3 ROWS vs RANGE window framing — PASS (4.625); minor INTERVAL '0' DAY redundancy nit
- Q4 partition evolution — PASS (4.3125); ONE confident-inaccuracy: file-count-vs-partition-count conflation
- Federation 4.4963 → 4.4976 (+0.0013 UP, direction sustains UP for 4th consecutive iter; 34th consecutive iter below threshold; 0.0024 below; could cross 4.5 in ~2 iters at current pace)
- Lakehouse schema design 4.4375 → 4.4773 (+0.0398 UP, Q1 4.875 well above topic avg)
- Analytical query patterns 4.4471 → 4.4598 (+0.0127 UP, Q3 4.625 above topic avg)
- SQL best practices 4.5450 → 4.5472 (+0.0022 UP, Q3 4.625 above topic avg)
- Iceberg partition design 4.503 → 4.4957 (-0.0073 DOWN, Q4 4.3125 below topic avg but still above threshold)

**Failure-mode count: 14 of prior 33 iterations** (iter434 introduces 1 new failure-mode class in Q4: PARTITION-COUNT-VS-FILE-COUNT-CONFLATION — claiming "N month-partitions = N files at most" when each partition typically holds many files driven by target-file-size and ingestion cadence).

---

## Teacher actions next (iter 435)

1. **HIGH — Fix Q4 PARTITION-COUNT-VS-FILE-COUNT-CONFLATION.** Install in r09 (lakehouse schema design) OR r17 (Iceberg table maintenance) OR r18/r19 (partition design) a GUARDRAIL:
   - **GUARDRAIL — PARTITIONS-ARE-NOT-FILES:** A partition in Iceberg is a logical grouping; each partition typically contains MANY data files driven by target-file-size, ingestion batch size, parallelism, and compaction. For example, a 27M-row month-partition at typical 128-512MB target-file-size will hold dozens to hundreds of files, not one.
   - **DO-NOT-WRITE entries banning:** (a) "N partitions = N files" claim, (b) "~18 files monthly (one per month)" style oversimplification, (c) conflating partition count with file count in any compaction context.
   - **Worked example:** 500M rows / 18 months at 256MB target-file-size with avg row size 2KB → each month-partition ≈ 27M rows × 2KB ≈ 54GB → 54GB / 256MB ≈ 210 files per month-partition → 18 partitions × 210 files ≈ 3,780 total files (not 18).
   - **Q-pattern matcher:** "How many files will N partitions have?" → "Files ≠ partitions. Files = (partition data volume) / (target-file-size). Use `SELECT spec_id, COUNT(*) FROM tbl\\$files GROUP BY spec_id` to count actual files."
   - Cite iceberg.apache.org/docs/latest/configuration/#write-properties for target-file-size and iceberg.apache.org/docs/latest/spark-procedures/#rewrite_data_files for compaction.

2. **MEDIUM — Polish Q3 RANGE-INTERVAL idiom.** In r-window-functions resource, note that Trino's default RANGE frame (RANGE UNBOUNDED PRECEDING TO CURRENT ROW) already groups peers (same ORDER BY value) into the same frame. The idiomatic fix for tie-handling is to either (a) omit the frame entirely (default behavior covers it) or (b) add a unique tiebreaker to ORDER BY. Avoid suggesting `RANGE BETWEEN INTERVAL '0' DAY PRECEDING AND CURRENT ROW` as the primary fix — it's syntactically valid but redundant and verbose.

3. **LOW — Q1 SCHEMA-EVOLUTION-COLUMN-TYPE-CHANGE GUARDRAIL landed precisely.** No structural changes needed. Re-probe at +3-5 iter horizon to confirm durability.

4. **LOW — Q2 federation HAVING + cross-catalog aggregation pushdown** answered cleanly. EXPLAIN signature canonical. No structural changes needed.

5. **MEDIUM — Federation topic** at 4.4976 / 0.0024 below threshold; 34th consecutive iter below. Direction sustains UP for 4th straight iter (+0.0013 sustained pace). At this density, sustained 4.75+ federation answers would cross 4.5 in ~2 iters. Carry-forward angles still un-asked: function-wrapped predicate contrast (LOWER/COALESCE-wrapped column), 4-way cross-catalog join.

6. **LOW — Carry-forward backlog** (mostly unchanged from iter433):
   - HMS→Nessie write-freeze
   - Snapshot vs serializable phantom-row 3rd-angle
   - Window NULL 2nd-angle
   - Iceberg concurrency 5th-angle (commit.retry exhaustion behavior)
   - OPA-override timeout
   - Schema registry compat
   - JWT+OPA concurrency
   - Federation function-wrapped predicate contrast (LOWER/COALESCE-wrapped column)
   - CTAS NOT NULL +3-iter durability re-probe
   - Trino session timezone +3-5 iter durability re-probe

---

## Judge probe targets next (iter 435)

1. **HIGH — Re-probe partition evolution / partition-vs-file-count framing** to verify the new GUARDRAIL lands. A direct question: "I'm thinking about partitioning my 1B-row Iceberg table by month vs day — how many data files will that produce, and how does file count relate to partition count?" Looking for: (a) explicit distinction between partitions and files, (b) target-file-size as the driver, (c) `$files` metadata table to count actual files, (d) NO claim that "N partitions = N files".

2. **HIGH — Federation function-wrapped predicate contrast** (carry-forward, still un-asked): "Does `WHERE LOWER(email) = 'a@b.com'` push to Postgres? Contrast with naked equality."

3. **HIGH — Federation 4-way cross-catalog join execution location** (extends iter426 3-way angle): "Postgres dim + Iceberg fact + Iceberg dim + Postgres lookup — where does the join run, and what does EXPLAIN show for each TableScan?"

4. **MEDIUM — Type widening +3-5 iter durability re-probe** to confirm iter434 fix holds.

5. **MEDIUM — CTAS NOT NULL durability re-probe** (+4 iter horizon from iter431): "I want to add a strict NOT NULL via CTAS-swap — walk me through the exact SQL."

6. **MEDIUM — Trino session timezone command re-probe** (+4-5 iter durability): "How do I make Trino's SYSDATE-equivalent return Chicago wall clock when the cluster default is UTC?"

7. **LOW — Iceberg concurrency 5th-angle** (carry-forward): commit.retry.num-retries exhaustion behavior.

---

## Critical message to teacher for iter 435

Iter434 is a STRONG PASS (4.672) and a +0.219 step-UP from iter433 4.453, driven by Q1's full recovery from iter433's dual confident-inaccuracy. The iter434 teacher plan — installing the SCHEMA-EVOLUTION-COLUMN-TYPE-CHANGE GUARDRAIL in r09 + r13 with Trino `SET DATA TYPE` + Spark `ALTER COLUMN ... TYPE` + DO-NOT-WRITE banning `MODIFY COLUMN` and "must use Spark" + worked example pair — landed precisely on the first re-probe. The proven structural-fix-within-one-iteration recipe extends to 17 instances.

**However, the zero-confident-inaccuracy streak does NOT recover (now 6 consecutive iters).** ONE new failure-mode class emerges in Q4:

1. **PARTITION-COUNT-VS-FILE-COUNT-CONFLATION:** Responder claims "monthly partitioning of 500M/18mo = ~18 files at most (one per month)" and "day = ~547 files". This is FACTUALLY WRONG — a partition is a logical grouping that typically holds many data files driven by target-file-size and ingestion cadence. For 500M rows / 18 months at typical 128-512MB target-file-size, a monthly partition would hold dozens to hundreds of files. An engineer using this oversimplified mental model would mis-size compaction thresholds and be confused when `$files` shows file counts an order of magnitude higher than partition count.

**The teacher needs to install a PARTITIONS-ARE-NOT-FILES GUARDRAIL in r09 (lakehouse schema design) or r17 (Iceberg table maintenance) or r18/r19 (partition design) explicitly banning the partition-count-equals-file-count claim and providing a worked example with target-file-size division.**

**Federation topic moved +0.0013 UP to 4.4976**, now 0.0024 below threshold (34th consecutive iter below). Direction sustains UP for 4th consecutive iter at sustained pace. With sustained 4.75+ federation answers, the topic could cross 4.5 in ~2 iters at this density. Q2 4.875 is the fourth consecutive iter of 4.75+ federation datapoints — the federation topic is on the cusp of crossing the raised threshold.

**Iter435 should focus on:**
(1) Add PARTITIONS-ARE-NOT-FILES GUARDRAIL with worked example (target-file-size → files-per-partition arithmetic) + DO-NOT-WRITE banning "N partitions = N files" (Q4 fix)
(2) Polish Q3 RANGE-INTERVAL idiom (prefer default RANGE or unique tiebreaker over redundant INTERVAL '0' DAY)
(3) Re-probe partition evolution / partition-vs-file-count to verify the GUARDRAIL lands
(4) Continue federation function-wrapped predicate / 4-way join angles to grind federation topic across 4.5
(5) Type widening +3-5 iter durability re-probe
