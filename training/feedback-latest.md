# Feedback — Iter 297 (Extended phase)

Date: 2026-05-27
Topics: Iceberg table maintenance (storage cleanup) + Trino federation with Postgres

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Iceberg maintenance: storage spike, cleanup order, historical data mismatch | **4.50** | PASS |
| Q2 | Trino PostgreSQL connector: live cross-catalog joins, read replica, dynamic filtering | **4.875** | PASS |

**Iter 297 average: 4.69 — PASS** ✓

**Topic updates**:
- Iceberg table maintenance: 4.623/16 → **4.616/17 questions** (PASSED — stable)
- Trino federation: 4.511/251 → **4.513/252 questions** (PASSED — stable)

---

## What worked

### Q1 — Iceberg maintenance (4.50)
1. Storage jump → snapshot accumulation diagnosis — correctly identifies the root cause
2. Race condition explanation for wrong cleanup order — makes the ordering intuitive, not just prescribed
3. Complete 4-step runbook with correct order (compact → expire → orphan → manifests) — copy-paste ready
4. Dry-run preview before orphan cleanup — critical safety step, correctly included
5. "Storage goes UP after step 1 before dropping after steps 2-3" — explains the counterintuitive behavior
6. Historical mismatch investigation: `$snapshots` metadata table + `FOR VERSION AS OF` — bonus coverage that pre-empts the natural follow-up
7. Permanent schedule recommendation (nightly compact, weekly full maintenance) — moves from fix to operational habit

### Q2 — Trino federation (4.875)
1. Yes/no answer with three critical rules up front — correct framing for a SaaS engineer
2. Predicate pushdown for `plan_tier = 'enterprise'` → pushed to Postgres as WHERE clause — correctly explained
3. Dynamic filtering (Iceberg events → customer ID list → pushed back to Postgres) — correctly described, on by default
4. "No JDBC connection pooling in OSS Trino 467" — correct and confirmed against GitHub issue #15888
5. Read replica requirement with concrete failure scenario (20 connections on primary) — makes the risk visceral
6. Hybrid pattern (live federation by default, hourly materialization for high-frequency dashboards) — practical and matches production stack

---

## Resource status

**Q1 error**: Answer routed to Spark exclusively ("not Trino — Spark's Iceberg procedures accept flexible retention windows; Trino's ALTER TABLE EXECUTE optimize is for bin-pack compaction only"). In fact, Trino 467 supports `ALTER TABLE ... EXECUTE expire_snapshots` and `... EXECUTE remove_orphan_files` natively. Resource 17 lines 75-101 already document the Trino-native cheat sheet correctly. **No resource fix needed** — the responder missed the resource.

**Q2**: No errors. All claims verified correct.

---

## Suggested iter298 angles

1. **Iceberg maintenance follow-up** — reinforce Trino-native maintenance path (the responder missed it, but the resource is correct — a second angle gives the responder another chance to surface it)
2. **Multi-tenant analytics** — row-level security with Apache Ranger; or the "one table vs many tables" data isolation model decision for B2B SaaS
3. **Column-oriented storage** — a new angle not covered recently: why a predicate on a non-indexed column is still faster in columnar Iceberg than Postgres (row-skipping via Parquet min/max stats)
4. **SQL OLAP best practices** — EXPLAIN ANALYZE workflow for diagnosing a slow query step by step (covered piecemeal; systematic end-to-end hasn't been a standalone question)
