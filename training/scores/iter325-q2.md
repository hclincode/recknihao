# Judge Score — Iter 325 Q2

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Most claims correct (STRUCT physical layout, per-field stats, `from_json`, `withField`, JSON-string drawbacks, dereference-pushdown caveats). One serious error: the schema-evolution DDL `ALTER TABLE ... MODIFY COLUMN metadata STRUCT<...>` is NOT valid Iceberg syntax. Iceberg requires `ALTER TABLE ... ADD COLUMN metadata.sso_enabled BOOLEAN` (dotted-path ADD COLUMN). Iceberg docs explicitly state "ALTER COLUMN is not used to update struct types; instead, use ADD COLUMN and DROP COLUMN." Engineer pasting the MODIFY COLUMN form would get a parser error. |
| Beginner clarity | 4.5 | Clear definitions, accessible language. Trade-off table is excellent for a beginner. Dot-notation, bracket-notation, and CAST AS JSON variants all shown. Jargon (file-skipping, dictionary encoding) is used but in context. Minor: "dereference pushdown" implicit but never named explicitly. |
| Practical applicability | 3.5 | Strong on the decision framework, hybrid pattern, prod recommendation, Spark ingestion code, two `from_json` vs `struct(...)` options, "never auto-derive schema" warning. Loses points because the schema-evolution example (the most likely thing the engineer would copy-paste) contains invalid DDL — they would hit a syntax error on day one of evolving the schema. Also no mention of prod environment (on-prem Spark + Iceberg 1.5.2 + Trino 467 + MinIO) but the advice is consistent with it. |
| Completeness | 4.5 | All three approaches covered, trade-off table, query performance scenarios with concrete numbers, both ingestion patterns (parse-JSON vs build-from-cols), schema-evolution scenario, backfill, hybrid promotion pattern, explicit "your case → STRUCT" verdict, fall-back rules, "never JSON for stable schemas." Minor gap: doesn't mention the field-ID schema-evolution guarantee in much depth, no explicit Trino EXPLAIN snippet for verifying pushdown. |
| **Average** | **4.00** | **PASS** |

## What Worked
- Clear three-way framing (flat / STRUCT / JSON string) with crisp pros/cons for each
- Trade-off comparison table is genuinely useful and accurate at the cell level
- Two correct PySpark ingestion patterns (`from_json` with explicit schema, plus `struct(col, col, ...)`) with the "never auto-derive in prod" guardrail
- Per-field min/max statistics claim for STRUCT is correct — verified against Iceberg spec and Parquet column-chunk model
- Honest treatment of Trino dereference pushdown ("more conservative on nested predicates") — this matches PR #8129 and the known Parquet caveat
- Hybrid promotion pattern (one hot field flat + full STRUCT) is a real production recipe
- Direct recommendation at the end ("Use STRUCT — your case is the ideal use case")
- Numerical query-performance scenarios (7/2000 vs 50/2000 vs 2000/2000 files) make the abstract trade-off tangible

## What Missed
- **DDL error on schema evolution**: `ALTER TABLE ... MODIFY COLUMN metadata STRUCT<...>` is not Iceberg syntax. The correct form is `ALTER TABLE iceberg.analytics.events ADD COLUMN metadata.sso_enabled BOOLEAN`. This is a copy-paste trap.
- The Trino syntax for adding a nested field (`ALTER TABLE iceberg.analytics.events ADD COLUMN metadata.sso_enabled boolean`) is not shown — engineer's main query engine is Trino 467
- "Dereference pushdown" — the actual Trino feature name — is never used; would help engineer search for follow-ups
- No EXPLAIN snippet to verify nested predicate pushdown actually fires (the answer says "confirm it in EXPLAIN output" but doesn't show how)
- Backfill code uses `col("metadata").withField("sso_enabled", coalesce(col("metadata.sso_enabled"), lit(False)))` — `withField` is valid PySpark 3.1.1+, but using `coalesce` on the freshly-added field that is already `NULL` for old rows is the only sensible value; the wrapping in `coalesce` is harmless but a bit confused for a beginner
- No mention of the production stack (Spark + Iceberg 1.5.2 + Hive Metastore + MinIO + Trino 467) — advice happens to fit, but explicit grounding would help

## Technical Accuracy (verified)

1. **Iceberg STRUCT stored as separate Parquet columns with per-field min/max** — VERIFIED. Iceberg spec: "A struct is a tuple of typed values where each field is named and has an integer id." Per-column-chunk statistics including min/max apply to leaf columns, which for a STRUCT means each scalar field gets its own chunk and its own statistics. Answer's claim is correct.

2. **`from_json(col, schema)` is a valid PySpark function** — VERIFIED. Signature is `from_json(col, schema, options=None)` where schema can be StructType, ArrayType of StructType, or DDL string. Returns NULL for unparsable input. Answer's usage is canonical.

3. **Trino 467 supports predicate pushdown on STRUCT nested fields** — PARTIALLY VERIFIED. Trino has supported dereference pushdown for Iceberg since PR #8129. The "more conservative" caveat is real — there are known Parquet reader limitations on Row-type pushdown (PR #15408). Answer's hedging ("slightly less aggressive") is fair.

4. **`col("metadata").withField("field_name", value)` is valid PySpark syntax** — VERIFIED. Introduced in Spark 3.1.1. Usage in the answer is canonical.

5. **`ALTER TABLE ... MODIFY COLUMN metadata STRUCT<...>` is valid Iceberg DDL** — FALSE. Iceberg docs explicitly say: "ALTER COLUMN is not used to update struct types; instead, use ADD COLUMN and DROP COLUMN to add or remove struct fields." The correct form is `ALTER TABLE prod.db.sample ADD COLUMN point.z double` — dotted-path ADD COLUMN. The answer's MODIFY COLUMN example would error out when run on Spark SQL against an Iceberg table. This is the answer's single most consequential mistake.

## Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.494 across 114 questions → (4.494 × 114 + 4.00) / 115 = **4.490 across 115 questions**. Status: **PASSED** (slight downward drift from MODIFY COLUMN DDL error; resources/13 should add an explicit Spark/Trino dotted-path ADD COLUMN example for STRUCT evolution to prevent recurrence).
