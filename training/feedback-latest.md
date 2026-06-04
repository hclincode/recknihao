# Iter 462 — Judge Feedback (End-of-Iteration, Extended Phase)

**Phase**: extended (end-of-iteration feedback only)
**Date**: 2026-06-05
**Overall**: 4.8125 STRONG PASS (61st consecutive extended-phase PASS)

All four questions cleared the 3.5 floor by wide margin. Two critical streak fixes confirmed; zero new fabrications across all four questions.

## Per-question breakdown

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | Iceberg time-travel — TWO clauses (re-probe iter461 Q4 conflation) | 5.0 | 4.75 | 5.0 | 5.0 | 4.9375 |
| Q2 | NULLS-default inside window function ORDER BY | 5.0 | 4.75 | 5.0 | 4.75 | 4.875 |
| Q3 | Iceberg small-files: cause/detect/fix order | 4.75 | 4.75 | 4.75 | 4.75 | 4.75 |
| Q4 | Oracle NVL2 → Trino CASE + empty-string-NULL quirk | 4.75 | 4.5 | 4.75 | 4.75 | 4.6875 |

Overall avg = (4.9375 + 4.875 + 4.75 + 4.6875) / 4 = **4.8125 — STRONG PASS**

## Per-question justification

**Q1 (4.9375 STRONG PASS — time-travel two-clause RE-PROBE)**: Responder produced TWO SEPARATE Trino clauses — `FOR TIMESTAMP AS OF TIMESTAMP '2026-05-23 14:00:00'` for the time-based case and `FOR VERSION AS OF 1234567890123456789` (BIGINT, unquoted) for the snapshot-id case. NO conflation, NO welded `FOR VERSION AS OF TIMESTAMP '...'` hybrid. 7-day default retention correct. Partition-filter advice on time-travel queries sound (historical snapshot still encodes partition bounds, so the predicate prunes manifests). Both clauses verified verbatim at trino.io/docs/current/connector/iceberg.html (Time travel queries section). Iter461 Q4 clause-conflation fab fully resolved.

**Q2 (4.875 STRONG PASS — NULLS-default in window function)**: Oracle DESC default places NULLs FIRST, Trino DESC default places NULLs LAST — correct dialect contrast. Same query different ordering with no error (silent semantic drift) — correct framing. Fix `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY last_event_at DESC NULLS LAST)` is the canonical migration pattern. Responder explicitly stated "Trino defaults to NULLS LAST for BOTH ASC and DESC — no direction-dependent behavior like Oracle" — matches trino.io/docs/current/sql/select.html verbatim ("The default null ordering is NULLS LAST, regardless of the ordering direction"). Window function ORDER BY honors same null-ordering rule per trino.io/docs/current/functions/window.html. Did NOT claim Trino defaults NULLS FIRST for DESC.

**Q3 (4.75 STRONG PASS — small-files cause/detect/fix)**: Cause attribution (per-write new files + MERGE delete files + small writes never compacted) correct per iceberg.apache.org/docs/latest/maintenance/. Detection query against `iceberg.analytics."events$files" WHERE content = 0` correct — `$files` columns (content, file_path, record_count, file_size_in_bytes) verified at trino.io/docs/current/connector/iceberg.html; `content=0` for data files (excluding positional/equality delete files) verified per Iceberg manifest spec. Double-quoted `"events$files"` syntax correct (required because of `$`). Fix order `optimize → expire_snapshots → remove_orphan_files` with correct rationale (compact into live snapshot, expire snapshots that pinned the small files, then sweep orphans). All procedure parameter names verified (`file_size_threshold => '128MB'`, `retention_threshold => '7d'`). No-data-loss claim correct.

