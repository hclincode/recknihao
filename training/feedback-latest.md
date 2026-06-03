# Judge Feedback — Iter 408 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.125 PASS** (Q1 4.625 + Q2 3.0 + Q3 4.5 + Q4 4.375)

**Headline: ITER407 Q2 INACCURACY IS DURABLY RESOLVED.** The Iceberg branches + fast_forward WAP re-probe (Q1) was answered correctly with all four lifecycle steps spelled out, the Spark/Trino split correctly drawn, and all three Trino issue numbers (#12844 umbrella, #16569 read-done, #16570 write closed-not-planned) cited. The teacher's iter408 MEDIUM fix in `resources/17-iceberg-table-maintenance.md` landed.

**Pattern change worth noting:** Q2 (Trino materialized views) was a PUNT — "I don't have enough information" — not a confident inaccuracy. This is a meaningful behavioral improvement over iter405/iter407 where the responder fabricated wrong claims (e.g., "branches are Spark-only"). Honest "don't know" when resources are missing is exactly the desired failure mode. **However**, it's still an unanswered question and Trino DOES support materialized views on Iceberg — so this exposes a new resource gap that the teacher must fill in iter409.

Seventh consecutive PASS. The oscillation pattern (iter401/iter403/iter405/iter407 mid-iteration FAILs) has not recurred. Score stability around 4.0-4.6 with the iter407 inaccuracy fixed.

---

## Q1 — Iceberg branches + fast_forward WAP (iter407 Q2 RE-PROBE)

**Scores: 4.5 / 4.5 / 5.0 / 4.5 — avg 4.625 STRONG PASS**

### What landed
- **4-step WAP lifecycle correctly stated:**
  1. Spark `CREATE BRANCH audit-branch RETAIN 7 DAYS` (Trino cannot create — verified #16570).
  2. Spark writes with `spark.wap.branch=audit-branch`, main untouched.
  3. Trino reads via `$refs` (snapshot_id lookup) then `FOR VERSION AS OF '<branch-name>'` for audit queries; default readers see main only.
  4. Spark `CALL system.fast_forward('analytics.events','main','audit-branch')` — atomic metadata-only commit, no data rewrite, no partial-state window — OR `DROP BRANCH` if audit fails.
- **Trino issue citations all correct:** #12844 umbrella, #16569 (READ done), #16570 (WRITE closed not planned).
- **Trino CAN read branches via FOR VERSION AS OF** — verified against Trino 481 docs (`SELECT * FROM tbl FOR VERSION AS OF 'audit-branch'`).
- **Trino CANNOT write branches** — verified #16570 closed not-planned (INSERT always commits to main).
- **fast_forward = metadata-only atomic commit** — verified against Apache Iceberg Spark Procedures docs.
- **View-swap correctly framed as Trino-only fallback NOT canonical** when Spark is in stack.

### Minor gaps
- Dense style — beginner clarity loses half a point.
- No literal `spark.wap.branch` DataFrame write syntax sample (`df.write.option('branch','audit-branch').insertInto('analytics.events')` or equivalent).
- No explicit "main advances mid-audit → rebase or MERGE" callout (the FAQ block in the resource covers this, but the responder didn't lift it).

### Verdict
**STRONG PASS — iter407 Q2 INACCURACY DURABLY RESOLVED.** The teacher's MEDIUM fix is confirmed working. The "branches are Spark-only" dodge mechanism is gone.

---

## Q2 — Trino materialized views on Iceberg (PUNTED)

**Scores: 4.0 / 3.5 / 3.0 / 1.5 — avg 3.0 LOW PASS**

### What landed
- **Honest punt:** "I don't have enough information" — resources don't cover Trino materialized views. No fabricated claims.
- **Offered correct alternative patterns:** dbt pre-aggregated rollup table, partition-pruning filters.
- **Pointed user to official Trino Iceberg connector docs + test in env** — appropriate fallback when resources are silent.

### What's missing (resource gap, NOT a responder failure)
- **Trino DOES support materialized views on Iceberg** per Trino 481 docs:
  - `CREATE MATERIALIZED VIEW` with storage table layered as Iceberg.
  - `REFRESH MATERIALIZED VIEW` — incremental refresh when all sources are Iceberg, full refresh otherwise.
  - Staleness detection across source Iceberg snapshots (grace period via `mv_storage_table` properties).
  - Storage table properties: `storage_schema`, `format`, `partitioning` controllable via CREATE.
  - No auto-refresh — refresh must be triggered (typically via cron / dbt / orchestrator).
- The resources folder has zero coverage of Trino MVs (grep across `resources/` returns no matches for `MATERIALIZED VIEW` outside passing mentions in 06/14/22).

### Honest punt is better than confident wrong
This is a meaningful behavioral improvement over iter405 ("perf should be identical" — wrong) and iter407 ("branches are Spark-only" — wrong). When resources are missing, "I don't have enough information" is the right output. Do NOT punish the responder for honesty.

### But it's still an unanswered question
Completeness scores 1.5 because the engineer asked a specific question and didn't get an answer. The alternatives offered (dbt rollup) are workable but not what was asked.

### Verdict
**LOW PASS** — honest behavior, real resource gap. Teacher MUST fill the Trino MV gap in iter409.

---

## Q3 — Concurrent write snapshot conflicts

**Scores: 4.5 / 4.0 / 5.0 / 4.5 — avg 4.5 STRONG PASS**

### What landed
- **Iceberg optimistic concurrency model:** NOT locking — commit-time validation ("is the snapshot I read still current?"). Correct.
- **"Failed to commit: Requirements not met"** — verified as Iceberg's conflict error message.
- **Fixes correctly enumerated:**
  - Different partitions = no conflict (`overwritePartitions` atomic partition-scoped).
  - Same hot partition = `partial-progress.enabled=true` commits per partition independently.
  - `commit.retry.num-retries` auto-retries (responder said ~20 default — see nit below).
  - Clean separation = staging table + MERGE or branch fast_forward (tied back to Q1).

### Minor gaps
- `commit.retry.num-retries` default is actually **4**, not ~20 in Iceberg upstream. The number ~20 may have been a misremembering or applies to a specific config layer. This is a small accuracy nit on a key tuning knob — fix in resource.
- Doesn't mention `commit.retry.min-wait-ms` / `commit.retry.max-wait-ms` exponential backoff defaults.
- Doesn't mention `write.distribution-mode=hash` for hot-partition write distribution.

### Verdict
STRONG PASS. Concurrency model framing is solid. Minor numeric nit on retry default.

---

## Q4 — Orphan file cleanup vs in-flight long queries

**Scores: 4.5 / 4.5 / 4.5 / 4.0 — avg 4.375 STRONG PASS**

### What landed
- **3-day retention default verified** against Iceberg `remove_orphan_files` docs (older_than = 3 days default).
- **Retention semantics correct:** files not modified in last N days are eligible — protects in-flight writes still being committed.
- **10-15 min queries finish within 3-day window** — correct framing for the engineer's risk model.
- **Distinction between expire_snapshots vs remove_orphan_files** drawn cleanly:
  - `expire_snapshots` removes snapshots from history, dereferenced data files get S3 DELETEd.
  - `remove_orphan_files` removes physical files that are NOT referenced by any live snapshot AND are older than retention.
- **Safer pattern:** schedule maintenance in quiet window (2-4 AM), `dry_run` first.

### Minor gaps
- "Live snapshot referenced by query context not deleted" is slightly imprecise — Iceberg's safety mechanism is file-mtime + retention, NOT query reservation. A query reading snapshot S is protected because S still exists in table metadata (until `expire_snapshots` removes S), not because the query "holds" S. The operational outcome is the same but the mental model framing matters for a debugger.
- Doesn't explicitly state `remove_orphan_files` is Spark-only in this stack (Trino doesn't expose the procedure).

### Verdict
STRONG PASS. Operational safety guidance is correct. Minor framing nit on the protection mechanism.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.625 | STRONG PASS — Iceberg branches+fast_forward re-probe DURABLY RESOLVED |
| Q2 | 3.0 | LOW PASS — honest punt on Trino MVs, resource gap to fill |
| Q3 | 4.5 | STRONG PASS — concurrent write snapshot conflicts |
| Q4 | 4.375 | STRONG PASS — orphan file 3-day retention safety |

**Average 4.125 PASS** — modest recovery from iter407 4.0625 in headline score, but **the structural failure pattern has improved**: iter407 had a confident factual inaccuracy; iter408 has an honest "don't know" punt. That's a meaningful behavioral improvement.

**Trajectory iter394-408:** `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/4.625P/4.0625P/**4.125P**`. Seventh consecutive PASS.

**ITER407 Q2 inaccuracy resolution: CONFIRMED.** The "branches are Spark-only" dodge is gone. Q1 re-probe answered correctly with full Spark/Trino split and all three Trino issue numbers. Teacher MEDIUM fix in `resources/17-iceberg-table-maintenance.md` landed.

---

## Teacher actions next (iter 409)

1. **MEDIUM — Trino materialized views on Iceberg resource gap.** Add a new section (in `resources/17-iceberg-table-maintenance.md` or a new file) covering:
   - `CREATE MATERIALIZED VIEW` Trino syntax with Iceberg storage table.
   - Storage table properties: `storage_schema`, `format`, `partitioning`, `format-version`.
   - `REFRESH MATERIALIZED VIEW` semantics — incremental refresh when sources are all Iceberg, full refresh otherwise, grace-period freshness detection across source snapshots.
   - No auto-refresh — refresh must be triggered (cron, dbt, orchestrator).
   - MV vs dbt rollup vs Spark Iceberg rollup table — decision matrix (Trino-managed lifecycle vs orchestrated job vs Spark-side rewrite).
   - `iceberg.materialized-views.storage-schema` connector config.
   - Cite Trino 481 Iceberg connector docs `#materialized-view-management` section.

2. **LOW polish — `commit.retry.num-retries` default value verification.** Iceberg upstream default is 4, not ~20. Fix wherever the resource states this default (Iceberg concurrency / optimistic concurrency resource).

3. **LOW polish — Iceberg optimistic concurrency resource:** add `commit.retry.min-wait-ms` / `commit.retry.max-wait-ms` exponential backoff defaults; add worked example of two concurrent INSERTs to disjoint partitions (no conflict) vs same partition (conflict + retry).

4. **LOW polish — orphan file resource:** explicit "remove_orphan_files needs Spark in your stack" callout; clarify retention threshold semantics (file last-modified-time vs metadata-reference); state that the file-mtime + retention is the safety mechanism, not query reservation.

5. **LOW carry-forward backlog:** dbt-trino merge dups, predicate-pushdown JDBC rewrite, write.isolation-level, SHOW SESSION catalog-prefix, HMS->Nessie no-downtime, SPILL_FAILED 60GB cap, MERGE rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO/VALIDATE, JWT+OPA concurrency, Iceberg tagging 3rd, fs.cache 3rd JMX, PERCENT_RANK/NTILE 3rd, RANGE INTERVAL gap-day, equality delete 1.5.2 bug context, Iceberg v3 deletion vectors timeline.

---

## Judge probe targets next (iter 409)

1. **CRITICAL Trino materialized views on Iceberg** — durability re-probe after teacher MEDIUM fix lands. Probe REFRESH semantics (incremental vs full), storage table layout properties, MV vs dbt rollup decision, no-auto-refresh constraint.

2. **Iceberg branch READ from Trino — 3rd angle** — "I want to expose `audit-branch` as a view for analysts — how do I write that CREATE VIEW?" probes `FOR VERSION AS OF '<branch-name>'` usage inside CREATE VIEW.

3. **`commit.retry.num-retries` tuning — natural follow-on from Q3** — "how do I increase retries for a hot partition that always conflicts?" — confirms responder knows the correct default (4) and tuning knobs.

4. **HMS-to-Nessie no-downtime migration** — long-standing carry-forward. Especially relevant now that branches are a confirmed-working pattern (Nessie is the canonical catalog for branch-heavy workflows).

5. **Iceberg v3 deletion vectors timeline** — "when does this stack get deletion vectors and what changes for compaction?" — probes upstream-fix horizon understanding.

6. Carry-forward backlog rotation as needed.
