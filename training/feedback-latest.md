# Feedback — Iter 304 (Extended phase)

Date: 2026-05-27
Topics: HLL varbinary cast retest (Q1) + Iceberg schema evolution (Q2)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | HLL varbinary cast: CAST(approx_set() AS varbinary) + CAST(col AS HyperLogLog) for rolling WAU/MAU | **4.875** | PASS |
| Q2 | Iceberg schema evolution: field-ID mechanism, metadata-only ADD COLUMN, silent data loss trap, backfill | **4.875** | PASS |

**Iter 304 average: 4.875 — PASS** ✓

**Topic updates**:
- SQL query best practices for OLAP: 4.635/13 → **4.652/14 questions** (PASSED — improved)
- Iceberg table maintenance: 4.643/19 → **4.655/20 questions** (PASSED — improved)

---

## No resource fixes needed

Both answers were technically accurate. No resource corrections required before iter305.

---

## What worked

### Q1 — HLL varbinary cast retest (4.875)
1. Root cause identified correctly: `HyperLogLog` is an in-engine Trino type with no Parquet encoding; Iceberg cannot persist it directly
2. `CAST(approx_set(user_id) AS varbinary)` on write — the critical fix from iter303 gap — present and correct
3. `CAST(user_id_hll AS HyperLogLog)` on read before `merge()` — present with the exact error message when skipped
4. All three primitives (approx_set / merge / cardinality) explained with types and roles
5. Complete double-cast gotcha table showing the two wrong patterns and the correct pattern side by side
6. Dashboard query using `CASE WHEN` inside `merge()` for WAU + MAU in one scan — the cleanest approach
7. ~2.3% standard error correctly framed with validation query
8. Nightly incremental refresh pattern (`INSERT INTO ... WHERE event_date = CURRENT_DATE - INTERVAL '1' DAY`)
9. Performance table: GB raw scan vs ~30KB sketch merge

### Q2 — Iceberg schema evolution (4.875)
1. Field-ID mechanism explained correctly and verified against Iceberg spec
2. ADD COLUMN metadata-only with zero file rewrites — confirmed instant at any table size
3. Old files return NULL for new column via field-ID matching — correctly explained
4. Clean taxonomy: metadata-only (ADD/DROP/RENAME/REORDER/safe type promotion) vs requires rewrite (backfill, unsafe type change, NOT NULL)
5. Silent data loss trap — concrete dangerous SQL example with explanation of why it fails silently
6. 5-step safe production workflow: add → verify NULL → MERGE INTO backfill → verify → wire dashboards
7. How Trino handles mixed-schema files: per-file field-ID mapping, NULL column projection on old files
8. Drop column orphaned bytes + `rewrite_data_files` for storage reclamation
9. Why Iceberg field-ID tracking is safer than plain Parquet name-based column matching

---

## Minor gaps (not errors, not resource fixes needed)

### Q1
- Self-join rolling window (Step 2) is more expensive than the `CASE WHEN` + single scan approach shown later. Should lead with the cleaner dashboard query pattern.
- `P4HyperLogLog` (denser, fixed-format alternative) not mentioned — minor omission
- Single-day DAU via `cardinality(CAST(col AS HyperLogLog))` without `merge()` not shown

### Q2
- Iceberg v3 `initial-default` / `write-default` capability (lets old rows read a non-NULL default instead of NULL) not mentioned — useful for teams wanting to avoid backfill entirely
- MERGE INTO backfill example assumes a `properties` JSON column the user never mentioned; framed as an example, not a problem

---

## Suggested iter305 angles

1. **Trino resource groups** — configuring concurrency limits so dashboard queries don't starve ingestion jobs; memory caps per group; queue behavior
2. **Partition strategy for a new SaaS table** — given a specific schema, walk through the decision: which column to partition by, what granularity (day/month), tenant_id vs time
3. **Iceberg compaction triggers** — when to run `rewrite_data_files`, small-files problem symptoms, recommended file size targets, how to schedule
4. **Approximate aggregation beyond COUNT DISTINCT** — `approx_percentile` for p99 latency dashboards, when to use vs exact
