# Iter 358 Q1 Feedback — Trino federation stop-gap session properties

**Question**: "We know we need to eventually ingest our 50M-row Postgres accounts table into Iceberg instead of federating it live, but the engineering work will take 2 weeks. Our dashboards are currently failing because the federated joins are OOMing. Are there session properties or config we can set RIGHT NOW to keep things running while we build the ingestion pipeline?"

**Verdict**: **FAIL — 2.75 / 5.0 average**

| Dimension | Score |
|---|---|
| Technical accuracy | 2.0 |
| Beginner clarity | 3.0 |
| Practical applicability | 2.0 |
| Completeness | 4.0 |

This was a critical correctness probe (iter357 judge probe target #4) and the answer failed by giving the inverse of the correct recommendation on the central question.

---

## What went well

1. **Step 0 (dynamic filtering verification via EXPLAIN ANALYZE VERBOSE)** — correct and matches iter358 teacher action #1. `dynamicFilterSplitsProcessed > 0` is a real field in the ScanFilterAndProjectOperator JSON stats per Trino docs. This is the first iteration in 4 attempts where DF verification was surfaced as Step 0.
2. **Step 1 (ANALYZE on Postgres + SHOW STATS verification)** — correct and matches iter358 teacher action #3. Checking `distinct_values_count` populated is the right NULL-stats sanity check.
3. **Step 3 (spill_enabled)** — `SET SESSION spill_enabled = true` syntax is correct per Trino spilling properties docs.
4. **Step 4 (resource group concurrency cap)** — the idea of capping concurrent federated queries is correct and a legitimate stability lever. The selector regex is wrong but the concept is right.
5. **Five distinct levers covered** — DF check, stats, distribution, spill, concurrency throttling. Good breadth.

---

## Critical errors

### 1. PRIMARY RECOMMENDATION IS INVERTED — BROADCAST is the OOM cause, not the fix

The answer's Step 2 is `SET SESSION join_distribution_type = 'BROADCAST'` for a federated join to a 50M-row Postgres table that is currently OOMing.

This is the opposite of correct. Per [Trino cost-based optimization docs](https://trino.io/docs/current/optimizer/cost-based-optimizations.html):

> "Broadcast joins require that the tables on the right side of the join after filtering fit in memory on each node, whereas distributed joins only need to fit in distributed memory across all nodes."

BROADCAST replicates the right-side table to every worker. The default `join_max_broadcast_table_size` is 100MB precisely as a guard against OOM. A 50M-row Postgres table is approximately 10-20GB uncompressed (per iter356 framing) — far above the broadcast threshold. The result of following Step 2 will be one of:
- Trino refuses to broadcast (exceeds `join_max_broadcast_table_size`) and the plan stays as it was, no change
- If the engineer also raises `join_max_broadcast_table_size`, the OOM gets WORSE because every worker now tries to hold 10-20GB

PARTITIONED is the documented OOM-avoidance lever for large joins. PARTITIONED hash-redistributes both sides across workers, so the build-side hash table is split across the cluster instead of replicated. This is exactly what iter356 (4.125 PASS) and iter357 (4.00 soft PASS) got right and what iter358 teacher action #3 instructed.

### 2. "What NOT to do" actively warns against the correct answer

> "Do NOT set join_distribution_type = 'PARTITIONED' as a long-term fix. ... It's a temporary fix only."

This buries the correct stop-gap inside a warning. The framing is the inverse of safe. PARTITIONED IS the temporary stop-gap that the engineer asked for. They explicitly said they will rebuild as an Iceberg ingestion pipeline in 2 weeks; a "temporary fix only" is exactly what they want.

### 3. Resource group selector regex is wrong

```json
"selectors": [{"user": ".*", "source": ".*postgresql.*"}]
```

Per [Trino resource group docs](https://trino.io/docs/current/admin/resource-groups.html), the `source` field matches the client-supplied ApplicationName (set via `--source` CLI flag or `ApplicationName` JDBC connection property), NOT the catalog name. A JDBC client querying the postgresql catalog will NOT automatically have "postgresql" in its source. This selector will silently fail to match in production unless every client app happens to set source to include "postgresql".

### 4. "If it's the smaller side" hedge is dangerous

Step 2 says: "The 50M-row accounts table fits in broadcast if it's the smaller side of the join and workers have sufficient RAM."

The question is explicit: the dashboards are OOMing on a federated join to this 50M-row table. The "if it's the smaller side" hedge is buried in a sentence and not turned into an actionable check. An engineer in pain TODAY will skim and run Step 2. If accounts is the larger side, Step 2 makes the OOM worse. If accounts is the smaller side but >100MB, Step 2 trips the broadcast threshold guard. There's no scenario where BROADCAST is the right first try for an OOM on a 50M-row JDBC join.

---

## Specific teacher actions for iter359 (HIGH priority)

`resources/22-trino-federation-postgresql.md` needs the following fixes before iter359:

1. **Add a "Stop-gap for federated-join OOM" checklist** with this exact order:
   - (a) Verify `join-dynamic-filtering-enabled=true` (default true in Trino 467; confirm via EXPLAIN ANALYZE VERBOSE looking for `dynamicFilterSplitsProcessed > 0`)
   - (b) `SHOW STATS FOR postgresql.<schema>.<table>` — if `row_count` or `distinct_values_count` is NULL, run `ANALYZE <table>` on the Postgres source replica
   - (c) `SET SESSION join_distribution_type = 'PARTITIONED'` — this is the primary OOM remedy, NOT BROADCAST
   - (d) `SET SESSION spill_enabled = true` as a stability backstop

2. **Add an explicit anti-pattern callout**: "If your federated join is OOMing, BROADCAST is almost never the fix and is likely already the cause. The default `join_max_broadcast_table_size=100MB` is a guard against exactly this. If you find yourself raising `join_max_broadcast_table_size`, you probably want `PARTITIONED` instead."

3. **Fix the resource group example**: `source` matches client ApplicationName, not catalog name. Either show a `queryType` selector, show `clientTags`, or explicitly state that the source string must be set by the client app.

4. **Inline glossary at top of resources/22** (flagged for 4 consecutive iterations): "build side", "probe side", "broadcast join", "partitioned join", "hash redistribute", "spill". Currently load-bearing terms used without definitions.

5. **"How to identify the build side" callout** — Trino's CBO picks the smaller side as build when stats are populated; without stats it falls back to syntactic right-side. Verify via `EXPLAIN (TYPE DISTRIBUTED)` looking for the `HashBuilder` step.

---

## Topic state

- **Trino federation / cross-source connectors**: 4.509/254 -> **4.499/255 questions** — SLIPPED BELOW 4.5 RAISED THRESHOLD for the first time since iter356 recovery. Topic flipped from PASSED back to NEEDS WORK on a critical correctness probe.
- Three consecutive iterations of decline (iter356 4.125, iter357 4.00, iter358 2.75). The trajectory is concerning even though the running avg only slipped marginally below threshold.

## Judge probe targets for iter359

1. **CRITICAL RE-PROBE** — Re-test stop-gap federation tuning at fresh phrasing (e.g., "our federated join is hitting `Query exceeded per-node memory limit` — which session property do we change?"). Iter358 failed this question; iter359 must re-probe to verify the BROADCAST→PARTITIONED correction lands.
2. Query plan optimization (EXPLAIN ANALYZE reading for slow Iceberg queries) — recurring open probe target since iter356.
3. Cost considerations cloud vs on-prem (lift-and-shift S3+Athena+Glue vs on-prem Trino+Iceberg+MinIO) — still not probed.
4. CDC tier — iter358 teacher action #2 (>100M or <5min freshness → Debezium → Iceberg MoR) untested.

## Sources verified via WebSearch

- [General properties — Trino 481 Documentation](https://trino.io/docs/current/admin/properties-general.html) — `join_distribution_type` BROADCAST/PARTITIONED/AUTOMATIC semantics
- [Cost-based optimizations — Trino 481 Documentation](https://trino.io/docs/current/optimizer/cost-based-optimizations.html) — `join_max_broadcast_table_size` default 100MB, broadcast requires right side fits in worker memory
- [Spilling properties — Trino 479 Documentation](https://trino.io/docs/current/admin/properties-spilling.html) — `spill_enabled` session property confirmed
- [EXPLAIN ANALYZE — Trino 481 Documentation](https://trino.io/docs/current/sql/explain-analyze.html) — `dynamicFilterSplitsProcessed` field in ScanFilterAndProjectOperator JSON
- [Resource groups — Trino 480 Documentation](https://trino.io/docs/current/admin/resource-groups.html) — `source` selector matches client ApplicationName, not catalog name
- [Dynamic filtering — Trino 481 Documentation](https://trino.io/docs/current/admin/dynamic-filtering.html) — verification via EXPLAIN ANALYZE

---

## Iter 358 End-of-Iteration Summary

**Verdict**: **FAIL — 3.5625 / 5.0 iteration average**

| Question | Topic | Score | Result |
|---|---|---|---|
| Q1 | Trino federation stop-gap OOM (session properties) | 2.75 | FAIL |
| Q2 | 5M-rows in RAM, columnar advantage / Postgres-vs-OLAP | 4.375 | PASS |
| **Iter avg** | | **3.5625** | **FAIL** |

### Headline finding

Iter358 fails on the iter357 critical re-probe target #2 (stop-gap federation tuning). The answer recommended the inverse of correct: `SET SESSION join_distribution_type = 'BROADCAST'` as the primary OOM remedy on a 50M-row federated Postgres join, and explicitly warned the engineer NOT to use `PARTITIONED` (which is the documented fix). This is a critical correctness inversion on a topic that has now slipped from PASSED back to NEEDS WORK after three consecutive declining iterations (iter356 4.125, iter357 4.00, iter358 2.75).

### Per-question pattern

- **Q1 (2.75 FAIL)** — Critical inversion on the primary lever. The good news: Step 0 (dynamic filtering verification via EXPLAIN ANALYZE VERBOSE) finally landed for the first time in 4 attempts, matching iter358 teacher action #1. ANALYZE/SHOW STATS sanity check (Step 1) landed too (teacher action #3). But Steps 2-5 inverted the primary distribution recommendation and embedded the correct answer inside a "do NOT do this" warning. The breadth was right (5 levers), the central correctness was wrong.
- **Q2 (4.375 PASS)** — Postgres-vs-OLAP 4th probe lands cleanly. Vectorization/SIMD reasoning solid, tuning-first framing preserved (EXPLAIN BUFFERS / work_mem / partial indexes / BRIN BEFORE OLAP-proxy step), upward trajectory across iter355/356/357/358 (4.9375 / 3.875 / 4.00 / 4.375). Subtopic now stable enough to declare durable.

### Topic state changes

- **Trino federation / cross-source connectors**: 4.509 -> **4.499 (255 questions)** — slipped below raised 4.5 threshold for the first time since iter356 recovery. Status flipped PASSED -> NEEDS WORK.
- **When to add an OLAP layer / Postgres-vs-OLAP decision**: 4th probe at fresh phrasing (5M rows, fits in RAM) lands at 4.375, durability now demonstrated across 4 angles. Topic remains PASSED with reinforced confidence.
- **Column-oriented storage**: Q2 also touched columnar/vectorization reasoning — landed cleanly, no regression.

### Recurring gaps (now CHRONIC)

1. **Federation OOM-stop-gap correctness** — iter356/357/358 all show this topic is fragile under stop-gap framing. The answer keeps either omitting `PARTITIONED` (iter356/357) or now actively recommending its opposite (iter358). Stop-gap tier in resources/22 is either missing, mis-ordered, or being read wrong by the responder. Highest-priority repair target.
2. **Inline glossary at top of resources/22** — flagged for 4 consecutive iterations (iter355/356/357/358). "Build side", "broadcast", "partitioned", "hash redistribute", "spill" still load-bearing without definitions in resources/22.
3. **Resource group selector example wrong** — `source` matches client ApplicationName, not catalog name. This has been incorrect in two iterations now.

### What is working

- Dynamic filtering verification finally surfaced as Step 0 on the federation answer (iter358 teacher action #1 landed)
- ANALYZE / SHOW STATS Postgres-stats sanity check landed (teacher action #3 landed)
- Tuning-first framing on Postgres-vs-OLAP subtopic now durable across 4 probes
- Vectorization/SIMD/columnar reasoning on Q2 was correct and concrete

### Iter359 teacher actions (HIGH priority — extending iter358 actions)

1. **CRITICAL — rewrite stop-gap checklist in resources/22 with `PARTITIONED` as the primary OOM lever** and an explicit anti-pattern callout that BROADCAST is almost never the fix for an OOMing federated join (and is likely already the cause if `join_max_broadcast_table_size` was raised). See iter358 Q1 feedback section "Specific teacher actions" for exact ordering.
2. **CRITICAL — add anti-pattern callout** "BROADCAST is the OOM cause, not the fix" with the `join_max_broadcast_table_size=100MB` default explained as a guard.
3. **HIGH — fix resource group selector example** in resources/22: use `queryType` or `clientTags` or explicitly note that `source` matches client ApplicationName.
4. **HIGH — inline glossary at top of resources/22** (4th iteration flagged): build side, probe side, broadcast join, partitioned join, hash redistribute, spill. Currently load-bearing without definitions.
5. **MEDIUM — "how to identify the build side" callout**: Trino CBO picks smaller side as build when stats are populated; falls back to syntactic right-side without stats. Verify via `EXPLAIN (TYPE DISTRIBUTED)` looking for `HashBuilder`.

### Iter359 judge probe targets

1. **CRITICAL RE-PROBE** — Re-test stop-gap federation tuning at fresh phrasing (e.g., "our federated join is hitting `Query exceeded per-node memory limit` — which session property do we change?"). Iter358 failed; iter359 must verify the BROADCAST->PARTITIONED correction lands.
2. CDC tier — iter358 teacher action #2 (>100M or <5min freshness -> Debezium -> Iceberg MoR) still untested.
3. Query plan optimization (EXPLAIN ANALYZE reading for slow Iceberg queries) — recurring open probe target since iter356.
4. Cost considerations cloud vs on-prem (lift-and-shift S3+Athena+Glue vs on-prem Trino+Iceberg+MinIO) — still not probed.

