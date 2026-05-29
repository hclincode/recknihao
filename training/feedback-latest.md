# Judge Feedback — Iter 360 Q1 (EXTENDED phase, mid-iteration)

**Date**: 2026-05-29
**Phase**: EXTENDED
**Topic probed**: Trino federation / cross-source connectors — 3rd-phrasing stop-gap re-probe ("PARTITIONED still OOMs, what's the next lever?") per iter359 judge probe target #4.

**Question scenario**: SaaS engineer set `join_distribution_type = 'PARTITIONED'` on a federated join per prior guidance, workers still OOM with `Query exceeded per-node memory limit`, slower queries acceptable, just need completion. Asks "what's next after PARTITIONED?"

---

## Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | `SET SESSION spill_enabled = true` is the correct documented next lever. WebSearch-confirmed: `spill_enabled` is a real session property (maps to `spill-enabled` config), `spiller-spill-path` is a real config property, `hardConcurrencyLimit` + source selector are real resource-group features. The "build-side hash table to local worker disk" mechanism description is correct. Anti-pattern callout against raising `query.max-memory-per-node` is sound. Deduction: missing the cluster-config-level `spill-enabled=true` check at `etc/config.properties` — the session property is a no-op if cluster has spill disabled, which is a real production trap. Resource-group JSON is a fragment, not a complete `etc/resource-groups.json`. |
| Beginner clarity | 3.5 | Steps are labeled, code is runnable, "trades latency for stability" is a clear framing. But "build-side hash table", "spill", "resource group", "concurrency limit", "JDBC scan", "build side" all used without inline definitions. This is the 6th consecutive iteration the inline-glossary gap has been flagged on this topic — single largest remaining clarity deduction. |
| Practical applicability | 4.5 | Engineer in pain TODAY knows exactly what to do next: (1) run `SET SESSION spill_enabled = true`, (2) verify k8s worker pods have `emptyDir`/`local-pv` mounted at `spiller-spill-path`, (3) add a resource group with `hardConcurrencyLimit = 2` or `3`. Production environment fit (on-prem k8s) is acknowledged. "1-2 weeks of stability, not permanent, durable fix is Iceberg ingestion" framing is exactly right. Minor deductions: no `EXPLAIN ANALYZE VERBOSE` diagnostic step before spill (spill helps for joins/aggs/sorts but not output buffer OOM); no OPA + JWT production auth note on the resource-group example. |
| Completeness | 4.0 | Covers next-lever (`spill_enabled`), prerequisite (storage mount), complementary lever (concurrency cap), framing ("not permanent"), and an anti-pattern (`query.max-memory-per-node`). Missing: cluster-config `spill-enabled=true` check, spill disk budget knobs (`max-spill-per-node`, `query-max-spill-per-node`), `EXPLAIN ANALYZE VERBOSE` confirmation step, and production environment fit (OPA + JWT on the resource-group selector). |
| **Average** | **4.125** | **PASS** above per-question 4.0 bar. |

---

## Verdict: PASS (4.125)

Above per-question 4.0 threshold. Topic running average moves 4.498/256 → **4.497/257** — still 0.003 below the raised 4.5 topic threshold so the topic remains NEEDS WORK by the per-topic override, but the federation stop-gap session-property sequence is now demonstrably durable across three different phrasings of the OOM scenario:

- Iter358: BROADCAST/PARTITIONED inversion (FAIL, 2.75)
- Iter359: PARTITIONED as primary OOM remedy (PASS, 4.125)
- Iter360: spill_enabled as next lever after PARTITIONED (PASS, 4.125)

The iter360 teacher action #4 (Step 3 `spill_enabled=true` backstop) landed cleanly.

---

## What the teacher must do for iter361

**MEDIUM (correctness) — Cluster-config trap on spill**:
Add explicit callout in stop-gap Step 3 to `resources/22-trino-federation-postgresql.md`:

> Before running `SET SESSION spill_enabled = true`, verify cluster-level `spill-enabled=true` is set in `etc/config.properties` on coordinator and workers. The session property is a no-op if the cluster has spill disabled at the config level — this is the most common reason engineers report "I enabled spill and nothing changed."

This is a real production trap and the iter360 answer missed it.

**MEDIUM (completeness) — Spill disk budget**:
Add `max-spill-per-node` and `query-max-spill-per-node` to the stop-gap tier. Engineers commonly hit silent spill-budget exhaustion and need to know these exist to size them.

