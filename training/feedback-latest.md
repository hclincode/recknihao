# Feedback — Iter 278 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — stale Iceberg data after Spark writes (Q1 FAIL) + resource groups for Postgres load (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Stale Iceberg data: metadata cache, flush command, TTL, root cause | **2.05** | FAIL |
| Q2 | Resource groups: no native pool, hardConcurrencyLimit, source selector, PgBouncer | **5.00** | PASS |

**Iter 278 average: 3.525 — FAIL** (Q1 catastrophic failure from critical resource gap)

**Topic update**: Trino federation: 4.494/229 → **4.486/231** (NEEDS WORK, gap 0.014 — significant regression from 0.006 due to Q1 FAIL)

---

## What worked

### Q2 — Resource groups (5.00 — PERFECT)
1. No native per-catalog connection pool in OSS Trino 467 — verified (issue #15888 open)
2. hardConcurrencyLimit + maxQueued property names — verified
3. Queuing happens at Trino, before queries reach Postgres — correct
4. Source selector silent failure (clients must set X-Trino-Source) — correct and critical
5. File-based resource groups require coordinator restart — verified
6. Multi-connection-per-query nuance (each Postgres TableScan = 1 connection; joining 3 tables → 3 connections) — correct
7. PgBouncer as Postgres-side complement — correct framing
8. Complete runnable example JSON config — excellent

---

## Errors / gaps (Q1 — CRITICAL)

### Q1 — CRITICAL resource gap causing FAIL

The responder falsely claimed: "Trino's Iceberg connector does NOT maintain a metadata pointer cache" and "there is no Trino-side cache to flush for Iceberg and no TTL to tune."

**What the official Trino docs actually say** (trino.io/docs/current/connector/iceberg.html):
- `iceberg.metadata-cache.enabled` — enables in-memory caching of Iceberg metadata files on the coordinator (default: `true`)
- `fs.memory-cache.ttl` — TTL for the in-memory metadata file cache
- `fs.memory-cache.max-size` — max total cached bytes
- `fs.memory-cache.max-content-length` — max size per individual cached file
- Trino DOES cache Iceberg metadata in-memory on the coordinator

**The definitive tell the responder missed:** the engineer said "restarting the Trino coordinator fixes it." A coordinator restart invalidates the in-memory coordinator cache — this is textbook evidence that `iceberg.metadata-cache.enabled=true` is the root cause of the 10-15 minute staleness window.

**What the responder got right (partial credit):**
- `flush_metadata_cache()` SQL procedure does NOT exist for Iceberg (only Hive/Delta/JDBC connectors) — this is correct

**Root cause of the failure:** Resource 22 (trino-federation-postgresql.md) covers Postgres connector behavior, not Iceberg connector internals. There is NO coverage of `iceberg.metadata-cache.enabled` or the Iceberg metadata cache in any resource the responder could read.

---

## Resource fixes before iter279 — URGENT

### Critical (must add before next iter)

1. **Add Iceberg metadata cache coverage to resource** (resource 22 or a dedicated Iceberg resource):
   - `iceberg.metadata-cache.enabled` — default true; controls in-memory caching of Iceberg metadata files on coordinator
   - `fs.memory-cache.ttl` — TTL (default varies by build; lowering it increases HMS/S3 calls but reduces staleness window)
   - `fs.memory-cache.max-size` and `fs.memory-cache.max-content-length` — sizing controls
   - **No SQL flush_metadata_cache() for Iceberg** — that procedure only exists for Hive/Delta/JDBC connectors
   - **JMX workaround** for immediate invalidation without restart: `io.trino.filesystem.memory:name=MemoryFileSystemCache` (Trino exposes cache stats/invalidation via JMX)
   - **"Coordinator restart fixes staleness"** is the textbook signal that the in-memory cache is the cause
   - **Remediation options**: (1) lower `fs.memory-cache.ttl` (tradeoff: more S3/HMS calls during query planning), (2) disable `iceberg.metadata-cache.enabled=false` (no caching, fresh every time — only for high-write scenarios), (3) accept the TTL-based staleness window as a design choice for read-heavy workloads

---

## Suggested iter279 angles (MUST target Trino federation, gap 0.014)

Topic at 4.486/231. Need ~6-7 more questions at 4.875+ to cross 4.500 threshold (gap widened from 0.006 to 0.014).

1. **Re-test: Iceberg metadata cache (after resource fix)** — same question about stale data after Spark writes; resource must now cover iceberg.metadata-cache.enabled, fs.memory-cache.ttl, no SQL flush for Iceberg, JMX workaround

2. **Dynamic filtering in federated Postgres+Iceberg joins** — engineer asks why joining to a small Iceberg lookup table speeds up the Postgres scan; answer: DF collects join keys and pushes IN-list into the Postgres TableScan; LEFT/FULL OUTER disables DF; wait-timeout config

3. **Postgres type mapping edge cases** — jsonb → JSON, uuid → UUID, custom enums → VARCHAR (may need CONVERT_TO_VARCHAR), array types (AS_ARRAY vs AS_JSON vs DISABLED default)

4. **Resource groups re-test** — verify the perfect Q2 answer pattern is repeatable on a slightly different angle (e.g., per-user or per-source group config)
