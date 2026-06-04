# Judge Feedback — Iter 449 (END-OF-ITERATION, EXTENDED PHASE)

## Verdict
**4.828125 STRONG PASS overall** (Q1 4.84375 + Q2 4.84375 + Q3 4.875 + Q4 4.75). Zero confident-inaccuracies. 48th consecutive overall PASS in extended phase. Citation-hygiene streak intact.

## Per-question summary

| Q | Topic | Avg | Result |
|---|---|---|---|
| Q1 | Query perf regression (oncall, 2s→45s) | 4.84375 | STRONG PASS |
| Q2 | Cost — MinIO 8TB→14TB | 4.84375 | STRONG PASS |
| Q3 | Iceberg partition design (date-only → tenant sort) | 4.875 | STRONG PASS |
| Q4 | Real-time vs batch (nightly → near-real-time worth it?) | 4.75 | STRONG PASS |

## Topic average updates (this iter)

- Query perf regression (r18): 4.2596/13 → **4.28097/14** (+0.0214). Lowest-buffer PASSED topic gained meaningful ground from Q1 4.84375. Buffer-above-3.5 now 0.781.
- Cost considerations (r16): 4.1088/15 → **4.1547/16** (+0.0459). Second-lowest-buffer topic strongest gain this iter from Q2 4.84375. Buffer-above-3.5 now 0.655.
- Iceberg partition design (r10): 4.5251/28 → **4.5372/29** (+0.0121) from Q3 4.875.
- Real-time vs batch (r14): 4.771/6 → **4.7680/7** (-0.0030 nudge). Q4 4.75 fractionally below topic avg but still ~1.27 above 3.5 floor — no concern.
- Federation NOT probed this iter — 4.49944/310 UNCHANGED per directive.

## What the responder did right (iter449 teacher work that LANDED)

1. **r18 oncall worked example** — responder reached for the canonical four-check playbook (cluster saturation → all-vs-one COUNT(*) → EXPLAIN partition pruning → EXPLAIN ANALYZE Scheduled vs CPU vs skew) in the prescribed order. The BI-tool date-wrapping example from the iter449 leading worked example surfaced verbatim in Q1's partition-pruning Filter-above-TableScan signature.
2. **r16 cost worked example** — `$snapshots` summary['added-files-size'] by day query landed exactly as the iter449 canonical diagnostic. `EXECUTE expire_snapshots + remove_orphan_files` both with correct `retention_threshold` parameter name and 7d default floor.
3. **r10 partition-evolution worked example** — Q3 correctly identified that file-level min/max requires sort; recommended `SET PROPERTIES sorted_by = ARRAY['tenant_id ASC NULLS LAST','occurred_at ASC']` then `EXECUTE optimize(file_size_threshold => '512MB')`; correctly warned that `EXECUTE rewrite_data_files(sort_order=>...)` does NOT exist in Trino — pointed at Spark `CALL system.rewrite_data_files` for true rewrites. This is exactly the DO-NOT-WRITE guard the iter449 r10 §STEP 3 SPARK-ONLY block instilled.
4. **Citation hygiene** — zero fabricated PR/issue numbers, zero fabricated DDL clauses, zero fabricated `system.runtime` columns, zero fabricated EXPLAIN operators. Spark-vs-Trino boundaries respected: no `CALL iceberg.system.rewrite_data_files` written for Trino console; no `ANALYZE TABLE` (Spark dialect) for Trino.

## Verified facts (against official docs)

| Claim | Status | Source |
|---|---|---|
| `EXECUTE optimize(file_size_threshold => '256MB'/'512MB')` syntax | VERIFIED | trino.io/docs/current/connector/iceberg.html (default 100MB; `file_size_threshold` is the parameter name) |
| `EXECUTE expire_snapshots(retention_threshold => '7d')` syntax | VERIFIED | trino.io/docs/current/connector/iceberg.html (7d is default `iceberg.expire-snapshots.min-retention` floor) |
| `EXECUTE remove_orphan_files(retention_threshold => '7d')` syntax | VERIFIED | trino.io/docs/current/connector/iceberg.html (7d is default `iceberg.remove-orphan-files.min-retention` floor) |
| `sorted_by = ARRAY['col ASC NULLS LAST', ...]` syntax | VERIFIED | trino.io/docs/current/connector/iceberg.html sorted_by property accepts per-column ASC/DESC NULLS FIRST/LAST |
| `$files` has `file_size_in_bytes`, `lower_bounds`, `upper_bounds` columns | VERIFIED | trino.io/docs/current/connector/iceberg.html $files metadata table |
| `$snapshots` summary map contains `added-files-size` key (bytes) | VERIFIED | apache/iceberg issue #4689 example snapshot summary |
| Trino Web UI shows QUEUED/RUNNING/BLOCKED query states at /ui/queries | VERIFIED | trino.io/docs/current/admin/web-interface.html |
| `CALL iceberg.system.rewrite_data_files` does NOT exist in Trino (Spark-only) | VERIFIED | trino.io/docs/current/connector/iceberg.html — Trino has EXECUTE optimize only; rewrite_data_files w/ sort/zorder strategy is Spark; z-order on Trino roadmap issue #27371 only |
| MoR via `write.delete.mode`/`write.update.mode`/`write.merge.mode = 'merge-on-read'` | VERIFIED | iceberg.apache.org write properties + AWS best-practices-write |
| Structured Streaming 60s/1-minute minimum trigger interval | VERIFIED | iceberg.apache.org/docs/latest/spark-structured-streaming/ |

