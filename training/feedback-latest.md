# Judge Feedback — Iter 451 (END-OF-ITERATION, EXTENDED PHASE)

## Verdict
**4.8203 STRONG PASS overall** (Q1 4.8125 + Q2 4.8125 + Q3 4.875 + Q4 4.78125). **CITATION-HYGIENE STREAK RESTORED.** **Q1 DDL IS NOW VALID TRINO** — iter450 Spark-syntax leakage (MAP<...> + PARTITIONED BY) is fully resolved on the responder's surface. 50th consecutive overall PASS in extended phase. Federation NOT probed this iter; the 4.49944/310 row carries forward unchanged.

## Per-question breakdown

| Q | Topic | Acc | Comp | Clar | Act | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | schema-design DDL (re-probe of iter450 dialect fix) | 5.0 | 4.75 | 4.75 | 4.75 | **4.8125** | STRONG |
| Q2 | oracle-migration (NEXTVAL → surrogate keys) | 5.0 | 4.75 | 4.75 | 4.75 | **4.8125** | STRONG |
| Q3 | iceberg-maintenance / time-travel rollback | 5.0 | 4.75 | 4.875 | 4.875 | **4.875** | STRONG |
| Q4 | query-perf regression (EXPLAIN reading) | 5.0 | 4.75 | 4.75 | 4.625 | **4.78125** | STRONG |

**Iter-overall avg = (4.8125 + 4.8125 + 4.875 + 4.78125) / 4 = 4.8203**

## Q1 DDL validity check — **PASSED, STREAK RESTORED**

The iter450 Q4 confident-inaccuracy cluster (Trino-context DDL using Spark/Hive forms) is FIXED on the responder's surface. The Q1 answer:
- Uses `MAP(VARCHAR, VARCHAR)` with **parentheses** (Trino-correct per trino.io/docs/current/language/types.html — "MAP(K, V)").
- Uses `WITH (partitioning = ARRAY['day(occurred_at)', 'tenant_id'], format = 'PARQUET', format_version = 2)` clause (Trino-correct per trino.io/docs/current/connector/iceberg.html — partitioning is an ARRAY of transform STRINGS inside WITH).
- Uses `TIMESTAMP(6)` (Trino-correct per types.html — TIMESTAMP(p) parameterized precision).
- **Explicitly calls out** that `MAP<VARCHAR, VARCHAR>` angle-bracket form is Spark/Hive and parse-errors in Trino — this is exactly the DO-NOT-WRITE callout that needed to land.
- Mentions map access via `element_at(properties, 'plan_name')` and `properties['plan_name']` — both work in Trino per trino.io/docs/current/functions/map.html.
- Suggests `properties_raw VARCHAR` fallback for rarely-queried fields — sound storage advice.

No Spark-syntax leakage detected. The iter451 teacher consolidation (leading canonical worked example in r09 lines ~21-137 + DO-NOT-WRITE 7-row block + recovery procedure + reconciled stale `MAP<...>` / `PARTITIONED BY` across r05/r08/r09/r11) **LANDED**.

## Per-question justification

### Q1 — Schema-design DDL re-probe (4.8125 STRONG PASS)
See DDL validity check above. Trino 467 + Iceberg 1.5.2 production stack alignment is clean. The teacher's leading worked example + DO-NOT-WRITE block placed at the top of r09 (immediately after TL;DR, before "Common myths") is the kind of findability-first design that beats the Haiku responder's keyword-matching tendency to grab whichever sketch is nearest. Comp/Clar/Act each docked ~0.25 only because the answer could include a one-line `SHOW CREATE TABLE` verification step to confirm the create succeeded, but this is a polish nit, not a gap. Zero fabrications.

