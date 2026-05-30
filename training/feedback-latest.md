# Judge Feedback — Iter 405 (EXTENDED PHASE)

**Overall: 4.40625 PASS** (Q1 4.75 + Q2 3.625 + Q3 4.625 + Q4 4.625)

This iteration probed the four iter404 follow-ups. Three out of four landed strongly; Q2 is the weak link — a real technical inaccuracy on NOT EXISTS vs NOT IN performance that the responder glossed over with "should be identical." That single misclaim drops Q2 to a low-PASS and tugs the overall down.

---

## Q1 — $snapshots / $manifests / $files distinction (storage investigation)

**Scores: 5.0 / 4.5 / 5.0 / 4.5 — avg 4.75 STRONG PASS**

### What went well
- **Three-layer mental model**: snapshot layer ($snapshots/$history) = when writes happened; index layer ($manifests) = metadata overhead; leaf layer ($files/$partitions) = physical files. This is the clean conceptual scaffold that closes the iter403/iter404 cheat-sheet gap.
- **Storage investigation runbook**: start with $partitions (per-partition record_count/file_count/total_size — metadata-only, fastest), then $files for per-file sizes. The content=0 (data) vs content=1 (delete) distinction is the correct Iceberg metadata table convention.
- **Healthy file size band**: 128–512MB target. Matches Iceberg best-practice.
- **When-to-use table**: Differentiates "investigate write activity" ($snapshots/$history) vs "investigate metadata bloat" ($manifests) vs "investigate physical files" ($files/$partitions). The "NOT interchangeable" callout is the key insight that beginners miss.

### Minor gaps
- Did not mention $refs (branches/tags) or $properties — minor; not required by question.
- Did not show literal SELECT examples for each table.

### Verdict
Closes the iter403/iter404 cheat-sheet carry-forward. Strong PASS.

---

## Q2 — NOT EXISTS slower than NOT IN (anti-join executor cost)

**Scores: 3.0 / 4.0 / 4.0 / 3.5 — avg 3.625 LOW PASS — TECHNICAL INACCURACY**

### What went well
- **3VL correctness framing**: Correctly explained NULL-safety of NOT EXISTS as the reason to switch from NOT IN. Sound.
- **Diagnostic moves**: Run EXPLAIN, look for SemiJoin ANTI vs CorrelatedJoin; run ANALYZE if CorrelatedJoin. These are the right next steps.
- **Honest framing of NOT IN safety**: NOT IN is fine when column is guaranteed non-NULL (NOT NULL schema constraint or IS NOT NULL guard), but "brittle." Accurate.
- **Three-scenario lookup**: original NOT IN worked = same anti-join; original returned zero rows = NOT EXISTS doing MORE work because previously short-circuiting on UNKNOWN. The "more correct work = slower" framing is genuinely useful.

### CRITICAL technical issue
The answer's framing that NOT IN and NOT EXISTS "decorrelate to the same anti-join so performance should be identical" is **not always true**, and this is the exact gap the question was probing. Verified against [Trino issue #21859](https://github.com/trinodb/trino/issues/21859):
- Correlated NOT EXISTS in Trino is implemented as a LeftJoin that **enumerates all matches** rather than short-circuiting after the first hit. The optimization to add a `singleMatch` flag to JoinNode has been proposed but not landed.
- This means a correlated NOT EXISTS can produce many duplicate join rows that subsequent aggregation/filtering must process — work that NOT IN's SemiJoin operator avoids because SemiJoin is built to return only true/false per probe row.
- The blanket claim "perf should be identical" is therefore wrong for the correlated case. The right answer is: **non-correlated** NOT IN and NOT EXISTS over a subquery both lower to SemiJoin and perform similarly; **correlated** NOT EXISTS can be measurably slower because the join cannot short-circuit.

The responder's "check EXPLAIN for SemiJoin ANTI vs CorrelatedJoin" is the right action, but it implies the user's slowdown must be a planner regression — when in fact it can be inherent executor cost even when decorrelation succeeds (LeftJoin without singleMatch).

### Minor gaps
- Did not name Trino issue #21859 or the singleMatch optimization gap.
- Did not give an actionable bottom line for the slower-after-switch case (e.g., "if the column is non-nullable, NOT IN with a SemiJoin can be the right choice; if nullable, accept that NOT EXISTS is correct even if slower, or pre-filter NULLs with a subquery wrapper").

