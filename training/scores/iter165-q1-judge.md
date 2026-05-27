# Iter 165 Q1 — Judge Score Report

**Date**: 2026-05-26 (EXTENDED PHASE)
**Question topic**: Trino federation — federation join scaling cliff from 5K to 120K accounts; should we add Postgres indexes or change approach?
**Production stack**: Trino 467, Iceberg 1.5.2, PostgreSQL connector, on-prem k8s + MinIO

---

## Verification of key technical claims (WebSearch)

| Claim | Verdict | Source |
|---|---|---|
| "Cross-catalog joins execute on Trino workers, not Postgres" | CORRECT. Cross-catalog joins between iceberg and postgres cannot push down to either source; the join executes on Trino workers. | trino.io/docs PostgreSQL connector + cross-catalog discussion (issue #18339) |
| "Dynamic filtering becomes less effective with 120K rows vs 5K" | DIRECTIONALLY CORRECT but simplified. Actual mechanism: when build-side exceeds `dynamic-filtering.max-distinct-values-per-driver`, Trino falls back to min/max range filters (graceful degradation, not catastrophic). Also `domain-compaction-threshold` (default 1000) compacts large IN-lists into ranges. Answer's framing ("harder to compress and apply for file pruning") captures the practical effect without naming the specific knobs. | trino.io/docs/current/admin/dynamic-filtering.html |
| `iceberg.dynamic_filtering_wait_timeout` default 1s | CORRECT. Catalog property is `iceberg.dynamic-filtering.wait-timeout` (default 1s); session form is `iceberg.dynamic_filtering_wait_timeout`. This was the iter164 carry-forward bug (resources previously said 2s) — now fixed. | trino.io/docs/current/connector/iceberg.html |
| "Ingest the Postgres table into Iceberg" as Option 2 | CORRECT. This is the canonical recommendation when federation joins stop scaling — both sides become intra-catalog, enabling columnar I/O, CBO statistics, and no JDBC overhead. | Standard Trino/Iceberg architectural guidance |
| "OSS Trino 467 has no native PostgreSQL connection pooling" | CORRECT. Iter163 carry-forward fix is still being applied properly — no `connection-pool.enabled` invention. | trino.io/docs/current/connector/postgresql.html |

All five high-risk claims pass verification. The dynamic filtering explanation is simplified but not wrong.

---

## Scoring

| Dimension | Score | Weight | Reasoning |
|---|---|---|---|
| Technical accuracy | 5 | ×2 | All claims verify correctly against Trino 467 docs. Iceberg DF wait-timeout default (1s) is stated correctly with catalog prefix — the iter164 carry-forward bug has been fixed. No invented connection pool properties. Cross-catalog join mechanics are accurately described. DF degradation is explained directionally correctly (the min/max-fallback nuance is simplified, but not stated incorrectly). |
| Beginner clarity | 5 | ×1 | Clear narrative: identifies the cliff, walks through the 3-step join mechanics (scan PG → build hash → probe Iceberg), shows side-by-side "before/after" SQL for Option 1, defines dynamic filtering by what it does (IN-list pushdown), uses concrete numbers (24× larger). A SaaS engineer with no OLAP background can follow this end-to-end. |
| Practical applicability | 5 | ×1 | Three ranked options with explicit trade-offs (immediate / medium-term / freshness-sensitive hybrid). Immediate next-step section gives a concrete EXPLAIN ANALYZE command and tells the engineer what fields to look for (`dynamicFilters`, `dynamicFilterSplitsProcessed`). Explicit "what you should NOT do" section pre-empts the two most common wrong turns (PG indexes, fake connection pooling). |
| Completeness | 5 | ×1 | Directly answers both parts of the question ("is there a point where this stops working?" — yes, and explains why; "more PG indexes or completely different approach?" — explicitly rejects PG indexes and offers three alternative approaches). Covers the full decision tree: filter first, ingest if filter isn't possible, hybrid view if freshness matters. Includes diagnostic step. Minor gap: doesn't mention `join_distribution_type=BROADCAST` session knob (called out in iter164 state notes as a recurring resource gap), but the question didn't ask about join distribution and the answer is complete for the asked question. |

**Weighted score** = (5×2 + 5 + 5 + 5) / 5 = **5.00 / 5**

**Result**: PASS (threshold 3.5; topic threshold 4.5)

---

## Key findings

**Strengths:**
1. The iter164 carry-forward bug on `iceberg.dynamic_filtering_wait_timeout` default value (was 2s, should be 1s) appears to be fixed in the resources — the answer correctly states 1s with the catalog prefix.
2. The iter163 fix on "no native PG connection pooling in OSS Trino" is being applied consistently — the answer explicitly warns against `connection-pool.enabled` and explains it would be silently ignored.
3. The "What you should NOT do" section is exactly the right structure for a federation question — it kills both the PG-index dead-end and the fake-connection-pooling trap in one place.
4. Option 3 (hybrid Iceberg + Postgres live-tail UNION ALL view) is a sophisticated and correct pattern that goes beyond textbook answers.

**Minor nits (did not deduct):**
1. DF degradation explanation could be tightened by naming `dynamic-filtering.max-distinct-values-per-driver` and the min/max fallback explicitly, but the simplification is appropriate for the audience and is not incorrect.
2. Could mention `join_distribution_type=BROADCAST` as a session-level lever for the small-dim-side case, but this question is about the cliff between 5K and 120K (where broadcast may itself be the wrong choice at 120K), so the omission is defensible.

**Resource health signal**: This is the strongest federation answer in the iter160s run. The teacher's fixes from iter163/164 (PG pooling, DF wait-timeout default + catalog prefix) are now being correctly synthesized into composite questions. The resource is finally stable on the previously-buggy claims.

---

## Topic running average update

Trino federation / cross-source connectors:
- Prior: 3.972 / 7 questions (NEEDS WORK, threshold 4.5)
- New: (3.972 × 7 + 5.00) / 8 = (27.804 + 5.00) / 8 = **32.804 / 8 = 4.1005**
- Status: STILL NEEDS WORK (4.10 < 4.5). One strong answer is not enough to lift the topic over the raised threshold; need to maintain ≥4.5 across the next several questions to recover.
