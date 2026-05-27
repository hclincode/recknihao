# Feedback — Iter 285 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — DF domain compaction (Q1 FAIL) + resource groups no catalog routing (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Dynamic filtering breakdown at 2M distinct join keys: domain compaction to BETWEEN range, Iceberg 1s wait timeout, enable_large_dynamic_filters, ingest as structural fix | **4.40** | **FAIL** |
| Q2 | Resource groups cannot route by catalog; three-layer Postgres protection: CONNECTION LIMIT, PgBouncer, resource groups via X-Trino-Source; coordinator restart required | **4.83** | PASS |

**Iter 285 average: 4.615 — mixed** (Q1 FAIL, Q2 PASS)

**Topic update**: Trino federation: 4.500/243 → **4.501/245** (**DEFINITIVELY PASSED** — 4.501 > 4.5 threshold!)

---

## Critical error that caused Q1 FAIL

### Iceberg connector has NO session-property form for dynamic filtering wait timeout

The answer included:
```sql
SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';
```

**This is WRONG.** The Iceberg connector does NOT expose `dynamic_filtering_wait_timeout` as a session property. It is catalog-config only:

```properties
# etc/catalog/iceberg.properties — requires coordinator restart
iceberg.dynamic-filtering.wait-timeout=15s
```

Hive connector: HAS `<hive-catalog>.dynamic_filtering_wait_timeout` as a session property.
Delta Lake connector: HAS session property form.
Iceberg connector: **NO session property — catalog config only.**

**Teacher285 has fixed resource 22** with explicit callout, connector comparison table, and "DOES NOT WORK" comments removing all phantom Iceberg session property examples.

---

## What worked

### Q1 — DF domain compaction (4.40 — FAIL despite mostly correct content)
1. Domain compaction threshold 256 → BETWEEN range — verified correct
2. Iceberg 1s default wait timeout as key binding constraint — correct
3. `enable_large_dynamic_filters` session property — real in Trino 467 — verified
4. EXPLAIN diagnostic path (dynamicFilters annotation → dynamicFilterSplitsProcessed) — correct
5. Ingest Postgres lookup into Iceberg as structural fix — correct
6. MERGE INTO incremental sync with overlap watermark — correct
7. Selective WHERE predicate to shrink build side — correct

### Q2 — Resource groups (4.83 PASS)
1. No `catalog` selector in Trino resource groups — verified (routing before parsing)
2. Valid selectors: user, source, clientTags, queryType, sessionPropertyFilters — verified
3. Postgres CONNECTION LIMIT on the Trino role — correct and immediate
4. PgBouncer transaction-pooling with `prepareThreshold=0` — verified correct
5. `hardConcurrencyLimit`/`maxQueued` correct property names — verified
6. Coordinator restart required for file-based resource group config — verified
7. X-Trino-Source header for source selector routing — correct

---

## Errors / gaps

### Q1 (CRITICAL — caused FAIL)
- `SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s'` is a phantom session property — does not exist for Iceberg connector. **Teacher285 has fixed resource 22.**

### Q2 (minor — did not block pass)
- No mention of DB-backed resource group configuration manager as a hot-reload alternative (file-based requires restart; DB-backed polls for changes)
- No mention that `enable_large_dynamic_filters` was removed in Trino 480 (relevant for future Trino upgrades)

---

## Resource fixes status

**Teacher285 fix applied**: Resource 22 corrected to remove all phantom Iceberg session property examples for `dynamic_filtering_wait_timeout`. Now correctly states: Iceberg = catalog config only (coordinator restart required); Hive/Delta/JDBC = session property available.

---

## Suggested iter286 angles (topic PASSED at 4.501/245 — continue to solidify)

1. **Re-test: Iceberg DF wait timeout (verify fix applied)** — engineer asks how to tune dynamic filtering wait timeout for an Iceberg-Postgres cross-catalog join; correct answer must NOT say SET SESSION iceberg.*; must say catalog config only with coordinator restart

2. **Trino ILIKE pushdown conditions** — case-insensitive LIKE on Postgres text column; `enable_string_pushdown_with_collate=true` session property + compatible column collation (COLLATE "C" risk for ICU columns); what happens without the flag

3. **Postgres unsupported type handling** — engineer confused why a column exists in Postgres but is missing from Trino schema view; `postgresql.unsupported-type-handling=IGNORE` (default silently drops); `CONVERT_TO_VARCHAR` to expose; array mapping; custom ENUMs → VARCHAR

4. **Dynamic filtering with broadcast join hint** — when CBO guesses wrong build/probe assignment; `join_distribution_type='BROADCAST'` forces correct side; when to override

5. **Federated query result ordering** — engineer expects ORDER BY on Postgres federation query to be preserved in Trino result; it's not guaranteed (no ORDER BY preservation across JDBC); ORDER BY must be at the Trino level
