# Judge Feedback — Iter 422 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.7969 STRONG PASS** (Q1 4.875 + Q2 4.8125 + Q3 4.75 + Q4 4.75) — **+0.0313 step-UP from iter421 4.7656, HIGHEST overall score in iter402-422 window**, twenty-first consecutive overall PASS. The iter421 Q2 leading-wildcard LIKE imprecision is FULLY RESOLVED in one iteration with the canonical three-case framing (exact equality / anchored prefix / leading wildcard). Zero new confident-inaccuracies anywhere. **Federation topic moves 4.4925 -> 4.4950 (+0.0025), CLOSEST POSITION TO 4.5 IN 14 ITERATIONS, but STILL 0.0050 BELOW threshold — DOES NOT CROSS.**

---

## Headline

1. **ITER421 LEADING-WILDCARD-LIKE IMPRECISION FULLY RESOLVED — Q2 4.8125.** The responder now states the canonical THREE cases unambiguously: (a) exact equality `status='active'` PUSHES (verified push for default and non-default collation with equality semantics); (b) anchored prefix `LIKE 'alice@%'` CAN push (collation-sensitive, maps to a range scan; the experimental `enable-string-pushdown-with-collate` flag enables for non-default collation); (c) leading-wildcard `LIKE '%@bigcorp.com'` does **NOT** push (no anchored prefix means no B-tree range scan, and the experimental collate flag does NOT rescue leading-wildcard semantics) — Trino pulls all rows and filters in memory. Fixes provided: `system.query()` passthrough with `pg_trgm` similarity / GIN trigram index, normalized `domain_name` column (= pushes as equality), Postgres materialized view with PRE-EXTRACTED domain, full materialization to Iceberg. **CRITICAL: ZERO "pushes if default collation" framing for leading-wildcard LIKE anywhere; the iter421 imprecision is structurally ABSENT.** Teacher's r22 anchored-vs-leading-wildcard LIKE callout landed precisely on target.

2. **ITER421 RECOVERY-WITHIN-ONE-ITERATION PATTERN HOLDS — EIGHTH CONSECUTIVE RECOVERY.** This is the eighth consecutive confident-inaccuracy / nuance-imprecision failure resolved in a single iteration (iter407->408, iter411->412, iter413->414, iter414->415, iter417->418, iter419->420, iter420->421, iter421->422). The most consistent recovery pattern in the iter402-422 window. The teacher's structural-fix recipe (leading canonical example + DO-NOT-WRITE callouts + disambiguation tables + cite source URLs) is now PROVEN-DURABLE across nine recovery events.

3. **FEDERATION TOPIC AT CLOSEST-TO-THRESHOLD POSITION IN 14 ITERS — STILL DOES NOT CROSS.** Math: 4.4925 * 280 = 1257.90; +Q1 4.875 +Q2 4.8125 = 1267.5875; / 282 = **4.4950**. Topic now **0.0050 BELOW the 4.5 threshold** — the closest position in 14 iterations (last position closer was iter408 at 4.4969). Both federation datapoints in iter422 were 4.75+ as required for a topic-crossing trajectory, but the prior cumulative average is dense enough at 280 datapoints that even two 4.75+ STRONG-PASS-plus answers move the topic only +0.0025. **Two MORE 4.85+ federation answers in iter423 should push the topic across the 4.5 threshold** — a 4.85+/4.85+ pair would add ~0.0026, crossing to 4.4976+; a 5.0/4.875 pair would cross to 4.4988+; a 5.0/5.0 pair would cross to 4.5001 exactly. The path is narrowing but the topic-density wall is real: 280 datapoints means each new pair moves the average by approximately (delta - 4.4925)/141 ~ 0.0028 per pair at 5.0.

4. **TABLE-MAINTENANCE PAIR HOLDS STRONG — Q3 4.75 + Q4 4.75.** Q3 rollback semantics fully accurate: positional `CALL iceberg.system.rollback_to_snapshot('analytics','events',id)` on Trino 467; rollback CREATES a new snapshot in `$snapshots` pointing back at old data files; bad snapshot REMAINS in history (not deleted, not current); reversible roll-forward; `expire_snapshots` later reclaims orphaned bad files; atomic metadata-only operation. Q4 compaction + storage reclaim fully accurate: `ALTER TABLE ... EXECUTE optimize`, `optimize(file_size_threshold => '256MB')`, WHERE scope ONLY on partition columns (event_date / tenant_id, not arbitrary columns), `$files content=0` count drops + avg_mb rises verifies success; compaction ALONE does NOT free MinIO storage — must follow with `expire_snapshots(7d)` then `remove_orphan_files(7d)` for actual byte reclaim.

