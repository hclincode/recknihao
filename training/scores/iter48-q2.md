# Iteration 48, Q2 — Score

**Question**: We have a Postgres `events` table with a `properties` JSONB column that stores per-event metadata. After ingesting into Iceberg using Spark JDBC, `properties` shows up as `STRING`. How do I query `device_type` out of `properties` in Trino, and can I make Iceberg store it as a proper struct so I can use dot notation?

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

---

## Technical verification (via WebSearch against trino.io, spark.apache.org, iceberg.apache.org)

1. **Is `json_extract_scalar(col, '$.key')` the correct Trino syntax?**
   YES — verified against Trino official JSON functions docs. Signature is `json_extract_scalar(json_input, json_path)`. Example from docs: `SELECT json_extract_scalar(json, '$.store.book[0].author')`. The function returns the scalar string value at the JSON path and is the direct equivalent of Postgres `->>`. Modern alternative `json_value` exists in newer Trino releases but `json_extract_scalar` remains valid in Trino 467 (the production query engine). Answer's syntax `json_extract_scalar(properties, '$.device_type')` is exactly right.

2. **Does Spark's `get_json_object` work for extracting from a JSON string column?**
   YES — verified against Apache Spark docs. Signature: `get_json_object(col, path)` — takes a column containing a JSON-formatted string and a JSON path string. Example: `get_json_object('{"a":"b"}', '$.a')` returns `b`. Returns NULL on invalid JSON. The answer's usage `.withColumn("device_type", get_json_object("properties", "$.device_type"))` is exactly the documented pattern.

3. **Is ALTER TABLE ADD COLUMN metadata-only in Iceberg (no Parquet rewrite)?**
   YES — verified against the Iceberg Evolution doc: "Schema changes never require rewriting your table." "Added columns never read existing values from another column" because Iceberg assigns a new unique column ID. This is exactly what the answer claims: instant, even on terabytes of existing data, no Parquet rewrite, old rows return NULL automatically. Engine-agnostic — works in Trino, Spark, Flink.

4. **Production-stack fit (prod_info.md)**: Spark + Iceberg 1.5.2 + Trino 467 + Hive Metastore + MinIO — every code block in the answer fits this stack exactly. `iceberg.analytics.events` catalog notation matches the prod Trino + Iceberg catalog setup. `df.writeTo(...).append()` is valid Spark 3.x + Iceberg 1.5.2 API. The "STRING vs structured column" framing is grounded in Parquet's lack of a native JSON type (correct).

