# Iter 142 Q2 — Judge Score

**Question**: Customer ran a big export (two years of event data, filters and groupings); Trino died with OOM. Bumping memory didn't help. Why does SELECT use memory and what can be done without throwing more RAM?

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter142-q2.md`

---

## Score breakdown

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4.5 | All core claims verified against official docs; one minor imprecision on memory layers |
| Clarity for SaaS engineer | 4.75 | Excellent progression from "why SELECT uses memory" through diagnosis to fixes; Postgres mental-model contrast in joins section is helpful |
| Practical usefulness | 4.75 | Every fix has concrete SQL; INSERT INTO ... AS SELECT + MinIO direct download maps exactly to the prod env's documented export pattern; Trino UI URL pattern is correct |
| Completeness | 4.75 | Covers root causes (join, agg, sort, spill), three-layer memory model, diagnostics (UI + EXPLAIN + EXPLAIN ANALYZE), six fixes, sizing guidance, and config-to-check section |

**Average**: (4.5 + 4.75 + 4.75 + 4.75) / 4 = **4.6875** → **PASS** (≥ 4.5)

---

## What was verified correct (via WebSearch)

1. **Hash join build side in memory** — VERIFIED. Trino loads the right-most/build side of the join into an in-memory hash table and streams the probe side against it. Broadcast joins require the build side to fit in each worker's memory; partitioned joins distribute by hash key. Answer's description matches official Trino docs.
   - Source: https://trino.io/docs/current/optimizer/cost-based-optimizations.html

2. **`query.max-memory-per-node`** — VERIFIED as the correct config property name. Per official docs, it "defines the maximum memory a query can consume on each worker node" and limits user memory (hash tables, sort buffers). Answer correctly characterizes it as a per-worker, per-query cap (not cluster-wide).
   - Source: https://trino.io/docs/current/admin/properties-resource-management.html

3. **`approx_distinct` uses HyperLogLog** — VERIFIED. Trino's HyperLogLog implementation uses 32-bit buckets, sparse-to-dense layout transition. Standard error is approximately **2.3%** (answer says "~2%" — close enough; rounded down slightly but not misleading).
   - Source: https://trino.io/docs/current/functions/hyperloglog.html

4. **`EXPLAIN (TYPE DISTRIBUTED)`** — VERIFIED valid syntax. The docs show `EXPLAIN [ ( option [, ...] ) ] statement` with `TYPE { LOGICAL | DISTRIBUTED | VALIDATE | IO }`. DISTRIBUTED is actually the default if you just write `EXPLAIN`, but the explicit form in the answer is fully valid.
   - Source: https://trino.io/docs/current/sql/explain.html

5. **Spill-to-disk** — VERIFIED. Trino supports spill for aggregations, joins (inner and outer), sorting, and window functions. Spill writes intermediate results to disk and is slower than in-memory; can be exhausted by tmp disk pressure. Answer's framing ("safety net that sometimes fails", "spill itself exhausting temporary disk space") is accurate.
   - Source: https://trino.io/docs/current/admin/spill.html

6. **Linear scaling memory guidance** — REASONABLE for the dominant operators here (hash agg / hash join build side) where memory scales roughly with distinct-key cardinality and join build cardinality. For a 2-year export query whose aggregation cardinality grows roughly linearly with time, "30 days = 3 GB → 730 days = ~73 GB" is a defensible back-of-envelope estimate, with the answer correctly suggesting it as a *starting* point (UI measurement first). Not a precise model, but the answer frames it as approximate guidance, which is appropriate.

---

## Errors or gaps found

### Minor

1. **HyperLogLog error rate**: Answer says "~2% error"; actual standard error is ~2.3%. Within rounding tolerance; not misleading. No fix required.

2. **Memory layer #2 ("Per-resource-group memory limit")**: The description is roughly correct, but resource-group `softMemoryLimit` queues *new* queries when the threshold is exceeded (which the answer says) — however, resource groups have additional levers (`softCpuLimit`, `hardCpuLimit`, `maxQueued`, `hardConcurrencyLimit`) that bound concurrent execution. The answer simplifies to just memory which is fine given the question's scope.

3. **`query.max-memory` vs `query.max-memory-per-node`**: The answer only mentions the per-node property. The cluster-wide cap is `query.max-memory` (sum across all nodes). For an export query that uses lots of distributed memory, hitting `query.max-memory` (`EXCEEDED_DISTRIBUTED_MEMORY_LIMIT`) is also possible. The answer covers cluster-wide pressure conceptually under "Layer 3" but doesn't name the property. Minor gap.

4. **EXPLAIN DISTRIBUTED is the default**: Minor stylistic note — `EXPLAIN <stmt>` alone produces a distributed plan; the explicit `(TYPE DISTRIBUTED)` is redundant but valid. Not an error.

5. **Spill default**: Answer says "Verify spill is enabled — if spill is disabled..." This is correct guidance; spill is disabled by default in Trino (`spill-enabled=false`), so the recommendation to enable it for large export workloads is on-target.

### No major errors found

All SQL syntax in the answer is valid Trino. The `INSERT INTO ... AS SELECT` + MinIO direct download pattern matches the documented production export pattern in `prod_info.md`. The HyperLogLog, broadcast/partitioned join, and EXPLAIN claims are all verifiable.

---

## Production fit (per `prod_info.md`)

- Trino 467 + Iceberg 1.5.2 + MinIO + Hive Metastore: all advice is compatible.
- INSERT INTO ... AS SELECT + download Parquet from MinIO: this is explicitly listed in prod_info as a supported export pattern ("Users sometimes run `INSERT INTO <temp_table> AS SELECT ...` and then download the result files directly from MinIO to speed up query performance"). Answer's fix #5 matches.
- Resource groups + JWT auth context: answer references resource groups under multi-tenant query isolation, consistent with the stack.
- Pre-aggregation via Spark nightly job: matches the documented ingestion stack (Spark with Iceberg 1.5.2).
- No public-cloud-only tools recommended; on-prem k8s assumptions respected.

---

## Resource fix recommendations

None required. The OOM / memory-management resource set is already producing high-quality, production-aligned answers. If the teacher wants to push a 4.7 → 4.9 lift on future iterations of this topic, a small addition worth considering:

- A short note distinguishing `query.max-memory-per-node` (per-worker user-memory cap) vs `query.max-memory` (cluster-wide distributed memory cap), and what error class each one produces (`EXCEEDED_LOCAL_MEMORY_LIMIT` vs `EXCEEDED_DISTRIBUTED_MEMORY_LIMIT`). This would let answers name the precise error the customer is hitting.
- Optional: a one-liner that spill is disabled by default in Trino, so "enable it for export workloads" is a real, non-trivial config change.

These are nice-to-haves; nothing blocks the current PASS.

---

## Verdict: PASS (4.69 / 5)

High-quality answer. Beginner-friendly framing of why SELECT uses memory (joins → aggregations → sorts → spill), accurate three-layer memory model, six concrete fixes each with SQL, diagnostic workflow that an engineer can follow today, and a summary table at the end. All technical claims verified against trino.io docs. Production fit is excellent (MinIO direct-download export pattern matches prod_info exactly).
