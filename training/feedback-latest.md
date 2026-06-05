# Judge Feedback — Iter 470 (Extended Phase, End-of-Iteration)

**Date**: 2026-06-05
**Phase**: Extended (end-of-iteration feedback only)
**Overall**: **3.71875 THIN PASS** (69th consecutive extended-phase PASS — thinnest margin in months)

**Verdict**: PASS, but only because Q4 (4.4375) and Q2 (4.25) carried the iter. Q1 (3.375) and Q3 (2.8125) alone would have failed. Three distinct load-bearing fabrications across Q1 and Q3 — citation-hygiene streak BROKEN.

---

## Per-question scores

| Q | Topic | Acc | Compl | Clar | Act | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Iceberg WAP staging-branch + fast_forward | 3.0 | 3.75 | 4.0 | 2.75 | **3.375** | THIN PASS |
| Q2 | Oracle MERGE WHEN NOT MATCHED BY SOURCE → Trino | 4.25 | 4.25 | 4.5 | 4.0 | **4.25** | PASS |
| Q3 | Iceberg schema evolution (widen/rename/reorder/drop) | 2.0 | 3.5 | 4.0 | 1.75 | **2.8125** | HARD FAIL |
| Q4 | Why Parquet faster than Postgres | 4.5 | 4.25 | 4.75 | 4.25 | **4.4375** | STRONG PASS |

**Overall avg**: (3.375 + 4.25 + 2.8125 + 4.4375) / 4 = **3.71875** → PASS (≥3.5), but barely.

---

## Per-question justification (1-2 lines each)

**Q1 — 3.375 THIN PASS**: fast_forward arg order CORRECT (credit — `branch='main'` moved forward to `to='staging'` matches iceberg.apache.org/docs/latest/spark-procedures/), Spark WAP wiring and Trino 467 branch-write limits correctly identified. BUT two load-bearing bugs in the same snapshot-lookup SQL: (a) malformed quoting `iceberg.analytics.orders.$snapshots` (must be `iceberg.analytics."orders$snapshots"`), and (b) `ref_name` is NOT a column of `$snapshots` — branch refs live in the separate `$refs` table.

**Q2 — 4.25 PASS**: Substance correct on no `WHEN NOT MATCHED BY SOURCE` in Trino MERGE, and the two-model NOT-EXISTS-anti-join decomposition is the canonical workaround. Minor framing slip — Model 2 was shown as a `.sql` model body with raw UPDATE/DELETE, but dbt models are SELECT-only; this DML belongs in a `post_hook` or `dbt run-operation` macro.

**Q3 — 2.8125 HARD FAIL**: INT→BIGINT widening and RENAME COLUMN correct. BUT TWO distinct load-bearing fabrications: (a) `column_order` table property is NOT a real Trino Iceberg property — supported properties list does not include it; (b) the "Trino 467 cannot DROP COLUMN — use Spark" claim is a fabricated capability restriction — trino.io/docs/current/sql/alter-table.html DOES document `ALTER TABLE name DROP COLUMN column_name` and the Iceberg connector supports it natively.

**Q4 — 4.4375 STRONG PASS**: Columnar projection, dictionary encoding, min/max stats + pushdown, vectorized batch + SIMD, and OLTP point-lookup tradeoff all directionally correct. Illustrative numbers (4096 batch, AVX2/512) are not presented as pinned Trino spec — no fab.

---

## Fabrications — full list with correct facts + source URLs

### Fab 1 (Q1) — `$snapshots.ref_name` column does NOT exist + malformed quoting

- **Malformed quoting**: `iceberg.analytics.orders.$snapshots` will not parse. The `$` is part of the metadata-table identifier and must be inside the same double-quote pair as the base table name. Correct: `iceberg.analytics."orders$snapshots"`.
- **`ref_name` is NOT a `$snapshots` column**. Per trino.io/docs/current/connector/iceberg.html, `$snapshots` columns are exactly: `committed_at`, `snapshot_id`, `parent_id`, `operation`, `manifest_list`, `summary`. Branch/tag refs live in the separate **`$refs`** metadata table whose columns are `name`, `type`, `snapshot_id`, `max_reference_age_in_ms`, `min_snapshots_to_keep`, `max_snapshot_age_in_ms`. The column is `name`, not `ref_name`.
- **Correct lookup pattern**: query `$refs` filtered by `name = 'staging_2026_06_05' AND type = 'BRANCH'` to get the snapshot_id; optionally join to `$snapshots` on snapshot_id for commit metadata.
- **Source**: trino.io/docs/current/connector/iceberg.html (Metadata tables section).

**CREDIT (do not lose)**: `fast_forward('analytics.orders', 'main', 'staging_2026_06_05')` arg order is CORRECT — verified at iceberg.apache.org/docs/latest/spark-procedures/. `branch` is the ref moved forward; `to` is the source tip.

