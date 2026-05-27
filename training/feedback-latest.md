# Feedback — Iter 288 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — broadcast join CBO override (Q1 PASS) + federate vs ingest 5M-row table (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Broadcast join: CBO automatic from pg_stats; join_distribution_type=BROADCAST; EXPLAIN Exchange[type=REPLICATE]; join-max-broadcast-table-size=100MB; native ANALYZE on primary; flush_metadata_cache() | **4.94** | PASS |
| Q2 | Federate vs ingest 5M-row accounts: above threshold at dozens/day; Spark JDBC initial load; MERGE INTO with updated_at + 2-day lag buffer; maintenance | **4.92** | PASS |

**Iter 288 average: 4.93 — PASS** ✓ Both passed with high scores!

**Topic update**: Trino federation: 4.507/249 → **4.511/251** (PASSED — solidly above threshold)

---

## What worked

### Q1 — Broadcast join (4.94)
1. CBO reads Postgres stats from `pg_stats` — requires native `ANALYZE` on Postgres primary — correct
2. `join_distribution_type='BROADCAST'` session property — verified correct
3. `Exchange[type=REPLICATE]` in EXPLAIN = broadcast happening; `Exchange[type=REPARTITION]` = partitioned join — correct signals
4. `join-max-broadcast-table-size=100MB` default limit — verified
5. `CALL app_pg.system.flush_metadata_cache()` — parameterless for PostgreSQL, correct
6. `SHOW STATS FOR app_pg.public.customers` to verify stats visible — correct diagnostic

### Q2 — Federate vs ingest (4.92)
1. 5M rows + dozens/day → above federation threshold (comfortable ≤1-2M at low frequency) — correct rule of thumb
2. Spark JDBC → `writeTo().using("iceberg").createOrReplace()` syntax — correct
3. MERGE INTO with `updated_at` watermark + 2-day lag buffer — correct pattern
4. 2-day lookback rationale (replica lag + job timing drift + idempotency) — well-explained
5. Nightly compaction (`rewrite_data_files`) + weekly snapshot expiry (`expire_snapshots`) — correct maintenance
6. Before/after join query showing elimination of Postgres touch — good instructional finish

---

## Errors / gaps (minor — did not block pass)

### Q1
- Did not explain *why* stale JDBC stats cause CBO to miss broadcast: stats are cached in Trino's metadata cache; cache flush is the fix (mentioned) but root cause connection between ANALYZE-then-flush not fully articulated

### Q2
- No mention of soft-delete handling: incremental MERGE INTO only handles INSERT/UPDATE; rows deleted from Postgres survive in Iceberg indefinitely unless full refresh or explicit WHEN MATCHED AND src.deleted=true THEN DELETE logic is added

---

## Resource fixes

None required. Resource 22 covers all these topics correctly. 

**Optional future improvement**: Add soft-delete pattern to MERGE INTO section in resource 22 — flag that tables with physical deletes need either a `deleted_at` column or periodic full refresh to stay in sync.

---

## Suggested iter289 angles

1. **SQL query best practices for OLAP (new topic)**: partition column always in WHERE; avoid SELECT * on wide Iceberg tables; approximate functions (approx_distinct, approx_percentile); verify execution plan with EXPLAIN; type-safe predicates to avoid implicit casts breaking pushdown; avoid UDFs in WHERE

2. **Trino Postgres catalog: JDBC connection tuning** — `socketTimeout`, `connectTimeout`, `defaultRowFetchSize`; increasing fetch size for large scans; tradeoff with memory pressure

3. **Federation with SSL/TLS** — `sslmode=verify-full`, certificate paths in catalog properties; on-prem Kubernetes with internal TLS

4. **Re-test: federation predicate pushdown** — confirm ScanFilterProject vs constraint annotation understanding after all the DF fixes
