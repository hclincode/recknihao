# Judge Feedback — Iter 361 Q1 (EXTENDED phase, mid-iteration)

**Date**: 2026-05-29
**Phase**: EXTENDED
**Topic probed**: Trino federation / cross-source connectors — 4th-phrasing cluster-config trap re-probe ("we set SET SESSION spill_enabled=true and nothing changed") per iter360 judge probe target #4.

## Question
"We set `SET SESSION spill_enabled = true` on our Trino queries like you suggested, but the queries are still OOMing exactly the same way — nothing seems to have changed. Is there something else we're missing? We verified the session property was set by running `SHOW SESSION` and saw `spill_enabled = true`."

## Score: 4.0 — PASS (exactly at per-question 4.0 bar)

| Dimension | Score |
|---|---|
| Technical accuracy | 4.0 |
| Beginner clarity | 3.5 |
| Practical applicability | 4.5 |
| Completeness | 4.0 |
| **Average** | **4.0** |

## What landed (iter361 teacher action wins)

- **Iter361 teacher action #1 — cluster-config trap callout — LANDED CLEANLY.** Top-line diagnosis "session property is silently no-op'ing" with precise cluster-override semantics: `SET SESSION` can only flip ON if cluster has spill enabled at config level. This is exactly the trap iter360 missed.
- **Step 1 cluster-config inspection** — engineer told to verify `spill-enabled=true` and `spiller-spill-path=/var/trino/spill` in `etc/config.properties`. Correct files, correct properties.
- **Step 2 restart requirement** — explicitly noted that `etc/config.properties` is read at startup only. Coordinator + workers must restart.
- **Step 4 k8s storage prerequisite** — `emptyDir` / `local-pv` mount per worker Deployment, "if spill path is a network mount or doesn't exist, spill fails silently." Environment-aware to the on-prem k8s production setup per `prod_info.md`.
- **Closing "why this matters"** — three-condition gate (cluster enabled, spill path exists and is local fast storage, each worker pod can write to path) summarizes the diagnostic correctly.

## Critical gap — technical inaccuracy

**Step 3 `SHOW SESSION LIKE 'spill%'` verification is wrong.** The answer claims "You should see `spill_enabled = true` AND `spiller_spill_path = /var/trino/spill`." This is incorrect: `spiller-spill-path` is a CONFIG property in `etc/config.properties`, NOT a session property — it does NOT appear in `SHOW SESSION` output. The engineer will run the command, see only `spill_enabled`, and incorrectly conclude that spill is still misconfigured. This is a real diagnostic trap that will mislead the engineer following the recipe.

**Correct verification**: inspect `etc/config.properties` directly, or check the coordinator/worker startup log for the spill subsystem initialization line. This is the highest-priority correction for iter362.

## Persistent gaps (iter362 teacher actions)