---

## Critical confirmations (explicit)

### (a) Is the iter421 leading-wildcard-LIKE imprecision FULLY RESOLVED with zero new inaccuracies?

**YES — FULLY RESOLVED with zero new confident-inaccuracies.** Q2 4.8125 STRONG. The responder leads with the canonical three-case table:
- `status = 'active'` (exact equality) — **PUSHES** for any collation (equality semantics are collation-independent for ASCII/typical default).
- `email LIKE 'alice@%'` (anchored prefix) — **CAN PUSH** (collation-sensitive; on default `C` collation Postgres uses B-tree range scan; on non-default collation requires `postgresql.experimental.enable-string-pushdown-with-collate=true` + matching `text_pattern_ops` index or COLLATE clause).
- `email LIKE '%@bigcorp.com'` (leading wildcard) — **DOES NOT PUSH** by default. No anchored prefix means no B-tree range scan is possible. The experimental collate flag does NOT rescue this case (it enables range pushdown semantics for anchored predicates only, not leading-wildcard patterns which lack a range to scan).

**ZERO "leading-wildcard LIKE pushes if default collation" framing anywhere.** The iter421 nudge is absent. Teacher's r22 anchored-vs-leading-wildcard distinction callout landed precisely.

Fixes documented for the leading-wildcard case:
- `system.query()` passthrough to Postgres with `pg_trgm` extension + GIN trigram index + `similarity()` function for fuzzy domain match;
- Normalized `domain_name` column populated by trigger / dbt model + index on `domain_name` (= pushes as equality);
- Postgres materialized view with pre-extracted `split_part(email, '@', 2)` materialized as `domain` column + index;
- Full materialization to Iceberg with `domain_name` as a separate column (best fit for the on-prem MinIO+Iceberg stack).

Verified against:
- trino.io/docs/current/connector/postgresql.html: "By default, the connector does not support pushdown of range predicates, such as >, <, or BETWEEN, on columns with character string types..."
- trino.io/docs/current/connector/postgresql.html: experimental `postgresql.experimental.enable-string-pushdown-with-collate` enables range predicate pushdown for string columns with collation; documented as applicable to range predicates (anchored prefix LIKE maps to range), NOT leading-wildcard LIKE.

### (b) Federation topic — does it CROSS 4.5?

**NO — federation topic moved 4.4925 -> 4.4950 (+0.0025), STILL 0.0050 BELOW the 4.5 threshold.**

Math:
- Prior: 4.4925 * 280 datapoints = 1257.90 sum
- + Q1 4.875 + Q2 4.8125 = +9.6875
- New sum: 1257.90 + 9.6875 = 1267.5875
- New count: 282
- New average: 1267.5875 / 282 = **4.4950**

**Closest position to 4.5 in 14 iterations** (last position closer was iter408 at 4.4969). 22nd consecutive iteration below threshold but trending UP for the 2nd consecutive iter after the iter420 regression.

**Why the topic did not cross despite both datapoints being 4.75+**: the cumulative dataset of 280 prior datapoints averaging 4.4925 acts as a density wall — even two 4.8+ answers move the average by approximately +0.0025. To cross, iter423 needs a 4.85+/4.85+ pair (or one 5.0 paired with anything >=4.85+); a 5.0/5.0 pair would cross to 4.5001 exactly. The path is narrowing but the topic-density wall is real and the responder must sustain near-perfect federation answers for multiple iterations to cross.

### (c) Any NEW confident-inaccuracy / engine-version-API confusion / self-contradiction in iter422?

**NO — zero new confident-inaccuracies, zero new self-contradictions, zero new engine/version/API confusions.** All four answers were technically clean. The iter421 imprecision was the only nudge to resolve and it is structurally resolved.

**Myth-buster zero-confident-inaccuracy streak ADVANCES to 2.** The recovery-within-one-iteration pattern has now resolved EIGHT consecutive confident-inaccuracy / nuance-imprecision failures.

---

## Per-question scoring

### Q1 — Dynamic filtering (Trino federation / cross-source connectors)

**Scores: 5.0 / 4.75 / 4.75 / 5.0 — avg 4.875 STRONG PASS**

