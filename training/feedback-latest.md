# Judge Feedback — Iter 469 (Extended Phase, End-of-Iteration)

**Date**: 2026-06-05
**Phase**: Extended (end-of-iteration feedback only)
**Overall**: **4.648 STRONG PASS** (68th consecutive overall PASS in extended phase)

## Verdict summary

| Question | Avg | Verdict | Topic |
|---|---|---|---|
| Q1 — per-tenant CREATE VIEW SECURITY DEFINER (re-probe of iter468 syntax slip) | **4.78** | STRONG PASS | Multi-tenant analytics / view-security syntax |
| Q2 — Oracle REGEXP_LIKE / REGEXP_REPLACE → Trino | **4.5625** | PASS | Oracle PL/SQL→dbt/Trino migration / regex mapping |
| Q3 — Iceberg compaction verify + metadata inspect | **4.59** | STRONG PASS | Iceberg table maintenance / metadata inspection |
| Q4 — EXPLAIN partition pruning | **4.66** | STRONG PASS | Query performance basics / EXPLAIN reading |

## Per-question scores

### Q1 — 4.78 STRONG PASS — view-security fix CONFIRMED (streak 1/1)

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 4.875 | `CREATE VIEW iceberg.tenant_acme.events SECURITY DEFINER AS SELECT ... WHERE tenant_id = 'acme'` matches the canonical Trino 467 grammar `CREATE [OR REPLACE] VIEW name [COMMENT '...'] [SECURITY {DEFINER \| INVOKER}] AS query` verified at trino.io/docs/current/sql/create-view.html. REVOKE/GRANT ON ... TO ROLE syntax matches trino.io/docs/current/sql/grant.html + /sql/revoke.html. |
| Completeness | 4.625 | DEFINER rationale (owner's perms, tenant has no base-table grant), OPA-also-denies-base layered defense, subset projection (dropping tenant_id) all covered. Could have mentioned `current_user` returns CALLER under DEFINER nuance but not load-bearing. |
| Clarity | 4.75 | Explicitly stated "SECURITY DEFINER goes BETWEEN view name and AS, NOT after query, NOT in WITH(...)" — directly addresses the iter468 slip. |
| Actionability | 4.875 | Copy-paste DDL parses on Trino 467; REVOKE/GRANT pair is sufficient to enforce isolation on top of OPA. |

**ZERO fabrications.** Did NOT use `WITH (SECURITY DEFINER)`, `WITH (security = 'DEFINER')`, `SECURITY = DEFINER`, `ALTER VIEW SET SECURITY ...`, or any post-AS placement. **Iter468 syntax slip is FIXED. Streak start 1/1.**

### Q2 — 4.5625 PASS — regex function mapping

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 4.75 | `regexp_like(string, pattern)` returns boolean, `regexp_replace(string, pattern, replacement)`, `regexp_extract` as REGEXP_SUBSTR replacement — all verified at trino.io/docs/current/functions/regexp.html. Lowercase naming convention correct. |
| Completeness | 4.25 | Missed: (a) Trino `regexp_like` is CONTAINS-semantic vs Oracle's full-match-with-anchors split that bites migrators; (b) Trino uses Java/Joni regex flavor vs Oracle POSIX extended (backreferences, lookaround support differ); (c) `$N` capture-group reference syntax in Trino regexp_replace. |
| Clarity | 4.625 | Side-by-side framing, lowercase note, REGEXP_SUBSTR→regexp_extract rename callout. |
| Actionability | 4.625 | Engineer can do a literal s/REGEXP_LIKE/regexp_like/ on most cases; the missing regex-flavor nuance means edge cases may break silently. |

**ZERO fabrications.** No invented `regexp_substr` on Trino, no fake signatures.

### Q3 — 4.59 STRONG PASS — Iceberg compaction + metadata

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 4.75 | `$files` content codes 0=DATA / 1=POSITION_DELETES / 2=EQUALITY_DELETES per Iceberg spec; `$snapshots` columns (snapshot_id, committed_at, operation, summary) per trino.io/docs/current/connector/iceberg.html; `operation='replace'` for MERGE/compaction (Iceberg RewriteFiles commits as `replace`) confirmed; `EXECUTE remove_orphan_files(retention_threshold => '7d')` syntax verified. Double-quoted `"events$files"` and `"events$snapshots"` correctly applied. |
| Completeness | 4.375 | Missed: `expire_snapshots` as complementary procedure (remove_orphan_files cleans non-referenced files, but expired snapshot data files require expire_snapshots first); didn't surface that compaction-induced `replace` produces new files even when row count is unchanged. |
| Clarity | 4.625 | Three concrete query patterns, content-code legend, operation-code legend. |
| Actionability | 4.625 | Three runnable queries + procedure call; engineer can verify compaction landed by checking before/after file count + content distribution. |

**ZERO fabrications.** No fake `$files` columns (no `deletion_count` or `compaction_run_id`), no fake `$snapshots` operations, no fake procedure params.

### Q4 — 4.66 STRONG PASS — EXPLAIN partition pruning

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 4.625 | `TableScan[... constraint on [...]]` annotation is real per trino.io/blog/2023/04/11/date-predicates.html. Filter-residual-above-TableScan = pruning defeated is the correct interpretation. Function-wrap (date_trunc(event_ts)) and type-mismatch (string vs DATE) pruning-defeat patterns are the canonical examples from that blog. Naked-range form is the canonical safest recipe. |
| Completeness | 4.5 | Slight oversimplification: predicate may still partially push down with `predicate=` even when a residual Filter is present; the Filter residual is the negative signal but not 100% binary. Didn't mention EXPLAIN ANALYZE for actual row-count verification of pruning. |
| Clarity | 4.75 | Two-state heuristic (constraint-in-TableScan = good, separate Filter = bad), concrete naked-range example with TIMESTAMP literals, "verify both forms with EXPLAIN" actionable. |
| Actionability | 4.75 | Engineer has a recipe: rewrite to naked range, run EXPLAIN, look for constraint annotation, fix function-wrap or cast on partition col. |

**ZERO fabrications.** No fake EXPLAIN node names, no fake `constraint_satisfied=true` flag, no fake EXPLAIN format options.

## View-security streak status

**1/1 PASS** — Iter468 Q2 `WITH (SECURITY DEFINER)` syntax slip is FIXED at iter469 Q1. The r05 canonical block + r12 inline pattern update + 7-form DO-NOT-WRITE matrix landed cleanly. **Needs at least one more re-probe in a different phrasing to lock the fix at 2/2.** Candidates for iter470 re-probe: SHOW CREATE VIEW round-trip, DEFINER-vs-INVOKER tradeoff matrix, `CREATE OR REPLACE VIEW ... SECURITY INVOKER` (test the INVOKER branch), view-on-view security inheritance.

## Fabrications

**ZERO across all four answers.** Specifically NOT present:
- No `WITH (SECURITY DEFINER)` (the iter468 fab pattern — fixed)
- No fake Trino function names (no `regexp_substr` on Trino, no fake signature)
- No fake `$files` / `$snapshots` column names
- No fake `remove_orphan_files` parameters (the real `retention_threshold => '7d'` was used correctly)
- No fake EXPLAIN node names (no `PartitionScan`, no `constraint_satisfied=true`)
- No invented version-gated features

## Topic average updates

| Topic | Before | After | Delta |
|---|---|---|---|
| Multi-tenant analytics | 4.4561 / 152 | **4.4582 / 153** | +0.0021 (Q1 4.78 above topic avg) |
| Oracle PL/SQL→dbt/Trino migration | 4.5832 / 42 | **4.5827 / 43** | -0.0005 (Q2 4.5625 essentially at topic avg) |
| Iceberg table maintenance | 4.4907 / 129 | **4.4915 / 130** | +0.0008 (Q3 4.59 just above topic avg) |
| Query performance basics | 4.4314 / 11 | **4.4501 / 12** | +0.0187 (Q4 4.66 above topic avg) |
| **Federation NOT probed** | 4.49944 / 310 | **4.49944 / 310** | UNCHANGED per directive (0.0006 below 4.5 raised threshold) |

## Teacher actions for iter470

**Breadth design — 4 non-federation angles. NO dedicated federation probe (the 4.49944/310 row sits 0.0006 below the 4.5 raised threshold — thin probe locks or breaks it; let the count grow naturally).**

### Required (1) — Lock view-security streak at 2/2

Pick ONE of these phrasings to re-probe CREATE VIEW SECURITY mode from a DIFFERENT angle than iter469 Q1 (which was DEFINER + REVOKE/GRANT):

- **SHOW CREATE VIEW round-trip**: ask how to inspect an existing view's SECURITY mode without re-running the DDL. Correct answer is `SHOW CREATE VIEW iceberg.tenant_acme.events` — the output preserves the SECURITY clause. Tests whether the responder can READ the DDL not just write it.
- **DEFINER-vs-INVOKER decision matrix**: "We have a view that joins customer data with a finance-team-owned reference table. Should the view use SECURITY DEFINER or INVOKER?" Tests whether the responder understands DEFINER = owner's grants used (good for tenant isolation), INVOKER = caller's grants used (caller must have base-table SELECT — defeats isolation but is correct for shared dimension tables where the caller already has access).
- **CREATE OR REPLACE VIEW with INVOKER**: tests the INVOKER branch + the `OR REPLACE` keyword.
- **View-on-view security inheritance**: does a view built on top of a SECURITY DEFINER view inherit the upstream view's owner grants? Tests deeper Trino semantics.

### Recommended (2) — 3 additional breadth probes

Candidate pool for the remaining three probes:

- **Trino MERGE INTO clause set** — `WHEN MATCHED [AND condition] THEN UPDATE/DELETE/INSERT` vs `WHEN NOT MATCHED [AND condition] THEN INSERT`. Watchlist: ban `WHEN NOT MATCHED BY SOURCE` (Spark/Snowflake-only; NOT in Trino 467).
- **dbt snapshots SCD2 config** — `strategy=timestamp|check`, `updated_at`, `unique_key`, `check_cols`, `target_schema`, `target_database`, `hard_deletes`. Watchlist: ban any non-listed snapshot config key.
- **Trino query timeout properties** — session vs config split. Real: `query.max-run-time`, `query.max-execution-time`, `query.max-cpu-time`. Watchlist: ban fabricated `query.timeout` config key.
- **Iceberg `expire_snapshots` vs `remove_orphan_files` ordering** — complementary to Q3 from iter469. expire_snapshots first (drops snapshot references), then remove_orphan_files (cleans unreferenced files).
- **Trino EXPLAIN ANALYZE vs EXPLAIN** — extends Q4 from iter469. EXPLAIN ANALYZE actually runs the query and reports row counts at each node, EXPLAIN is plan-only.

### Resource-side patches recommended

- **r27 (oracle-plsql-to-dbt-trino)**: add a one-paragraph Oracle-vs-Trino-regex-flavor callout — POSIX-extended (Oracle) vs Joni/Java (Trino); regexp_like CONTAINS-vs-FULL-MATCH semantic split; `$N` vs `\N` capture-group reference syntax differences; regexp_replace lambda variant available in Trino but not Oracle. Q2 completeness gap was here; easy patch.
- **r17 (iceberg-table-maintenance)** or wherever metadata inspection is canonicalized: add an explicit note that `expire_snapshots` and `remove_orphan_files` are complementary and have a required ordering (expire snapshots first to drop references, then orphan_files to clean unreferenced files). Q3 completeness gap was here.
- **r05 (multi-tenant-analytics) — DEFENSIVE**: DO NOT modify the new canonical CREATE VIEW SECURITY block until the streak reaches 3/3. Reconcile-don't-append: if a third re-probe still passes, the block is durable.

### Citation-hygiene watchlist for iter470

- **fabricated `ALTER VIEW ... SET SECURITY ...` DDL** — does NOT exist on Trino 467. To change a view's SECURITY mode, must use `CREATE OR REPLACE VIEW ... SECURITY {DEFINER | INVOKER} AS query`.
- **fabricated `WITH (SECURITY ...)` property-bag form** — keep on watchlist until 3-probe streak achieved (iter468 root-cause class).
- **fabricated `current_user` returns CREATOR/OWNER under DEFINER** — it returns the CALLER even under DEFINER mode. Only the row-access permission check uses the owner's grants; `current_user` in the view body still resolves to the caller.
- **fabricated Iceberg `$snapshots` columns** beyond the spec list (snapshot_id, parent_id, committed_at, operation, manifest_list, summary). No invented `deletion_count` or `compaction_id`.
- **fabricated Trino MERGE `WHEN NOT MATCHED BY SOURCE` clause** — Spark/Snowflake only; Trino 467 has `WHEN MATCHED` and `WHEN NOT MATCHED` only.
- **fabricated dbt snapshot config keys** beyond `strategy / unique_key / check_cols / updated_at / target_schema / target_database / hard_deletes`.
- **fabricated `query.timeout` config key** — real keys are `query.max-run-time`, `query.max-execution-time`, `query.max-cpu-time`.

## Sources

- [Trino CREATE VIEW — trino.io/docs/current/sql/create-view.html](https://trino.io/docs/current/sql/create-view.html)
- [Trino GRANT — trino.io/docs/current/sql/grant.html](https://trino.io/docs/current/sql/grant.html)
- [Trino REVOKE — trino.io/docs/current/sql/revoke.html](https://trino.io/docs/current/sql/revoke.html)
- [Trino Regular expression functions — trino.io/docs/current/functions/regexp.html](https://trino.io/docs/current/functions/regexp.html)
- [Trino Iceberg connector — trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html)
- [Iceberg spec — iceberg.apache.org/spec/](https://iceberg.apache.org/spec/)
- [Trino blog — Just the right time date predicates with Iceberg](https://trino.io/blog/2023/04/11/date-predicates.html)
- [Trino PR #621 — Use enforced constraint in EffectivePredicateExtractor](https://github.com/trinodb/trino/pull/621)
- [Trino PR #10810 — Expire Snapshot and Remove Orphan files](https://github.com/trinodb/trino/pull/10810)
- [Trino Issue #16473 — Metadata $files table on iceberg connector throws an error (double-quoting context)](https://github.com/trinodb/trino/issues/16473)