1. **HIGH (correctness)** — Fix the `SHOW SESSION LIKE 'spill%'` verification step in `resources/22`. Replace with: "Inspect `etc/config.properties` directly on the coordinator OR check the startup log for the spill subsystem initialization line." Do NOT tell engineers to look for `spiller_spill_path` in `SHOW SESSION` — it will not be there.
2. **HIGH (completeness)** — Add `max-spill-per-node` and `query-max-spill-per-node` to the stop-gap tier with sizing guidance. Now 2nd iteration flagged (iter360, iter361). Engineers commonly hit silent spill-budget exhaustion.
3. **HIGH (clarity, 7th iteration flagged)** — Inline glossary at top of `resources/22-trino-federation-postgresql.md` for: build side, probe side, broadcast join, partitioned join, hash-redistribute, spill, build-side hash table, spill path, dynamic filtering, resource group, concurrency limit, HashBuilder. This is the longest-standing open gap and accounts for a persistent -1.5 beginner-clarity deduction across iter355-iter361.
4. **MEDIUM (practical applicability)** — Add EXPLAIN ANALYZE VERBOSE HashBuilder confirmation step before recommending spill. Now 2nd iteration flagged (iter360, iter361). "Verify the OOM is in a spillable operator (HashBuilder for joins, Aggregation, OrderBy). If it's output-buffer pressure or task-execution-memory, spill does not help."
5. **MEDIUM (completeness)** — Add escalation path: if cluster-config-level spill IS enabled AND `SET SESSION spill_enabled=true` AND HashBuilder is confirmed as the OOM source AND OOM still happens — what next? (Larger workers, concurrency cap via resource group, ingest-rewrite the Postgres dimension into Iceberg.)
6. **LOW (environment fit)** — Note that OPA + JWT auth stack is orthogonal to spill configuration; spill operates at the Trino worker level below the authn/authz boundary. (Iter361 teacher action #6, still not landed.)

## WebSearch verification

1. **`spill_enabled` session property requires `spill-enabled=true` in `etc/config.properties`** — CONFIRMED per [Spilling properties — Trino docs](https://trino.io/docs/current/admin/properties-spilling.html). Session property maps to config property; cluster-level prerequisite is documented. Answer's core diagnosis is correct.
2. **`spiller-spill-path` is a real Trino config property** — CONFIRMED per [Spill to disk — Trino docs](https://trino.io/docs/current/admin/spill.html). No default value, must be set when spilling is enabled, supports comma-separated multi-path for JBOD, do-not-spill-to-JVM-log-drive guidance. Answer's `/var/trino/spill` example is correct.
3. **Coordinator + worker restart for config changes** — CONFIRMED per Trino deployment docs.
4. **`SHOW SESSION` does NOT include config-only properties** — CONFIRMED. `SHOW SESSION` lists session properties only; `spiller-spill-path` is not a session property and will not appear there. This is the source of the technical-accuracy deduction.

## Topic running avg

Trino federation: 4.497/257 -> **4.495/258 questions** — still NEEDS WORK (0.005 below raised 4.5 threshold). The cluster-config trap callout landed cleanly (iter361 teacher action #1) but technical accuracy took a 1.0 deduction for one inaccurate verification claim. Topic needs ~6-7 more 4.5+ landings to recross the threshold.

## Iter362 judge probe targets

1. **CDC tier 2nd angle** — Debezium tuning for high-volume tables OR Debezium-vs-Kafka-Connect-S3-sink tradeoff OR Iceberg MoR compaction cadence for CDC workloads. (Iter358 teacher action #2 still untested across iter357-361 except single iter359 Q2 baseline at 4.375.)
2. **Query plan optimization 2nd angle** — EXPLAIN ANALYZE VERBOSE dynamic-filter rows-filtered interpretation OR TableScan cost reading. (Iter360 Q2 baseline 4.125 single-angle, needs 2nd angle.)
3. **Cost considerations cloud vs on-prem** — AWS S3+Athena+Glue lift-and-shift vs on-prem Trino+Iceberg+MinIO. (Still not probed.)
4. **Trino federation glossary landing check (7 iterations flagged)** — re-probe with a question that specifically requires terminology to be defined inline (e.g., "what does build-side hash table mean and why does spill help with it?").
5. **Trino federation 5th-phrasing escalation** — "spill is enabled at cluster level AND `SET SESSION spill_enabled=true` is set AND OOM still happens — what next?" to test if escalation path past spill lands.

## Sources

- [Spilling properties — Trino 479 Documentation](https://trino.io/docs/current/admin/properties-spilling.html)
- [Spill to disk — Trino 481 Documentation](https://trino.io/docs/current/admin/spill.html)
- [Session property managers — Trino 481 Documentation](https://trino.io/docs/current/admin/session-property-managers.html)
- [Spill is not easily triggered when enabling spill — Trino GitHub issue #16524](https://github.com/trinodb/trino/issues/16524)

---

## Iter 361 End-of-Iteration Summary

**Date**: 2026-05-29
**Phase**: EXTENDED
**Iteration average**: 4.00 — MARGINAL PASS (both questions at exactly the 4.0 per-question bar; no per-question collapse below threshold but also zero headroom)

### Per-question recap

| Q | Topic | Score | Verdict | Headline finding |
|---|---|---|---|---|
| Q1 | Trino federation — cluster-config trap 4th phrasing | 4.00 | PASS | Cluster-config trap fix landed cleanly (iter361 teacher action #1 win) but Step 3 `SHOW SESSION LIKE 'spill%'` verification is factually wrong — `spiller-spill-path` is config-only, not a session property, will not appear in `SHOW SESSION` output |
| Q2 | Query plan optimization — dynamic filter collected vs applied 2nd angle | 4.00 | PASS | Solid DF collected-vs-applied semantics establishes durable 2nd-angle pass for query plan optimization tier (iter360 4.125 single-angle now durable across 2 phrasings) but `domain-compaction-threshold` recommendation is JDBC-connector specific and does NOT apply to Iceberg connector targets — wrong stack-fit |

### Patterns across iter361 answers

1. **Cluster-config trap callout LANDED (iter361 teacher action #1 success)** — Q1 top-line diagnosis correctly named the "session property is silently no-op'ing because cluster config has spill-enabled=false" trap that iter360 missed. This was the iter361 highest-priority teacher action and it lands cleanly. Real production-grade diagnostic win.
2. **Query plan optimization tier — 2nd angle durable (iter361 judge probe target #2 cleared)** — Q2 establishes that the iter360 4.125 baseline was not a single-prompt artifact. Dynamic-filter collected-vs-applied semantics handled correctly. Topic can now be marked passing on durable two-angle basis in the rubric.
3. **Recurring connector-fit mistake** — BOTH questions had a connector-stack-fit factual error: Q1 confused config vs session properties (SHOW SESSION trap), Q2 recommended a JDBC-only property to an Iceberg-stack engineer. Pattern: the answers are diagnostically correct at the conceptual layer but ship one incorrect property/command per answer at the operational layer. This is the highest-priority correctness pattern for iter362.
4. **Glossary gap — 7TH CONSECUTIVE ITERATION FLAGGED** — beginner-clarity dimension capped at 3.5 on Q1 again. Inline glossary at top of resources/22 still not landed despite being the longest-standing open gap. Accounts for persistent -1.5 beginner-clarity deduction across iter355-iter361.
5. **Topic running averages — Trino federation 4.495/258 still below raised 4.5 threshold** — 0.005 below; needs ~6-7 more 4.5+ landings to recross. Iter361 stayed at the 4.0 floor with one technical-accuracy deduction per answer, so Trino federation didn't gain ground this iteration.

### Iter362 teacher actions (priority-ordered, carried forward)

1. **HIGH (correctness, NEW iter361)** — Fix Step 3 `SHOW SESSION LIKE 'spill%'` verification in resources/22. Replace with: "Inspect `etc/config.properties` directly on coordinator/workers OR check startup log for spill subsystem initialization." Do NOT instruct engineers to look for `spiller_spill_path` in `SHOW SESSION` — it is config-only and will not appear there.
2. **HIGH (correctness, NEW iter361)** — Audit query-plan-optimization resource (resources/query-plan tier) for connector-specific properties. Flag `domain-compaction-threshold` as JDBC-connector only; do NOT recommend it for Iceberg-stack tuning. Add a connector-fit callout: "Before recommending an EXPLAIN-tier property, check whether it applies to the target connector (Iceberg vs JDBC vs Hive)."
3. **HIGH (clarity, 7TH CONSECUTIVE ITERATION FLAGGED)** — Inline glossary at top of resources/22-trino-federation-postgresql.md: build side, probe side, broadcast join, partitioned join, hash-redistribute, spill, build-side hash table, spill path, dynamic filtering, resource group, concurrency limit, HashBuilder. Longest-standing open gap; accounts for persistent -1.5 beginner-clarity deduction.
4. **HIGH (completeness, 2nd iteration flagged)** — Add `max-spill-per-node` and `query-max-spill-per-node` to stop-gap tier with sizing guidance.
5. **MEDIUM (practical applicability, 2nd iteration flagged)** — Add EXPLAIN ANALYZE VERBOSE HashBuilder confirmation step before recommending spill. Verify OOM is in spillable operator (HashBuilder/Aggregation/OrderBy), not output-buffer or task-execution-memory.
6. **MEDIUM (completeness)** — Add escalation path: cluster spill ON + SET SESSION spill_enabled=true + HashBuilder confirmed + still OOM -> next levers (larger workers, resource-group concurrency cap, Postgres-to-Iceberg ingest rewrite).
7. **LOW (environment fit)** — Note OPA + JWT orthogonality to spill configuration; spill is below the authn/authz boundary.

### Iter362 judge probe targets

1. **CDC tier 2nd angle — STILL PENDING across iter357-iter361** — Debezium tuning for high-volume tables OR Debezium-vs-Kafka-Connect-S3-sink tradeoff OR Iceberg MoR compaction cadence for CDC workloads. Iter359 Q2 baseline 4.375 is the only data point.
2. **Cost considerations cloud vs on-prem — STILL NOT PROBED** — AWS S3+Athena+Glue lift-and-shift vs on-prem Trino+Iceberg+MinIO TCO comparison.
3. **Trino federation glossary landing check (8th iteration probe)** — re-probe with a question requiring inline terminology definitions (e.g., "what is a build-side hash table and why does spill help with it?").
4. **Trino federation 5th-phrasing escalation** — "cluster spill enabled AND SET SESSION spill_enabled=true AND OOM still happens — what next?" to test escalation path past spill.
5. **Query plan optimization 3rd angle** — TableScan cost reading OR Exchange operator interpretation, to keep the iter360/iter361 two-angle durability extending.
6. **Connector-fit correctness re-probe (NEW iter362)** — ask a query plan tuning question against an explicitly Iceberg-only stack to test whether the JDBC-only property mistake recurs.

### Sources

- [Spilling properties — Trino Documentation](https://trino.io/docs/current/admin/properties-spilling.html)
- [Spill to disk — Trino Documentation](https://trino.io/docs/current/admin/spill.html)
- [JDBC-based connectors common properties — Trino Documentation](https://trino.io/docs/current/connector/jdbc.html)
- [Iceberg connector — Trino Documentation](https://trino.io/docs/current/connector/iceberg.html)
- [Dynamic filtering — Trino Documentation](https://trino.io/docs/current/admin/dynamic-filtering.html)
