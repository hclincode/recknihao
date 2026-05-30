# Judge Feedback — Iter 406 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.625 STRONG PASS** (Q1 4.75 + Q2 4.625 + Q3 4.5 + Q4 4.625)

**Headline: the iter405 Q2 inaccuracy (correlated NOT EXISTS "perf should be identical") IS RESOLVED.** The teacher's MEDIUM fix landed cleanly. All four iter406 probe targets closed at STRONG PASS. Fifth consecutive PASS; iter405 step-down (4.40625) recovered to 4.625. Oscillation pattern continues to damp.

---

## Q1 — Correlated NOT EXISTS shows LeftJoin not SemiJoin (critical re-probe of iter405 Q2 inaccuracy)

**Scores: 5.0 / 4.0 / 5.0 / 5.0 — avg 4.75 STRONG PASS — INACCURACY RESOLVED**

### What landed
- **LeftJoin lowering pipeline**: Filter[not exists] / Projection[exists] / Aggregation[dedup] / LeftJoin[enumerates all matches]. Correct order and node names. Verified against Trino issue #21859 description that correlated NOT EXISTS lowers to LeftJoin.
- **Executor-cost framing**: "LeftJoin returns every matching right row (user blocked 5x = 5 rows) then Aggregation dedupes = extra work SemiJoin avoids by short-circuiting one TRUE/FALSE per probe." This is the exact gap iter405 missed. Concrete "blocked 5x" example anchors it.
- **#21859 citation + singleMatch flag**: Names the issue and the un-landed optimization explicitly. "NOT a bug, inherent executor cost" is the right framing — separates planner regression from architectural cost.
- **Workaround = non-correlated anti-join**: `LEFT JOIN (SELECT DISTINCT user_id FROM blocked) ... WHERE IS NULL`. DISTINCT-ensures-unique-right-key note is correct and critical (without DISTINCT the LEFT JOIN dup-rows). States Trino lowers this to SemiJoin FilterMode=ANTI — verified against the Semi-Join IN Decorrelation rule path.
- **Alternative**: keep NOT IN if `blocked.user_id` is NOT NULL schema-enforced (SemiJoin fires).
- **Verification step**: re-run EXPLAIN look for SemiJoin. Closes the loop.

### Minor gaps
- Very dense / abbreviated style. A true beginner would struggle to parse "Filter[not exists]/Projection[exists]/Aggregation[dedup]/LeftJoin" without prior plan-node fluency. "Anti-join" and "FilterMode=ANTI" jargon still unglossed (iter404 carry-forward).
- No literal SQL example showing the input correlated NOT EXISTS source query alongside the rewrite.

### Verdict
**STRONG PASS — iter405 Q2 critical inaccuracy fully resolved.** The teacher's MEDIUM iter406 action landed precisely on the gap. Durability check passed on the first re-probe.

---

## Q2 — Partition spec changed, ran Trino EXECUTE optimize, old files still old layout

**Scores: 5.0 / 4.0 / 5.0 / 4.5 — avg 4.625 STRONG PASS**

### What landed
- **Optimize vs repartition distinction**: optimize rewrites small files bigger but does NOT change partition spec layout of existing files. This is the precise iter405 Q3 implicit gap now made explicit.
- **Old snapshot files keep old directory paths + manifest partition metadata reflects old spec**: correct mental model of Iceberg metadata-only spec evolution.
- **Fix = Spark rewrite_data_files with rewrite-all=true**: correct, forces rewrite of all files under current spec. Verified against Iceberg Spark procedures docs.
- **Trino issue citations #26109/#26503/#25279**: #25279 (IcebergMetadata applyFilter rejects newly-added partition predicates) and #26503 (Iceberg ALTER PARTITION NULL partitioning) verified. #26109 not independently verified but plausible in the same cluster.
- **Diagnostic SQL**: `SELECT spec_id, COUNT(*) FROM $files GROUP BY spec_id until only new spec_id` — exact actionable runbook. spec_id column on $files verified.
- **Resume Trino optimize for routine** after Spark migration — correct ops sequencing.

### Minor gaps
- Doesn't explicitly explain WHY old files still exist (Iceberg metadata-only spec evolution = manifests track spec_id, file bytes immutable until rewrite).
- Doesn't warn that rewrite-all on large tables is hours-long, or that combining `rewrite-all=true` with WHERE causes the dup-rows bug (iter405 Q3 had this).
- No cleanup chain reminder (expire_snapshots + remove_orphan_files after).

### Verdict
STRONG PASS. Closes iter405 Q3 implicit gap on Trino-vs-Spark optimize behavior.

---

## Q3 — MoR compaction cadence thresholds

**Scores: 4.5 / 4.0 / 5.0 / 4.5 — avg 4.5 STRONG PASS**

### What landed
- **Ratio-based triggers** with healthy/investigate/compact bands:
  - Position delete ratio `count(content=1)/count(content=0)`: <5% healthy / 5-10% investigate / >10% compact
  - Per-file density `avg(record_count)` on delete files: >50K healthy / <5K compact
- **content=1 = position delete, content=0 = data**: verified against Iceberg spec (data=0, position-delete=1, equality-delete=2).
- **Cadence-by-write-rate table**: <10K rows/day monthly, 10K-1M weekly, >1M daily, heavy CDC hourly or reconsider CoW. Honest "don't overthink at low volume" framing avoids over-engineering at small scale.
- **Monitoring SQL one-query computing pct_position_delete + avg_delete_record_count**: exactly the actionable artifact iter405 Q4 was missing.
- **`rewrite_position_delete_files` Spark-only**: verified Trino does not expose this procedure. Cites Trino #27371 (Iceberg Roadmap umbrella issue) — reasonable proxy for "Trino doesn't yet support this."

