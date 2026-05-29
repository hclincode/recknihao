# Judge Feedback — Iter 395 (2026-05-30, EXTENDED PHASE)

## Overall result: PASS — 4.3125 average

| Question | Average | Verdict |
|---|---|---|
| Q1 — Hive Parquet → Iceberg 500GB migrate() (RE-PROBE of iter394 Q2 inversion) | 4.0 | PASS |
| Q2 — 847 equality delete files + Iceberg 1.5.2 bug #12838 | 4.625 | STRONG PASS |
| **Iter 395 overall** | **4.3125** | **PASS** |

---

## Q1 — Hive Parquet → Iceberg 500GB migration

### What the answer claimed
- `migrate()` is metadata-only, completes in 1-5 minutes
- `snapshot()` for testing first
- Post-migration `rewrite_manifests` recommended
- Spark-only
- Zero data rewrite

### Scoring
| Dimension | Score | Note |
|---|---|---|
| Technical accuracy | 3.5 | Core claims correct; "Spark-only" is wrong — Trino Iceberg connector also exposes `CALL <catalog>.system.migrate(...)` |
| Beginner clarity | 4.5 | Clear time bounds, named procedures |
| Practical applicability | 4.0 | Engineer knows the path; "Spark-only" claim could push them to spin up Spark unnecessarily |
| Completeness | 4.0 | Covers migrate/snapshot/manifests/zero-rewrite; misses Trino-side option |
| **Average** | **4.0** | |

### Critical fix verification — VERIFIED
Iter394 Q2 catastrophically claimed "no in-place conversion, must rewrite". Iter395 Q1 correctly inverts that claim on the CORE point: `migrate()` is metadata-only, no data rewrite, minutes not hours. The teacher's between-iter resource add worked for the core claim.

### Residual issue: Spark-only claim
Verified against Trino 481 Iceberg connector docs: `system.migrate` is callable from Trino via `CALL <catalog>.system.migrate(schema_name => 'x', table_name => 'y')`. On the prod stack (Spark + Trino + HMS + MinIO), the engineer has BOTH options. The "Spark-only" framing is technically wrong and practically suboptimal — if they already have a Trino client open, Trino is the faster path.

---

## Q2 — 847 equality delete files, read amplification

### What the answer claimed
- 2-5x slowdown
- Way past the >50 file critical threshold
- Iceberg 1.5.2 bug #12838 — no silver bullet
- Partial mitigation: `rewrite-all=true` weekly
- Real fix: upgrade to Iceberg 1.8+
- Diagnostic: `$files` metadata query filtering `content=2`

### Scoring
| Dimension | Score | Note |
|---|---|---|
| Technical accuracy | 5.0 | All claims verified; #12838 is real and accurately characterized (partition-level sequence-number cleanup bug in 1.5.x); content=2 is correct equality-delete content type |
| Beginner clarity | 4.0 | Some jargon ("content=2", "rewrite-all=true") — fine for an engineer already debugging this, but a softer onboarding line would help |
| Practical applicability | 5.0 | Exact production-stack fit (Iceberg 1.5.2 is what prod_info.md describes); engineer has a diagnostic query, a mitigation, and an upgrade target |
| Completeness | 4.5 | Mitigation + diagnostic + root cause + upgrade target all present |
| **Average** | **4.625** | |

### Strengths
- The 50-file threshold heuristic matches documented `delete-file-threshold` guidance
- Bug #12838 characterization is precise — partition-level sequence-number cleanup means delete files orphan even after rewrite, which is exactly why "no silver bullet" in 1.5.2 is the right framing
- The `$files content=2` diagnostic is the correct Iceberg metadata table approach for counting equality deletes per partition
- Upgrading to ≥1.8 is the actual community-recommended fix

---

## Pattern across recent iterations

Trajectory of last 10 iters: ..., 4.125 PASS, 3.9375 FAIL, 4.625 PASS, 4.75 PASS, 3.125 FAIL, **4.3125 PASS**.

**Key signal**: the iter394 catastrophic inversion (Hive→Iceberg "must rewrite" claim) was FIXED on the core claim in iter395. The re-probe worked. The residual "Spark-only" error is a smaller secondary issue, not a category inversion.

---

## Teacher actions for iter 396

### HIGH priority
1. **Fix Spark-only claim in Hive→Iceberg migration resource.** The newly added migration resource should explicitly state that `system.migrate` is callable from BOTH Spark (`spark.sql("CALL spark_catalog.system.migrate('db.tbl')")`) AND Trino (`CALL iceberg.system.migrate(schema_name => 'db', table_name => 'tbl')`). On the prod stack with HMS shared between engines, either works. Include a one-line "when to use which": Trino if you already have a SQL client open and a small table; Spark if you want recursive_directory control or are scripting a batch.

### MED priority
2. **Equality-delete answer landed strong.** No action needed on Iceberg 1.5.2 #12838 content, but consider adding a note to the upgrade-to-1.8 section about whether the prod stack's HMS schema is compatible with a 1.5.2 → 1.8 in-place lib upgrade (it is, but the answer didn't have to address it — useful preempt for next probe).

### Judge probe targets for iter 396
1. HIGH — Hive→Iceberg migration **3rd angle**: explicitly probe whether the engineer can call migrate from Trino, OR a probe about migrating a 50TB table (size-scaling question) to test whether the 1-5min estimate holds.
2. MED — equality-delete buildup **2nd-angle reprobe**: same root cause via a different symptom (e.g., "MERGE INTO slowness after 6 months of CDC") to confirm #12838 awareness is durable.
3. Carry-forward backlog from iter394: HMS->Nessie no-downtime, SPILL_FAILED 60GB at 200GB cap, MERGE INTO rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO + VALIDATE, result caching, Iceberg branches fast_forward, bucket sizing, JWT+OPA concurrency, partition spec migration, Iceberg tagging 3rd angle, fs.cache 3rd angle JMX.
