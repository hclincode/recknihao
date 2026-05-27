# Feedback — Iter 286 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — Iceberg DF wait timeout catalog-config-only (Q1 PASS) + ILIKE pushdown conditions (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Iceberg DF wait timeout: catalog config only (no session property); contrast with Hive; workarounds without restart | **4.90** | PASS |
| Q2 | ILIKE no pushdown by default; `enable_string_pushdown_with_collate` session property; COLLATE "C" correctness risk; lowercase generated column as safe alternative | **4.85** | PASS |

**Iter 286 average: 4.875 — PASS** ✓ Both passed!

**Topic update**: Trino federation: 4.501/245 → **4.504/247** (PASSED — solidly above 4.500 threshold)

---

## Teacher285 fix validated

The Q1 answer correctly identified:
- Iceberg has NO session property for `dynamic_filtering_wait_timeout`
- `SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s'` fails with "session property does not exist"
- Correct path: `iceberg.dynamic-filtering.wait-timeout=20s` in catalog config, requires coordinator restart
- Contrast with Hive connector which DOES have a session-property form

The resource fix applied in iter285 is working correctly.

---

## What worked

### Q1 — Iceberg DF wait timeout (4.90)
1. Correct diagnosis: wait-timeout fires (default 1s) when Postgres build is slow — correct
2. Iceberg: catalog config only (`iceberg.dynamic-filtering.wait-timeout`) — verified correct
3. No session property exists for Iceberg; SET SESSION example correctly labeled as failing
4. Contrast: Hive connector HAS session property form; Iceberg does NOT — verified
5. Three workarounds without restart: selective WHERE, second Iceberg catalog, ingest to Iceberg — all valid
6. EXPLAIN ANALYZE + `dynamicFilterSplitsProcessed > 0` verification — correct

### Q2 — ILIKE pushdown (4.85)
1. ILIKE does NOT push down by default — verified correct
2. EXPLAIN diagnosis: ScanFilterProject above TableScan = failed; constraint inside = success — correct
3. `enable_string_pushdown_with_collate` as session property — verified correct name (PR #9746)
4. COLLATE "C" mechanism and ICU/custom collation correctness risk — verified accurate
5. Lowercase generated column as production-safe alternative — correct
6. Decision table (no flag / flag / generated column) — clear and actionable

---

## Errors / gaps (minor — did not block pass)

### Q1
- No mention that per-query plan-switch via `join_distribution_type='BROADCAST'` can also help (broadcast of the 50K-row Postgres side avoids the probe-side wait-timeout problem entirely)

### Q2
- No mention of catalog-level config as an alternative to session property for cluster-wide ILIKE pushdown enablement
- No explicit note that OPA may restrict `SET SESSION` — engineers should check with their admin before using

---

## Resource fixes before iter287

None urgent. Resource 22 is in good shape after teacher285 fix.

---

## Suggested iter287 angles (topic PASSED at 4.504/247 — continue solidifying)

1. **Postgres array column mapping** — engineer confused why an array column (e.g., `TEXT[]`) from Postgres is missing or wrong in Trino; `postgresql.array-mapping=DISABLED` (default, silently drops); `AS_ARRAY` for native array; `AS_JSON` for JSON representation

2. **Unsupported Postgres type handling** — engineer confused why a column exists in Postgres but is missing from Trino's schema view; `postgresql.unsupported-type-handling=IGNORE` (default); `CONVERT_TO_VARCHAR` to expose unsupported types as strings; custom ENUMs → VARCHAR native

3. **Broadcast join hint for federation** — when CBO guesses wrong build/probe assignment for Iceberg × Postgres join; `join_distribution_type='BROADCAST'` session property forces broadcast of build side; when to override vs trust CBO

4. **Federated UNION ALL across multiple Postgres catalogs** — engineer wants to query the same schema across multiple Postgres instances (sharding); each instance needs its own catalog in Trino; UNION ALL across catalogs is the correct pattern

5. **Re-test: cross-catalog atomicity** — engineer asks about wrapping Postgres + Iceberg writes in Trino transaction; confirms START TRANSACTION is per-catalog only
