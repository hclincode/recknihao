# Feedback — Iter 271 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — predicate pushdown EXPLAIN debugging (Q1 PASS) + Postgres type mapping (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | EXPLAIN output patterns for pushdown: ScanFilterProject vs constraint on [col], EXPLAIN ANALYZE row counts, Postgres slow log | **4.75** | PASS |
| Q2 | Postgres type mapping: UUID→UUID, JSONB→JSON, custom enum→VARCHAR, unsupported-type-handling, array-mapping | **4.75** | PASS |

**Iter 271 average: 4.75 — PASS** ✓ Both passed!

**Topic update**: Trino federation: 4.478/215 → **4.481/217** (NEEDS WORK, gap 0.019 — improving)

---

## What worked

### Q1 — Predicate pushdown EXPLAIN (4.75)
1. `ScanFilterProject` above `TableScan` = pushdown failure signal — correct
2. `constraint on [col]` inside `TableScan` = pushdown success signal — correct
3. VARCHAR equality and IN-list predicates push to Postgres — correct
4. VARCHAR range (>, <) does NOT push by default — correct
5. Implicit cast (`CAST(col AS VARCHAR)`) breaks pushdown — correct
6. EXPLAIN ANALYZE `Input:` row count comparison to full table size — correct and practical
7. Postgres slow log (`log_min_duration_statement=0`) as ground truth — concrete
8. Three-step diagnostic workflow — clear and actionable

### Q2 — Postgres type mapping (4.75)
1. UUID → Trino `UUID` natively (not VARCHAR coercion) — correct
2. JSONB → Trino `JSON` natively (not dropped) — correct
3. Custom enum → Trino `VARCHAR` natively (not via `unsupported-type-handling`) — correct
4. Default behavior: `postgresql.unsupported-type-handling=IGNORE` silently drops unsupported columns — critical risk, correctly explained
5. `CONVERT_TO_VARCHAR` fix — correct
6. Arrays: `postgresql.array-mapping=DISABLED` default, `AS_ARRAY` fix — correct
7. `system.query()` for JSONB server-side predicates — correct practical workaround
8. Diagnostic flow comparing `information_schema.columns` to Trino DESCRIBE — concrete

---

## Minor gaps (did not cause FAIL, fix for future iterations)

### Q1
- No mention of `EXPLAIN (TYPE IO)` as alternative EXPLAIN mode
- `pg_stat_statements` on Postgres side not mentioned (useful for verifying what SQL Postgres actually executed)
- EXPLAIN indentation may differ slightly from actual Trino 467 output (structure correct, presentation may vary)

### Q2
- `postgresql.array-mapping=AS_JSON` value omitted — Trino docs list three values (DISABLED, AS_ARRAY, AS_JSON); AS_JSON is the way to get multi-dim arrays as JSON strings
- `INTEGER[]` → `ARRAY<INTEGER>` (not `ARRAY<BIGINT>` as stated — minor type name error)

---

## Resource fixes before iter272

### Low priority (minor gaps, not errors)

1. **array-mapping=AS_JSON** (resource 22, type mapping section):
   - Add `AS_JSON` as a third value for `postgresql.array-mapping`
   - Note when to use: multi-dimensional arrays (`INTEGER[][]`) that can't be represented as flat Trino ARRAY types
   - Current resource likely only documents DISABLED and AS_ARRAY

2. **INTEGER[] type mapping** (resource 22):
   - Verify the mapping table says `INTEGER[]` → `ARRAY<INTEGER>` (not ARRAY<BIGINT>)
   - Correct if needed

---

## Suggested iter272 angles (MUST target Trino federation, gap 0.019)

Topic at 4.481/217. Need ~10 more questions at 4.875+ to cross 4.500 threshold.

1. **Cross-schema queries in multi-tenant Postgres** — engineer has one Postgres instance with one schema per tenant; asks how to query across schemas; UNION ALL approach; why Trino can't pattern-match schema names dynamically; schema-as-catalog approach

2. **Metadata caching and stale views** — engineer sees stale schema after Postgres DDL change; `metadata.cache-ttl`; `CALL catalog.system.flush_metadata_cache()`; views frozen at CREATE time need `CREATE OR REPLACE VIEW`

3. **Dynamic filtering in cross-catalog joins** — engineer asks why their Iceberg+Postgres join is slow even with a small Iceberg filter; LEFT OUTER join disables DF; switching to INNER join enables DF; `iceberg.dynamic-filtering.wait-timeout`

4. **system.query() edge cases** — schema inference from first row; empty results; ORDER BY non-preservation; cross-catalog joins with system.query() results
