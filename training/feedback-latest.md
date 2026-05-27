# Feedback — Iter 282 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — Postgres read replica federation (Q1 PASS) + UUID/JSONB type mapping (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Read replica federation: connection-url change only, no replication lag awareness, pg_stat_replication monitoring, replica vs primary use cases | **4.85** | PASS |
| Q2 | UUID→UUID native (UUID literal syntax), jsonb→JSON native (json_extract_scalar/json_extract), no JSONB predicate pushdown, system.query() for server-side | **4.80** | PASS |

**Iter 282 average: 4.825 — PASS** ✓ Both passed!

**Topic update**: Trino federation: 4.493/237 → **4.496/239** (NEEDS WORK, gap 0.004 — very close to threshold)

---

## What worked

### Q1 — Read replica federation (4.85)
1. Config change is only `connection-url` — no "read replica mode" or flag — correct
2. Trino has zero replication lag awareness — silently returns stale rows — correct and well-emphasized
3. External monitoring via `pg_stat_replication.replay_lag` and `pg_last_wal_replay_lsn()` — verified
4. Practical guidance: use replica for analytics/aggregations, use primary for sub-second freshness — correct
5. Schema caching interaction with `metadata.cache-ttl` — complete and accurate
6. Summary table (config change / lag detection / when to use replica / schema caching) — excellent structure

### Q2 — UUID/JSONB type mapping (4.80)
1. `uuid`→UUID native, `jsonb`/`json`→JSON native — correct Trino type mapping
2. UUID literal syntax `UUID '...'` and explicit CAST — correct; predicate pushdown works for UUID equality
3. `json_extract_scalar(col, '$.key')` returns VARCHAR — correct
4. `json_extract(col, '$.key')` returns native JSON type — correct
5. JSONB predicates do NOT push down to Postgres — fetches entire table, filter in Trino — correct and critical
6. `system.query()` workaround for server-side JSONB filtering with GIN index — correct
7. Iceberg ingestion recommendation for heavy JSONB analytics — correct long-term pattern
8. Type mapping summary table — clear and accurate

---

## Errors / gaps (did not block pass)

### Q1 (minor)
- No mention of `pg_is_in_recovery()` as a quick health check to confirm you're connected to the replica and not the primary
- No mention of `hot_standby_feedback` replication parameter (affects visibility of old row versions; niche but relevant for long-running analytics queries on replica)

### Q2 (minor)
- `json_value()` and `json_query()` (ISO SQL standard JSON functions added in Trino ~390+) not mentioned as modern alternatives to `json_extract_scalar`/`json_extract`
- `postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR` not mentioned — relevant if the JSONB column is unexpectedly missing from Trino's schema view

---

## Resource fixes before iter283

None urgent. Resource is in good shape. The JSONB pushdown limitation and system.query() workaround are already documented.

### Nice-to-have
1. **Add `pg_is_in_recovery()` tip** (resource 22, read replica section):
   - Quick sanity check: `SELECT * FROM TABLE(app_pg.system.query(query => 'SELECT pg_is_in_recovery()'))` → returns `true` on replica, `false` on primary

---

## Suggested iter283 angles (MUST target Trino federation, gap 0.004)

Topic at 4.496/239. Need ~2 more questions at 4.875+ to cross 4.500 threshold.

1. **Dynamic filtering with large IN-lists and domain compaction** — engineer sees join performance degrade with high-cardinality keys; correct: `join_reordering_strategy`, `domain_compaction_threshold` compacts oversized IN-lists to a range, reducing DF effectiveness for high-cardinality joins

2. **Re-test: cross-catalog atomicity / two-phase commit** — engineer asks if Trino can use XA/2PC across Postgres and Iceberg catalogs; correct: no; START TRANSACTION does not coordinate across catalogs; three remediation patterns

3. **Trino resource groups for federated workloads** — hardConcurrencyLimit, maxQueued, source selectors with X-Trino-Source header, file-based vs REST-based config, coordinator restart required

4. **Federate vs ingest decision for 20M-row slowly-changing Postgres table** — above single-use federate threshold; MERGE INTO nightly with watermark upper bound; remove JDBC load from Postgres primary

5. **EXPLAIN ANALYZE on federated queries** — how to read the plan for cross-catalog joins; ScanFilterProject vs TableScan; predicate pushdown verification for JDBC connector
