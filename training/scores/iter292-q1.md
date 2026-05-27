# Iter292 Q1 Score — Trino CTEs (Inlined vs Materialized)

## Question recap
Are CTEs in Trino materialized or inlined? Does referencing a CTE twice run the subquery twice? Should the engineer avoid CTEs in Trino 467? Engineer has queries referencing the same CTE 2-3 times for different aggregations.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All core claims verified against trino.io and community sources. (1) Trino inlines CTEs by default — confirmed; the SQL for the WITH clause is inlined anywhere the named relation is used. (2) Multiple references => multiple executions — confirmed: "Trino executes the same named result set as many times as the named result set is referred." (3) Trino 467 has no MATERIALIZED/NOT MATERIALIZED hint or session property for inline CTEs (unlike Postgres/DuckDB) — answer correctly avoids suggesting one and recommends CTAS as the workaround. (4) `CASE WHEN` inside aggregates is the standard, correct one-pass pattern. (5) `CREATE TABLE ... AS SELECT ...` for materializing cross-statement reuse is correct and works on Iceberg/Hive Metastore (fits prod stack). (6) Predicates from outer query combining with inlined CTE WHERE — accurate; Trino's optimizer pushes/combines predicates into the Iceberg scan when CTE is inlined once. EXPLAIN guidance is on-point. No factual errors. |
| Beginner clarity | 5 | Postgres comparison made explicitly up front ("In Postgres CTEs are materialized; Trino is different"). Uses small worked SQL examples for both the problem and the fix. The single-reference vs multi-reference distinction is the right teaching frame. CASE WHEN inside aggregates is shown step by step. No unexplained jargon. |
| Practical applicability | 5 | Directly answers the engineer's "I have 2-3 CTE references" scenario with a copy-pasteable collapsed query. CTAS option is shown end-to-end including the DROP TABLE. EXPLAIN verification recipe lets engineer self-diagnose. Fits the on-prem Trino 467 + Iceberg + Hive Metastore stack (temp table CTAS works on Iceberg). |
| Completeness | 5 | Covers: inlining behavior, single-use is free, multi-use cost, two fix patterns (CASE-WHEN single-pass, CTAS), explicit "should I avoid CTEs? No" guidance, EXPLAIN verification. Nothing material missing for the question asked. Could optionally mention `WITH SESSION` materialization is NOT available in Trino 467 — but the absence of that suggestion is itself correct. |

**Average**: (5 + 5 + 5 + 5) / 4 = **5.00**
**Pass threshold**: 3.5 — **PASS**

## Verification notes (WebSearch against trino.io and community sources)

- Trino SELECT docs and tech blogs confirm: CTEs are inlined; no per-query materialization hint exists in Trino 467.
- Trino 467 release notes (Dec 2024) do not introduce a CTE materialization option.
- CASE WHEN inside aggregates is the canonical Trino pattern for multi-aggregation single-scan.
- CTAS to a managed Iceberg temp table is the supported way to materialize an intermediate result for reuse across statements; fits the on-prem MinIO + Iceberg + Hive Metastore stack in prod_info.md.
- Predicate pushdown through inlined CTEs is part of Trino's optimizer pipeline (ScanFilterProject + applyFilter), so combining outer WHERE with CTE WHERE into one Iceberg scan is accurate.

## Topics touched
- SQL OLAP best practices (CTE semantics, single-pass aggregation, EXPLAIN usage)
- Trino-specific query optimization patterns for Iceberg

## Notes for teacher
No corrections needed. This is an exemplary answer: correct, beginner-accessible, immediately actionable, and fitting the on-prem Trino 467 + Iceberg stack. Keep this answer pattern (Postgres comparison up front + worked single-pass fix + CTAS fallback + EXPLAIN verification) as a template for similar "Trino vs Postgres semantic difference" questions.
