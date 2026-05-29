# Iter 359 Q1 — Judge Feedback (Trino federation OOM session-property re-probe)

**Date**: 2026-05-29
**Phase**: EXTENDED
**Topic**: Trino federation / cross-source connectors (CRITICAL RE-PROBE of iter358 BROADCAST/PARTITIONED inversion)

**Question**: "Our Trino workers are throwing `Query exceeded per-node memory limit of 8GB` when we run a JOIN between our Iceberg events table and a Postgres dimension table via the postgresql connector. Which session property do we change to fix this? I've heard there's a setting for broadcast vs partitioned joins — which one should we be using when the Postgres table is large?"

---

## Verdict: PASS — 4.125 / 5.00

The iter358 critical inversion is FIXED. The responder correctly recommended `SET SESSION join_distribution_type = 'PARTITIONED'` as the primary OOM remedy and included an explicit anti-pattern callout warning against BROADCAST. This is a 1.375-point per-question recovery from iter358's 2.75.

**However, the topic running average is 4.498/256 questions — still 0.002 below the raised 4.5 threshold.** The topic remains NEEDS WORK until ~5-6 more 4.5+ questions land. The recovery trajectory is now: iter355 4.9375 / iter356 4.125 / iter357 4.00 / iter358 2.75 / iter359 **4.125**.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | PARTITIONED correctly named as primary OOM remedy; BROADCAST mechanism (replicate-to-every-worker) correct; ~100MB safe-BROADCAST threshold matches `join_max_broadcast_table_size` default. Minor: `dynamicFilterSplitsProcessed` field most reliably under `EXPLAIN ANALYZE VERBOSE` not bare `EXPLAIN ANALYZE`; guardrail property name (`join_max_broadcast_table_size`) not explicitly stated. |
| Beginner clarity | 3.5 | BROADCAST/PARTITIONED contrast clear at prose level. But "build side", "probe side", "hash-redistribute", "1/N slice", "dynamic filtering" all still used without inline definitions — 5th iteration this gap is flagged. |
| Practical applicability | 4.5 | Engineer in pain TODAY can copy-paste `SET SESSION join_distribution_type='PARTITIONED'` safely. Anti-pattern callout prevents iter358 failure mode. Step 0 (DF check) and Step 1 (stats) actionable. Minor: no `spill_enabled` backstop, no `query.max-memory-per-node` headroom check, no production environment fit (Trino 467 on-prem). |
| Completeness | 4.0 | Five of six iter358 teacher-action levers landed (DF check, stats, PARTITIONED, anti-pattern callout, mental-model contrast). Missing: `spill_enabled=true` backstop, explicit `join_max_broadcast_table_size` property name, "how to identify the build side" callout. |

---

## What worked (iter358 → iter359 wins)

1. **CRITICAL CORRECTION LANDED**: `SET SESSION join_distribution_type='PARTITIONED'` is the primary remedy. Iter358 teacher actions #1 + #4 succeeded.
2. **Anti-pattern callout LANDED**: "Do NOT try `SET SESSION join_distribution_type = 'BROADCAST'`. BROADCAST is the exact cause of OOM on large tables." This is exactly the iter358 teacher action #2 warning. The framing "The confusion: BROADCAST is correct when the dimension is **small**" is the right mental model for why an engineer would have heard it recommended.
3. **Step 0 dynamic-filtering check carries forward**: `EXPLAIN ANALYZE` + `dynamicFilterSplitsProcessed = N` check appears as preliminary diagnosis — iter358 teacher action sequencing landed.
4. **Step 1 stats sanity check carries forward**: `ANALYZE` on Postgres source + `SHOW STATS FOR postgresql.public.accounts` — iter358 teacher action #3 (a)+(b) landed.
5. **Resource group selector regression NOT repeated**: The iter358 wrong `source: ".*postgresql.*"` example was correctly omitted from this answer.
6. **Mechanism prose is correct**: "BROADCAST: Sends the entire build side to every worker" and "PARTITIONED: Hash-redistributes both sides across workers by join key. Each worker sees only its 1/N slice" — both consistent with Trino docs.

---

## What still needs work (iter360 teacher actions)

### MEDIUM priority — these are the levers to push topic running avg above 4.5

1. **MEDIUM (clarity, 5TH ITERATION FLAGGED)** — Inline glossary at top of `resources/22-trino-federation-postgresql.md`:
   - **build side** — the smaller table in a join that's loaded into a hash table first; the larger table (probe side) is streamed through it
   - **probe side** — the larger table that's streamed through the build-side hash table
   - **broadcast join** — distribution where the build side is replicated to every worker (only safe when build side is small, default cap `join_max_broadcast_table_size=100MB`)
   - **partitioned join** — distribution where both sides are hash-redistributed across workers on the join key, so each worker handles only its slice
   - **hash-redistribute** — the network shuffle step in a partitioned join where rows are routed to workers based on `hash(join_key) % N`
   - **spill** — writing in-memory intermediate state to local disk when memory runs out (controlled by `spill_enabled` session property)
   - **dynamic filtering** — Trino's runtime optimization that pushes the build-side's join-key values down to the probe-side scan as a predicate filter

