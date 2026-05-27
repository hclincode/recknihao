# Iter 100 Q2 — Judge Score

**Topic**: Postgres-to-Iceberg ingestion (JSONB column handling: Debezium streaming + Iceberg storage + Trino query-time JSON extraction + schema evolution without rewrite)

**Question**: Customer wants to filter a dashboard by a specific key inside a JSONB blob streamed from Postgres via Debezium. Should the whole JSON blob be stored as a string and parsed at query time, or is there a better way to handle evolving JSONB structure without rewriting the table whenever someone adds a new key?

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All technical claims verified correct against official docs |
| Beginner clarity | 5.0 | Strong framing, no unexplained jargon, scenario table, plain-language summary |
| Practical applicability | 5.0 | Three-tier timeline (today/this week/ongoing), exact code, correct anti-pattern guidance, fits the production stack |
| Completeness | 5.0 | Addresses both choices in the question, the no-rewrite concern, schema-evolution scenarios, and anti-patterns |
| **Average** | **5.0** | |

**Verdict**: PASS (well above 3.5 threshold).

---

## Verified via WebSearch

1. **Debezium JSONB handling**: Confirmed via debezium.io — Debezium converts Postgres JSON/JSONB columns to strings in Kafka messages. No schema is inferred from JSONB contents; the entire blob is passed through as a VARCHAR/string. Matches the answer's "Debezium streams JSONB as VARCHAR; no auto-expansion; by design" claim exactly.
2. **`json_extract_scalar(json, json_path) -> varchar`**: Confirmed at trino.io/docs/current/functions/json.html. The function signature and the "returns NULL for both missing keys and malformed JSON" semantics are correct.
3. **`JSON_VALUE(... RETURNING type NULL ON EMPTY NULL ON ERROR)`**: Confirmed for Trino 467. The full SQL/JSON-standard syntax including `RETURNING varchar`, `NULL ON EMPTY`, and `NULL ON ERROR` clauses is supported and used exactly as the answer demonstrates.
4. **PySpark `get_json_object(col, path)`**: Confirmed at spark.apache.org. Function signature, `$.key` path syntax, and NULL-on-invalid behavior all match.
5. **Iceberg `ADD COLUMN` metadata-only**: Confirmed at iceberg.apache.org/docs/latest/evolution/. Adding a column is metadata-only, takes milliseconds regardless of table size, and Iceberg fills NULL for old data files at read time. Matches the answer's "metadata-only, instant; old events return NULL automatically" claim.
6. **MAP/STRUCT anti-patterns**: Substantially correct — Iceberg MAP type cannot well represent nested objects (per spec, identifier fields cannot be nested in maps or lists; nested struct evolution inside maps has known issues — apache/iceberg#14043). MAP also forces uniform value types, losing the numeric-vs-string distinction the answer flags. STRUCT does require explicit `ADD COLUMN` per JSON key, as the answer states.

No factual errors found.

---

## Strengths

1. **Correct framing upfront**: "JSONB has no schema, Parquet demands one" — gives the SaaS engineer the right mental model in one line, then explains that this is by design for variable-key blobs.

2. **Two-layer pattern is the canonical recommendation**: Hot keys flattened to real columns + raw blob preserved for the long tail. This is exactly what lakehouse practitioners recommend and what the question is really asking about.

3. **Exact, runnable code**:
   - PySpark `get_json_object` with correct `$.key` paths.
   - Spark MERGE INTO using Debezium op codes ('c', 'r', 'u', 'd') — the right CDC merge pattern.
   - Trino `JSON_VALUE` with the full standard syntax including `RETURNING varchar NULL ON EMPTY NULL ON ERROR`.

4. **Schema-evolution table is excellent**: Three scenarios (key added, key removed, key retyped) with what happens at each layer (Postgres → Iceberg → dashboards). This is exactly the SaaS engineer's worry, and the answer matches it head-on. Correctly identifies that retyping a key is a downstream consumer-contract break, NOT a pipeline failure.

5. **Anti-patterns called out by name**: `MAP<STRING,STRING>` (type erasure, no nested object) and `STRUCT` (rigid evolution per key). Pre-empts wrong choices the engineer might consider.

6. **Three-tier timeline (today / this week / ongoing)**: Gives the engineer an immediate answer for the requesting customer ("add a JSON_VALUE in your dashboard query — no table change"), a follow-up rule for high-traffic keys (promote to real column via ADD COLUMN), and an ongoing graduation rule ("flatten what you GROUP BY, WHERE, or JOIN ON — leave the long tail in the raw blob").

7. **Correctly identifies `ADD COLUMN` as metadata-only / instant**: Matches Iceberg spec; correctly notes old rows return NULL automatically without backfill (unless historical non-NULL values are needed).

8. **Provides both `json_extract_scalar` and `JSON_VALUE`** with the right tradeoff (simpler/silent vs SQL-standard/explicit-error-handling).

9. **Production stack fit**: Trino 467 syntax, PySpark for Spark consumer, Iceberg `ADD COLUMN`, Debezium VARCHAR pass-through. All compatible with on-prem k8s + MinIO + Hive Metastore stack.

---

## Issues / Gaps

None material. Minor possible nits (none score-affecting):

- The MERGE INTO `s.op` values are correct ('c', 'r', 'u', 'd'), but the answer could optionally mention that 'r' is the snapshot/read event and that filtering tombstones (null-value Debezium messages following DELETE events) before MERGE is a recurring footgun. This was flagged in iter98 as a recurring miss in resources/13. Not penalized here because the question is specifically about JSONB handling, not the general CDC merge contract.

- The answer mentions `properties_raw` as the source column name but does not state who is responsible for naming it (Debezium default vs Spark consumer rename). A one-liner like "Debezium emits the column with its Postgres name; rename to `properties_raw` in your consumer if you want to keep your Iceberg schema clean" would tidy this up. Not a real gap.

---

## Resource fix recommendations

None required. Resources covering JSONB handling are answering the question correctly and completely. The teacher does not need to change `resources/13-postgres-to-iceberg-ingestion.md` for this topic based on this answer.

---

## Topic state update

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

- Prior: 4.471 across 84 questions
- New score: 5.0
- New running average: (4.471 × 84 + 5.0) / 85 = (375.564 + 5.0) / 85 = 380.564 / 85 ≈ **4.477 across 85 questions**
- Status: PASSED (well above 3.5 threshold)

---

## Production fit

Fully compatible with on-prem Spark + Iceberg 1.5.2 + Hive Metastore + Trino 467 + Debezium 2.x + MinIO + JWT auth + OPA stack. All code snippets are directly runnable. JSON_VALUE syntax is correct for Trino 467. get_json_object is the standard PySpark JSON extractor. Iceberg ADD COLUMN is metadata-only as claimed. No public-cloud-only services referenced.

---

## Sources verified

- [Debezium PostgreSQL Connector documentation](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- [Trino JSON functions and operators](https://trino.io/docs/current/functions/json.html)
- [PySpark get_json_object documentation](https://spark.apache.org/docs/latest/api/python/reference/pyspark.sql/api/pyspark.sql.functions.get_json_object.html)
- [Apache Iceberg Schema Evolution](https://iceberg.apache.org/docs/latest/evolution/)
- [Apache Iceberg Spec (MAP/STRUCT)](https://iceberg.apache.org/spec/)
