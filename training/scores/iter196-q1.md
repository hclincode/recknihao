# Iter196 Q1 Score

**Question**: Dynamic filtering deep dive for Postgres-build / Iceberg-probe cross-catalog join — what it is, how it works, EXPLAIN signals, configuration, cross-catalog behavior.
**Topic**: Trino federation / dynamic filtering
**Date**: 2026-05-26 (EXTENDED PHASE)

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 5.0 |
| Completeness | 4.75 |
| **Average** | **4.81** |

**Pass/Fail**: PASS (threshold 4.5)

## Verified facts (WebSearch against trino.io/docs)

- Dynamic filtering enabled by default — VERIFIED (trino.io/docs/current/admin/dynamic-filtering.html)
- `dynamicFilters = {...}` annotation on ScanFilterProject — VERIFIED (same)
- `dynamicFilterSplitsProcessed` operator-stats field — VERIFIED (PR #3217)
- `iceberg.dynamic-filtering.wait-timeout` default `1s` — VERIFIED (trino.io/docs/current/connector/iceberg.html)
- Postgres JDBC connector wait-timeout default `20s` — VERIFIED
- `domain-compaction-threshold` default 256 in Trino 481 — VERIFIED (trino.io/docs/current/connector/postgresql.html)
- `enable_large_dynamic_filters` valid session property — VERIFIED
- Cross-catalog joins: no join pushdown but DF works across JDBC — VERIFIED (PR #13334)

## What the answer got right

1. Correct build/probe direction explicitly stated (Postgres build, Iceberg probe). Calls out the common mistake of checking the metric on the wrong side — exact disambiguation that was a recurring resource gap.
2. EXPLAIN signals at two levels: plan-time (`dynamicFilters = {...}`) vs runtime (`dynamicFilterSplitsProcessed > 0`). Both verified.
3. Wait-timeout disambiguation: Iceberg `1s` vs Postgres `20s`. Matches iter164 disambiguation request exactly.
4. `domain-compaction-threshold` default 256 + IN-list-to-BETWEEN explanation + per-query override path. All correct.
5. Cross-catalog correctness: no join pushdown (join runs on Trino workers), DF still works across JDBC. Correct.
6. Production-fit: `etc/catalog/*.properties` paths, fits Trino 467 on-prem, no cloud-only suggestions.
7. Bonus troubleshooting checklist (5 concrete steps) and `join_distribution_type = 'BROADCAST'` hint.

## What the answer got wrong or missed

1. Minor: `SET SESSION iceberg.dynamic_filtering_wait_timeout = '15s'` uses the catalog-prefix session-property convention; Iceberg connector docs do not explicitly document a session-property form for `dynamic-filtering.wait-timeout`. Works in practice; would be more accurate to call out the convention.
2. Minor gap: no mention that DF on Iceberg gives the biggest probe-side win when the join key matches a partition column or has tight file-level min/max stats.
3. Minor gap (recurring 12th iter): no mention of OPA decision logs / Trino event listener for fleet-scale observability of timed-out DFs.
4. Minor: Web UI URL `/ui/query.html?<query_id>` is version-dependent (modern UI uses `/ui/#/query/<id>`). Not wrong on Trino 467 but worth noting.

## Resource fixes suggested (low priority — extended phase)

- Add a one-sentence note clarifying that `iceberg.dynamic_filtering_wait_timeout` is the catalog-prefix convention, not a documented session property.
- Add partition-alignment tip for Iceberg DF.
- (Recurring) OPA decision logs + event listener as the observability path for timed-out DFs.

## Topic delta

This is one of the strongest dynamic-filtering answers in extended phase. Confirms recent resource fixes (build/probe direction, wait-timeout disambiguation, domain-compaction-threshold) have stuck. New running average for the topic should move upward from 4.376.