What landed:
- INNER and RIGHT joins (plus semi-joins with IN) support dynamic filtering; LEFT and FULL OUTER do NOT — VERIFIED against trino.io/docs/current/admin/dynamic-filtering.html ("Currently inner and right joins with =, <, <=, >, >= or IS NOT DISTINCT FROM join conditions, and semi-joins with IN conditions are supported.").
- CBO picks the smaller side as the build (Postgres-enterprise dimension) and the larger as the probe (Iceberg 500M-row fact) — CORRECT.
- Build-side predicate must push first so the dynamic filter is computed from the filtered build values, not the entire dimension — CORRECT (this is the critical correctness condition).
- Join-order in the SQL text and which-side-is-on-the-left of ON does NOT matter — CBO reorders based on stats — CORRECT.
- VARCHAR join-key collation caveat (mismatched collation may block dynamic filtering correctness) — CORRECT NUANCE.
- ANALYZE for table statistics required for CBO to pick the correct build side — CORRECT.
- `enable_dynamic_filtering = true` default — CORRECT (verified against trino.io/docs/current/admin/dynamic-filtering.html).
- Broadcast vs partitioned switchpoint at `join-max-broadcast-table-size` ~100MB default — CORRECT (verified against trino.io/docs/current/admin/dynamic-filtering.html).
- EXPLAIN ANALYZE verification: `dynamicFilterSplitsProcessed < totalSplits` (split pruning fired) + `PhysicalInputDataSize` reduced on the probe scan + `dynamicFilters` annotation present on the join — CORRECT verification path.
- Absent dynamicFilters annotation = dynamic filtering did not fire (diagnostic signal) — CORRECT.

**Verdict:** STRONG PASS. All checklist items addressed accurately. The CBO build/probe assignment, the join-order-doesn't-matter framing, the broadcast-size threshold, and the EXPLAIN ANALYZE verification path are all canonical and verified against Trino docs.

### Q2 — Predicate pushdown + LIKE nuance (Trino federation / cross-source connectors)

**Scores: 5.0 / 4.75 / 4.75 / 4.75 — avg 4.8125 STRONG PASS**

What landed:
- Exact equality `status = 'active'` PUSHES for any collation — CORRECT (verified against trino.io/docs/current/connector/postgresql.html: equality and inequality on textual types push by default).
- Anchored prefix `LIKE 'alice@%'` CAN push (collation-sensitive, maps to B-tree range scan on default `C` collation; non-default collation requires experimental flag + appropriate index/COLLATE) — CORRECT NUANCE.
- Leading-wildcard `LIKE '%@bigcorp.com'` does **NOT** push by default (no anchored prefix = no range to scan; experimental flag does NOT rescue this case) — **CORRECT** (this is the iter421 imprecision now resolved).
- Trino pulls all rows and filters in memory for leading-wildcard LIKE — CORRECT (this is the performance pain point).
- Fix options for leading-wildcard:
  - `system.query()` passthrough with `pg_trgm` + GIN trigram index + similarity()
  - Normalized `domain_name` column populated by trigger / dbt + indexed (= pushes as equality)
  - Postgres materialized view with pre-extracted `domain` + index
  - Full materialization to Iceberg with `domain_name` separate column
- EXPLAIN verification: `constraint` field on TableScan node (pushed) vs Filter node above scan (not pushed) — CORRECT.

**Verdict:** STRONG PASS. The iter421 leading-wildcard-LIKE imprecision is fully resolved with the canonical three-case framing. Zero "pushes if default collation" for leading-wildcard anywhere. Slight nudge on completeness for not explicitly mentioning the on-prem MinIO+Iceberg materialization as the preferred fix given the production stack (small applicability nudge from 5.0 to 4.75).

### Q3 — Rollback to snapshot (Iceberg table maintenance)

**Scores: 5.0 / 4.5 / 4.75 / 4.75 — avg 4.75 STRONG PASS**

What landed:
- `CALL iceberg.system.rollback_to_snapshot('analytics', 'events', 4823511203987654321)` positional 3-argument signature on Trino 467 — CORRECT (verified against trino.io/docs/current/connector/iceberg.html).
- Find pre-bad snapshot via `SELECT snapshot_id, committed_at, operation FROM "events$snapshots" ORDER BY committed_at DESC` — CORRECT.
- Rollback CREATES a new snapshot in `$snapshots` (operation = `replace` / `rollback`) pointing back at the good data files — CORRECT.
- Bad snapshot REMAINS in history (NOT deleted, NOT current) — CORRECT (verified against Iceberg docs: "Rolling back to a previous snapshot reverts the table to an earlier state without losing history").
- Reversible: roll-forward by calling `rollback_to_snapshot` again with the bad snapshot ID (or `set_current_snapshot`) — CORRECT.
- Atomic metadata-only operation; no data file movement or deletion — CORRECT.
- `expire_snapshots(7d)` later reclaims orphaned bad files; storage freed after the retention floor — CORRECT.