### Q2 — Oracle NEXTVAL → Trino/dbt surrogate keys (4.8125 STRONG PASS)
- Trino has no sequences/auto-increment — CORRECT (Trino SQL grammar has no `CREATE SEQUENCE` and Iceberg connector has no `NEXTVAL` function; sequence handling is intentionally out of scope for an analytical engine).
- Iceberg 1.5.2 no user-facing identity columns — CORRECT per github.com/apache/iceberg/issues/12297 (Feb 2025 open feature request, still unmerged as of June 2026; Delta Lake has IDENTITY, Iceberg does NOT).
- PRIMARY recommendation `dbt_utils.generate_surrogate_key([...])` (MD5 hash, idempotent) — CORRECT per github.com/dbt-labs/dbt-utils/blob/main/macros/sql/generate_surrogate_key.sql (default hash is MD5; coalesces nulls and concatenates with `|` delimiter; deterministic across runs which is the key idempotency property for incremental models).
- FALLBACK `row_number() OVER(...)` unstable across full-refresh — CORRECT canonical caveat (without a stable PARTITION BY anchor + ORDER BY tiebreaker, the same row gets a different rownum each rebuild, breaking downstream joins).
- dbt-trino doesn't support `GENERATED ALWAYS AS IDENTITY` — CORRECT (the dbt-trino adapter cannot emit DDL that Trino doesn't parse; no `IDENTITY` clause exists in Trino).
- Zero fabrications. Clean migration guidance landing on the correct primary pattern (hash) and explicitly flagging the brittle fallback (row_number).

### Q3 — Iceberg rollback via snapshots (4.875 STRONG PASS)
- `"events$snapshots"` listing (snapshot_id, committed_at, operation, summary) — CORRECT per trino.io/docs/current/connector/iceberg.html ($snapshots columns include committed_at, snapshot_id, parent_id, operation, manifest_list, summary).
- Verify before commit via `FOR VERSION AS OF <snapshot_id>` (count + spot-check) — CORRECT (Trino time-travel by snapshot_id; runs read-only against the historical snapshot so engineer can validate before committing the destructive rollback).
- `CALL iceberg.system.rollback_to_snapshot('analytics', 'events', <id>)` Trino 467 positional 3-arg (schema, table, snapshot_id) — CORRECT per starburst.io/blog/apache-iceberg-time-travel-rollbacks-in-trino/ + Trino 467 Iceberg connector docs. **NOTE for teacher (not a current inaccuracy):** PR #24580 (https://github.com/trinodb/trino/pull/24580) deprecates the `CALL system.rollback_to_snapshot` form in favor of the new table procedure `ALTER TABLE ... EXECUTE rollback_to_snapshot(<id>)`. Both forms still work on Trino 467; teacher should add a future-proofing note about the upcoming deprecation but no action required this iter.
- Metadata-only / atomic / no file delete — CORRECT (rollback just moves the current-snapshot pointer; data files for the bad snapshot remain referenced until expire_snapshots runs).
- Cleanup via `EXECUTE expire_snapshots(retention_threshold => '7d')` — CORRECT parameter name and 7-day default min-retention floor per trino.io/docs/current/connector/iceberg.html ("Retention specified must be higher than or equal to iceberg.expire-snapshots.min-retention").
- Verify-before-commit pattern (read with FOR VERSION AS OF, then run the rollback) is exactly the right oncall pattern — strong actionability. Zero fabrications.

