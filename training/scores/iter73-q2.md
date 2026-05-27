# Iter73 Q2 — Score

**Question**: Postgres JSONB column with per-customer variable structure needs to land in Iceberg. Store as string? Try to flatten? Does Iceberg support nested column types? Tricks to make it queryable in Trino?

**Answer file**: /Users/hclin/github/recknihao/training/answers/iter73-q2.md

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Completeness | 5 | Hits all 5 required points: (1) VARCHAR as practical choice, (2) selective flattening with `get_json_object` and Parquet stats benefit, (3) raw blob fallback queryable via `json_extract_scalar`, (4) Iceberg schema evolution as metadata-only `ALTER TABLE ADD COLUMN` with NULL backfill for old rows, (5) decision framework table (WHERE/GROUP BY → flatten; long-tail/ad-hoc → raw). Bonus: nested-path extraction, array handling with `from_json` + `array_contains`, summary comparison table. |
| Accuracy | 4.5 | All function syntax verified against official docs: `get_json_object(col, '$.path')` is correct Spark/PySpark (spark.apache.org); `json_extract_scalar(varchar, jsonpath)` returns varchar in Trino (trino.io/docs/current/functions/json.html); Iceberg supports STRUCT/MAP/ARRAY nested types (iceberg.apache.org/spec). Minor inaccuracy: claim that "deeply nested STRUCT columns mean Trino reads entire nested blocks to access one inner field, negating the columnar benefit" — Parquet actually stores each leaf field as its own column chunk with def/rep levels, so projection of a single nested leaf does NOT require reading sibling leaves. The real reason STRUCT doesn't fit (schema rigidity, point #1) is correctly stated and is the dominant argument. |
| Clarity | 5 | TL;DR up front; clean section headings (Why not STRUCT / Recommended approach / Querying fast path / Querying raw / Nested+arrays / Schema evolution / Decision checklist / Summary); inline code examples for Spark and Trino; two decision tables; no unexplained jargon (Parquet min/max, dictionary compression briefly motivated). Beginner with no OLAP background can follow. |
| No-hallucination | 5 | Every function name, signature, and behavior cross-checked. `withColumnRenamed`, `from_json`, `array_contains` are real PySpark functions. `ALTER TABLE ... ADD COLUMN` on Iceberg is metadata-only and old rows return NULL — correct. No invented APIs or fabricated behaviors. Fits production stack (Spark + Iceberg 1.5.2 + Trino 467 + MinIO + Hive Metastore). |

**Final score**: (5 + 4.5 + 5 + 5) / 4 = **4.875**

**Status**: PASSED (>= 3.5 threshold)

---

## Required points coverage

1. **VARCHAR is the practical choice; STRUCT doesn't fit per-row variable schema** — COVERED (section "Why not use Iceberg nested types"). Reason #1 (schema rigidity) is on-target.
2. **Selective flattening with `get_json_object`; real columns get Parquet stats + dictionary compression** — COVERED with PySpark example and explicit rationale.
3. **Keep full JSON as VARCHAR fallback, queryable via Trino's `json_extract_scalar`** — COVERED with concrete SQL example.
4. **Iceberg schema evolution: `ALTER TABLE ADD COLUMN` is metadata-only, old rows NULL, no reload** — COVERED in its own section.
5. **Decision framework: flatten WHERE/GROUP BY keys, keep long-tail in raw blob** — COVERED in decision checklist table.

---

## Accuracy verification (WebSearch)

- Spark `get_json_object(col, '$.path')` — VERIFIED against spark.apache.org/docs/latest/api/python/reference/pyspark.sql/api/pyspark.sql.functions.get_json_object.html. Signature, root `$`, nested path, and array index syntax (`$[0]`) all match.
- Trino `json_extract_scalar(varchar, jsonpath) returns varchar` — VERIFIED against trino.io/docs/current/functions/json.html. Both `(json, jsonpath)` and `(varchar, jsonpath)` signatures exist.
- Iceberg nested types (STRUCT/MAP/ARRAY) — VERIFIED against iceberg.apache.org/spec. All three are supported; schema evolution (add/drop/rename/reorder) applies to nested struct fields.

---

## Production environment fit

Fits cleanly: Spark ingest path uses PySpark (the on-prem ingestion stack), targets Iceberg 1.5.2 tables, query examples use Trino 467 with the Iceberg connector. No public-cloud-only services referenced. `ALTER TABLE` syntax works under Hive Metastore catalog. MinIO/S3-backed storage is transparent to the pattern.

---

## Minor improvement opportunity (not score-affecting)

The "Parquet performance" sub-point under "Why not Iceberg nested types" overstates the columnar penalty of STRUCT. Parquet's Dremel encoding does project individual nested leaves efficiently; the real reason STRUCT is wrong here is the per-row schema variation, which the answer already states as reason #1. The teacher could tighten this bullet in a future revision but it does not change the recommendation or the score.