### Verdict
LOW PASS. Technical inaccuracy on "performance should be identical" — the question was specifically probing this and the responder did not land it. Teacher should add a resource note documenting the LeftJoin-without-singleMatch limitation for correlated NOT EXISTS.

---

## Q3 — Partition spec evolution day(ts) → add tenant_id

**Scores: 4.5 / 4.5 / 5.0 / 4.5 — avg 4.625 STRONG PASS**

### What went well
- **ALTER TABLE SET PROPERTIES partitioning**: Correct Trino syntax verified against [Trino 481 docs](https://trino.io/docs/current/connector/iceberg.html). `ALTER TABLE t SET PROPERTIES partitioning = ARRAY['day(ts)', 'tenant_id']` works.
- **Old files keep old spec — correct**: Iceberg partition spec evolution is metadata-only; existing data files retain their original spec ID in manifests. Verified.
- **Queries still correct**: Iceberg's split planner merges across specs. Filters on `day` prune both old and new files (both specs have day). Filter on `tenant_id` only prunes new files. This is the canonical Iceberg spec-evolution behavior.
- **Fix: rewrite_data_files with rewrite-all=true (Spark)**: Correct — Iceberg's Spark RewriteDataFiles action with `rewrite-all` is what re-partitions old files to the current spec. Verified against [Iceberg Spark procedures](https://iceberg.apache.org/docs/latest/spark-procedures/).
- **Warns hours-long + don't combine rewrite-all with WHERE (dup rows bug)**: Accurate operational gotcha.
- **Cleanup chain**: expire_snapshots + remove_orphan_files after the rewrite. Correct sequencing.

### Minor gaps
- Could mention that Trino's `ALTER TABLE t EXECUTE optimize` does file compaction within partitions but does NOT repartition old files to the new spec — i.e., even after running Trino optimize, old files keep their day-only partition. Verified against Trino issue #25279 / #26503. This is the precise reason Spark is required for the rewrite step.
- Did not mention partition transform stability — once tenant_id is added as a partition column it becomes a tracked field-id in the spec history.

### Verdict
Strong PASS. The Spark-only callout for rewrite-all is correct and important for the on-prem Spark-ingestion / Trino-query split.

---

## Q4 — MERGE rewriting 80GB, switch to MoR (CoW vs MoR write.merge.mode)

**Scores: 4.5 / 4.5 / 5.0 / 4.5 — avg 4.625 STRONG PASS**

### What went well
- **Three independent properties named correctly**: `write.delete.mode`, `write.update.mode`, `write.merge.mode`. Verified against Iceberg docs that all three exist, default to `copy-on-write`, and can be set independently. Setting only `write.merge.mode = merge-on-read` does NOT change DELETE or UPDATE behavior — the responder's "all three independent" callout is the precise nuance.
- **CoW vs MoR mechanism**: CoW rewrites full files containing affected rows; MoR writes position-delete markers and lets the reader merge at query time. Write cost drops; read cost rises. Verified.
- **Position-delete accumulation downside**: MoR requires regular position-delete compaction. Verified — Iceberg has `rewrite_position_delete_files` Spark procedure for this. The responder is correct that it must run from Spark side; [verified that Trino's Iceberg connector does NOT expose rewrite_position_delete_files as ALTER TABLE EXECUTE](https://trino.io/docs/current/connector/iceberg.html), so it lives on the Spark ingestion side. This matches the on-prem prod stack.
- **rewrite_data_files with delete-file-threshold**: Correct — this is the Spark RewriteDataFiles option that triggers data rewrite when too many delete files have accumulated.
- **Verify via $files content=1 count**: Genuinely actionable — content=1 is the position-delete file marker; counting them measures compaction debt.
- **Trade-off table**: CoW nightly-pain vs MoR weekly-compaction is a useful operational mental model.

### Minor gaps
- Did not mention Iceberg 1.5.2 equality-delete bug #12838 (relevant context for the prod stack — though MoR with position deletes is unaffected, only equality deletes have the read-amplification issue).
- Did not specify what "frequent" compaction cadence actually means in numbers (e.g., when position-delete file count > 10% of data file count, or > N MB).
- Did not warn about read-side cost amplification proportional to delete file count for queries that don't prune well.

### Verdict
Strong PASS. Closes the iter400–402 CoW vs MoR carry-forward cleanly. The Spark-only callout for `rewrite_position_delete_files` is correct and important.

---

## Pattern across all four answers

| Q | Score | Gap closed |
|---|---|---|
| Q1 | 4.75 | Metadata tables cheat sheet (iter403+iter404 carry) |
| Q2 | 3.625 | NOT EXISTS perf — technical inaccuracy on "identical" |
| Q3 | 4.625 | Partition spec migration (backlog) |
| Q4 | 4.625 | CoW vs MoR write.merge.mode (iter400-402 carry) |

**Average 4.40625** — PASS. Three of four iter405 probe targets landed strongly. Q2 is the weak link with a real technical claim error (correlated NOT EXISTS executor cost gap — Trino issue #21859 is not surfaced).

Trajectory iter394–405: `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/**4.40625P**`. The "PASS-PASS-PASS" run continues — fourth consecutive PASS after iter402, but step-down from iter404 high (4.6875 → 4.40625). Oscillation pattern damped but not broken: the iter405 Q2 weakness is exactly the kind of nuance that has previously triggered the next-iteration FAIL.

---

## Teacher actions next (iter 406)

1. **MEDIUM — fix Q2 inaccuracy**: Add a focused resource note to the NOT IN/NOT EXISTS resource that distinguishes:
   - **Non-correlated** NOT IN vs NOT EXISTS over a subquery → both decorrelate to SemiJoin via Trino's Decorrelate Subqueries rule; performance comparable.
   - **Correlated** NOT EXISTS → implemented as LeftJoin which cannot short-circuit on first match (per [Trino issue #21859](https://github.com/trinodb/trino/issues/21859)). Can be measurably slower than the equivalent non-correlated form even when decorrelation succeeds.
   - **Bottom-line**: if user reports "NOT EXISTS slower than NOT IN," check (a) is the subquery correlated, (b) does EXPLAIN show LeftJoin or SemiJoin. Workaround: rewrite as non-correlated form (anti-join via LEFT JOIN ... WHERE IS NULL + DISTINCT) or accept correctness premium.
2. **LOW polish** — Add to Q3 partition-spec-migration resource: Trino's `ALTER TABLE t EXECUTE optimize` does NOT repartition old files to new spec; only Spark's RewriteDataFiles with `rewrite-all=true` does. Document the Trino limitation explicitly so users don't try optimize and wonder why old files still have the old spec.
3. **LOW polish** — Add to Q4 MoR resource: when does compaction cadence trigger? Sensible thresholds (e.g., position-delete file count > 10% of data file count, or per-file delete record count > N), plus a $files content=1 monitoring SQL snippet.
4. **LOW carry-forward backlog** unchanged: dbt-trino merge dups, predicate-pushdown JDBC rewrite, write.isolation-level, SHOW SESSION catalog-prefix, HMS→Nessie no-downtime, SPILL_FAILED 60GB cap, MERGE rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO/VALIDATE, result caching 2nd, Iceberg branches fast_forward, JWT+OPA concurrency, Iceberg tagging 3rd, fs.cache 3rd JMX, PERCENT_RANK/NTILE 3rd, RANGE INTERVAL gap-day, equality delete 1.5.2 bug context.

## Judge probe targets next (iter 406)

1. **NOT EXISTS 3rd-angle re-probe** — "I ran EXPLAIN and see LeftJoin not SemiJoin even after switching to NOT EXISTS, why?" — probes the correlated NOT EXISTS LeftJoin executor-cost gap that iter405 Q2 missed. This is the critical re-probe.
2. **Partition spec migration 2nd-angle** — "I ran Trino's ALTER TABLE EXECUTE optimize after changing partition spec but old files are still day-only partitioned, why?" — probes the Trino-vs-Spark optimize distinction Q3 left implicit.
3. **MoR compaction cadence 4th-angle** — "How often should I run rewrite_position_delete_files and what's the trigger threshold?" — natural follow-on from Q4 iter405.
4. **Metadata tables 3rd-angle** — "$refs and $properties — when do I use those?" — completes the cheat-sheet rotation iter405 started.
5. Carry-forward backlog rotation as needed.
