# Judge feedback — Iter 474 (END-OF-ITERATION, EXTENDED PHASE)

## Overall result

**Overall avg: 4.328125 — PASS** (≥3.5 threshold). 73rd consecutive extended-phase PASS.

Margin ~0.83 above 3.5 floor, ~0.19 below iter473's 4.5234.

## Per-question breakdown

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Storage tiering re-probe (rejects SET STORAGE TIER trap) | 4.5 | 4.5 | 4.5 | 4.5 | **4.5** | STRONG PASS |
| Q2 | Oracle GREATEST/LEAST → Trino | 4.75 | 4.5 | 4.75 | 4.75 | **4.6875** | STRONG PASS |
| Q3 | Broadcast join auto + influence | 3.0 | 4.0 | 4.25 | 3.0 | **3.5625** | THIN PASS (FAB) |
| Q4 | dbt snapshot SCD2 meta columns + PIT query | 4.75 | 4.25 | 4.75 | 4.5 | **4.5625** | STRONG PASS |

## Per-question justifications

**Q1 — Storage tiering re-probe (4.5 STRONG PASS).** Question literally planted the trap `ALTER TABLE events SET STORAGE TIER 'cold' WHERE partition_date < '2024-01-01'`. Responder REJECTED it cleanly: said no such DDL exists in Trino 467, no Iceberg `storage_tier`/`storage_class` table property, tiering is a MinIO object-storage-layer concern, configure with MinIO lifecycle policies, Trino transparently reads whichever tier MinIO stores files on. Iter474 LEADING CANONICAL block in r16 + reconciled r11 line 602 did exactly the job. Minor (non-load-bearing) accuracy slip: responder said MinIO transitions are based on "access time" — actual mechanism is object age (`--transition-days N`) per docs.min.io. Note as completeness, not fab.

**Q2 — GREATEST/LEAST (4.6875 STRONG PASS).** Both functions verified at trino.io/docs/current/functions/comparison.html: scalar variadic, identical to Oracle. NULL-if-any-arg-null is consistent between Oracle and Trino (responder did not claim otherwise — no flag). Minor completeness: did not surface that PostgreSQL's GREATEST/LEAST IGNORE nulls (returns null only if all args null) — a useful migration warning but not asked.

**Q3 — Broadcast join (3.5625 PASS, FAB).** REPLICATE/REPARTITION terms correct, automatic CBO decision correct, `join_max_broadcast_table_size` 100MB default correct (verified at trino.io/docs/current/optimizer/cost-based-optimizations.html), bare `ANALYZE <table>` correctly held (NOT `ANALYZE TABLE`), EXPLAIN-shows-distribution correct, Iceberg-vs-memory-irrelevant correct. **Load-bearing FAB**: `SET SESSION distributed_join_distribution_type = 'partitioned'` does NOT exist. Correct form is `SET SESSION join_distribution_type = 'PARTITIONED'`. Engineer running the SET SESSION line as written gets "Session property distributed_join_distribution_type does not exist". Regression on iter456/457 fix.

**Q4 — dbt snapshot SCD2 (4.5625 STRONG PASS).** Meta columns dbt_valid_from / dbt_valid_to (NULL=current) / dbt_scd_id / dbt_is_deleted (1.9+) all verified at docs.getdbt.com/reference/resource-configs/snapshot_meta_column_names + /docs/build/snapshots. Correctly said NO dbt_is_current column. Point-in-time query `WHERE dbt_valid_from <= <ts> AND (dbt_valid_to IS NULL OR dbt_valid_to > <ts>)` is the canonical validity-window pattern. Minor completeness: the question specified strategy=timestamp + updated_at config but responder did not echo that config block back in the snapshot example. Non-load-bearing.

## Key status calls

### Storage-tiering micro-topic: PROMOTED TO PASSED (4.25/2)
The 2nd-angle re-probe LANDED CLEAN. Iter474 LEADING CANONICAL block in r16 + reconciled r11 line 602 are doing their job. Topic moves from `NEEDS WORK 4.0/1` → `PASSED 4.25/2`. (Minor MinIO access-time-vs-age slip noted; non-load-bearing.)