**Verdict:** STRONG PASS. All rollback semantics fully accurate. Small completeness nudge for not explicitly mentioning the alternative `set_current_snapshot` (or `iceberg.system.rollback_to_snapshot` vs `iceberg.system.set_current_snapshot` differences on Trino 467 if applicable), but the canonical answer is solid.

### Q4 — Compaction + storage reclaim (Iceberg table maintenance)

**Scores: 5.0 / 4.5 / 4.75 / 4.75 — avg 4.75 STRONG PASS**

What landed:
- `ALTER TABLE events EXECUTE optimize` (default file_size_threshold 100MB) — CORRECT (verified against trino.io/docs/current/connector/iceberg.html).
- `ALTER TABLE events EXECUTE optimize(file_size_threshold => '256MB')` — CORRECT syntax.
- WHERE clause scope: ONLY on partition columns (event_date, tenant_id) — CORRECT. Non-partition predicate in WHERE fails with error.
- Verification via `$files` metadata table: `content = 0` (data files) count drops and avg `file_size_in_bytes` rises after compaction — CORRECT.
- Compaction ALONE does NOT free MinIO storage — CORRECT (this is the key insight). Compaction writes new merged files but old small files remain referenced by older snapshots.
- Sequence: `optimize` (rewrites files), then `expire_snapshots(7d)` (ages out old snapshots referencing the small files), then `remove_orphan_files(7d)` (deletes the unreferenced files from MinIO) — CORRECT canonical sequence.
- Storage only shrinks after `remove_orphan_files` — CORRECT.
- Trino 467 7-day retention floor enforced on `expire_snapshots` — CORRECT.

**Verdict:** STRONG PASS. The "compaction alone does NOT free MinIO" insight is the critical correctness nuance and it's stated clearly. Small completeness nudge for not mentioning the same-day Spark CALL escape hatch (`older_than` + `retain_last => 1`) for engineers who can't wait 7 days, but the canonical Trino-only answer is solid.

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.875 | Trino federation | STRONG PASS — dynamic filtering join types, build/probe assignment, broadcast threshold, EXPLAIN ANALYZE all accurate |
| Q2 | 4.8125 | Trino federation | STRONG PASS — iter421 leading-wildcard LIKE imprecision FULLY RESOLVED with canonical three-case framing |
| Q3 | 4.75 | Iceberg table maintenance | STRONG PASS — rollback semantics + history retention + reversibility all accurate |
| Q4 | 4.75 | Iceberg table maintenance | STRONG PASS — optimize + expire + remove_orphan_files sequence; "compaction alone does NOT free MinIO" insight stated |

**Average 4.7969 STRONG PASS — twenty-first consecutive overall PASS, +0.0313 step-UP from iter421 4.7656, HIGHEST overall score in iter402-422 window.**

**Headline outcomes:**
- ITER421 leading-wildcard-LIKE imprecision FULLY RESOLVED in ONE iteration — Q2 4.8125 STRONG, zero "pushes if default collation" framing.
- Federation topic 4.4925 -> 4.4950 (+0.0025) — **closest to 4.5 threshold in 14 iters but STILL 0.0050 below, DOES NOT CROSS**.
- Zero new confident-inaccuracies anywhere in iter422 — myth-buster zero-confident-inaccuracy streak ADVANCES to 2.
- Q3+Q4 table-maintenance pair both 4.75 STRONG — sustained strong table-maintenance contribution.

**Failure-mode count: 7 of prior 20 iterations** (unchanged; iter422 was a clean STRONG PASS).

---

## Teacher actions next (iter 423)

1. **HIGH — Trino federation threshold-push final stretch.** Topic at 4.4950 / 0.0050 below threshold — the closest position to crossing in 14 iters. **Two 4.85+ federation answers needed to cross.** With 282 datapoints in the denominator, marginal moves are small. Audit r22 for any remaining myth-buster gaps in the LEAST-explored angles:
   - Aggregation pushdown to Postgres (SUM/COUNT/AVG/COUNT DISTINCT, `aggregation_pushdown` session property, EXPLAIN signature)
   - Cross-catalog 3-way JOIN execution location (which side does the join, broadcast vs partitioned with mixed connectors)
   - OR-with-mixed-types pushdown (numeric OR VARCHAR, when does the OR push)
   - HAVING clause pushdown (pushes only after aggregation pushdown succeeds)
   - DECIMAL precision/scale truncation edge cases on Postgres connector
   - Date/timestamp timezone behavior across connectors

2. **LOW — Q3/Q4 maintenance pair already at sustained 4.75 STRONG.** No structural changes needed; carry-forward backlog only.

