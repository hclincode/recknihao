# Iter273 Q1 Score

**Score**: 4.75 / 5.0
**Pass/Fail**: PASS

## Dimension scores
- Technical accuracy: 4.5/5
- Beginner clarity: 5/5
- Practical applicability: 5/5
- Completeness: 4.5/5

## What the answer got right
- Correct framing of the root cause: Trino plans SQL statically, schema names cannot be bound as runtime variables; every table reference must resolve at parse time.
- UNION ALL pattern with hardcoded `catalog.schema.table` triples is the canonical Trino workaround — correct.
- Includes a constant literal projection (`'tenant_abc' AS tenant_id`) so the consumer can tell rows apart — exactly the right idiom.
- Python generator script is concrete, idempotent, and tied to `information_schema.schemata` discovery on the Postgres side. The "wrap in CREATE OR REPLACE VIEW and version-control it" guidance is operationally sound.
- `system.query()` section is technically accurate: TABLE function syntax, verbatim passthrough to Postgres, no outer predicate/join pushdown, no parallelism, ORDER BY in passthrough not preserved (implicit in "Trino treats the result as an opaque blob"). Matches what was scored 4.88 in iter270-q2.
- Correctly identifies the long-term fix: a single shared Iceberg table with a `tenant_id` column, fits the production environment (Iceberg connector on Trino 467, MinIO/HMS).
- Decision matrix is concise and aligns with practical SaaS reality (UNION ALL up to a few hundred tenants; Iceberg for the long term).
- Production-fit: all three options are compatible with the on-prem Trino 467 + Iceberg + MinIO + HMS stack.

## Errors or gaps
- **Iceberg partitioning choice for tenant_id is questionable.** The answer recommends `partitioning = ARRAY['tenant_id', 'day(created_at)']` as identity partitioning. With 200+ tenants this creates 200 × N-day partitions — workable, but the conventional Iceberg best practice for high-cardinality tenant IDs is `bucket(N, tenant_id)` combined with `day(created_at)` to keep file counts manageable and avoid small-file skew when tenant volumes are uneven. The answer should at least mention the bucket-vs-identity trade-off and that very skewed tenant distributions degrade identity partitioning.
- **Migration plan is hand-wavy.** "Use Spark to iterate all 200 Postgres schemas and union into Iceberg" is correct in spirit but skips the practical mechanics (Spark JDBC reader per schema, `withColumn("tenant_id", lit(schema))`, write mode, CDC for incremental). The 2–4 week estimate is reasonable but unjustified.
- **No mention of `SHOW SCHEMAS FROM app_pg LIKE 'tenant_%'`** as a Trino-side discovery primitive that can drive the generator script without round-tripping to Postgres directly.
- **No warning about UNION ALL coordinator planning cost.** A 200-branch UNION ALL produces a large query plan; Trino can handle it but parse/plan time grows noticeably and EXPLAIN output becomes hard to read. Worth a one-line caveat.
- **`system.query()` example has a logic flaw.** The inner `SELECT (SELECT COUNT(*) FROM events ...)` subquery does NOT scope the COUNT to the per-tenant schema in the outer CTE — it counts whatever `events` table is in the search_path, returning the same number for every row. The correct passthrough would loop with `format()`/dynamic SQL in a PL/pgSQL `DO` block or use `UNION ALL` server-side. This is a real correctness bug in the example SQL, though the surrounding prose about limitations is correct.
- **No mention of OPA implications.** In the production stack, the OPA policy must permit `ExecuteFunction` on `system.query` per catalog — worth a one-line note since iter270-q2 flagged this.

## WebSearch findings
Verified against trino.io/docs/467/connector/postgresql.html and trino.io/docs/current/optimizer/pushdown.html:
- `system.query()` is documented as "the full query is pushed down and processed in PostgreSQL" — verbatim passthrough is correct.
- Docs explicitly call out that ORDER BY inside the passthrough is not preserved — answer's "opaque blob" framing is consistent.
- ConnectorTableFunctionHandle is treated as opaque to the engine — confirms no outer predicate/aggregation pushdown through the passthrough result. Answer is correct.
- Verified against iceberg.apache.org/docs/latest/partitioning/ and AWS/Starburst guidance: best practice for high-cardinality tenant IDs is `bucket(N, tenant_id)`, not identity partition. Answer's identity-partition recommendation is acceptable for ~200 tenants but is not the documented best practice.
- Trino has no construct for runtime schema-name binding in SELECT FROM — UNION ALL or client-side templating is indeed the only path. Confirmed.

## Topics updated
Trino federation — prior avg 4.483 across 219 questions; new running avg (4.483 × 219 + 4.75) / 220 = (981.777 + 4.75) / 220 = **4.484 across 220 questions**. Status: NEEDS WORK (4.484 < 4.500 raised threshold). Gap: 0.016 (improved from 0.017). Sustained ≥4.5 still needed across the next several questions to cross the threshold.