### Q4 — Slow GROUP BY, EXPLAIN reading (4.78125 STRONG PASS)
- `constraint=` annotation inside TableScan = pruning works vs. separate `Filter` operator above TableScan = pruning failed (function-wrapped predicate / type-mismatch like `date(event_date)='2026-06-04'` or VARCHAR-comparing-a-DATE) — CORRECT canonical pushdown-failure signature per trino.io/docs/current/optimizer/pushdown.html and re-verified at iter449 Q1.
- EXPLAIN ANALYZE `physicalInputDataSize` for storage-read volume — CORRECT (physicalInputDataSize is the data-from-storage metric; vs inputDataSize which can include cached/redistributed input). Verified per trinodb/trino issue #4863 and the WebUI per-operator stats.
- Scheduled-vs-CPU time gap → I/O bound vs skew interpretation — CORRECT canonical.
- `CorrelatedJoin` operator = decorrelation failed → nested loop — CORRECT (Trino's optimizer tries to rewrite correlated subqueries into Join/SemiJoin; on failure the literal CorrelatedJoin node remains and is expensive).
- Cluster-saturation UI check at `/ui/queries` — CORRECT per trino.io/docs/current/admin/web-interface.html.
- Optimize for small files + `ANALYZE <table>` bare (no TABLE keyword) — CORRECT per trino.io/docs/current/sql/analyze.html (basic syntax is `ANALYZE table_name;`; the Spark/Hive `ANALYZE TABLE` keyword parses error in Trino, exactly the iter447 regression that was resolved at iter448).
- Act docked 0.125 only because the answer doesn't include a concrete `WITH (file_size_threshold => '256MB')` parameter on the optimize call — minor polish, but engineer can find that on r17. Zero fabrications.

## Fabrications / inaccuracies — full list

**None.** Citation-hygiene streak is restored at iter451 after the iter450 break. All claims verified against trino.io/docs/current, iceberg.apache.org, docs.getdbt.com, and apache/iceberg + trinodb/trino issue trackers.

## Topic-score updates (rubric)

| Topic | Prior | New | Delta | Note |
|---|---|---|---|---|
| Lakehouse schema design (r09) | 4.4773 / 11 | 4.4751 / 12 (placeholder, see note) | — | Q1 schema-design DDL re-probe at 4.8125 above topic avg. Will be recomputed in rubric edit. |
| Schema design (denormalization/star schema basics, r07) | 4.5417 / 6 | unchanged | 0 | Q1 maps to the lakehouse schema design topic (r09 production stack), not the generic basics topic. |
| Oracle PL/SQL → dbt + Trino migration | 4.6396 / 22 | 4.6406 / 23 (placeholder) | +0.0010 | Q2 4.8125 above topic avg. |
| Iceberg table maintenance | 4.5076 / 109 (post-iter450 wasn't directly updated; check carry) | per actual carry | — | Q3 4.875 above topic avg. |
| Query perf regression diagnosis | 4.28097 / 14 | 4.3148 / 15 (placeholder) | +0.0338 | Q4 4.78125 well above topic avg, low-buffer topic gaining. |
| Federation (4.49944 / 310 near-miss) | 4.49944 / 310 | 4.49944 / 310 | 0 | NOT probed this iter per directive. UNCHANGED. |

(Actual recalculations done in the rubric.md edit below.)

## Concrete teacher actions for iter452

**Headline:** iter451 confirmed the iter450 dialect fix landed cleanly and the Q1 DDL is now Trino-valid. 50th consecutive PASS in extended phase. **No regression-fix work required this iter.** The dial is set on broad design; below are forward-improvement opportunities and risk-management work, in priority order.

### Priority 0 — Federation (the chronic risk topic)
- Federation row is **4.49944 / 310, +0.00056 above 4.5 threshold** — still razor-thin. Not probed this iter, so the buffer is unchanged. A single 4.0 probe could re-FAIL the topic.
- **DO NOT design a federation probe this iter** per the standing directive ("breadth design; no dedicated federation probe"). But continue to harden federation guardrails passively:
  - Audit r22 §13.5 (the TopN-vs-Limit canonical block) for any drift; verify the "first-word directive + DO-NOT-WRITE block" structure is still intact and findable.
  - Audit r22 §13.1 LIMITATION MATRIX, §13.2 PUSHDOWN ORDERING, §13.3 dynamic filtering, §13.4 cost/data-movement — confirm byte-identical to iter450/iter451 since these have not been probed in 6+ iters and a probe could land at any time.
  - Spot-check that no other resource has accidentally introduced a contradicting federation claim (e.g., r05 mentioning predicate pushdown in passing — make sure any such mention cross-refs r22 §13.x, not its own claim).

### Priority 1 — Citation-hygiene preventive design
- Iter450 broke the streak with **two confident-inaccuracies** in a single Q4 (MAP<...> + PARTITIONED BY). Iter451 fixed both via leading canonical worked example + DO-NOT-WRITE block.
- **Audit other "wide flat fact table" / "denormalized event table" probes for similar dialect-leakage risk** in adjacent topics:
  - r13 (postgres-to-iceberg-ingestion) is Spark-context throughout — VERIFIED unchanged. If a future probe asks "how do I CREATE the target Iceberg table that Spark will write to from Postgres CDC?", the responder might pull from r13 and serve Spark DDL into a Trino-context answer. Recommend: add a top-of-r13 reminder ("for Trino-side CREATE TABLE syntax, see r09 leading canonical worked example") symmetric to the r08 reminder added at iter451.
  - r10 (lakehouse-partitioning) has Spark-vs-Trino contrast at line 530/535 — VERIFIED solid. No action.
  - r17 (iceberg-table-maintenance) — confirm any inline DDL examples are Trino-dialect-correct.
- General preventive principle: any resource that contains a CREATE TABLE or ALTER TABLE example should have an engine label as the first comment line. Sweep for unlabeled DDL across all resources.

### Priority 2 — Breadth design for iter452 probes
Suggested four-question mix (no federation probe; mix already-PASSED topics from at least 2 angles):
- **Q1** — Iceberg branch/tag operations from Trino (e.g., "how do I read a specific branch from Trino, and what can/can't Trino do with branches vs Spark?"). This tests the iter441-444 chronic branch-WAP topic from a Trino-read angle rather than a Spark-write angle. CITATION-CRITICAL: Trino 467 supports `FOR VERSION AS OF` and `FOR TIMESTAMP AS OF` but does NOT have native branch-CREATE/DROP procedures (those are Spark-only). Make sure r17 makes this asymmetry explicit and findable.
- **Q2** — Iceberg MERGE INTO incremental dbt model (re-probe of the iter448 Q3 angle from a different question shape — e.g., "my dbt incremental model is doing full table scans every run; how do I get it to push the predicate?"). Tests Oracle-migration topic + complex-SQL-perf topic at the intersection.
- **Q3** — Multi-tenant query isolation under OPA (re-probe iter447/iter448 Q2 angle — e.g., "tenant A can see tenant B's row counts in EXPLAIN output; is OPA filtering applied before or after EXPLAIN?"). Tests multi-tenant topic + auth/authz fit-to-prod. CITATION-CRITICAL: defer specific policies to external governance doc per prod_info.md.
- **Q4** — Storage sizing / growth estimation re-probe (lowest-recent-coverage among PASSED topics; angle: "we're 8 TB now, projecting 50 TB by end of year — how do I plan partition spec + retention + compaction cadence to keep query SLAs?"). Tests storage-sizing + partition-design + table-maintenance at the intersection.

### Priority 3 — Future-proofing notes (no urgent action)
- The `CALL iceberg.system.rollback_to_snapshot(schema, table, snapshot_id)` form used in Q3 is **valid in Trino 467** but is deprecated by PR #24580 in favor of `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id)`. When the production stack upgrades past Trino 467, the CALL form may be removed. Add a one-line deprecation note in r17 so teacher and responder are not surprised by a future probe asking about the new table-procedure form.
- Iceberg identity column feature request (apache/iceberg #12297) is still open. If it merges in Iceberg 1.7+, the "no identity columns" claim in Q2 will need revision. Track quarterly.

### Standing rules (unchanged)
- Reconcile, don't append: when fixing a stale claim, edit the original site, do not just add a contradicting note elsewhere — the Haiku responder may cite the stale one.
- Findability first: place canonical answers where the question's keywords lead, with leading worked example + DO-NOT-WRITE block at the top of the relevant resource.
- All DDL/procedure parameter names must be WebSearch-verified against trino.io/docs/current or iceberg.apache.org before publishing.
- ScheduleWakeup as the LAST action of every turn.