### ANALYZE bare-form status: HELD
Q3 responder correctly wrote bare `ANALYZE <table>` (not `ANALYZE TABLE`). Confirmed at trino.io/docs/current/connector/iceberg.html — `ANALYZE table_name [WITH (columns = ARRAY[...])]`. The fix on this remains durable.

### Q3 ruling: `distributed_join_distribution_type` is a FABRICATED session-property name — REGRESSION
Central finding of iter474.

Verified at trino.io/docs/current/optimizer/cost-based-optimizations.html + trino.io/docs/current/admin/properties-general.html:
- Correct session property: **`join_distribution_type`** with values `'AUTOMATIC' | 'BROADCAST' | 'PARTITIONED'`
- Catalog/config-property form: `join-distribution-type`
- **There is NO `distributed_join_distribution_type` session property in Trino 467**
- Historical context: the long-deprecated `distributed_joins` / `distributed-joins-enabled` was replaced by `join_distribution_type`. The fab name appears to combine the dead old prefix with the current property name.

Engineer running the SET SESSION line gets `Session property distributed_join_distribution_type does not exist`. Load-bearing wrong-by-default. **Regression** on iter456/457.

## All fabrications + correct facts + sources

| # | Q | Fabrication | Correct fact | Source URL |
|---|---|---|---|---|
| 1 | Q3 | `SET SESSION distributed_join_distribution_type = 'partitioned'` | `SET SESSION join_distribution_type = 'PARTITIONED'` (values: AUTOMATIC, BROADCAST, PARTITIONED) | https://trino.io/docs/current/optimizer/cost-based-optimizations.html + https://trino.io/docs/current/admin/properties-general.html |

Q1, Q2, Q4 had ZERO fabrications. Q1 "MinIO based on access time" is a minor inaccuracy (actual mechanism is age/transition-days), not a fabricated capability or property, non-load-bearing.

## Teacher actions for iter475

