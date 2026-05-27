# Feedback — Iter 279 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — Iceberg metadata cache re-test (Q1 PASS) + dynamic filtering in federated joins (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Iceberg metadata cache: iceberg.metadata-cache.enabled, no SQL flush for Iceberg, fs.memory-cache.ttl, disable option | **4.75** | PASS |
| Q2 | Dynamic filtering: build/probe, IN-list push to Postgres, join types, optimizer decides, wait-timeout | **4.85** | PASS |

**Iter 279 average: 4.80 — PASS** ✓ Both passed! Resource fix validated.

**Topic update**: Trino federation: 4.486/231 → **4.489/233** (NEEDS WORK, gap 0.011 — recovering from iter278 regression)

---

## What worked

### Q1 — Iceberg metadata cache (4.75)
1. iceberg.metadata-cache.enabled=true correctly identified — verified against Trino docs
2. No flush_metadata_cache() SQL procedure for Iceberg — verified
3. fs.memory-cache.ttl correct property name — verified
4. Coordinator restart as definitive evidence of coordinator-level cache — correct reasoning
5. Three remediation options (lower TTL, disable cache, accept default) with tradeoffs — correct
6. Table of properties with purpose — well-organized
7. Snapshot query to verify staleness cause — practical diagnostic

### Q2 — Dynamic filtering (4.85)
1. Build/probe concept explained accessibly — excellent
2. DF mechanism: build collects distinct join keys → pushes IN-list to Postgres probe scan — verified
3. Fast path / slow path explained with execution steps — concrete and accurate
4. INNER/RIGHT = DF enabled; LEFT/FULL OUTER = DF disabled — verified
5. Optimizer decides build/probe based on statistics (not SQL order) — verified
6. iceberg.dynamic-filtering.wait-timeout, default 1s, underscore vs hyphen form — verified
7. ANALYZE on both tables recommendation — correct
8. EXPLAIN ANALYZE fields to verify DF fired (DynamicFiltersEnabled=true, dynamicFilterSplitsProcessed) — actionable

---

## Errors / gaps to fix before iter280

### Q1 (minor)
- Default for fs.memory-cache.ttl stated as "~10-60 min build-dependent" — actual default is 1 hour (documented)
- Default for fs.memory-cache.max-size stated as 128MB — actual default is 2% of max heap (not a fixed value)
- Should mention: changing fs.memory-cache.ttl requires catalyst-level restart — property reloads don't pick up TTL changes in Trino 467

### Q2 (minor)
- No mention of `join_distribution_type` session property (can force broadcast join to ensure DF fires even when CBO guesses wrong)
- No mention of `domain-compaction-threshold` (if the IN-list from DF exceeds the threshold, Trino compacts it to a range — affects when DF is applied)

---

## Resource fixes before iter280

### Nice-to-have

1. **Correct fs.memory-cache.ttl default** (resource 22, Iceberg metadata cache section):
   - Change "~10-60 min" to "1 hour (3600s)" — verified from Trino docs
   - Change "128MB" default for max-size to "2% of max heap" — verified from docs

2. **Add join_distribution_type session property** (resource 22, dynamic filtering section):
   - `SET SESSION join_distribution_type = 'BROADCAST';` forces the smaller table to be broadcast (build side) even when CBO guesses wrong
   - Use when you know one table is small but statistics are missing or stale
   - Contrast with default `PARTITIONED` distribution

---

## Suggested iter280 angles (MUST target Trino federation, gap 0.011)

Topic at 4.489/233. Need ~5-6 more questions at 4.875+ to cross 4.500 threshold.

1. **Postgres type mapping edge cases** — jsonb→JSON, uuid→UUID, custom enums→VARCHAR, array types (AS_ARRAY vs AS_JSON vs DISABLED default); unsupported-type-handling=IGNORE dropping columns silently

2. **Re-test: dynamic filtering** — verify responder gives correct answer on a slightly different framing (e.g., "why does adding a WHERE clause on the small table speed up the large Postgres scan?")

3. **Multi-tenant cross-schema Postgres federation** — engineer wants to query the same table across multiple tenant schemas dynamically; Trino cannot use dynamic schema names; UNION ALL generator pattern; system.query() for discovery; Iceberg with tenant_id + bucket partitioning

4. **Trino metadata.cache-ttl for Postgres federation** — different from Iceberg metadata cache; this controls Postgres schema/table metadata caching (column list, types); stale after a Postgres schema change (ALTER TABLE ADD COLUMN); flush_metadata_cache() DOES exist for Postgres connector
