# Iter 111 Q1 — Judge Verdict

**Topic**: Postgres-to-Iceberg ingestion (CDC with Debezium — JSONB handling)
**Question**: How to handle Postgres JSONB columns when streaming via Debezium into Iceberg — landing as a single string makes nested-field filtering slow; should we flatten at ingest?
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter111-q1.md`

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4.5 | Core recommendation (flatten hot fields, keep raw blob, ALTER TABLE ADD COLUMN later) is correct. One overstated claim ("Parquet has no native JSON type") — Parquet does define a JSON logical type annotation. In practice the Trino Iceberg connector still treats it as a string, so the operational impact of the claim is small, but it is technically inaccurate. |
| Beginner clarity | 5 | Two-option framing (string vs flatten) with clear pros/cons. Concrete PySpark and SQL snippets. "Rule of thumb" callout is exactly the kind of takeaway a SaaS engineer can act on. Zero unexplained jargon. |
| Practical applicability | 5 | Fits the on-prem stack (Spark + Iceberg 1.5.2 + Trino 467 + Debezium 2.x). Code is copy-pasteable. Specifically addresses the engineer's stated stack ("we're using Debezium…") and tells them they do NOT need to change Debezium config — the flattening lives in the Spark transformation step. Schema-evolution path (`ALTER TABLE ... ADD COLUMN`, metadata-only) is exactly right for Iceberg. |
| Completeness | 4.5 | Covers the two main options, schema evolution, rule of thumb, "what NOT to do", and Debezium-side implications. Misses: (a) the option of writing Iceberg `STRUCT<>` for a stable subset of JSONB fields (rejected too quickly with "operationally painful"); (b) no mention that `json_extract_scalar` predicates on the fallback `properties_raw` cannot be pushed down to Parquet row-group stats — the engineer should be told this explicitly so they know why flattening is required for hot fields, not just a nice-to-have; (c) no mention of using Iceberg's native `MAP<VARCHAR,VARCHAR>` for genuinely tenant-variable settings (also rejected too quickly). |

**Weighted average (simple mean)**: (4.5 + 5 + 5 + 4.5) / 4 = **4.75 / 5** → PASS

---

## Technical verification (via WebSearch)

1. **"Parquet has no native JSON type"** — **PARTIALLY INCORRECT**. Parquet *does* define a JSON logical type annotation: a binary primitive annotated as JSON, where the binary is UTF-8 encoded valid JSON. See the Apache Parquet LogicalTypes spec. However, the *practical* implication the answer is driving at is still mostly true: the JSON logical type is just a hint — there is no columnar shredding of JSON fields, no per-field min/max statistics, and Trino's Iceberg connector reads JSON-annotated columns as plain strings. So the recommendation (flatten hot fields, keep raw blob) remains correct. The accuracy gap is that the *reason* given is overstated. A more accurate phrasing would be: "Parquet stores JSON as an opaque binary/string — there is no per-field columnar storage or statistics for nested JSON keys, so Trino must parse the string at query time."

2. **`get_json_object(col, '$.key')` valid PySpark function** — **CONFIRMED**. `pyspark.sql.functions.get_json_object(col, path)` is the documented function; JSONPath syntax rooted at `$`; returns NULL for invalid JSON or missing keys. Signature in the answer matches.

3. **`json_extract_scalar(col, '$.key')` valid Trino SQL** — **CONFIRMED**. Documented in Trino's JSON functions reference. Returns VARCHAR; suitable for filtering scalar JSON values.

4. **"Parquet predicate pushdown" on a real flattened column** — **CONFIRMED**. Trino's Parquet reader does row-group pruning via min/max statistics and dictionary filtering on real columns. The answer's comment `-- columnar, no parsing, Parquet predicate pushdown` on `WHERE plan_tier = 'enterprise'` is accurate for a real top-level VARCHAR column.

5. **`json_extract_scalar(...) = 'value'` pushdown to Parquet** — **NOT pushed down** (correctly implied by the answer but not stated explicitly). Trino does not push function expressions like `json_extract_scalar` into the Parquet reader; the function is evaluated row-by-row after the rows are read. The answer's Option 1 con ("re-parses the JSON string on every query") is correct, but the answer could strengthen this by explicitly stating "no row-group skipping" — that is the *real* reason flattening matters for hot fields, not just CPU cost.

6. **`ALTER TABLE ... ADD COLUMN` is metadata-only in Iceberg with NULL fill for old rows** — **CONFIRMED** (verified in prior iterations and Iceberg spec). No data rewrite required; old rows return NULL automatically.

---

## Additional issues

### A. Slightly overstated "what NOT to do"
The answer says "Don't store JSONB as Iceberg `MAP<STRING,STRING>` or as a `STRUCT` with one field per key. Both make schema evolution worse, not better." This is too absolute:

- **STRUCT** with a fixed set of known fields is a perfectly reasonable pattern when the schema is stable and the field set is well-known. Iceberg handles STRUCT schema evolution well (`ALTER TABLE ... ADD COLUMN parent.child TYPE`). The downside is real (every schema change requires coordinated DDL), but STRUCT is genuinely better than parallel top-level columns when there are >10 related fields with a clear logical grouping.

- **MAP<VARCHAR,VARCHAR>** is actually the right answer for *truly* dynamic per-tenant settings where every tenant has a different key set. Trino supports `WHERE map_col['plan_tier'] = 'enterprise'` and Iceberg can store MAPs efficiently. The downside is no per-key statistics (same problem as JSON string), but it's not strictly worse than the `properties_raw` VARCHAR fallback the answer recommends.

The answer should have said "for the common case of mostly-stable JSON with a few hot keys, flatten + raw-blob fallback is best; STRUCT or MAP can be reasonable for specific patterns (stable schemas / truly dynamic per-tenant keys respectively)."

### B. Missing: Debezium JSONB serialization detail
The answer assumes the JSONB comes through as a JSON string. This is the Debezium 2.x default behavior, but worth a brief sentence: Debezium serializes Postgres JSONB by default as a JSON-encoded string in the change event payload (via the `io.debezium.data.Json` semantic type). Some teams configure transforms to deserialize it; in the default config, the Spark consumer sees a string and the answer's pattern works as written.

### C. Missing: ingestion ordering nuance for the flattened column when later added
The answer correctly says `ALTER TABLE ADD COLUMN` is metadata-only and old rows return NULL automatically. What it doesn't say: if you decide later to populate historical values for the new column, you must either (a) backfill via `INSERT OVERWRITE` / `MERGE INTO` from the still-present `properties_raw`, or (b) accept NULL for the historical period. Worth a one-line mention.

### D. `json_extract_scalar` returns VARCHAR even for numeric/boolean JSON values
A small operational detail: when the JSON value is a number or boolean, `json_extract_scalar` still returns VARCHAR — comparisons must be cast (e.g., `CAST(json_extract_scalar(raw, '$.price') AS DECIMAL) > 100`). Not mentioned, but a common gotcha for engineers using the raw-blob fallback.

---

## What the answer got right

- Correct two-option framing (string vs flatten) in the right order of preference.
- `get_json_object` correctly used for Spark-side extraction.
- `json_extract_scalar` correctly used for Trino-side fallback.
- `properties_raw` fallback pattern is the production-standard shape.
- Rule of thumb ("Flatten anything you GROUP BY, WHERE, or JOIN ON") is exactly right.
- Schema evolution path (ALTER TABLE ADD COLUMN, metadata-only, NULL fill) is correct.
- Correctly notes the Debezium connector doesn't need configuration changes — the flattening is in the Spark transformation, not the connector.
- Concrete on-prem-stack-compatible advice (Spark + Iceberg 1.5.2 + Trino 467 all supported as described).
- Good "what NOT to do" framing (even if slightly overstated — see A above).

---

## Resource fix recommendations

1. **MEDIUM — Fix the "Parquet has no native JSON type" overstatement** in any JSONB-related resource. Replace with: "Parquet does define a JSON logical type annotation, but it stores JSON as an opaque binary/string — there is no per-field columnar storage or statistics for nested keys, and Trino's Iceberg connector treats JSON-annotated columns as plain strings at query time." This is more accurate and still drives the same recommendation.

2. **MEDIUM — Explicitly state that `json_extract_scalar` predicates do NOT push down to Parquet row-group stats.** The answer's "re-parses on every query" framing captures CPU cost but misses the more important point: no file or row-group skipping happens, so a `WHERE json_extract_scalar(raw, '$.plan_tier') = 'enterprise'` filter reads every file in the table. Flattening enables min/max-based skipping, which is often the dominant performance win.

3. **LOW — Soften the "what NOT to do" framing** for STRUCT and MAP. STRUCT is appropriate when the schema is stable and grouped; MAP<VARCHAR,VARCHAR> is appropriate for genuinely dynamic per-tenant settings where flattening doesn't make sense. A short decision table would help: "stable + known fields → STRUCT; mostly-stable + hot keys → flatten + raw fallback (this answer's recommendation); truly dynamic per-tenant → MAP."

4. **LOW — Add a one-line note on `json_extract_scalar` return type** (always VARCHAR, must CAST for numeric/boolean comparisons).

5. **LOW — Add a one-line note on Debezium's default JSONB serialization** (comes through as `io.debezium.data.Json` semantic type, surfaces as a JSON string in the Spark consumer).

---

## Running average update

- Prior: 4.465 across 95 questions
- This score: 4.75
- New average: (4.465 × 95 + 4.75) / 96 = (424.175 + 4.75) / 96 = 428.925 / 96 = **4.468 across 96 questions**

Status: PASSED, modest upward movement (4.465 → 4.468). The answer is a clear pass — the only meaningful technical correction is the Parquet-JSON-logical-type claim, which is a precision issue rather than a bug. Iter 110 was 3.625; this iter 111 fix cycle restored the topic to its prior trajectory.

---

## Sources consulted

- [Logical Types — Apache Parquet](https://parquet.apache.org/docs/file-format/types/logicaltypes/)
- [parquet-format/LogicalTypes.md at master — apache/parquet-format](https://github.com/apache/parquet-format/blob/master/LogicalTypes.md)
- [pyspark.sql.functions.get_json_object — Apache Spark](https://spark.apache.org/docs/latest/api/python/reference/pyspark.sql/api/pyspark.sql.functions.get_json_object.html)
- [JSON functions and operators — Trino 481 Documentation](https://trino.io/docs/current/functions/json.html)
- [Predicate pushdown on parquet files in Trino](https://posulliv.github.io/posts/parquet-predicate-pushdown/)
- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html)
- [Predicate pushdown for nested fields in Parquet reader — trinodb/trino issue 9928](https://github.com/trinodb/trino/issues/9928)
