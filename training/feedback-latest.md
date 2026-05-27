# Feedback — Iter 303 (Extended phase)

Date: 2026-05-27
Topics: HLL sketch WAU/MAU pre-aggregation (Q1) + Iceberg time-travel for incident debugging (Q2)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | approx_set/merge/cardinality for rolling WAU/MAU without re-scanning raw events | **4.625** | PASS |
| Q2 | FOR TIMESTAMP AS OF / FOR VERSION AS OF; $snapshots/$history; rollback; 7-day retention | **4.75** | PASS |

**Iter 303 average: 4.69 — PASS** ✓

**Topic updates**:
- SQL query best practices for OLAP: 4.636/12 → **4.635/13 questions** (PASSED — stable)
- Iceberg table maintenance: 4.637/18 → **4.643/19 questions** (PASSED — improved)

---

## Resource fixes applied (PRIORITY — fix before iter304)

### Resources 07 and 23: HLL varbinary cast for Iceberg persistence

The Q1 answer showed:
```sql
CREATE TABLE iceberg.analytics.daily_user_hll AS
SELECT event_date, approx_set(user_id) AS user_id_hll
FROM events GROUP BY event_date;
```

**This is wrong.** Iceberg's Parquet storage does not know about Trino's `HyperLogLog` type. Without an explicit cast to `varbinary`, the CREATE TABLE CTAS may fail with a type error when the Iceberg connector tries to serialize the column.

**Correct pattern:**
```sql
-- Build: cast HyperLogLog to varbinary for storage
CREATE TABLE iceberg.analytics.daily_user_hll
WITH (partitioning = ARRAY['event_date'])
AS SELECT
    event_date,
    CAST(approx_set(user_id) AS varbinary) AS user_id_hll
FROM iceberg.analytics.events
GROUP BY event_date;

-- Query: cast varbinary back to HyperLogLog before merging
SELECT
    event_date,
    cardinality(merge(CAST(user_id_hll AS HyperLogLog))) AS wau_7d
FROM iceberg.analytics.daily_user_hll
WHERE event_date >= CURRENT_DATE - INTERVAL '6' DAY
GROUP BY event_date;
```

Fix in both resources 07 and 23 wherever the HLL sketch table pattern appears.

---

## What worked

### Q1 — HLL sketch WAU/MAU (4.625)
1. Three-function explanation (approx_set / merge / cardinality) — correct and clear
2. Why re-scanning is slow — MarkDistinct multi-shuffle cost explained (correctly, per the iter302 resource fix)
3. Concrete CREATE TABLE + rolling window JOIN query
4. 2.3% error bounds explained with standard deviation framing (not a hard ceiling)
5. Validation SQL to measure real error on production data
6. `EXPLAIN ANALYZE` to verify bytes-read reduction after optimization

### Q2 — Iceberg time-travel (4.75)
1. Both syntax forms (FOR TIMESTAMP AS OF / FOR VERSION AS OF) with direct production examples
2. `$snapshots` and `$history` metadata table queries to find the right snapshot
3. Before/after comparison query pattern — ground-truth diff of affected rows
4. Version-aware: correctly notes `ALTER TABLE EXECUTE rollback_to_snapshot` requires Trino 469; prod uses Trino 467, so Spark `CALL` form is required
5. 7-day minimum floor explained with the Trino enforcement behavior
6. Snapshot tagging (Spark-only) for forensic preservation
7. Environment fit: all code matches Trino 467 + Iceberg 1.5.2 + MinIO stack

---

## Suggested iter304 angles

1. **HLL varbinary cast** — retest the HLL sketch pattern now that resources 07/23 have the correct cast syntax
2. **Iceberg schema evolution in practice** — adding/dropping/renaming columns on a live Iceberg table; which operations are metadata-only vs require file rewrites
3. **Trino resource groups** — how to configure concurrency limits so dashboard queries don't starve ingestion jobs; memory caps per group
4. **Partition strategy for a new table** — given a specific SaaS use case, walk through the decision: which column(s) to partition by, what granularity