**Q4 (4.6875 STRONG PASS — NVL2 → Trino CASE + empty-string-NULL)**: Trino has no NVL2 function — verified (not in trino.io/docs/current/functions/comparison.html or any other Trino function reference). `NVL2(last_login,'active','never')` → `CASE WHEN last_login IS NOT NULL THEN 'active' ELSE 'never' END` is the exact logical equivalent per Oracle docs. Oracle empty-string-is-NULL quirk verified per docs.oracle.com and EDB/ABCloudz Oracle-vs-Postgres migration writeups — Oracle treats `''` and NULL as the same entity; Trino/Postgres treat `''` as a distinct zero-length string. Defensive rewrite `WHERE name IS NOT NULL AND name != ''` is the standard migration pattern. Minor nit: could have called out that the `''`-vs-NULL drift only matters for VARCHAR columns ingested from Oracle (a fresh greenfield Trino table won't have the artifact), but the engineer asked about migration so the warning is the right framing.

## Streak status — both critical streaks resolved

### (a) Trino-internal-clause-conflation streak — FIXED on 1st re-probe (Q1)
- Iter461 Q4 fab: `FOR VERSION AS OF TIMESTAMP '...'` (welded snapshot-id keyword with timestamp literal)
- Iter462 Q1: TWO SEPARATE clauses, NO welded hybrid. Used `FOR TIMESTAMP AS OF TIMESTAMP '...'` for time-based and `FOR VERSION AS OF <bigint>` for snapshot-based.
- iter462 teacher r17 LEADING CANONICAL block + 9-row DO-NOT-WRITE table + 5-engine muscle-memory map LANDED at the keyword path.
- Streak now at 1 PASS post-fix. Needs another angle at iter463+ to lock across phrasings (candidates: branch/tag time travel, $snapshots snapshot-id-finder pattern, time-travel + partition-pruning interaction).

### (b) NULLS-default concept — NOW LOCKED across 2nd angle (Q2)
- Iter460 Q1 confirmed it on top-level ORDER BY DESC.
- Iter462 Q2 confirms it INSIDE window function ORDER BY (`ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ... DESC NULLS LAST)`).
- Verified per trino.io/docs/current/sql/select.html and trino.io/docs/current/functions/window.html.
- Concept no longer fragile to question phrasing — confirmed on two distinct surface forms.

## Fabrications / inaccuracies — NONE

Every load-bearing claim verified against official docs. No cross-dialect spillover. No version-pin spillover. No Trino-internal clause conflation. No fabricated PR/issue/function/property/column/DDL-clause.

## Topic avg updates
- Iceberg table maintenance: 4.4941/121 → **4.4961/123** (+0.0020, Q1 4.9375 + Q3 4.75 both above topic avg)
- Oracle PL/SQL→dbt/Trino migration: 4.5811/34 → **4.5895/36** (+0.0084, Q2 4.875 + Q4 4.6875 both above topic avg)
- Federation: 4.49944/310 UNCHANGED (not probed this iteration per directive)

## Teacher actions for iter463 — concrete

### 1. Breadth design — pick angles that don't touch just-fixed surfaces
Avoid time-travel, avoid NULLS-default, avoid storage-sizing formula (locked across multiple iterations). Candidates ranked by gap-coverage value:
- **Hive Metastore + Iceberg interaction** under-probed recently — try a question on schema evolution visibility across HMS+Iceberg (e.g., "I added a column via Trino — why doesn't Spark see it?").
- **Iceberg WAP (write-audit-publish) workflow** in r17 documented but rarely probed — try a question on staging a backfill before publishing.
- **Multi-tenant partitioning trade-off** at 4.4562/151 has steady traffic; one angle on bucket-partitioning vs identity-partitioning for tenant_id would test r10/r05 cross-refs.
- **Query-perf-regression triage** at 4.3338/16 is the lowest-margin PASSED topic outside federation — one EXPLAIN-driven walkthrough would lift it.

### 2. Lock the just-fixed Trino-internal-clause-conflation class with a 2nd-angle re-probe
1 PASS at 1 angle is fragile. Pick ONE of these for iter463 to bring it to a 2-angle lock:
- **Branch/tag time travel**: "I have a tagged snapshot called `month-end-2026-05` — how do I query it?" (Expected: `FOR VERSION AS OF 'month-end-2026-05'` — string literal for ref-name, distinct from BIGINT for snapshot-id. Tests whether the responder collapses ref-name into snapshot-id form vs keeping them straight.)
- **Snapshot-id-finder from $snapshots**: "I want to query 'as of 2 days ago' but I only have $snapshots — how do I find the right snapshot_id first, then time-travel?" (Tests whether responder chains the two-step pattern: `SELECT snapshot_id FROM ...$snapshots WHERE committed_at < ...` → plug BIGINT into `FOR VERSION AS OF`. Fab risk: responder shortcuts to `FOR VERSION AS OF (SELECT ...)` which is invalid — `FOR VERSION AS OF` requires a literal.)
- **Time-travel + partition-pruning interaction**: "Does a partition filter prune partitions on the historical snapshot, or does it scan the full historical snapshot first?" (Tests deeper understanding — partition pruning applies because the historical snapshot's manifest list still encodes partition bounds.)

### 3. One Oracle migration sub-topic NOT recently touched
Migration topic now confirmed clean on NULLS-default (iter460 Q1, iter462 Q2), surrogate keys (iter461 Q2), NVL2 + empty-string-NULL (iter462 Q4). Untouched recently: ROWNUM → LIMIT, DECODE → CASE, MERGE syntax differences (Oracle's USING clause vs Trino's), PL/SQL cursor → set-based dbt model, exception block → dbt test, package-level constants → dbt vars. Pick one for breadth coverage.

### 4. Federation — do NOT probe unless a specific bulletproofed angle emerges
Row sits at 4.49944/310, fractionally below the 4.5 raised threshold. A new probe risks a thin FAIL that locks the gap, or a thin PASS that only barely crosses. Only probe if the teacher has installed a fresh resource fix that addresses a specific known fab pattern (none identified this iteration).

### 5. No resource edits required from this iteration's findings
Zero fabs. Teacher r17 LEADING CANONICAL block from iter462 LANDED clean. No reconciliation needed for iter463.
