# Judge Feedback — Iter 416 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.5625 STRONG PASS** (Q1 4.75 + Q2 4.625 + Q3 4.75 + Q4 4.25) — well above the 3.5 overall PASS threshold and the fifteenth consecutive PASS in the iter402-416 window. Slight step-DOWN of -0.0625 from iter415 4.625, driven entirely by Q4's small practical-applicability flag (parquet_bloom_filter_columns availability on prod's Trino 467).

**Headline:**
1. **MYTH-BUSTER STRATEGY IS HOLDING — ZERO new confident-inaccuracies on load-bearing "X can't do Y" claims this iteration.** The recurring failure mode (5 of the prior 9 iterations had at least one such failure) did NOT recur. The iter416 teacher push to extend canonical myth-buster pattern to resources 13/10/18/25 landed cleanly on all four answers; each leads with the correct affirmative and enumerates myths-vs-truths in the right framing.
2. **Q1 STRONG (4.75)** — Spark JDBC parallelism single-threaded default + 4-options stride mechanism + out-of-range-rows-go-to-first/last-partition-no-data-lost + predicates[] alternative all correct. Verified against spark.apache.org/docs/latest/sql-data-sources-jdbc.html ("lowerBound and upperBound are just used to decide the partition stride, not for filtering the rows in table. So all rows in the table will be partitioned and returned").
3. **Q2 STRONG (4.625)** — Partition evolution month->day metadata-only via ALTER TABLE SET PROPERTIES; old files keep month spec not rewritten; cross-spec queries transparent + correct (no missing/dup); optional Spark rewrite_data_files for old data. Verified against iceberg.apache.org/docs/latest/evolution/ + trino.io/blog/2021/07/12 in-place-table-evolution.
4. **Q3 STRONG (4.75)** — MV staleness: no auto-refresh manual REFRESH via cron/k8s CronJob; default GRACE PERIOD infinity for new MVs + WHEN STALE INLINE default; past-grace-fall-through-to-source-SELECT semantics. Verified against trino.io/docs/current/sql/create-materialized-view.html ("new materialized views have an unlimited grace period by default" + "INLINE behavior expands it like a logical view... This is the default behavior when WHEN STALE is not specified"). k8s CronJob hourly example fits prod stack.
5. **Q4 PASS (4.25, below STRONG) — SMALL FLAG**: Filter-above-TableScan != pushdown failure + physicalInputDataSize as the real metric + $files lower/upper bounds + sort-strategy rewrite_data_files all correct. **The deduction**: responder recommends parquet_bloom_filter_columns table property as a fix, but this property was added in Trino 469 (Jan 2025, PR #24573) and is NOT available on prod's Trino 467 (engineer setting it gets an "unknown table property" error). The Spark-side alternative (Spark Iceberg writes Parquet bloom filters at write time; Trino 467 reads them for filtering) IS available on prod but wasn't differentiated. This is a DIFFERENT flavor of inaccuracy from the recurring confident-inaccuracy-on-load-bearing-claim pattern — it's a version-gated-fix-recommendation gap, less harmful but still actionable.

---

## Did the myth-buster strategy hold this iteration?

**YES — ZERO new confident-inaccuracies on load-bearing "X can't do Y" claims.** The recurring failure mode (iter407 Q2 branches-Spark-only / iter411 Q2 QUALIFY-not-in-Trino / iter413 Q2 TopN-not-pushed / iter414 Q3 expire_snapshots-orphans-branch-files) did NOT recur. All four iter416 answers lead with the correct affirmative truth and frame exceptions narrowly. The teacher's iter416 myth-buster pass on resources 13/10/18/25 landed cleanly.

## Did the Q4 small flag rise to the recurring failure-mode pattern?

**NO — different flavor.** The Q4 issue is a fix-recommendation that's version-gated for prod (parquet_bloom_filter_columns Trino 469+, prod 467). This is not a wrong claim about WHAT THE SYSTEM CAN DO (the property exists in current Trino), but a version-availability oversight in the recommendation. The diagnostic mechanism (Filter-above-TableScan + physicalInputDataSize + $files lower/upper) was correct. A version-availability callout in resource 18 would close this gap.

## Did the Trino federation topic cross 4.5 threshold?

**N/A — no federation question this iteration.** Topic unchanged at 4.4880/272, still 0.0120 below threshold. **16th consecutive iteration stuck below threshold but no movement this iteration (no federation data point added).**

---

## Q1 — Spark JDBC parallelism (Postgres-to-Iceberg ingestion)

**Scores: 5.0 / 4.5 / 5.0 / 4.5 — avg 4.75 STRONG PASS**

### What landed
- **Single-threaded default** — CORRECT (verified: partitionColumn+lowerBound+upperBound+numPartitions must ALL be specified to enable parallel read; without them Spark reads as one partition).
- **4-options stride mechanism** (partitionColumn, lowerBound, upperBound, numPartitions split into WHERE id BETWEEN ranges) — CORRECT canonical mechanism.
- **Out-of-range rows go to first/last partition, no data lost** — CORRECT (VERIFIED against spark.apache.org/docs/latest/sql-data-sources-jdbc.html: "lowerBound and upperBound are just used to decide the partition stride, not for filtering the rows in table. So all rows in the table will be partitioned and returned"). The first partition gets `col < lowerBound + stride` (catches below-range), the last gets `col >= upperBound - stride` (catches above-range).
- **predicates[] array alternative for gappy keys** — CORRECT (Scala `jdbc(url, table, predicates: Array[String], connProps)`; each predicate becomes one partition's WHERE clause; useful when partitionColumn has gaps or skew that uniform stride doesn't handle).
- **partitionColumn unrelated to Postgres native PARTITION BY** — CORRECT subtle clarification (Spark JDBC partitionColumn is a Spark-side WHERE-clause split, not Postgres declarative partition).
- **Verify Spark UI task count = numPartitions** — CORRECT canonical diagnostic (1 task = single-threaded; N tasks = parallel N).

### Minor (not gating)
- Could mention the `fetchsize` JDBC option (default 0 = unbounded, often causes OOM on large tables — set to 1000-10000 per partition).
- Could mention that high numPartitions can hammer Postgres (responder DID mention "don't create too many partitions" implicitly via general guidance, but explicit Postgres connection-pool note would land it cleaner).

### Verdict
STRONG PASS. Right mechanism + right verified default + right alternative for gappy keys + right verification recipe.

---

## Q2 — Partition evolution month->day (Iceberg partition design)

**Scores: 5.0 / 4.5 / 4.5 / 4.5 — avg 4.625 STRONG PASS**

### What landed
- **Metadata-only ALTER TABLE SET PROPERTIES partitioning=ARRAY['day(occurred_at)']** — CORRECT (Trino's canonical path for in-place Iceberg partition evolution; verified against trino.io/blog/2021/07/12/in-place-table-evolution-and-cloud-compatibility-with-iceberg.html + trino.io/docs/current/connector/iceberg.html).
- **New writes day-partitioned, old files keep month metadata, NOT rewritten** — CORRECT (VERIFIED against iceberg.apache.org/docs/latest/evolution/: "When you evolve a partition spec, the old data written with an earlier spec remains unchanged. New data is written using the new spec in a new layout").
- **Trino evaluates both specs, prunes correctly, returns union no missing/dup** — CORRECT (VERIFIED: "Both partitioning layouts are able to coexist in the same table"; Iceberg's per-spec-id manifest organization lets the scan planner apply each spec's pruning logic to its own subset).
- **Old files don't benefit from day pruning until optional Spark rewrite_data_files where occurred_at<cutoff** — CORRECT (rewrite_data_files is Spark procedure; Trino OPTIMIZE compacts files but doesn't rewrite-with-new-partition-spec automatically).
- **Correctness not affected** — CORRECT canonical semantic (this is the killer Iceberg feature vs Hive — partition evolution is safe).

### Minor (not gating)
- Could mention that the Trino OPTIMIZE command DOES rewrite files using the current schema/partition spec when run against partitions matching the new spec, but for OLD partitions written under the month spec, Trino OPTIMIZE alone won't convert them to day-partition layout — Spark's rewrite_data_files with appropriate where_clause is needed.
- Could mention $partitions metadata table to verify spec-id-per-partition post-evolution.

### Verdict
STRONG PASS. Right mechanism, right semantics, right correctness guarantee, right Spark-side path for old-data conversion.

---

## Q3 — MV staleness/refresh (Trino materialized views)

**Scores: 5.0 / 4.5 / 5.0 / 4.5 — avg 4.75 STRONG PASS**

### What landed
- **No auto-refresh, no background poller, must REFRESH manually via cron/Airflow/CronJob** — CORRECT (VERIFIED against trino.io/docs/current/sql/refresh-materialized-view.html: REFRESH MATERIALIZED VIEW is the manual command; Trino has no built-in scheduler; scheduling is external).
- **Default GRACE PERIOD infinity for new MVs** — CORRECT (VERIFIED: "new materialized views have an unlimited grace period by default" — backward-compat zero only for existing pre-411 MVs).
- **WHEN STALE INLINE default** — CORRECT (VERIFIED: "INLINE behavior expands it like a logical view, and queries accessing the materialized view will use the underlying query definition to retrieve up-to-date data. This is the default behavior when WHEN STALE is not specified").
- **Within grace + stale → serve cached stale silently; past grace → fall through to live source SELECT** — CORRECT canonical post-411 semantic (Q3 correctly distinguishes within-grace vs past-grace behavior).
- **Fix: SET GRACE PERIOD INTERVAL '90' MINUTE then past grace + new snapshot falls through to live source** — CORRECT recipe.
- **k8s CronJob hourly example** — CORRECT for prod stack (matches prod_info.md on-prem k8s + Trino 467 + REFRESH MATERIALIZED VIEW SQL).

### Minor (not gating)
- Could mention ALTER MATERIALIZED VIEW SET PROPERTIES grace_period = INTERVAL '90' MINUTE (the SQL syntax for adjusting grace period post-creation; was added in release 479 — verify availability on Trino 467).
- Could mention that REFRESH is synchronous (Trino docs: REFRESH runs the AS query and replaces storage table contents; takes as long as the underlying query); for long-running refreshes the CronJob needs a longer timeout.

### Verdict
STRONG PASS. Right default behavior, right manual-refresh framing, right grace-period semantics, right fix recipe, right prod-stack-fitting CronJob example.

---

## Q4 — Filter above TableScan diagnosis (query performance regression)

**Scores: 4.0 / 4.5 / 4.0 / 4.5 — avg 4.25 PASS (below STRONG)**

### What landed
- **Filter above TableScan != pushdown failure** — CORRECT canonical Iceberg framing (non-partition column filters apply residually; file-skipping via min/max stats still happens during the scan even when Filter is the node above TableScan).
- **physicalInputDataSize is critical metric not row count** — CORRECT (VERIFIED: physicalInputDataSize from EXPLAIN ANALYZE measures bytes read from storage = the real I/O smoking gun; raw inputRows can mislead because it counts post-scan filtered rows or post-aggregation values).
- **Partition predicate prunes free, non-partition column (plan_type) residual unless sorted/clustered or parquet bloom filter** — CORRECT (without min/max clustering via sort or bloom filter, the scan reads each file's full contents to find matching rows).
- **Diagnose physicalInputDataSize + selectivity + $files lower_bounds/upper_bounds** — CORRECT canonical Iceberg diagnostic ($files metadata table exposes per-file lower_bounds/upper_bounds maps that let you check whether min/max stats would prune effectively).
- **Sort-strategy rewrite_data_files (Spark)** — CORRECT and AVAILABLE on prod (Spark Iceberg rewrite_data_files with strategy=sort sort_order='plan_type ASC' clusters files by plan_type so min/max bounds become tight per file).

### What's missing (the deduction)
- **parquet_bloom_filter_columns Trino 467 availability flag** — Responder recommends setting parquet_bloom_filter_columns table property. **This property was added in Trino release 469 (Jan 27 2025) via PR #24573 — NOT available on prod's Trino 467.** An engineer running `ALTER TABLE SET PROPERTIES parquet_bloom_filter_columns = ARRAY['plan_type']` on prod 467 will hit "unknown table property" error. The Spark-side alternative (Spark Iceberg writer supports parquet bloom filter properties at write time, Trino 467 reads them for filter pushdown) IS available on prod but wasn't differentiated.
- VERIFIED via trino.io/docs/current/connector/iceberg.html + trino.io release notes search: bloom filter WRITE support to the Iceberg connector landed release 451 (June 2024); the parquet_bloom_filter_columns TABLE PROPERTY for in-Trino configuration landed release 469 (Jan 2025).
- This is NOT the recurring confident-inaccuracy-on-load-bearing-claim pattern (no wrong "X can't do Y" statement). It's a version-availability oversight in the FIX recommendation.

### Verdict
PASS (below STRONG). Right diagnosis mechanism + right physicalInputDataSize metric + right $files lower/upper bounds pattern. Deduction is the version-gated parquet_bloom_filter_columns fix recommendation that doesn't work on prod's Trino 467.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.75 | STRONG PASS — Spark JDBC parallelism (out-of-range rows preserved, predicates[] alt) |
| Q2 | 4.625 | STRONG PASS — partition evolution month->day metadata-only, both specs coexist |
| Q3 | 4.75 | STRONG PASS — MV no auto-refresh, default GRACE PERIOD infinity + WHEN STALE INLINE default |
| Q4 | 4.25 | PASS — Filter-above-TableScan + physicalInputDataSize correct, parquet_bloom_filter_columns Trino 467 availability MISSED |

**Average 4.5625 STRONG PASS** — fifteenth consecutive overall PASS in the iter402-416 window. -0.0625 step-DOWN from iter415 4.625, still STRONG PASS band. Zero new confident-inaccuracies on load-bearing claims.

**Trajectory iter394-416:** `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/4.625P/4.0625P/4.125P/4.5625P/4.0P/4.219P/4.625P/4.21875P/4.0625P/4.625P/**4.5625P**`.

**Topic status table:**
- Postgres-to-Iceberg ingestion: 4.4927/147 -> 4.4945/148 (Q1 4.75 above topic avg, nudge UP +0.0018).
- Iceberg partition design: 4.498/24 -> 4.503/25 (Q2 4.625 above topic avg, nudge UP +0.005).
- Analytical query patterns Iceberg+Trino: 4.4214/12 -> 4.4471/13 (Q3 4.75 above topic avg, nudge UP +0.0257).
- Query performance regression diagnosis: 4.6385/8 -> 4.5957/9 (Q4 4.25 below topic avg, nudge DOWN -0.0428; the topic-avg dragdown is the largest single-question impact this iteration because the topic has the smallest sample size).
- **Trino federation: 4.4880/272 unchanged (no federation Q this iteration; 16th consecutive iteration below 4.5 threshold).**

---

## Teacher actions next (iter 417)

1. **MEDIUM — Q4 parquet_bloom_filter_columns Trino 467-vs-469 availability flag** — update resources/18-query-performance-regression.md to note: (a) the parquet_bloom_filter_columns Iceberg-connector table property requires Trino 469+ (added release 469 Jan 27 2025 via PR #24573) — NOT available on prod 467; (b) for prod 467 the bloom-filter path is Spark-side write (Spark Iceberg writer supports bloom_filter_enabled per-column properties at write time), Trino 467 reads bloom filters for filter pushdown via parquet.use-bloom-filter; (c) for prod 467 the IN-TRINO fix levers remain: sort-strategy rewrite_data_files (Spark), z-order rewrite (Spark), repartition by clustering column (Spark), or schema design (partition by plan_type if cardinality permits). Add a "Trino version availability" small table to the Q4 fix section showing which fixes work on 467 vs 469+.

2. **MEDIUM — Trino federation topic threshold-push continuation** — no federation Q this iteration; topic still 0.0120 below threshold. Sustained 4.7+ federation answers still needed to cross. Continue auditing resource 22 for remaining myth-buster gaps (cross-catalog JOIN pushdown mechanics, IS DISTINCT FROM pushdown, OR-with-mixed-types pushdown, schema-evolution-with-pushdown).

3. **LOW — Carry-forward backlog**: HMS->Nessie write-freeze alternative + Hive-views-don't-migrate gotcha; MERGE rollback; OPA-override timeout; schema registry compat; JWT+OPA concurrency; Iceberg tagging 3rd-angle; fs.cache JMX 3rd-angle; Iceberg v3 deletion vectors timeline; snapshot vs serializable phantom-row 3rd-angle.

4. **LOW — Audit resource 18 for other version-gated-fix-recommendations** that may not work on Trino 467 — e.g., any release-469+ table properties, session properties, or procedures recommended without version qualifier. Pattern: when a fix recommendation references a Trino-Iceberg table property added post-467, qualify with "(Trino 469+) — for 467 use Spark-side alternative X".

---

## Judge probe targets next (iter 417)

1. **HIGH — Trino federation topic threshold-push** (NOT probed iter416): probe federation with a shape NOT yet covered — cross-catalog JOIN pushdown semantics ("which side pushes what, where does the join run?"), or schema-evolution-with-pushdown ("I added a new VARCHAR column to my Postgres table; will Trino pushdown break on the new column?"), or OR-with-mixed-types pushdown.

2. **HIGH — Q4 parquet_bloom_filter_columns Trino 467 availability re-probe** (durability check on iter417 teacher fix): "I tried setting parquet_bloom_filter_columns on my Trino 467 cluster and got an error — what gives, and what's the alternative?" — probes responder now correctly notes the 469+ availability + Spark-side write-time bloom filter alternative.

3. **MEDIUM — Iceberg branches-vs-expire_snapshots 3rd-angle (durability re-probe of iter415 fix)** — still pending. Different shape: "After running expire_snapshots, an old snapshot I thought was branch-protected is gone — why?" probes legitimate failure modes; or tag-vs-branch protection independence.

4. **MEDIUM — Snapshot vs serializable phantom-row 3rd-angle** — still pending durability re-probe from iter412 teacher's resource 26 §8.1/8.2 fix.

5. **MEDIUM — HMS->Nessie 2nd-angle for write-freeze alternative** — still pending.

6. **MEDIUM — Window NULL 2nd-angle (calendar-dim LEFT JOIN densification)** — still pending: "Rolling 7-day metric shows NULL gaps but I need zero-fill — what's the right pattern?"

7. **LOW — Iceberg v3 deletion vectors timeline** carry-forward (long-standing backlog item).

---

## Critical message to teacher for iter 417: extend myth-buster pattern + close version-availability gap

The iter416 result confirms the now-canonical recovery pattern continues to work repeatably — zero new confident-inaccuracies on load-bearing claims for the second consecutive iteration (iter415 + iter416). The structural risk of NEW confident-inaccuracy failures persists but the recovery-within-one-iteration pattern is durable. The NEW failure-flavor surfaced this iteration is version-gated-fix-recommendation (parquet_bloom_filter_columns Trino 469+, prod 467). This deserves an iter417 fix to add explicit version-availability qualifiers to fix recommendations in resource 18 (and possibly audit other resources for the same pattern).

For iter417, three priorities:
1. **HIGH** — version-availability fix for parquet_bloom_filter_columns in resource 18 + Trino 467 alternative paths.
2. **HIGH** — federation topic threshold-push (16 consecutive iterations stuck below 4.5; no federation Q this iter416 means no movement; need sustained 4.7+ in iter417+).
3. **MEDIUM** — branches-vs-expire_snapshots 3rd-angle durability re-probe still pending.
