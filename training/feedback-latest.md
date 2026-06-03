# Judge Feedback — Iter 421 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.7656 STRONG PASS** (Q1 4.875 + Q2 4.6875 + Q3 4.75 + Q4 4.75) — **+0.219 step-UP from iter420 4.547, HIGHEST overall score in iter402-421 window**, twentieth consecutive overall PASS. The iter420 Q3 self-contradiction is FULLY RESOLVED in one iteration; zero new confident-inaccuracies; federation topic moves UP +0.0021 to 4.4925 (closest to threshold in 13 iters) but STILL 0.0075 below 4.5.

**Headline:**
1. **ITER420 PLAIN-TOPN SELF-CONTRADICTION FULLY RESOLVED — Q1 4.875.** Responder now states UNAMBIGUOUSLY that plain ORDER BY+LIMIT on PostgreSQL connector PUSHES BY DEFAULT since release 354 (19 Mar 2021), Postgres does sort+limit, returns only N rows, Trino does NOT pull millions. EXPLAIN success signature: sortOrder+limit folded inside TableScan node, NO separate TopN operator above the scan (absence IS the signature). Failed case correctly distinguished (separate TopN above scan for computed aggregate ORDER BY or non-default collation). **CRITICAL: zero "Trino pulls all rows" or "Postgres does no work" sentences anywhere in the answer — the iter420 dual-framing failure mode is ABSENT.** Teacher's iter421 r22 TOP-OF-DOC GUARDRAIL + TOP-OF-SECTION GUARDRAIL with DO-NOT-WRITE table + DISAMBIGUATION TABLE + MENTAL MODEL ANCHOR + LEADING WORKED EXAMPLE landed precisely on target.
2. **FEDERATION PAIR STRONG — Q1 4.875 + Q2 4.6875.** Q2 (predicate pushdown types) delivered clean push-vs-not table: equality/IN/IS NULL/numeric range/date range push; VARCHAR equality usually YES with non-default-collation caveat; VARCHAR range does NOT push by default; EXPLAIN TYPE IO FORMAT JSON columnConstraints/domain verification path correctly documented. **One minor TA imprecision:** `email LIKE '%@bigcorp.com'` framed as "pushes if default collation" — leading-wildcard LIKE is range-class semantics and generally does NOT push regardless of collation without the experimental collate flag.
3. **TABLE-MAINTENANCE PAIR STRONG — Q3 4.75 + Q4 4.75.** Q3 DROP COLUMN reclaim: metadata-only, Parquet bytes remain, lifecycle optimize→expire(7d Trino floor)→remove_orphan_files, Spark CALL escape hatch with older_than+retain_last. Q4 concurrent Spark+Trino: optimistic concurrency Git-like, snapshot pointer swap with CAS, loser retries (default 4), serializable (default) vs snapshot weaker, three write.{delete,update,merge}.isolation-level properties, disjoint partitions no conflict. Both fully accurate.

---

## Critical confirmations (explicit)

### (a) Is the iter420 plain-TopN self-contradiction RESOLVED?

**YES — FULLY RESOLVED with zero new self-contradictions.** Q1 4.875 STRONG. Responder leads with: "plain ORDER BY+LIMIT on Postgres connector Trino 467 PUSHES BY DEFAULT since release 354 (19 Mar 2021)." EXPLAIN success signature correctly described as `TableScan[..., sortOrder=[created_at DESC NULLS LAST], limit=100]` with sortOrder= and limit= FOLDED INTO the TableScan node, NO separate TopN operator above the scan (absence IS the signature, quoting trino.io/docs/current/optimizer/pushdown.html). Failed case correctly distinguished as separate TopN operator above the scan when computed aggregate ORDER BY is involved or non-default collation blocks the push.

**ZERO self-contradiction.** The iter420 dual-framing ("Trino pulls ALL rows" + "TopN pushdown fires" in same paragraph for same query) is ABSENT from this answer. The responder does NOT also say "pulls all rows / Postgres does no work" anywhere. The leading mental model is correct on the first attempt.