### Minor gaps
- Numeric thresholds (5% / 10%, 50K / 5K) are sensible operational heuristics but not anchored to a primary source. Acceptable since Iceberg docs don't publish a definitive threshold either.
- Doesn't mention `rewrite_data_files` with `delete-file-threshold` option as an alternative compaction trigger.
- Doesn't tie back to read-amplification impact at >50 delete files (iter395 Q2 #12838 context).
- "Heavy CDC hourly or reconsider CoW" is a one-liner that deserves more context — when does CDC volume make MoR untenable?

### Verdict
STRONG PASS. Cadence-by-write-rate table + monitoring SQL together close the iter405 Q4 "how often" gap with actionable numbers.

---

## Q4 — $refs and $properties usage

**Scores: 5.0 / 4.5 / 5.0 / 4.0 — avg 4.625 STRONG PASS**

### What landed
- **$refs schema**: name/type/snapshot_id/max_reference_age_in_ms/min_snapshots_to_keep. Verified against Iceberg branching docs and Trino Iceberg connector docs. Correct.
- **Use case for $refs**: discovering time-travel tag targets + checking retention policies. Aligns with the canonical Iceberg branching/tagging operations model.
- **Honest framing**: "most SaaS teams don't use branches/tags" — correct prioritization for the on-prem Spark+Trino+Iceberg 1.5.2 stack where Iceberg branching is rarely used.
- **$properties usage**: "effective table config" k/v table, most practical of the two. Verify `write.delete.mode` CoW vs MoR, `format-version` v1/v2, retention policies without Spark. Real scenario "can we DELETE rows" → check write mode. This is the SaaS engineer's actual daily use of $properties.
- **"Neither is daily maintenance" framing**: prevents over-emphasis on metadata tables that aren't on the hot path.

### Minor gaps
- No literal `SELECT * FROM tbl$refs` or `SELECT * FROM tbl$properties` example — beginner would benefit from one snippet.
- Doesn't mention `max_snapshot_age_in_ms` column on $refs.
- Doesn't mention that $properties is read-only from Trino — to mutate, use `ALTER TABLE SET PROPERTIES`.
- Doesn't cite the Trino 481 docs section that lists $refs and $properties.

### Verdict
STRONG PASS. Closes the metadata-tables cheat-sheet rotation (iter403→iter404→iter405→iter406). Engineer knows when each table is worth their time.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.75 | STRONG PASS — iter405 inaccuracy resolved |
| Q2 | 4.625 | STRONG PASS — Trino-vs-Spark optimize distinction |
| Q3 | 4.5 | STRONG PASS — MoR cadence thresholds + SQL |
| Q4 | 4.625 | STRONG PASS — $refs / $properties closes cheat-sheet rotation |

**Average 4.625 STRONG PASS.** All four iter406 probe targets landed at STRONG PASS. Critically, the iter405 Q2 inaccuracy (Trino #21859 / correlated NOT EXISTS LeftJoin cannot short-circuit) is **fully resolved** on the durability re-probe — the teacher's MEDIUM iter406 fix landed precisely on the gap.

**Trajectory iter394-406**: `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/**4.625P**`. Fifth consecutive PASS. Recovery from iter405 step-down (4.40625) back to STRONG PASS territory. The historic oscillation pattern (mid-3 FAILs every 4-6 iterations) appears damped — no FAIL in the last 5 iterations and the iter405 weakness was fixed without triggering a downstream regression elsewhere.

---

## Teacher actions next (iter 407)

1. **LOW polish** — add literal `SELECT * FROM tbl$refs` and `SELECT * FROM tbl$properties` example snippets to the metadata-tables resource (Q4 minor completeness gap).
2. **LOW polish** — gloss "anti-join" jargon in correlated-subquery resource for beginner clarity (Q1 minor clarity gap, carry from iter404).
3. **LOW polish** — in the partition-spec-migration resource, add the warning that combining `rewrite_data_files rewrite-all=true` with a WHERE clause causes the duplicate-rows bug + hours-long warning (Q2 minor completeness gap, carry from iter405).
4. **LOW** — tie MoR compaction cadence resource to the iter395 Q2 read-amplification context (>50 delete files → 2-5x read slowdown per Iceberg 1.5.2 #12838 context).
5. **LOW carry-forward backlog** unchanged: dbt-trino merge dups, predicate-pushdown JDBC rewrite, write.isolation-level, SHOW SESSION catalog-prefix, HMS->Nessie no-downtime, SPILL_FAILED 60GB cap, MERGE rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO/VALIDATE, result caching 2nd, Iceberg branches fast_forward, JWT+OPA concurrency, Iceberg tagging 3rd, fs.cache 3rd JMX, PERCENT_RANK/NTILE 3rd, RANGE INTERVAL gap-day.

## Judge probe targets next (iter 407)

1. **NOT EXISTS 4th-angle durability** — yet another phrasing to confirm the correlated/non-correlated distinction is durable across query shapes (e.g., correlated EXISTS for a whitelist filter — same architectural cost?).
2. **Iceberg branches `fast_forward`** — actual branching workflow that exercises $refs in operations (not just metadata inspection from Q4).
3. **Trino result caching 2nd-angle** — long-standing carry-forward.
4. **HMS-to-Nessie no-downtime migration** — long-standing carry-forward.
5. **`rewrite_data_files delete-file-threshold` option** — natural follow-on from Q3 MoR cadence (alternative trigger to ratio-based monitoring).
6. Carry-forward backlog rotation as needed.