2. **MEDIUM (correctness)** — Update `resources/22-trino-federation-postgresql.md` Step 0 to specify `EXPLAIN ANALYZE VERBOSE <query>` (with `VERBOSE` keyword) so engineers actually find the `dynamicFilterSplitsProcessed` field in the operator-level stats. Bare `EXPLAIN ANALYZE` surfaces summary stats but not the per-operator dynamic-filter telemetry.

3. **MEDIUM (completeness)** — Name `join_max_broadcast_table_size` explicitly. Current answer says "Safe only when the build side is small (under ~100MB after filtering)" — that 100MB is the documented default of `join_max_broadcast_table_size`. Engineers need the property name so they can check `SHOW SESSION LIKE 'join_max_broadcast_table_size%'` and understand the guardrail.

4. **MEDIUM (completeness)** — Add `SET SESSION spill_enabled = true` as a Step 3 backstop. The stop-gap order should be:
   - Step 0: `EXPLAIN ANALYZE VERBOSE` — verify `dynamicFilterSplitsProcessed > 0`
   - Step 1: `SHOW STATS FOR postgresql.<schema>.<table>` + `ANALYZE <table>` on Postgres source if NULL
   - Step 2: `SET SESSION join_distribution_type = 'PARTITIONED'`
   - Step 3: `SET SESSION spill_enabled = true` (backstop if PARTITIONED still spills under memory pressure)
   - Step 4: escalate to ingestion pipeline (>100M rows -> Debezium CDC -> Iceberg MoR)

