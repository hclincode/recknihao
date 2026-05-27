# Feedback — Iter 300 (Extended phase)

Date: 2026-05-27
Topics: When to move from Postgres to OLAP (decision criteria + thresholds) + SELECT * in Trino vs Postgres (columnar storage / projection pushdown)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | When to add OLAP: concrete thresholds, Postgres tuning checklist, decision tree, stack-aware migration steps | **5.00** | PASS |
| Q2 | SELECT * harm in Trino: columnar storage mechanics, projection pushdown, bytes-read math, impact table | **5.00** | PASS |

**Iter 300 average: 5.00 — PASS** ✓

**Topic updates**:
- When to add an OLAP layer: 4.415/8 → **4.480/9 questions** (PASSED — improved)
- Column-oriented storage: 4.456/7 → **4.524/8 questions** (PASSED — improved)

---

## What worked

### Q1 — When to move from Postgres to OLAP (5.00)
1. Direct engagement with both teammates' positions — validated the "optimize first" view while correctly framing its limits
2. Concrete 5-item Postgres tuning checklist (read replica, materialized views, partial indexes, pg_partman, PgBouncer) — actionable and ordered by impact
3. Quantitative thresholds table: >50M rows + >10% growth, >2s latency, >3 queryers, >1 source system, >20% CPU — "two or more = move"
4. Decision tree with STOP nodes — clear exit conditions prevent premature migration
5. Replication lag claim on replicas verified correct (MVCC + WAL replay conflict)
6. Stack-aware migration steps (Spark → MinIO → Iceberg → Trino) match prod_info.md exactly
7. Runnable table-size SQL — immediately actionable

### Q2 — SELECT * / columnar storage (5.00)
1. Direct Postgres-vs-Trino framing — met the engineer where they are
2. 80÷3 = 27x bytes-read math — concrete and verifiable
3. Impact table with four tiers (10%, 2–3x, 10–20x, 100x) — directly answered the "10% vs 10x?" question
4. `DESCRIBE table_name`, `TABLESAMPLE BERNOULLI`, `EXPLAIN (TYPE DISTRIBUTED)` — all verified valid Trino syntax
5. Partition column in WHERE called out as the biggest independent win

---

## Minor nits (not score-affecting)

- Q2: Used "column strips" (ORC vocabulary) — Parquet uses "column chunks within row groups." Not wrong, just imprecise terminology.
- Q2: TABLESAMPLE BERNOULLI still scans all physical blocks (no I/O reduction). The answer uses it correctly for sampling (not claiming I/O reduction), but could note SYSTEM is more I/O efficient if skipping blocks matters.

Neither nit requires a resource fix.

---

## No resource fixes needed

Both answers were factually clean and verified against official docs.

---

## Suggested iter301 angles

1. **dbt incremental models on Iceberg** — how `is_incremental()`, `unique_key`, and `on_schema_change` interact with Iceberg's snapshot model; when to use `merge` vs `append` strategy
2. **JSONB from Postgres ingested to Iceberg** — flattening vs keeping as string; filtering on nested keys; Spark `from_json` / `get_json_object`
3. **Iceberg time-travel** — `FOR TIMESTAMP AS OF` / `FOR VERSION AS OF` for debugging or compliance; retention floor interaction with time-travel
4. **Approximate functions in Trino** — `approx_distinct`, `approx_percentile` — why they're useful for analytics and when exact counts aren't needed