### Fab 2 (Q3) — `column_order` table property does NOT exist on Trino 467 Iceberg connector

- Per trino.io/docs/current/connector/iceberg.html, supported Iceberg table properties are: `format`, `compression_codec`, `partitioning`, `sorted_by`, `location`, `format_version`, `max_commit_retry`, `delete_after_commit_enabled`, `max_previous_versions`, `orc_bloom_filter_columns`, `orc_bloom_filter_fpp`, `parquet_bloom_filter_columns`, `object_store_layout_enabled`, `data_location`, `extra_properties`. **`column_order` is NOT in this list.**
- Engineer running `ALTER TABLE t SET PROPERTIES column_order = ARRAY[...]` gets `Catalog 'iceberg' table property 'column_order' does not exist`.
- **Correct answer**: Trino 467 has NO native column-reorder DDL on Iceberg. Reorder must be done via **Spark** `ALTER TABLE ... ALTER COLUMN col FIRST | AFTER other_col`. Trino's `ADD COLUMN` accepts `FIRST | AFTER name` only for placing NEW columns — it does not reorder existing ones.
- **Source**: trino.io/docs/current/connector/iceberg.html + trino.io/docs/current/sql/alter-table.html.

### Fab 3 (Q3) — "Trino 467 cannot DROP COLUMN — use Spark" is a FABRICATED capability restriction

- trino.io/docs/current/sql/alter-table.html: `ALTER TABLE [IF EXISTS] name DROP COLUMN [IF EXISTS] column_name` is a documented supported statement.
- trino.io/docs/current/connector/iceberg.html lists DROP COLUMN among supported ALTER TABLE statements for the Iceberg connector.
- **Trino 467 DOES support DROP COLUMN natively** on the Iceberg connector. The "must use Spark" claim is fabricated and sends engineers to Spark unnecessarily.
- **Correct answer**: `ALTER TABLE iceberg.schema.table DROP COLUMN column_name;` — runs natively on Trino 467. Metadata-only per Iceberg spec.

### Minor framing slip (Q2) — NOT a hard fab, but worth flagging

- Model 2 shown as a `.sql` dbt model body containing raw UPDATE/DELETE. dbt models are SELECT-only by contract. Standalone DML belongs in `post_hook`, `dbt run-operation` macro, or a separate operation file — not a model body.
- SQL logic itself (NOT EXISTS anti-join on Iceberg V2 MoR) is correct.
- **Source**: docs.getdbt.com/docs/build/models.

---

## Teacher actions for iter471

### PRIMARY (must land before any other edits)

**Action 1 — Fix the Q3 DROP COLUMN fabricated-capability-restriction**

In the Iceberg schema-evolution resource (r17 Iceberg table maintenance, or whichever resource covers schema evolution DDL), add a LEADING CANONICAL block:

```
-- Trino 467 NATIVE on Iceberg connector (no Spark required):
ALTER TABLE iceberg.s.t ADD COLUMN c TYPE [FIRST | AFTER other_col];
ALTER TABLE iceberg.s.t DROP COLUMN c;                       -- YES, supported natively
ALTER TABLE iceberg.s.t RENAME COLUMN old TO new;
ALTER TABLE iceberg.s.t ALTER COLUMN c SET DATA TYPE BIGINT; -- safe promotions only:
                                                             --   INT→BIGINT, FLOAT→DOUBLE, DECIMAL widen
-- Trino 467 does NOT support natively (Spark required):
-- - Reorder existing columns (NO `column_order` property — use Spark ALTER COLUMN FIRST | AFTER)
-- - Narrowing type changes (rejected by Iceberg spec)
```

Add DO-NOT-WRITE matrix entries:
- `ALTER TABLE t SET PROPERTIES column_order = ARRAY[...]` — FABRICATED, no such property
- "Trino 467 cannot DROP COLUMN — use Spark" — FABRICATED CAPABILITY RESTRICTION, Trino 467 supports DROP COLUMN natively

Cite trino.io/docs/current/sql/alter-table.html and trino.io/docs/current/connector/iceberg.html.

**Action 2 — Fix the Q1 `$refs` vs `$snapshots` conflation**

In the Iceberg metadata-tables resource (r17 or a dedicated metadata-tables section), add a LEADING CANONICAL block distinguishing the two tables and showing the correct lookup join:

```
-- $snapshots — snapshot metadata (NO ref name column):
--   columns: committed_at, snapshot_id, parent_id, operation, manifest_list, summary
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."orders$snapshots"
ORDER BY committed_at DESC;

-- $refs — branch/tag references (this is where ref NAMES live):
--   columns: name, type, snapshot_id, max_reference_age_in_ms,
--            min_snapshots_to_keep, max_snapshot_age_in_ms
SELECT name, type, snapshot_id
FROM iceberg.analytics."orders$refs"
WHERE type = 'BRANCH';

-- Lookup snapshot for a branch — JOIN $refs to $snapshots:
SELECT r.name, r.type, s.snapshot_id, s.committed_at, s.operation
FROM iceberg.analytics."orders$refs" r
JOIN iceberg.analytics."orders$snapshots" s ON r.snapshot_id = s.snapshot_id
WHERE r.name = 'staging_2026_06_05' AND r.type = 'BRANCH';
```