5. **MEDIUM (clarity)** — Add a "how to identify the build side" callout (iter358 teacher action #6, still not landed). Engineers need to understand that Trino's CBO picks the smaller side as build when stats are populated, and falls back to syntactic right-side (the table after `JOIN`) without stats. They can verify via `EXPLAIN (TYPE DISTRIBUTED) <query>` looking for which input feeds the `HashBuilder` operator.

6. **LOW (environment fit)** — Resource should note production environment fit: Trino 467 on-prem with MinIO/Iceberg per `prod_info.md`. Session properties (`join_distribution_type`, `spill_enabled`) are version-stable so 467 behaves identically to 481 docs; but resource-group selector examples must reflect production OPA + JWT authentication stack, not file-based access control.

---

## Iter360 judge probe targets

1. **CDC tier** (>100M or <5min freshness SLO -> Debezium -> Iceberg MoR) — iter358 teacher action #2 still untested across iter357/358/359. STILL OPEN.
2. **Query plan optimization** (EXPLAIN ANALYZE VERBOSE reading for slow Iceberg queries: TableScan/Filter/Aggregate cost, scan stats, dynamic-filter rows-filtered) — still not probed since iter356 rubric flag.
3. **Cost considerations cloud vs on-prem** (AWS S3+Athena+Glue lift-and-shift vs on-prem Trino+Iceberg+MinIO) — still not probed.
4. **Stop-gap federation 3rd-phrasing re-probe** — "if we set PARTITIONED and it STILL OOMs, what's the next lever?" — to test if `spill_enabled` backstop lands.

---

## Source verification (judge WebSearch — official Trino docs)

- [General properties — Trino 481 Documentation](https://trino.io/docs/current/admin/properties-general.html) — `join_distribution_type` BROADCAST/PARTITIONED/AUTOMATIC semantics, BROADCAST replicates right table to all nodes
- [Cost-based optimizations — Trino 481 Documentation](https://trino.io/docs/current/optimizer/cost-based-optimizations.html) — `join_max_broadcast_table_size` default 100MB, broadcast requires right side fits in worker memory after filtering, distributed joins only need to fit in distributed memory across all nodes
- [Spill to disk — Trino 481 Documentation](https://trino.io/docs/current/admin/spill.html) — `spill_enabled` session property
- [EXPLAIN ANALYZE — Trino 481 Documentation](https://trino.io/docs/current/sql/explain-analyze.html) — VERBOSE flag exposes dynamic-filter operator-level stats

---

## Topic running averages

- **Trino federation: 4.499/255 -> 4.498/256 questions** (still NEEDS WORK below raised 4.5 threshold, but per-question score recovered 1.375 points from iter358 critical-inversion failure. ~5-6 more 4.5+ questions needed to recross threshold.)

---

## Iter 359 End-of-Iteration Summary

**Date**: 2026-05-29
**Phase**: EXTENDED
**Iteration average**: **4.25 / 5.00 — PASS** (recovery from iter358 3.5625 FAIL)

### Per-question scores

| # | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Trino federation OOM — session property (PARTITIONED fix, critical re-probe) | 4.125 | PASS |
| Q2 | CDC vs micro-batch for sub-5min freshness SLO (Debezium tier — first probe) | 4.375 | PASS |

### Key wins (iter358 -> iter359)

1. **CRITICAL inversion fixed**: Q1 correctly recommended `SET SESSION join_distribution_type = 'PARTITIONED'` as the primary OOM remedy and included the explicit anti-pattern callout against BROADCAST. The iter358 BROADCAST/PARTITIONED inversion did not recur. +1.375 per-question recovery on the federation topic.
2. **CDC tier finally tested**: Q2 was the first probe of the Debezium -> Iceberg MoR tier since the iter358 teacher action #2 was flagged. The 4.375 result establishes a passing baseline for the CDC tier from a single angle.
3. **Step-sequencing carry-forward stable**: Step 0 (dynamic-filter check via EXPLAIN ANALYZE), Step 1 (`ANALYZE` + `SHOW STATS` Postgres-source sanity), Step 2 (PARTITIONED) all landed together on Q1 — showing the iter358 teacher action sequence is durable, not a single-prompt artifact.
4. **Resource-group selector regression NOT repeated**: The iter358 wrong `source: ".*postgresql.*"` example was absent from Q1.
5. **Iteration-level recovery**: 4.25 iter avg is +0.6875 above iter358 — recovery from the FAIL is decisive at the iteration level.

### Remaining gaps

1. **MEDIUM (5TH iteration flagged)** — inline glossary at top of `resources/22-trino-federation-postgresql.md` for build side / probe side / broadcast / partitioned / hash-redistribute / spill / dynamic filtering still not landed. This is now the longest-standing open clarity gap.
2. **MEDIUM** — `EXPLAIN ANALYZE VERBOSE` (with explicit `VERBOSE` keyword) not yet specified in Step 0; bare `EXPLAIN ANALYZE` will not surface `dynamicFilterSplitsProcessed` per-operator.
3. **MEDIUM** — `join_max_broadcast_table_size` property name still not stated explicitly in the resource (only the 100MB default is mentioned).
4. **MEDIUM** — `SET SESSION spill_enabled = true` Step 3 backstop not yet present in stop-gap checklist.
5. **MEDIUM** — "how to identify the build side" callout (CBO smaller-side rule + syntactic right-side fallback + `EXPLAIN (TYPE DISTRIBUTED)` HashBuilder verification) still missing.
6. **TOPIC AVG** — Trino federation running avg 4.498/256 questions still 0.002 below the raised 4.5 threshold; needs ~5-6 more 4.5+ landings to recross.
7. **CDC tier coverage** — Q2 is a single-angle probe; needs at least one more angle before the CDC tier can be marked as passing in the rubric.

### Iter 360 suggestions

**Teacher actions (HIGH priority)**:
1. Add inline glossary at top of `resources/22-trino-federation-postgresql.md` covering build side / probe side / broadcast / partitioned / hash-redistribute / spill / dynamic filtering — 5th iteration flagged.
2. Update Step 0 to specify `EXPLAIN ANALYZE VERBOSE` with the explicit `VERBOSE` keyword.
3. Name `join_max_broadcast_table_size` explicitly with the 100MB default and `SHOW SESSION LIKE 'join_max_broadcast_table_size%'` verification.
4. Add Step 3 backstop `SET SESSION spill_enabled = true` after PARTITIONED in the stop-gap checklist.
5. Add "how to identify the build side" callout (CBO smaller-side rule + syntactic right-side fallback + `EXPLAIN (TYPE DISTRIBUTED)` HashBuilder).

**Teacher actions (MEDIUM priority)**:
6. Add a 2nd-angle CDC tier example to whichever resource hosts Debezium/MoR content — sub-5min freshness is now a documented question shape, the next likely phrasing is "we tried Kafka Connect S3 sink and it created too many small files — should we move to Debezium-direct-to-Iceberg?" or "how do we tune Debezium for >100M-row tables without saturating the source DB binlog reader?"

**Judge probe targets**:
1. **Stop-gap federation 3rd-phrasing re-probe** — "if we set PARTITIONED and it STILL OOMs, what's the next lever?" — to test if `spill_enabled` backstop lands and to push topic running avg above 4.5.
2. **CDC tier 2nd angle** — Debezium tuning for high-volume tables OR Debezium-vs-Kafka-Connect-S3-sink tradeoff OR Iceberg MoR compaction cadence for CDC workloads.
3. **Query plan optimization** — `EXPLAIN ANALYZE VERBOSE` reading for slow Iceberg queries (TableScan/Filter/Aggregate cost, scan stats, dynamic-filter rows-filtered) — still not probed since iter356 rubric flag.
4. **Cost considerations cloud vs on-prem** — AWS S3+Athena+Glue lift-and-shift vs on-prem Trino+Iceberg+MinIO — still not probed.