## Fabrications / inaccuracies

**NONE.** Citation-hygiene streak intact for the 48th consecutive iteration in extended phase.

## Concrete teacher actions for iter450 (breadth design, federation NOT a dedicated probe)

### Priority 1 — Probe under-touched PASSED topics (breadth strategy)

The lowest-data-density PASSED topics that have NOT been probed in many iterations should get exposure to keep the rubric honest. Pick ONE question from each cluster below for iter450:

- **r02 Data warehouse — when does a SaaS need one** (PASSED 4.647/3). 3 datapoints only; needs more angles. Suggested angle: "We're a 20-person SaaS, ~3M events/day, currently doing analytics off a Postgres read replica with materialized views. The data team wants to spend a quarter standing up a warehouse / lakehouse — how do I know if that's premature?"
- **r04 Data lakehouse vs warehouse** (PASSED 4.625/2). 2 datapoints only; lowest probe count among PASSED topics. Suggested angle: "Engineering leadership keeps saying 'we should just use a data lakehouse' but I don't actually know what differs from the Snowflake we already have. Plain-language difference and when each wins?"
- **r15 Popular tools overview** (PASSED 4.75/2). 2 datapoints only. Suggested angle: "If we're evaluating BigQuery vs Snowflake vs Iceberg+Trino for a multi-tenant B2B SaaS, what are the actual differentiators that matter for a 50-person engineering org, not the marketing pitch?"

These three topics are *passed but thinly probed*. If any of them regresses on a second-angle probe, the topic drops below pass — silently. Schedule one of them as Q1.

### Priority 2 — Keep extending the iter449 wins

Q1 (oncall regression) and Q2 (cost) both hit the canonical worked examples that iter449 installed. Consider one of these as a different-angle re-probe to confirm durability:

- **Q1 alternate angle**: "Trino query that used to return in 5s now hangs forever. Where do I start? I can SSH into the coordinator." (forces the responder away from BI-tool examples toward query-id-driven debugging via `system.runtime.queries` — this exercises a DIFFERENT path through r18 than the dashboard worked example).
- **Q2 alternate angle**: "MinIO bucket grew 6TB in one week but no schema changes. How do I figure out which TABLE is responsible and why?" (forces per-table $files SUM ranking, not just per-snapshot summary — exercises r16's diagnostic-query catalog rather than the worked-example walkthrough).

### Priority 3 — Tighten the Q4-style "is it worth it" decision framing

Q4's 4.75 was solid but the score was uniform 4.75 across all four dims — slight ceiling room. The "freshness tier" framework worked; what's missing is a sharper **rejection criterion** ("if your downstream consumers are humans looking at dashboards refreshed once per morning, near-real-time is almost never worth the operational cost of Kafka + Spark Structured Streaming"). Consider adding to r14 a short DO-NOT-CHASE block:

> If your near-real-time investment has any of these characteristics, STOP and do hourly batch:
> - Downstream consumer is a dashboard a human checks <10 times/day
> - Source system already batches its own writes (e.g., daily ETL into Postgres)
> - Team has no on-call rotation for streaming ops
> - SLA is defined in business hours not minutes

This adds a decision-rejection lever the responder can pull when asked "is it worth it" — currently the responder names the framework but doesn't carry a sharp veto criterion.

### Federation guidance (NOT a dedicated probe this iter)

Federation 4.49944/310 still sits 0.00056 below the 4.5 raised threshold. Per directive, no dedicated probe this iter. Keep the §13.x guardrails intact — verified intact at line 8050 of r22 per iter449 teacher state.json. If federation MUST be touched at all in iter450, only probe BULLETPROOFED angles (the iter445 §13.5 Limit-pushdown canonical worked example) — do NOT probe Q-with-WHERE-on-VARCHAR-range or any of the historically-regression-prone surfaces.

### Citation-hygiene maintenance

48 consecutive iters with zero new confident-inaccuracies. The DO-NOT-WRITE blocks installed across r10/r16/r18 in iter449 are working. Continue the discipline: every new claim in a leading worked example must cite a verified Trino docs URL OR an Iceberg docs URL OR a real GitHub issue/PR. Resist the temptation to "polish" passages by adding fluent-sounding-but-unverified specifics (e.g., specific timing claims like "this typically takes 3-5 minutes" unless measured).

## Iteration counter
- Extended phase iteration: 449
- Consecutive PASS streak in extended phase: 48
- Federation row status: FAIL at 4.49944/310 (carry-forward, not probed iter449)
- All other required topics: PASSED, all probed from ≥2 angles
