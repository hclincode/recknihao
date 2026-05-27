# Feedback — Iter 301 (Extended phase)

Date: 2026-05-27
Topics: dbt incremental models on Iceberg (Q1) + JSONB from Postgres to Iceberg (Q2)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | dbt incremental models: watermarks, unique_key, strategies, CoW/MoR, on_schema_change | **4.375** | PASS |
| Q2 | JSONB ingestion: VARCHAR vs flatten, get_json_object, file-skipping advantage, schema evolution | **5.00** | PASS |

**Iter 301 average: 4.69 — PASS** ✓

**Topic updates**:
- Postgres-to-Iceberg ingestion: 4.476/100 → **4.480/102 questions** (PASSED — stable)

---

## Resource bugs to fix (PRIORITY — fix before iter302)

### Resource 13: postgres-to-iceberg-ingestion.md — dbt incremental model section

The Q1 answer contained 6 factual errors sourced from or absent from the resource. Fix the following in resource 13 (or a dbt-specific resource if one exists):

1. **`on_schema_change` default is `ignore`, not `fail`**
   - Correct: The dbt default is `ignore` — new source columns are silently ignored unless you opt in.
   - Fix: Update any example or prose that says `fail` is default.

2. **dbt-trino incremental strategies are `append`, `merge`, `delete+insert`**
   - `insert_overwrite` is dbt-spark only and is explicitly rejected on dbt-trino with Iceberg.
   - Correct strategy for partition-level overwrite on dbt-trino: `delete+insert`.
   - Fix: Add a dbt-trino-specific strategy table distinguishing from dbt-spark.

3. **dbt-trino default incremental strategy is `append`, not `merge`**
   - Fix: State the correct per-adapter defaults clearly. Engineers must explicitly set `incremental_strategy='merge'` to get upsert behavior on dbt-trino.

4. **MERGE INTO compiled SQL conditional predicate**
   - dbt's default merge does NOT add `AND s.updated_at > t.updated_at` — it overwrites matched rows unconditionally.
   - To add a target-side filter, you use `incremental_predicates` config.
   - Fix: Show the actual default compiled SQL, and note `incremental_predicates` as the advanced option.

5. **Jinja timedelta syntax**
   - `macros.timedelta(days=4)` is invalid. Correct: `modules.datetime.timedelta(days=4)`.
   - Fix: Update any late-arriving data example that uses the invalid form.

6. **Trino rollback syntax**
   - `CALL iceberg.system.rollback_to_snapshot(...)` is Spark SQL syntax.
   - Trino uses: `ALTER TABLE iceberg.analytics.orders EXECUTE rollback_to_snapshot(snapshot_id => <id>)`.
   - Fix: Wherever the rollback procedure is mentioned, show both forms or Trino-only form.

---

## What worked

### Q1 — dbt incremental models (4.375)
1. "Not automatic magic — requires updated_at column" framing — correct and important
2. Watermark filter with `is_incremental()` Jinja macro — right concept
3. unique_key → MERGE INTO explained clearly
4. CoW vs MoR trade-offs with when-to-use guidance — correct
5. Iceberg-specific concerns (small files, snapshot rollback, partition pruning) — good coverage
6. Final copy-paste config block — actionable structure

### Q2 — JSONB ingestion (5.00)
1. VARCHAR vs flatten decision table with two real use cases (event_payload vs metadata)
2. `get_json_object` PySpark syntax — verified correct
3. `json_extract_scalar` Trino syntax — verified correct
4. File-skipping advantage quantified — correct (JSON-string predicate cannot skip files)
5. Lexicographic comparison gotcha for `json_extract_scalar` → always VARCHAR
6. `ALTER TABLE ADD COLUMN` metadata-only (no file rewrites) — verified correct
7. Schema evolution: old rows return NULL, backfill optional — correct

---

## Suggested iter302 angles

1. **Iceberg time-travel** — `FOR TIMESTAMP AS OF` / `FOR VERSION AS OF`; debugging with snapshots; retention floor interaction; when time-travel breaks (snapshot expired)
2. **Approximate functions in Trino** — `approx_distinct`, `approx_percentile`; why exact COUNT DISTINCT is slow on 500M rows; error bounds; when to use approximation
3. **Schema design: fact vs dimension table distinction** — reinforcing the star-schema mental model with a concrete SaaS example (events fact + accounts/plans dimension)
4. **dbt models corrected angle** — targeting the on_schema_change defaults and dbt-trino strategy list now that resource 13 is fixed
