# Feedback — Iter 298 (Extended phase)

Date: 2026-05-27
Topics: Trino-native Iceberg maintenance + Parquet/Iceberg vs Postgres B-tree index

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Iceberg maintenance from Trino only — ALTER TABLE EXECUTE syntax, 7-day floor, dry-run caveat | **5.00** | PASS |
| Q2 | Parquet/Iceberg vs Postgres B-tree index for bulk filter — three-layer skipping, columnar I/O | **5.00** | PASS |

**Iter 298 average: 5.00 — PASS** ✓

**Topic updates**:
- Iceberg table maintenance: 4.616/17 → **4.637/18 questions** (PASSED — improved)
- Column-oriented storage: 4.365/6 → **4.456/7 questions** (PASSED — improved)
- Query performance basics: 4.594/4 → **4.675/5 questions** (PASSED — improved)

---

## What worked

### Q1 — Trino-native maintenance (5.00)
1. Direct "you do NOT need Spark" answer up front — resolves the engineer's actual concern immediately
2. Three Trino-native commands with exact syntax — copy-paste ready, verified correct for Trino 467
3. `optimize_manifests` correctly gated to Trino 470, not 467 — accurate and prevents frustration
4. 7-day retention floor explained with the reason (protects in-flight writes) — not just a rule, but why
5. "Storage goes UP after step 1 before dropping after steps 2-3" — explains the counterintuitive behavior
6. Dry-run caveat: Trino has no dry_run, use Spark form once for preview — correct and appropriately minimal
7. K8s CronJob scheduling hint with `trino --execute "..."` — fits the on-prem stack exactly

This directly corrected the iter297 Q1 regression where the responder routed everything to Spark.

### Q2 — Parquet vs B-tree index (5.00)
1. "Not like an index — something different" framing — corrects the engineer's mental model before explaining
2. Postgres B-tree failure explanation (bulk fetch from heap, not index traversal) — explains why the index is correctly ignored
3. Three-layer skipping (manifest → row-group → column-only) — precise and verified correct
4. Unsorted vs sorted data contrast — makes clear the speedup requires sorting
5. Concrete byte math (80 GB → 1.5 GB → 75 MB) with "real world 10x–100x" caveat — honest
6. OLAP-vs-OLTP decision rule (bulk analytics = Parquet wins, single-row lookup = Postgres wins) — practical ending

---

## No resource fixes needed

Both answers were factually clean and verified against official docs. All claims correct.

---

## Suggested iter299 angles

1. **Multi-tenant analytics** — the "one table vs many tables" data isolation decision for B2B SaaS; or row-level security with Apache Ranger; or cross-tenant SLA metrics (p99 per tenant)
2. **Iceberg partition evolution** — what happens when you need to change a partition spec on an existing table with terabytes of data; ALTER TABLE SET PROPERTIES vs rewriting
3. **Trino CBO / ANALYZE TABLE** — a new angle: what happens when stats are stale or missing, and how to diagnose join order problems
4. **SQL OLAP best practices** — EXPLAIN ANALYZE end-to-end workflow for diagnosing a slow query (covered piecemeal but not as a systematic walkthrough)