### PRIMARY — re-fix the join_distribution_type session-property name regression
1. **Grep all of resources/ for the fab**: `distributed_join_distribution_type`. Remove or replace every occurrence with `join_distribution_type`. Reconcile IN-PLACE; do NOT append a correction note while leaving the wrong form somewhere else in the same file (per CLAUDE.md reconcile-don't-append rule).
2. **Verify canonical block is present** in resources/16-cost-considerations.md OR r28 complex-SQL-perf (wherever broadcast-join is the natural keyword landing zone), cross-referenced from the other file. The block should state:
   - Property name: **`join_distribution_type`** (session) / **`join-distribution-type`** (catalog/config)
   - Values: `'AUTOMATIC'` (default, CBO decides), `'BROADCAST'` (force replicate), `'PARTITIONED'` (force repartition)
   - Companion: `join_max_broadcast_table_size` (default 100MB) controls the AUTOMATIC threshold
   - Worked example: `SET SESSION join_distribution_type = 'PARTITIONED';` then `SELECT ... FROM large JOIN huge ON ...;` then `EXPLAIN ...` showing REPARTITION
   - Bare `ANALYZE <table>` (NOT `ANALYZE TABLE`) and CBO-feeds-from-Iceberg-stats clarification
3. **DO-NOT-WRITE matrix** — add an explicit row for EVERY plausible-fab sibling so the responder keyword-matches the warning when it would otherwise hallucinate:
   - `distributed_join_distribution_type` (fab — this iter's regression)
   - `distributed_joins` (deprecated/removed)
   - `distributed-joins-enabled` (deprecated/removed)
   - `broadcast_join_distribution_type` (fab)
   - `hash_join_distribution_type` (fab)
   - `join_distribution` (fab — missing `_type`)
   - `join_strategy` (fab — Spark-ism)
   - `/*+ BROADCAST(t) */` and `/*+ MAPJOIN(t) */` (Hive/Spark hint syntax, NOT Trino — block cross-dialect spillover)
   - For each: "does NOT exist on Trino 467 — engineer gets 'Session property X does not exist' error".
4. **Citation**: link to trino.io/docs/current/optimizer/cost-based-optimizations.html AND trino.io/docs/current/admin/properties-general.html in the canonical block.

### SECONDARY — minor MinIO transition-mechanism correction
In resources/16-cost-considerations.md storage-tiering canonical, the MinIO mechanism description should explicitly say "transitions are scheduled by object age (`--transition-days N`), not by access time/access pattern". This pre-empts the minor Q1 slip and matches docs.min.io exactly.

### SECONDARY — breadth design for iter475
- **NO dedicated federation probe** — 4.49944/310 stays UNCHANGED (sits 0.0006 below 4.5 raised threshold, do not perturb).
- 4-Q breadth design candidates:
  1. **Re-probe broadcast-join from a DIFFERENT angle** to verify the session-property regression-fix landed. MANDATORY this iter — fixes that aren't re-probed within 1-2 iters tend to silently drift. Phrasing candidates: "How do I force a hash-partitioned join for a 5GB build side?" / "What config knob lets Trino broadcast a 200MB dim table?" / "Show me the EXPLAIN output for a forced PARTITIONED join."
  2. **dbt snapshots SCD2 2nd-angle re-probe** to lock the new micro-topic (currently 4.5625/1 NEEDS 2ND ANGLE per rubric rule). Candidates: snapshot strategy=check vs timestamp tradeoff, invalidate_hard_deletes semantic, dbt_valid_to_current config (1.9+), snapshot on an Iceberg-backed target.
  3. **Storage-tiering 3rd-angle re-probe** to strengthen the now-2-deep PASSED row (4.25/2). Candidates: "Can I configure Iceberg to skip cold-tiered partitions during snapshot expiry?" / "If I lifecycle-tier my data/ prefix to MinIO cold, what breaks on Trino?" — tests whether responder still attributes mechanism to MinIO layer when phrased as a downstream consequence.
  4. **Wildcard low-count breadth probe**. Candidates: dbt sources / source freshness (PASSED 4.219/3, fragile), dbt model contracts (PASSED 4.1146/3, still thin), Lakehouse schema design (PASSED 4.5052/12).

### Citation-hygiene watchlist for iter475
- **Session-property fab pattern**: any SET SESSION line that uses an unverified property name. Watchlist: `join_*`, `query_max_*`, `broadcast_*`, `partition_*`, `iceberg_*`. Lesson from iter474: regressions on already-fixed fabs are still possible. Resources should host a CANONICAL "Trino 467 session properties used in this guide" subsection with all properties cited against live docs URL.
- **Cross-dialect spillover** (Snowflake/Databricks/Hive/Spark): joins SQL forms, MERGE forms, hint syntax (`/*+ BROADCAST(t) */` is Hive/Spark hint, NOT Trino).
- **Fabricated-capability-restriction**: claims like "Trino cannot X — use Spark" when Trino actually CAN do X (regressed in iter470, currently held — keep watch).

### Fab-class status this iter
- Cross-dialect spillover — none new
- Version-pin — Trino 467 + Iceberg 1.5.2 anchoring held
- Trino-internal-clause conflation — none new
- Fabricated-capability-restriction — none new
- **Fabricated session-property name — RESURFACED on Q3 (regression)** → PRIMARY teacher action above

## Bottom line
PASS overall at 4.328125. Storage-tiering micro-topic promoted to PASSED (canonical landed cleanly + 2nd probe confirmed it). The single fab is a regression on the iter456/457 `distributed_join_distribution_type` → `join_distribution_type` fix; the resource patch evidently drifted or was incompletely propagated. Fix in iter475 PRIMARY, then re-probe broadcast-join from a different angle to confirm the re-fix holds.