Verified against:
- trino.io/docs/current/release/release-354.html: "the optimization is now enabled by default"
- trino.io/docs/current/optimizer/pushdown.html: "absence of the TopN Trino operator in the Fragment 0 from the query plan demonstrates that the query benefits of the Top-N pushdown optimization"

Teacher's iter421 structural fix (TWO guardrails in r22 — TOP-OF-DOC at section 0 and TOP-OF-SECTION at 3.3A — with DO-NOT-WRITE table containing 5 banned phrasings + DISAMBIGUATION TABLE with plain-vs-aggregate rows + MENTAL MODEL ANCHOR + LEADING WORKED EXAMPLE + iter420 FAILURE MODE NAMED) is now a proven recovery pattern for self-contradiction-within-single-answer failures.

### (b) Federation topic — does it cross 4.5?

**NO — federation topic moved 4.4904 → 4.4925 (+0.0021), STILL 0.0075 BELOW the 4.5 threshold.**

Math: prior 4.4904 * 278 = 1248.331; + Q1 4.875 + Q2 4.6875 = 1257.894; / 280 = 4.4925.

This is the **closest to the 4.5 threshold in 13 iterations** (last position closer was iter408 at 4.4969). 21st consecutive iteration stuck below threshold, but trending UP for the 1st iter after the iter420 regression. The Q1 4.875 alone would have crossed if Q2 had also been 4.75+; the Q2 4.6875 (the leading-wildcard LIKE imprecision dragged Q2 TA from 5.0 to 4.5) was a small but threshold-relevant nudge.

**Two more 4.75+ federation answers would push the topic ACROSS the 4.5 threshold.** This is the most actionable threshold-push position in 13 iters.

### (c) Any NEW confident-inaccuracy / engine-version-API confusion / self-contradiction in iter421?

**NO — zero new confident-inaccuracies, zero new self-contradictions, zero new engine/version/API confusions.** The only nudge is the Q2 leading-wildcard LIKE example imprecision (small TA nudge, not load-bearing).

**Myth-buster zero-confident-inaccuracy streak RESTARTED at 1.** The recovery-within-one-iteration pattern (leading canonical example + DO-NOT-WRITE callouts + disambiguation tables + cite source URLs) has now resolved SEVEN consecutive confident-inaccuracy / self-contradiction failures (iter407→408, iter411→412, iter413→414, iter414→415, iter417→418, iter419→420, iter420→421).

---

## Per-question scoring

### Q1 — Plain TopN re-probe (Trino federation / cross-source connectors)

**Scores: 5.0 / 4.75 / 5.0 / 4.75 — avg 4.875 STRONG PASS**

What landed:
- Plain ORDER BY+LIMIT on PG connector Trino 467 pushes by default since release 354 (19 Mar 2021) — VERIFIED.
- Trino sends ORDER BY+LIMIT to Postgres; Postgres sorts (uses index if available) returns only N rows; Trino does NOT pull millions — CORRECT.
- EXPLAIN success signature: `TableScan[..., sortOrder=[created_at DESC NULLS LAST], limit=100]` with sortOrder+limit FOLDED inside TableScan, NO separate TopN operator above — VERIFIED against trino.io/docs/current/optimizer/pushdown.html.
- Failed case: separate TopN operator above the scan (computed aggregate ORDER BY, non-default collation) — CORRECT distinction.
- Plain single-column case very solid on Trino 467 — CORRECT.

**Critical: ZERO "Trino pulls all rows" or "Postgres does no work" framing anywhere. The iter420 self-contradiction failure mode is ABSENT.**

**Verdict:** STRONG PASS. The iter420 plain-TopN self-contradiction is fully resolved in one iteration. The leading mental model is the correct one on first attempt.

### Q2 — Predicate pushdown types (Trino federation / cross-source connectors)

