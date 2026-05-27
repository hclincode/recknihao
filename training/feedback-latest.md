# Feedback — Iter 299 (Extended phase)

Date: 2026-05-27
Topics: Multi-tenant data isolation (one table vs table-per-tenant) + Trino CBO / EXPLAIN ANALYZE / ANALYZE syntax

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Multi-tenant isolation: shared table + Trino views + OPA vs table-per-tenant for 80 customers | **5.00** | PASS |
| Q2 | Trino CBO: EXPLAIN ANALYZE, EXPLAIN (TYPE DISTRIBUTED), ANALYZE syntax, NDV, Puffin files, join ordering | **5.00** | PASS |

**Iter 299 average: 5.00 — PASS** ✓

**Topic updates**:
- Multi-tenant analytics: 4.456/106 → **4.461/107 questions** (PASSED — improved)
- Trino CBO / ANALYZE TABLE / Puffin statistics: 4.763/4 → **4.810/5 questions** (PASSED — improved)

---

## What worked

### Q1 — Multi-tenant isolation (5.00)
1. Clear recommendation up front ("keep one shared table at 80 tenants") — resolves the engineer's decision immediately
2. Three-model comparison (table-per-tenant / shared + app WHERE / shared + Trino views + OPA) — systematic and practical
3. Correct DDL syntax for partitioned Iceberg table with `ARRAY['day(occurred_at)', 'tenant_id']`
4. Trino view + OPA pattern explained correctly per production stack (prod_info.md)
5. Partition cardinality concern addressed (80 tenants = safe; user_id = anti-pattern)
6. Whale-tenant detection query using `events$partitions` metadata table
7. Postgres RLS → Trino view/OPA bridge — met the engineer where they are

### Q2 — Trino CBO / ANALYZE (5.00)
1. EXPLAIN ANALYZE actually runs the query — stated directly and correctly
2. EXPLAIN (TYPE DISTRIBUTED) as safe plan-only alternative — critical for a slow query
3. `rows: ?` as the smoking gun for missing NDV — precise and actionable
4. `ANALYZE schema.table` syntax (no TABLE keyword) with explicit Spark/Hive warning — prevents the #1 copy-paste bug
5. `WITH (partitions = ARRAY[...])` correctly labeled Hive-only
6. `join_reordering_strategy = 'AUTOMATIC'` correct with all three valid values
7. Three-layer stack (partition pruning / file skipping / CBO join ordering) cleanly separated
8. 7-step diagnostic checklist — copy-paste ready
9. k8s CronJob scheduling hint matches on-prem production stack

---

## No resource fixes needed

Both answers were factually clean and verified against official Trino docs. All claims correct.

---

## Suggested iter300 angles

1. **dbt incremental models on Iceberg** — how `is_incremental()`, `unique_key`, and `on_schema_change` interact with Iceberg's snapshot model; when to use `merge` vs `append` strategy
2. **Metabase / BI tool integration with Trino** — connection pooling caveats, session property injection, why BI tools generate bad SQL patterns (SELECT *) and how to handle them
3. **Iceberg time-travel and audit** — `FOR TIMESTAMP AS OF` / `FOR VERSION AS OF` queries; useful for compliance and debugging; retention floor interaction
4. **Multi-tenant analytics deeper dive** — cross-tenant aggregates for internal reporting; how to query "top 10 tenants by event volume this week" efficiently without full scans
