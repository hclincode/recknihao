# Iter 301 Q2 Judge Score

## Topic
Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

## Scores
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | 5.00 |

## Pass/Fail
PASS (threshold: 3.5)

## Technical accuracy verification
All five claims verified against official docs:

1. **`get_json_object` valid PySpark** — Confirmed in PySpark docs. Signature `get_json_object(col, path)`; supports `$.user.id` nested dot-notation and returns string (NULL on invalid JSON). Answer's usage matches official syntax.
2. **`json_extract_scalar(col, '$.path')` correct Trino function** — Confirmed in Trino docs (current/481). Function extracts scalar (boolean/number/string), always returns VARCHAR. Path syntax `$.store.book[0].author` matches the answer's `$.user.id`. The answer's explicit warning about VARCHAR return type and lexicographic-comparison gotcha (`'99' > '100'`) is accurate and a high-value caveat.
3. **Columnar file skipping fails for JSON-string predicates** — Confirmed. Trino's Parquet reader uses min/max on stored column values; a `json_extract_scalar(col, '$.x') = 'y'` predicate operates on the function output, which has no pre-computed per-file statistics, so no row-group / file pruning. The answer's claim is correct.
4. **`contains(array_col, value)` valid Trino syntax** — Confirmed in Trino array functions docs: `contains(x, element)` returns true if array contains element. Lowercase form is correct.
5. **`ALTER TABLE ADD COLUMN` metadata-only in Iceberg** — Confirmed by Iceberg evolution docs: schema updates are metadata-only, no data file rewrites; added columns return NULL for existing rows and get new column IDs. Answer's claim is correct, including the "optional backfill via MERGE INTO" guidance.

Production-environment fit: example uses Hive Metastore (`thrift://hive-metastore:9083`), S3A on MinIO (`s3a://lakehouse/warehouse`), Iceberg + Spark catalog config — matches the on-prem stack in `prod_info.md` exactly.

## What worked
- Decision table maps `event_payload` (mostly-known shape → flatten) vs `metadata` (truly variable → raw VARCHAR) directly to the engineer's two real columns — actionable without further interpretation.
- The "type safety" callout (`'99' > '100'` lexicographic comparison) is the exact production trap that bites engineers new to JSON functions.
- File-skipping section quantifies the win ("45-second query vs 2-second", "80–95% file skipping for low-cardinality enums") — gives engineer concrete justification to flatten.
- Two-tier pattern (promoted typed columns + `_raw VARCHAR` fallback) is the correct lakehouse design and is shown end-to-end.
- Schema-evolution path for promoting a new field (ALTER TABLE → write new rows → optional MERGE backfill) directly answers "what if I want to add a hot field later".
- Array handling shown both ways (Spark `from_json` to typed array; Trino `contains`) — addresses nested-collection question.
- Spark config matches on-prem stack (Hive Metastore, MinIO via s3a).
- Trino query examples answer "how would I actually query `event_payload.user.id`" directly with both options shown.

## What was wrong or missing
Nothing material. Possible minor additions that would not change the score:
- Could mention that `get_json_object` in Spark and `json_extract_scalar` in Trino both return STRING/VARCHAR, so casting is symmetric across both engines (only the Trino side is shown).
- No mention of `json_extract` (returns JSON, useful when chaining) vs `json_extract_scalar` (returns VARCHAR, terminal).
- Iceberg 1.5.2 does technically support nested `struct<>` typed columns — the answer's recommended "flatten + raw fallback" is the right pragmatic choice but could briefly note why STRUCT-typed columns are rarely worth it when schema varies (consistent with prior iter 18 finding on MAP/STRUCT anti-pattern).

These are polish items, not gaps.

## Suggested topic score update
Old: 4.476 / 100 questions
New avg if this scores 5.00: (4.476 × 100 + 5.00) / 101 = 452.6 / 101 ≈ **4.481** across 101 questions. Status: PASSED.