**MEDIUM (clarity, 6th consecutive iteration flagged) — Inline glossary**:
Top of `resources/22-trino-federation-postgresql.md` needs an inline glossary defining: build side, probe side, broadcast join, partitioned join, hash-redistribute, spill, build-side hash table, dynamic filtering, resource group, concurrency limit. This is the longest-standing open gap on this topic and accounts for the largest single deduction (-1.5 in iter359 and iter360 alike).

**MEDIUM (practical applicability) — Diagnostic step before spill**:
Add `EXPLAIN ANALYZE VERBOSE` confirmation step: "look for `HashBuilder` operator memory usage; if HashBuilder is the OOM source, spill helps; if it's output buffer pressure or a different operator, spill does not help." This was the missing diagnostic step in iter360.

**LOW (completeness) — Complete resource-group template**:
Provide a full `etc/resource-groups.json` template (not a fragment) plus the `etc/resource-groups.properties` manager configuration pointer, so engineers can copy-paste a working resource group rather than reconstruct the full file schema.

**LOW (environment fit) — OPA + JWT note on resource groups**:
Note that in the production OPA + JWT stack (per `prod_info.md`), the source field comes from the JWT-authenticated client and resource-group selectors run independently of OPA authorization — the two systems are orthogonal.

---

## Iter361 judge probe targets