5. **Why STRING in Iceberg** — answer correctly states Spark JDBC reads Postgres JSONB as VARCHAR because Postgres's JDBC driver returns JSONB as a `String` (PgJDBC default; the driver does not surface Postgres-specific binary JSON encoding to Spark), and Parquet has no native JSON logical type. Both points are accurate.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 5 | Every factual claim verified against trino.io, spark.apache.org, iceberg.apache.org. `json_extract_scalar(properties, '$.device_type')` syntax correct. `get_json_object("properties", "$.device_type")` syntax correct. ALTER TABLE ADD COLUMN metadata-only claim correct. Backfill-via-`overwritePartitions()` is the right Spark 3 + Iceberg 1.5.2 API (not the broken `createOrReplace()` warned about in Iter 7 Q2 feedback). Parquet's lack of a native JSON type is correct. Trino's per-row JSON re-parse cost is real. Iceberg's min/max file statistics on real columns enabling file-skipping is correct. Dictionary encoding on low-cardinality strings is correct. The only minor nit: `get_json_object` returns a string regardless of the JSON value's underlying type — if `os_version` were a number, the resulting column would be a string and might need a `.cast()` for numeric comparisons. The answer leaves all extracted columns as STRING which is safe but a reader querying numerics later may need to cast. This is a refinement, not a correction. |
| **Beginner clarity** | 4 | Strong opening that names exactly why the column lost its structure (JDBC -> VARCHAR -> Parquet has no JSON type). Two parallel code blocks (Trino quick fix vs Spark proper fix) with prose framing before each. "Re-parses the entire JSON string on every query for every row" is excellent plain-English about the cost. The rule-of-thumb closer ("flatten anything in WHERE/GROUP BY/JOIN ON, typically 5-10 hot keys") is highly actionable for beginners. Beginner clarity weakness: "dictionary encoding," "manifest," "min/max file statistics," "Parquet column statistics," "SCD," "MERGE INTO" appear without inline plain-English glosses. A SaaS engineer with zero OLAP background will not learn what "dictionary encoding" means from this answer (it appears once as "compress to nearly nothing"). "Hot keys" is also product jargon — should be glossed as "JSON keys that appear in your most common WHERE/GROUP BY clauses, e.g., device_type, os_version, plan_tier." |
| **Practical applicability** | 5 | Engineer leaves with: (a) immediate runnable Trino query using `json_extract_scalar` for ad-hoc exploration, (b) the right architectural fix (flatten at Spark ingest), (c) runnable PySpark code skeleton, (d) the recommended schema pattern (extracted columns + `properties_raw` STRING fallback), (e) explicit decision rule (5-10 hot keys), (f) future-proofing (ALTER TABLE ADD COLUMN for new keys), (g) explicit "why this is faster" justification grounded in file-skipping and dictionary encoding. The cleanest possible "what do I do Monday morning" output. Engineer has both the band-aid (Trino JSON function for today's question) and the structural fix (Spark flatten for tomorrow's dashboards). The struct-vs-columns trade-off section in the closing addresses the dot-notation half of the question explicitly. |
| **Completeness** | 5 | Covers every sub-question: (1) why STRING — JDBC + Parquet have no JSON type; (2) how to query right now — `json_extract_scalar`; (3) can Iceberg store as struct — yes, but flatten-to-columns is recommended over struct (with reasoning: structs are harder to evolve); (4) future-proofing for new JSON keys — ALTER TABLE ADD COLUMN, metadata-only. Also addresses unprompted: trade-off framing (speed vs flexibility), backfill plan for historical NULLs (`overwritePartitions()`), why keep `properties_raw` (long-tail / unexpected ad-hoc questions), why dot notation on struct is not the recommended path. No completeness gaps for the stated question. The only thing not addressed is type casting of extracted JSON values (numerics, booleans) — but the question was framed around string extraction, so this is out of scope. |

**Average**: (5 + 4 + 5 + 5) / 4 = **4.75**

---

## Rubric update

Topic: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling
- Prior: avg 4.247 across 49 questions
- New: avg (4.247 × 49 + 4.75) / 50 = (208.103 + 4.75) / 50 = 212.853 / 50 = **4.257** across 50 questions
- Status: PASSED (unchanged)

---

## Notes for teacher

No new resource gaps identified for this answer. The teacher's JSONB-handling content in `resources/13-postgres-to-iceberg-ingestion.md` is paying off: the responder correctly delivers the standard "flatten hot keys + keep raw fallback" pattern, names both engines' correct functions (`json_extract_scalar` for Trino, `get_json_object` for Spark), and correctly cites the metadata-only nature of ALTER TABLE ADD COLUMN.

Minor opportunities to harden the resource for future iterations:

1. **Type casting from `get_json_object` results**: `get_json_object` always returns string. If an engineer flattens `os_version` ("17.4") and later wants `os_version > 17.0` they'll get a lexical comparison, not numeric. A one-line callout in the JSONB section — "wrap numeric extractions in `.cast('double')` if you'll compare or aggregate them" — would prevent a class of subtle bugs.

2. **Beginner gloss on "dictionary encoding"**: this term appears in the responder's answer without explanation and is one of the load-bearing reasons real columns beat JSON re-parsing. A one-line gloss in `resources/03-columnar-storage.md` ("Parquet replaces each repeated value with a small integer code — e.g., 'mobile' becomes 0, 'desktop' becomes 1 — so a column of 1B rows where only 5 device types appear takes a few MB, not gigabytes") would let the responder pull this in naturally.

3. **Struct vs flatten-to-columns trade-off**: the answer correctly recommends flattening over Iceberg struct, but does not name the case where struct WOULD be the right call (deeply nested or hierarchical metadata where flattening produces dozens of columns with shared prefixes, e.g., `address.street`, `address.city`, `address.zip`). A one-line "when struct is the right call" sentence in the JSONB resource section would round this out.

None of the three above is blocking. Answer is well above pass threshold and demonstrates the responder reliably handles JSONB flattening from at least two angles now (Iter 4 Q2 set the foundation; this Iter 48 Q2 confirmed retention plus the new "dot notation / struct vs columns" angle).