Add DO-NOT-WRITE entries:
- `WHERE ref_name = '...'` on `$snapshots` — FABRICATED column (does not exist)
- `iceberg.schema.table.$snapshots` dotted form — MALFORMED quoting (must be `iceberg.schema."table$snapshots"`)

Cite trino.io/docs/current/connector/iceberg.html (Metadata tables section).

**Action 3 — Tighten the Q2 dbt-framing nuance**

In r27 §4.6A (Oracle MERGE → Trino two-model decomposition), add an explicit note that Model 2 (standalone DELETE / soft-delete UPDATE) must be implemented as:
- a `post_hook` on Model 1; OR
- a `dbt run-operation` macro; OR
- a separate dbt operation file

NOT as a `.sql` model body. dbt models are SELECT-only by contract; raw UPDATE/DELETE in a model body conflicts with dbt's materialization-driven CTAS/MERGE/INSERT pattern. Cite docs.getdbt.com/docs/build/models.

### SECONDARY

**Action 4 — Breadth design for iter471** (4 non-federation angles):

- **Re-probe Q3 DROP COLUMN with different phrasing** to lock the fix (e.g., "I need to drop 3 deprecated columns from a 5TB Iceberg table — can Trino 467 do this natively or do I need Spark?"). Streak-locker target.
- **Re-probe Q1 `$refs` vs `$snapshots` with different phrasing** (e.g., "How do I list all branches on an Iceberg table from Trino?" — the responder MUST hit `$refs`, not `$snapshots`).
- **Iceberg type promotion edge cases** (DECIMAL precision-widen OK, DECIMAL scale-change rejected, FLOAT→DOUBLE OK).
- **A fresh breadth angle** (e.g., dbt sources / freshness; Trino EXPLAIN ANALYZE vs EXPLAIN; Iceberg snapshot rollback via `rollback_to_snapshot`).

**Action 5 — NO dedicated federation probe**: 4.49944/310 row sits 0.0006 below the 4.5 raised threshold; thin probe locks or breaks it. Let it accrete passively through breadth.

### Citation-hygiene watchlist for iter471

- **Fabricated capability restrictions** (THIS iter's killer class): if the responder says "Trino 467 cannot do X — use Spark", judge MUST verify X against trino.io/docs/current. The DROP COLUMN fab is the canonical example.
- **Fabricated table properties**: if the responder uses `SET PROPERTIES foo = ...`, verify `foo` is in the connector docs property list. `column_order` was the fab this iter.
- **Metadata-table column-name conflation**: `$snapshots` vs `$refs` is the highest-risk pair (both have `snapshot_id`, only `$refs` has `name`/`type`). Watch also `$files` vs `$manifests` vs `$partitions`.
- **Metadata-table quoting**: `iceberg.s.t.$snapshots` (dotted) is ALWAYS WRONG. Must be `iceberg.s."t$snapshots"` with `$` inside the same quote pair.
- **fast_forward arg order**: `fast_forward(table, branch, to)` where `branch` moved forward, `to` is source tip — held this iter (credit), keep watching.
- **WHEN NOT MATCHED BY SOURCE**: Spark/Snowflake only, NOT Trino — held this iter, keep watching.

---

## Topic score deltas (logged in rubric.md iter470 row)

- **Iceberg table maintenance** (folding Q1 WAP + Q3 schema evolution): 4.4915/130 → 4.4669/132 (-0.0246, biggest single-iter topic drag in months).
- **Oracle PL/SQL→dbt/Trino migration**: 4.5827/43 → 4.5751/44 (-0.0076).
- **Column-oriented storage**: 4.4926/14 → 4.4889/15 (-0.0037).
- **Federation**: 4.49944/310 UNCHANGED (not probed per directive).

All topics remain PASSED; no topic dropped below 3.5. But Iceberg table maintenance lost meaningful margin — the Q3 fab cluster signals a topic-level gap requiring reinforcement.

---

## Summary

PASSED at 3.71875 by the thinnest margin in dozens of iterations. Q4 carried; Q3 nearly killed. Three load-bearing fabrications across Q1 and Q3 (`$snapshots.ref_name` + `column_order` property + "Trino 467 cannot DROP COLUMN") broke the citation-hygiene streak. Primary teacher actions: fix the Q3 DROP COLUMN capability-restriction fab (Trino 467 DOES support it natively) and the `column_order` property fab, plus the Q1 `$refs`/`$snapshots` conflation. Re-probe both in iter471 from different phrasings to lock the fixes.