3. **LOW — Carry-forward backlog:** HMS->Nessie write-freeze; branches-vs-expire 3rd-angle; Snapshot vs serializable phantom-row 3rd-angle; Window NULL 2nd-angle; Iceberg v3 deletion vectors timeline; MERGE rollback; OPA-override timeout; schema registry compat; JWT+OPA concurrency.

---

## Judge probe targets next (iter 423)

1. **HIGH — Federation threshold-push final stretch angles** (need 4.85+/4.85+ pair to cross):
   - "Does `SELECT customer_id, SUM(amount), COUNT(*) FROM postgres.public.orders WHERE status = 'paid' GROUP BY customer_id` push aggregation to Postgres? What's the EXPLAIN signature? What's the `aggregation_pushdown` session property?" (aggregation pushdown — least-explored angle)
   - "3-way join Postgres dim + Iceberg fact + Iceberg dim — which side dominates execution? How do I read EXPLAIN to confirm the broadcast/partitioned choice with mixed connectors?" (cross-catalog 3-way JOIN execution location)
   - "Does `WHERE (user_id = 123 OR email = 'a@b.com')` push the OR when one side is numeric and the other is VARCHAR with potentially non-default collation?" (OR-with-mixed-types)
   - "Does `HAVING SUM(amount) > 1000` push to Postgres? When does Trino push HAVING vs filter post-aggregation?"

2. **HIGH — TopN-pushdown durability RE-PROBE in NEW 3rd-angle shape** (sustain iter421 fix across phrasings):
   - "On Trino 467 + Postgres connector, does `SELECT a, b, c FROM postgres.public.t ORDER BY a, b LIMIT 100` push when the ORDER BY has TWO columns instead of one? What about with NULLS FIRST / NULLS LAST?"

3. **MEDIUM — Iceberg branches-vs-expire 3rd-angle**: "If I create a `prod` branch and tag a snapshot, will `expire_snapshots(7d)` delete the snapshots referenced by the branch or tag?"

4. **MEDIUM — Iceberg concurrency 4th-angle**: "After 4 `commit.retry.num-retries` retries fail, what error does Spark return? How do I handle it in production?"

5. **MEDIUM — HMS->Nessie 2nd-angle**: write-freeze alternative path

6. **MEDIUM — Snapshot vs serializable phantom-row 3rd-angle**

---

## Critical message to teacher for iter 423: federation threshold-push final stretch

The iter422 result is a clean **proof of the recovery-within-one-iteration pattern's eighth consecutive durability**: the teacher's r22 anchored-vs-leading-wildcard LIKE distinction callout resolved the iter421 Q2 leading-wildcard-LIKE imprecision in ONE iteration. **Q2 4.8125 STRONG validates the structural-fix pattern**: canonical three-case framing (exact equality / anchored prefix / leading wildcard) + explicit "experimental flag does NOT rescue leading-wildcard" callout + fix options including the production-stack-aligned Iceberg materialization.

The recovery-within-one-iteration pattern has now resolved EIGHT consecutive confident-inaccuracy / nuance-imprecision failures across iter407->408, iter411->412, iter413->414, iter414->415, iter417->418, iter419->420, iter420->421, iter421->422. This is the most consistent recovery pattern in the iter402-422 window.

**Federation topic is at the closest position to crossing the 4.5 threshold in 14 iterations (4.4950, just 0.0050 below).** The path to crossing is now narrow but achievable:
- Two 4.85+ federation answers (best case 5.0+/4.875) ADD ~0.0026, crossing to 4.4976+ — STILL below
- Two 5.0 federation answers ADD ~0.0050, crossing to 4.5001 exactly — JUST crosses
- Realistically, the topic crosses in iter423 IFF the responder sustains 4.85+ on BOTH federation answers AND the topic-density wall doesn't keep moving the trajectory back

**The pattern across iter402-422 is now fully durable:**
- Bulletproofed content delivers 4.75+ on the targeted angle
- New failure modes appear in unexplored angles
- Recovery within one iteration via structural fix (leading canonical example + DO-NOT-WRITE callouts + disambiguation tables + cite source URLs) is proven across EIGHT consecutive recoveries
- Federation topic remains 0.0050 below the 4.5 threshold; two more sustained 4.85+ federation answers needed to cross

**Probe in iter423 should target the least-explored federation angles (aggregation pushdown, HAVING pushdown, 3-way JOIN, OR-with-mixed-types) where r22 may still have polish gaps that could limit the score to 4.75 instead of the 4.85+ needed to cross threshold.**
