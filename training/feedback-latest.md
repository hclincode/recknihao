# Feedback — Iter 272 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — metadata caching stale schema (Q1 PASS) + dynamic filtering in Iceberg+Postgres joins (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Metadata caching: stale schema after Postgres DDL, flush_metadata_cache(), cache-ttl config, SELECT * view silent data loss | **4.75** | PASS |
| Q2 | Dynamic filtering: Iceberg+Postgres join, join type matrix (INNER/RIGHT vs LEFT/FULL), wait-timeout, EXPLAIN ANALYZE verification | **4.75** | PASS |

**Iter 272 average: 4.75 — PASS** ✓ Both passed!

**Topic update**: Trino federation: 4.481/217 → **4.483/219** (NEEDS WORK, gap 0.017 — improving steadily)

---

## What worked

### Q1 — Metadata caching (4.75)
1. `CALL app_pg.system.flush_metadata_cache()` syntax — correct
2. `metadata.cache-ttl` property name — correct (defaults to 0s)
3. Two failure modes: hard error (column not found) vs silent data loss (SELECT * frozen) — excellent teaching
4. `CREATE OR REPLACE VIEW` to refresh frozen view — correct; preserves grants
5. TTL change requires coordinator restart — correct
6. Add flush to migration script as automation — practical
7. Schema drift detection query — actionable

### Q2 — Dynamic filtering (4.75)
1. DF mechanism: build side → collect values → push runtime predicate to probe side — correct
2. Join type matrix: INNER/RIGHT OUTER enable DF; LEFT/FULL OUTER disable DF — correct
3. `iceberg.dynamic-filtering.wait-timeout` default 1s (verified for Trino 467) — correct
4. `SET SESSION iceberg.dynamic_filtering_wait_timeout = '10s'` — correct fix
5. `EXPLAIN ANALYZE VERBOSE` + `DynamicFilter` signal — correct diagnostic
6. Three-step diagnostic (join type → wait-timeout → EXPLAIN ANALYZE) — actionable

---

## Minor gaps (did not cause FAIL)

### Q1
- "Cluster-wide" flush is imprecise — cache is coordinator-only (workers don't cache metadata in this model)
- Granular sub-properties not mentioned: `metadata.schemas.cache-ttl`, `metadata.tables.cache-ttl`, `metadata.cache-missing` 
- Dynamic catalog management not mentioned as restart alternative

### Q2
- Session property syntax example uses catalog-specific prefix (`iceberg.`) without noting this is a placeholder for the actual catalog name
- EXPLAIN ANALYZE snippet is stylized — real output uses `dynamicFilters = {"col" = #df_N}` syntax, not prose description
- Didn't correct user's mental model: the 5,000-row Postgres table IS fully scanned (it's the build side) — DF pushes Postgres values INTO Iceberg, not the other way around
- Missing: broadcast vs partitioned join nuance and DF effectiveness when join column isn't correlated with Iceberg file clustering

---

## Resource fixes before iter273

### Low priority (minor gaps, not errors)

1. **DF mental model** (resource 22, dynamic filtering section):
   - Add explicit note: the small table (Postgres lookup) IS fully scanned — it's the build side; DF collects its values and pushes them INTO the large table (Iceberg), not the reverse
   - This corrects a common misconception that "DF means Trino skips reading Postgres"

2. **flush_metadata_cache scope** (resource 22, metadata caching section):
   - Clarify: the metadata cache lives on the coordinator only; "cluster-wide" is imprecise

---

## Suggested iter273 angles (MUST target Trino federation, gap 0.017)

Topic at 4.483/219. Need ~9-10 more questions at 4.875+ to cross 4.500 threshold.

1. **Cross-schema queries in multi-tenant Postgres** — engineer has one Postgres instance with one schema per tenant; asks how to query across schemas; UNION ALL approach; why Trino can't pattern-match schema names dynamically

2. **system.query() edge cases** — empty results causing schema inference errors; ORDER BY not preserved; column aliasing in join with system.query() result; when to use system.query() vs Trino-native

3. **MERGE INTO Iceberg — MoR write mode** — follow-up on iter270 Q1 error: confirm MoR with positional delete files; OPTIMIZE after MERGE compacts delete files; CoW is open FR
