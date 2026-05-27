# Feedback — Iter 277 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — LIKE/ILIKE pushdown re-test (Q1 PASS) + federate vs ingest at scale (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | LIKE/ILIKE pushdown: conditional (re-test after resource fix), session property, ScanFilterProject-disappears signal, COLLATE "C" warning | **4.90** | PASS |
| Q2 | Federate vs ingest: decision threshold, CTAS full load, MERGE INTO incremental, compaction, what changes after ingestion | **4.875** | PASS |

**Iter 277 average: 4.8875 — PASS** ✓ Both passed!

**Topic update**: Trino federation: 4.491/227 → **4.494/229** (NEEDS WORK, gap 0.006 — closing fast!)

---

## What worked

### Q1 — ILIKE pushdown re-test (4.90)
1. Conditional pushdown framing — no PR attribution, no categorical statement — correct (fix from teacher277 and teacher276 validated)
2. Session property `enable_string_pushdown_with_collate` — verified exact
3. Catalog property `postgresql.experimental.enable-string-pushdown-with-collate` — verified exact
4. Success signal: "ScanFilterProject disappears" (not constraint= textual format) — exactly the canonical phrasing from Trino docs
5. COLLATE "C" vs ICU correctness warning — correct and specific
6. Unanchored patterns (`%text%`) still scan all rows even with flag — correctly explained
7. Four practical options (generated lower column, date predicate pairing, flag test, ingest to Iceberg) — production-realistic
8. Postgres slow-query log as ground truth — actionable

### Q2 — Federate vs ingest (4.875)
1. Decision threshold table (CPU, latency, query frequency, freshness tolerance) — concrete
2. JDBC single-task bottleneck explanation (no parallelism, 50M rows over one connection) — correct and verified
3. CTAS for initial full load — verified
4. MERGE INTO for incremental sync — verified; WHEN MATCHED/WHEN NOT MATCHED correct syntax
5. Explicit upper-bound watermark pattern (not NOW() inside query) — production-safe guidance
6. ALTER TABLE EXECUTE optimize for compaction after MERGE — verified
7. Before/after query comparison (federated vs local) — concrete and illustrative
8. When to still federate edge cases — appropriate nuance
9. Action plan numbered list — actionable

---

## Errors / gaps to fix before iter278

### Q1 (minor — did not block pass)
- No mention of `pg_trgm` GIN index as the canonical Postgres-side fix for unanchored LIKE searches. The answer recommends `LIKE '%global%'` on a generated lower column, but a GIN trigram index is the standard approach for fast substring search in Postgres. Worth adding to resource.

### Q2 (minor — did not block pass)
- Jargon: "positional delete files," "predicate-prune and project-push," "watermark" used without inline explanation. Fine for the score but could confuse a SaaS engineer reading carefully.
- No mention of monitoring HMS (Hive Metastore) health during CTAS — if HMS is unavailable at commit time, the CTAS fails even if data was written.

---

## Resource fixes before iter278

### Nice-to-have

1. **pg_trgm GIN index for unanchored LIKE** (resource 22, ILIKE/string search section):
   - Add: for unanchored substring search (`LIKE '%text%'`), the production-grade Postgres fix is a GIN trigram index via `pg_trgm` extension
   - `CREATE EXTENSION IF NOT EXISTS pg_trgm;` + `CREATE INDEX ... USING GIN (name gin_trgm_ops);`
   - Once indexed, Postgres can use the GIN index for LIKE '%text%' queries efficiently, even when Trino can't push the filter
   - Note: the Trino flag only controls whether the filter arrives at Postgres; the index controls whether Postgres executes it efficiently

---

## Suggested iter278 angles (MUST target Trino federation, gap 0.006)

Topic at 4.494/229. Need ~2-3 more questions at 4.875+ to cross 4.500 threshold.

1. **Metadata caching and stale Iceberg reads** — engineer sees Trino return old Iceberg data after a Spark job adds new files; answer: metadata.cache-ttl, flush_metadata_cache (coordinator-only), CREATE OR REPLACE VIEW workaround; well-covered in resource

2. **Resource groups to limit Postgres load** — engineer wants to cap concurrent federated queries hitting Postgres; hardConcurrencyLimit + maxQueued; source selector caveat (clients must set X-Trino-Source or selector silently fails); PgBouncer integration

3. **Dynamic filtering in federated Postgres+Iceberg joins** — engineer asks why adding a join condition on a small Iceberg lookup table speeds up the Postgres scan; answer: DF collects join keys from the small table and pushes an IN-list into the Postgres TableScan; LEFT/FULL OUTER disables DF; wait-timeout config

4. **Re-test: federate vs ingest at scale** — high scores suggest this is a strong coverage angle; another variation would reinforce the pattern
