# Iter247 Q1 Score

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.0** |

**Topic**: Trino federation / cross-source connectors
**Pass/Fail**: FAIL (threshold 4.5)

## Strengths
- Correct headline claim: Trino's PostgreSQL connector maps Postgres `JSONB` to Trino `JSON` (verified against trino.io/docs/current/connector/postgresql.html).
- Good diagnostic-first instinct (`DESCRIBE`) to confirm the column's reported type before guessing.
- `system.query()` escape hatch example is syntactically correct and idiomatic for the PostgreSQL JDBC connector (`TABLE(catalog.system.query(query => '...'))`), and the rationale (push down JSONB-native operators, use JSONB indexes) is accurate.
- Long-term recommendation (denormalize into Iceberg via Spark for analytics workloads) fits the prod stack (Spark + Iceberg 1.5.2 + Hive Metastore + Trino 467 on MinIO).
- Clean separation of "quick workaround" vs "permanent fix" gives an actionable decision rule for the engineer.

## Gaps / Errors
- **Missed the canonical root cause and the canonical knob**: the answer never names the `unsupported-type-handling` connector property (default `IGNORE`, alternative `CONVERT_TO_VARCHAR`). For a federation question where the user reports a column that breaks the query, the FIRST suspect is usually an *adjacent* unsupported Postgres column (timestamp arrays, enums, hstore, intervals, ranges, citext, etc.), not JSONB itself — because JSONB is natively supported. The answer hand-waves the cause as "older configurations or specific connector settings may silently drop the column or throw an error" instead of telling the engineer to look at the other columns in the row and to consider setting `postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR` in the catalog properties.
- **Contradictory labeling in Option 1**: heading says "Exclude the JSONB column and reference it explicitly," but the example INCLUDES the settings column via `json_extract_scalar`. The two clauses contradict each other and will confuse a beginner.
- **No mention of the actual error text / how to read it**: a stronger answer would have suggested the engineer paste the exact Trino error (it usually names the offending column and type) so they can confirm whether JSONB is actually the culprit.
- **No mention of `IGNORE` default behavior nuance**: with `IGNORE`, the column is not even visible in `DESCRIBE`, so the `DESCRIBE` diagnostic might mislead the engineer (the column would simply be absent, not show a weird type). This is a beginner-trap the answer didn't pre-empt.
- Minor: `json_extract_scalar` example uses `$.key_name` jsonpath syntax without telling the engineer this is JSONPath — a SaaS engineer with zero OLAP background may not know this.
- Minor: doesn't reference the production read-replica setup specifically (e.g., warning that `system.query()` runs on the read replica and so must be a read-only query — though the answer's example is read-only by accident).

## Notes for teacher
- The `resources/` federation doc should call out the diagnostic flow for "column X breaks federated SELECT": (1) check Trino error message for the column name and type; (2) cross-reference Postgres column types vs the connector's supported-types table; (3) decide between `unsupported-type-handling=CONVERT_TO_VARCHAR` (cheap, schema-wide) vs `system.query()` passthrough (per-query, full Postgres dialect) vs denormalize-into-Iceberg (long-term analytics).
- The teacher should add a one-liner clarifying that JSONB itself is supported and so a "JSONB-related" error is more often an adjacent column type (arrays of timestamp-with-tz, enums, ranges, etc.) being the actual culprit.
