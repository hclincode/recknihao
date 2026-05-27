# Feedback — Iter 273 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — multi-tenant cross-schema queries (Q1 PASS) + federate vs ingest decision (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Cross-schema queries: static binding, UNION ALL + generator script, system.query(), Iceberg migration | **4.75** | PASS |
| Q2 | Federate vs ingest: size thresholds, frequency multiplier, freshness, three patterns | **4.75** | PASS |

**Iter 273 average: 4.75 — PASS** ✓ Both passed!

**Topic update**: Trino federation: 4.483/219 → **4.485/221** (NEEDS WORK, gap 0.015 — improving steadily)

---

## What worked

### Q1 — Cross-schema queries (4.75)
1. Trino cannot use dynamic schema names (static planning) — correctly explained
2. UNION ALL as the primary solution — correct
3. Python generator script to auto-generate UNION ALL — concrete and practical
4. system.query() correctly described: verbatim passthrough, no outer predicate pushdown
5. Iceberg migration with tenant_id partition as the long-term fix — correct
6. Decision guide (time/effort/scalability trade-offs) — clear

### Q2 — Federate vs ingest (4.75)
1. Decision table (size × frequency × freshness) — clear and actionable
2. MERGE INTO for incremental sync — correct syntax
3. Dynamic filtering note (INNER JOIN required for DF; LEFT disables it) — correct
4. EXPLAIN ANALYZE `Input: X rows` diagnostic — correct
5. Three architecture patterns (direct federation, nightly ingest, hybrid) — practical
6. Dimension vs fact framing — resonates with engineers

---

## Gaps to address before iter274

### Q1
- **system.query() SQL example has a correctness bug**: The CTE-based example's subquery `(SELECT COUNT(*) FROM events WHERE ...)` doesn't scope to the per-tenant schema from the outer CTE — every row returns the same count. The surrounding prose about pushdown limitations is correct, but the SQL itself is wrong. Fix: either simplify the system.query() example or correct the SQL scoping.
- **Iceberg partitioning**: `'tenant_id'` (identity transform) works for ~200 tenants but best practice for high-cardinality tenant IDs is `bucket(N, tenant_id)`. Worth a trade-off note.

### Q2
- Size thresholds (< 10M, > 100M) should be presented as heuristics, not hard cutoffs — they vary by column width, Postgres hardware, and JDBC pool size
- MERGE example assumes `updated_at` watermark column exists without flagging that prerequisite

---

## Resource fixes before iter274

### Low priority

1. **system.query() example correctness** (resource 22):
   - If the resource has a cross-schema system.query() example using a CTE + subquery, verify the SQL correctly scopes per-tenant schema names
   - Simplest fix: use a plain aggregation example without dynamic schema discovery in system.query() (just demonstrate the passthrough syntax, don't try to do per-schema dynamic discovery in it)

2. **Iceberg partitioning for high-cardinality tenant IDs** (resource 22 or Iceberg partitioning resource):
   - Add note: for tenant_id with high cardinality (hundreds to thousands), `bucket(N, tenant_id)` distributes data more evenly than the identity transform; identity creates one partition directory per unique value which can create small-file problems at scale

---

## Suggested iter274 angles (MUST target Trino federation, gap 0.015)

Topic at 4.485/221. Need ~7-8 more questions at 4.875+ to cross 4.500 threshold.

1. **Trino EXPLAIN output deep dive** — engineer asks what the different node types mean; TableScan, ScanFilterProject, Exchange, Aggregate; what "Input: X rows" vs "Output: Y rows" tells you about where filtering happens

2. **Connection pool configuration for Postgres federation** — engineer asks how many concurrent JDBC connections Trino uses to Postgres; how to tune the pool; what happens when queries pile up waiting for connections; PgBouncer's role

3. **Cross-catalog join planning** — engineer asks why Trino sometimes picks a different join order than expected; which table is build vs probe; broadcast join vs partitioned join; stats on Iceberg vs no stats on Postgres

4. **system.query() security and access control** — engineer asks about the security model; OPA ExecuteFunction permission; SQL injection risks; credentials used (catalog-configured, not per-user)