1. **CDC tier 2nd angle** — still untested across iter357/358/359/360 except single iter359 Q2 baseline (4.375). Probe Debezium tuning for high-volume tables OR Debezium-vs-Kafka-Connect-S3-sink tradeoff OR Iceberg MoR compaction cadence for CDC workloads.
2. **Query plan optimization** — `EXPLAIN ANALYZE VERBOSE` reading for slow Iceberg queries (TableScan/Filter/Aggregate cost, scan stats, dynamic-filter rows-filtered) — not probed since iter356 rubric flag.
3. **Cost considerations cloud vs on-prem** — AWS S3+Athena+Glue lift-and-shift vs on-prem Trino+Iceberg+MinIO — not probed.
4. **Trino federation 4th phrasing at the cluster-config level** — e.g., "we set `SET SESSION spill_enabled = true` and nothing happened — what's wrong?" to test if the cluster-config gap from iter360 lands.
5. **Trino federation glossary landing check** — re-probe to test whether the inline glossary at top of `resources/22` (iter360 teacher action #1, now 6 iterations flagged) actually landed in subsequent rewrites — clarity has been deducted 1.5 points two iterations running.

---

## Sources verified via WebSearch

- [Spilling properties — Trino 479 Documentation](https://trino.io/docs/current/admin/properties-spilling.html) — confirms `spill_enabled` is a valid session property mapping to `spill-enabled` config property
- [Spill to disk — Trino 481 Documentation](https://trino.io/docs/current/admin/spill.html) — confirms `spiller-spill-path` config property, JBOD model, do-not-spill-to-JVM-log-drive guidance
- [Resource groups — Trino 480 Documentation](https://trino.io/docs/current/admin/resource-groups.html) — confirms `hardConcurrencyLimit` and source selector semantics
- [General properties — Trino 481 Documentation](https://trino.io/docs/current/admin/properties-general.html) — confirms `query.max-memory-per-node` semantics (correctly framed as anti-pattern in the answer)

---

## Iter 360 End-of-Iteration Summary

**Date**: 2026-05-29
**Phase**: EXTENDED
**Iteration average**: **4.125 — PASS** (above 4.0 per-iteration bar)

### Per-question results

| Q | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Trino federation — spill_enabled as next lever after PARTITIONED (3rd-phrasing stop-gap re-probe) | 4.125 | PASS |
| Q2 | EXPLAIN ANALYZE on 850GB Physical Input — partition pruning diagnostic (first probe of this topic since iter356 rubric flag) | 4.125 | PASS |

### Iter 360 wins

1. **Stop-gap sequence durable across 3 different phrasings**: federation OOM remedy chain (PARTITIONED → spill_enabled → resource group concurrency cap) now demonstrably consistent. Iter358 BROADCAST/PARTITIONED inversion (FAIL 2.75) → iter359 PARTITIONED primary (PASS 4.125) → iter360 spill_enabled next-lever (PASS 4.125). Iter360 teacher action #4 (Step 3 spill_enabled backstop) landed cleanly.
2. **Query plan optimization tier finally tested**: Q2 first probe since iter356 rubric flag. 4.125 PASS establishes a passing baseline for EXPLAIN ANALYZE reading for slow Iceberg queries — but only one angle, needs at least one more probe before topic can be marked passing.
3. **Iteration-level consistency**: both questions scored identical 4.125 — no single-question collapse, no per-question fall below 4.0 bar.

### Iter 360 remaining gaps (carry into iter361)

1. **MEDIUM (correctness, NEW iter360)** — Cluster-config trap on spill: `SET SESSION spill_enabled = true` is a no-op if cluster-level `spill-enabled=true` is not set in `etc/config.properties`. Real production trap, iter360 Q1 missed it.
2. **MEDIUM (completeness, NEW iter360)** — Spill disk budget knobs `max-spill-per-node` and `query-max-spill-per-node` not surfaced in stop-gap tier.
3. **MEDIUM (clarity, 6TH CONSECUTIVE ITERATION FLAGGED)** — Inline glossary at top of `resources/22-trino-federation-postgresql.md` defining build side, probe side, broadcast join, partitioned join, hash-redistribute, spill, build-side hash table, dynamic filtering, resource group, concurrency limit. Longest-standing open gap, accounts for largest single deduction (-1.5 two iterations running).
4. **MEDIUM (practical applicability)** — Diagnostic step before spill: `EXPLAIN ANALYZE VERBOSE` to confirm HashBuilder operator memory pressure (spill helps for joins/aggs/sorts but not output-buffer OOM).
5. **LOW (completeness)** — Complete `etc/resource-groups.json` template (not just a fragment) plus `etc/resource-groups.properties` manager-configuration pointer.
6. **LOW (environment fit)** — Note that OPA + JWT auth stack from `prod_info.md` is orthogonal to resource-group source selectors.
7. **TOPIC AVG** — Trino federation running avg moves 4.498/256 → 4.497/257 after iter360 Q1, still 0.003 below raised 4.5 topic threshold. Needs ~5-6 more 4.5+ landings to recross.

### Iter 361 teacher actions

**HIGH**:
1. Add cluster-config callout to Step 3 of stop-gap checklist in `resources/22-trino-federation-postgresql.md`: verify `spill-enabled=true` in `etc/config.properties` before `SET SESSION spill_enabled = true`.
2. Add `max-spill-per-node` and `query-max-spill-per-node` to stop-gap tier with sizing guidance.
3. Inline glossary at top of `resources/22-trino-federation-postgresql.md` (6TH iteration flagged) — build side, probe side, broadcast join, partitioned join, hash-redistribute, spill, build-side hash table, dynamic filtering, resource group, concurrency limit.
4. Add `EXPLAIN ANALYZE VERBOSE` HashBuilder confirmation step before recommending spill — spill helps for HashBuilder OOM, not output-buffer OOM.

**MEDIUM**:
5. Provide complete `etc/resource-groups.json` template plus `etc/resource-groups.properties` manager-config pointer.
6. Note OPA + JWT orthogonality to resource-group source selectors in `prod_info.md` environment fit callout.

### Iter 361 judge probe targets

1. **Trino federation 4th-phrasing cluster-config gap** — probe "we set `SET SESSION spill_enabled = true` and nothing happened — what's wrong?" to test if iter361 teacher action #1 (cluster-config trap) lands.
2. **Trino federation glossary landing check** — re-probe to test whether inline glossary at top of `resources/22` (now 6 iterations flagged) actually lands in iter361 rewrite — clarity has been deducted -1.5 two iterations running.
3. **Query plan optimization 2nd angle** — second probe of `EXPLAIN ANALYZE VERBOSE` reading (e.g., dynamic-filter rows-filtered interpretation, or TableScan cost reading) to test if iter360 Q2 4.125 baseline is single-prompt or durable.
4. **CDC tier 2nd-angle** — still pending across iter357/358/359/360 except single iter359 Q2 baseline (4.375). Probe Debezium tuning for high-volume tables OR Debezium-vs-Kafka-Connect-S3-sink tradeoff OR Iceberg MoR compaction cadence for CDC workloads.
5. **Cost considerations cloud vs on-prem** — AWS S3+Athena+Glue lift-and-shift vs on-prem Trino+Iceberg+MinIO — still not probed.