**Scores: 5.0 / 4.5 / 4.75 / 4.5 — avg 4.6875 STRONG PASS**

What landed:
- Equality on any column type pushes — VERIFIED against trino.io/docs/current/connector/postgresql.html.
- IN-list pushes — VERIFIED.
- IS NULL pushes — CORRECT.
- Numeric range (>, <, BETWEEN on integer/numeric) pushes — CORRECT.
- Date range pushes — CORRECT.
- VARCHAR equality "usually YES, non-default collation NOT pushed without enable-string-pushdown-with-collate" — TECHNICALLY ACCURATE (verified via PR #9746 and postgresql.html: collation-aware flag needed for correctness on non-default collation; performance regression risk on equality with collation since indexes cannot be used).
- VARCHAR range does NOT push by default — VERIFIED.
- VARCHAR LIKE collation-dependent — CORRECT NUANCE.
- EXPLAIN (TYPE IO, FORMAT JSON) `columnConstraints` / `domain` field present = pushed — VERIFIED as documented method.

**Minor TA imprecision:** Example `email LIKE '%@bigcorp.com'` framed as "pushes if default collation" — this is slightly wrong because leading-wildcard LIKE is range-class semantics and generally does NOT push regardless of collation without the experimental collate flag. The broader VARCHAR/LIKE framing is correct; the slip is on this one example. Small TA nudge from 5.0 to 4.5.

**Verdict:** STRONG PASS. One small imprecision on the leading-wildcard LIKE example; the rest is exemplary. If this had been 4.75+, the federation topic would have crossed 4.5.

### Q3 — DROP COLUMN storage reclaim (Iceberg table maintenance)

**Scores: 5.0 / 4.5 / 5.0 / 4.5 — avg 4.75 STRONG PASS**

What landed:
- NOT immediate — VERIFIED. DROP COLUMN in Iceberg v2 is metadata-only (column marked dropped in schema-update; Parquet column-chunk bytes remain in existing files).
- Lifecycle: optimize(file_size_threshold => '512MB') → expire_snapshots (7d Trino floor) → remove_orphan_files (7d) — CORRECT canonical sequence. optimize rewrites Parquet files without the dropped column; expire_snapshots ages out snapshots still referencing pre-rewrite files; remove_orphan_files reclaims unreferenced bytes from MinIO.
- Trino 467 expire_snapshots 7d minimum retention floor enforced — VERIFIED.
- Same-day Spark escape hatch: `CALL spark_catalog.system.expire_snapshots(table => ..., older_than => TIMESTAMP '...', retain_last => 1)` + `CALL ... remove_orphan_files` — CORRECT. Spark has no min-retention floor.
- Storage freed ~7d after the DROP on a Trino-only stack — CORRECT operational expectation.

**Verdict:** STRONG PASS. Small completeness nudge for not mentioning that `optimize` alone is sometimes sufficient if column chunks are the dominant byte source and the engineer is willing to wait for natural snapshot expiry — but the full lifecycle answer is the safer recommendation.

### Q4 — Concurrent Spark+Trino writes (Iceberg concurrency model)

**Scores: 5.0 / 4.5 / 4.75 / 4.75 — avg 4.75 STRONG PASS**

What landed:
- Optimistic concurrency, Git-like analogy — CORRECT.
- A reads snap-123, writes files, swaps metadata.json pointer with CAS → wins — CORRECT.
- B detects stale base after writing files, retries: re-reads new snap-456, replays write plan, re-commits — CORRECT.
- Default `commit.retry.num-retries = 4` — VERIFIED against iceberg.apache.org/docs/latest/configuration/.
- Never corrupts — CORRECT (one writer wins, loser retries or hard-fails after exhausting retries).
- Serializable isolation default vs snapshot isolation weaker — CORRECT per Iceberg docs.
- Three table properties: `write.delete.isolation-level`, `write.update.isolation-level`, `write.merge.isolation-level` — VERIFIED.
- Disjoint partitions (Spark writes 2026-05-30, Trino writes 2026-05-29) = no conflict — CORRECT (partition-spec-aware conflict detection via DataFile partition tuple in manifests).
- Override path: Spark `ALTER TABLE ... SET TBLPROPERTIES (...)` or Trino `ALTER TABLE ... SET PROPERTIES (...)` — CORRECT engine-disambiguation.

**Verdict:** STRONG PASS. Small practical nudge for not foregrounding that the longer-running writer is more likely to be the loser in the retry race (Spark batch typically loses to Trino fast commits when both target the same partition).

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.875 | STRONG PASS — iter420 plain-TopN self-contradiction FULLY RESOLVED, zero "Trino pulls all rows" framing |
| Q2 | 4.6875 | STRONG PASS — predicate pushdown types clean, one small imprecision on leading-wildcard LIKE |
| Q3 | 4.75 | STRONG PASS — DROP COLUMN reclaim lifecycle + Spark escape hatch fully accurate |
| Q4 | 4.75 | STRONG PASS — concurrent writes optimistic concurrency model fully accurate |

**Average 4.7656 STRONG PASS — twentieth consecutive overall PASS, +0.219 step-UP from iter420 4.547, HIGHEST overall score in iter402-421 window (matches iter413/iter415 4.625 territory and exceeds).**

**Headline outcomes:**
- ITER420 SELF-CONTRADICTION FULLY RESOLVED in ONE iteration — Q1 4.875 STRONG, zero "Trino pulls all rows" framing anywhere.
- Federation topic 4.4904 → 4.4925 (+0.0021) — closest to 4.5 threshold in 13 iters but STILL 0.0075 below, DOES NOT CROSS.
- Zero new confident-inaccuracies anywhere in iter421 — myth-buster zero-confident-inaccuracy streak RESTARTED at 1.
- Q3+Q4 table-maintenance pair both 4.75 STRONG — strongest table-maintenance contribution in recent iters.

**Failure-mode count: 7 of prior 19 iterations** (unchanged; iter421 was a clean STRONG PASS).

---

## Teacher actions next (iter 422)

1. **MEDIUM — Trino federation threshold-push continuation.** Topic at 4.4925 / 0.0075 below threshold — the closest position to crossing in 13 iters. **Two more 4.75+ federation answers would push the topic ACROSS the 4.5 threshold.** Continue auditing r22 for remaining myth-buster gaps in unexplored angles: aggregation pushdown to Postgres (SUM/COUNT/AVG, aggregation_pushdown setting, EXPLAIN signature); cross-catalog 3-way JOIN execution location; schema-evolution-with-pushdown; OR-with-mixed-types pushdown; anchored-prefix-LIKE-vs-leading-wildcard-LIKE pushdown distinction.

2. **LOW — Q2 leading-wildcard LIKE example refinement.** The iter421 Q2 imprecision (`email LIKE '%@bigcorp.com'` framed as "pushes if default collation") is small but a polished framing would explicitly distinguish:
   - Anchored prefix LIKE 'alice@%' (collation-dependent, may push with experimental collate flag)
   - Leading-wildcard LIKE '%@bigcorp.com' (does NOT push regardless of collation by default, range-class semantics)
   
   Add a 2-line callout in r22 under the LIKE-pushdown section to harden this against future probes.

3. **LOW — Carry-forward backlog:** HMS->Nessie write-freeze alternative; branches-vs-expire 3rd-angle; Snapshot vs serializable phantom-row 3rd-angle; Window NULL 2nd-angle; Iceberg v3 deletion vectors timeline; MERGE rollback; OPA-override timeout; schema registry compat; JWT+OPA concurrency.

---

## Judge probe targets next (iter 422)

1. **HIGH — Federation threshold-push 7th-angle continuation.** Topic 0.0075 below threshold — two 4.75+ federation answers cross. Probe angles where r22 may have remaining gaps:
   - "Does `SELECT customer_id, SUM(amount) FROM postgres.public.orders GROUP BY customer_id` push the aggregation to Postgres? What's the EXPLAIN signature? What's the aggregation_pushdown setting?" (aggregation pushdown).
   - "I have a 3-way join Postgres dim + Iceberg fact + Iceberg dim — which side dominates execution and how do I read the EXPLAIN to confirm?" (cross-catalog 3-way JOIN execution location).
   - "Does `WHERE (user_id = 123 OR email = 'a@b.com')` push the OR clause when one side is numeric and the other is VARCHAR?" (OR-with-mixed-types pushdown).
   - "What's the difference between anchored prefix LIKE 'alice@%' and leading-wildcard LIKE '%@bigcorp.com' for pushdown to Postgres on Trino 467?" (probes the iter421 Q2 imprecision).

2. **HIGH — TopN-pushdown durability RE-PROBE in NEW 2nd-angle shape.** Probe whether the iter421 TopN fix carries across question phrasings: "On Trino 467 + PostgreSQL connector, write `SELECT * FROM postgres.public.orders ORDER BY created_at DESC LIMIT 50` and explain what Trino sends to Postgres and what Postgres returns" (probes whether the canonical pushed-case framing is durable across slightly different question shapes — selecting all columns instead of single column).

3. **MEDIUM — Iceberg concurrency 4th-angle continuation** carry-forward: "After 4 commit.retry retries fail, what error does Spark return and how do I handle it in production?".

4. **MEDIUM — Iceberg branches-vs-expire 3rd-angle** carry-forward.

5. **MEDIUM — Snapshot vs serializable phantom-row 3rd-angle** carry-forward.

6. **MEDIUM — HMS->Nessie 2nd-angle for write-freeze alternative** carry-forward.

7. **MEDIUM — Window NULL 2nd-angle (calendar-dim LEFT JOIN densification)** carry-forward.

---

## Critical message to teacher for iter 422: durable recovery pattern + threshold-push close

The iter421 result is a clean **proof of the recovery-within-one-iteration pattern's durability**: the teacher's r22 TWO-guardrail structural fix (TOP-OF-DOC GUARDRAIL at section 0 + TOP-OF-SECTION GUARDRAIL at 3.3A, with DO-NOT-WRITE table + DISAMBIGUATION TABLE + MENTAL MODEL ANCHOR + LEADING WORKED EXAMPLE + iter420 FAILURE MODE NAMED) resolved the iter420 self-contradiction in ONE iteration. **Q1 4.875 STRONG validates the structural-fix pattern: leading canonical example + DO-NOT-WRITE banned phrasings + cite source URLs.**

The recovery-within-one-iteration pattern has now resolved SEVEN consecutive confident-inaccuracy / self-contradiction failures. This is the most consistent recovery pattern in the iter402-421 window.

**Federation topic is at the closest position to crossing the 4.5 threshold in 13 iterations.** Two more 4.75+ federation answers cross. The iter421 Q2 4.6875 (instead of 4.75) was the only nudge that kept the topic below threshold this iter; if the leading-wildcard LIKE example had been precise, the topic would have crossed at 4.4953. **The path to crossing is now: (1) sustain Q1-style 4.875+ on bulletproofed federation angles; (2) polish remaining myth-buster gaps in unexplored federation angles (aggregation pushdown, 3-way JOIN, OR-with-mixed-types, anchored-vs-leading-wildcard LIKE).**

**The pattern across iter402-421 is now fully durable:**
- Bulletproofed content delivers 4.75+ on the targeted angle.
- New failure modes appear in unexplored angles.
- Recovery within one iteration via structural fix (leading canonical example + DO-NOT-WRITE callouts + disambiguation tables + cite source URLs) is a proven pattern, demonstrated across SEVEN consecutive recoveries.
- Federation topic remains 0.0075 below the 4.5 threshold; two more sustained 4.75+ federation answers needed to cross.
