# Feedback — Iter 281 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — Postgres schema cache flush re-test (Q1 PASS) + multi-tenant cross-schema federation (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Postgres schema cache: flush_metadata_cache() parameterless for JDBC, WRONG contrast, metadata.cache-ttl, coordinator scope | **4.83** | PASS |
| Q2 | Multi-tenant cross-schema: static schema limitation, UNION ALL generator, system.query() discovery, Iceberg bucket partitioning | **4.79** | PASS |

**Iter 281 average: 4.81 — PASS** ✓ Both passed!

**Topic update**: Trino federation: 4.490/235 → **4.493/237** (NEEDS WORK, gap 0.007 — continuing to close)

---

## What worked

### Q1 — Postgres schema cache flush re-test (4.83)
1. flush_metadata_cache() parameterless for PostgreSQL — verified (correct after resource fix)
2. WRONG vs CORRECT labeled contrast (Delta Lake/Hive have named params, PostgreSQL does not) — excellent
3. metadata.cache-ttl default 0s (caching disabled) — verified
4. Coordinator restart required for TTL changes — correct
5. Coordinator-only scope with HA caveat — correct
6. Finer-grained metadata.tables.cache-ttl and metadata.statistics.cache-ttl — practical
7. SELECT* view freeze + CREATE OR REPLACE VIEW fix — correct and complete

### Q2 — Multi-tenant cross-schema federation (4.79)
1. Trino requires static schema names at planning time — correct
2. UNION ALL generator with Python example — correct approach
3. system.query() with `query =>` named param and `''` escaping — verified
4. Iceberg bucket(tenant_id, 64) vs identity partition — verified; bucket bounded metadata, identity explodes
5. Tradeoffs table (effort / scalability / maintenance / freshness) — excellent structure
6. Recommendation: start with UNION ALL, migrate to Iceberg at ~30-50 tenants — actionable

---

## Errors / gaps to fix before iter282

### Q1 (minor — did not block pass)
- No explicit one-line definition of "what the metadata cache stores" for absolute beginners
- metadata.cache-missing not mentioned (not asked, so fine)

### Q2 (minor — did not block pass)
- Python client library for Trino not named (trino Python package or PyHive)
- No mention of OPA policy implications for multi-tenant data access through a single view (security boundary)

---

## Resource fixes before iter282

None urgent. Resource is in good shape after teacher280 and teacher281 fixes.

### Nice-to-have

1. **Add Python Trino client example** (resource 22, multi-tenant section):
   - Show `import trino; conn = trino.dbapi.connect(...)` as the Python client
   - Makes UNION ALL generator example copy-pasteable end-to-end

---

## Suggested iter282 angles (MUST target Trino federation, gap 0.007)

Topic at 4.493/237. Need ~4 more questions at 4.875+ to cross 4.500 threshold.

1. **UUID and jsonb in Trino — native type mapping edge cases** — engineer confused by UUID type appearing correctly but jsonb being returned as a string in some cases; correct answer: uuid→UUID native, jsonb→JSON native, but JSON functions needed to extract values

2. **Trino federation to read replica** — engineer wants to point Trino at a Postgres read replica to protect OLTP writes; connection string for replica; implications for stale reads; when to accept eventual consistency

3. **Dynamic filtering with large IN-lists** — domain-compaction-threshold: when the IN-list from DF exceeds the threshold, Trino compacts it to a range; affects DF effectiveness for high-cardinality joins

4. **Re-test: federate vs ingest** — another variation on the federate vs ingest decision; for a join-heavy workload with a 10M-row slowly-changing Postgres table; correct: above threshold, MERGE INTO nightly, remove JDBC load

5. **Re-test: cross-catalog atomicity variants** — engineer asks if Trino can use a two-phase commit across Postgres and Iceberg; answer: no XA/2PC; START TRANSACTION does not coordinate across catalogs
