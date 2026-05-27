# Score — Iter284 Q2

**Score: 4.78/5.0 PASS**

## Breakdown
- Technical accuracy (40%): 5/5 — Syntax `<catalog>.system.query(query => '...')` invoked as `SELECT * FROM TABLE(...)` is correct per Trino 481/467 docs. ORDER BY-not-preserved is explicitly confirmed by official PostgreSQL connector docs ("The query engine does not preserve the order of the results of this function. If the passed query contains an ORDER BY clause, the function result may not be ordered as expected."). The no-outer-pushdown claim is correct: `system.query` returns an opaque table handle whose schema is determined dynamically; the engine cannot rewrite the inner query, so any outer WHERE / LIMIT / ORDER BY runs in Trino after the full result set is pulled back. JSONB GIN-not-used-via-Trino-`json_extract_scalar` is accurate (those run on workers; only basic equality predicates push down for JDBC). OPA / security note matches Trino docs which explicitly state "Only the data source performs validation or security checks for these queries using its own configuration" — and there is a documented gap that table functions/procedures are not always covered by file-based access control (and historically by OPA), so that's a genuine, accurate caution. Single-quote doubling is correct.
- Completeness (25%): 4.5/5 — Covers the big-ticket gotchas: pushdown of outer predicates, ORDER BY loss, security/auth bypass, JOIN behavior with Iceberg + dynamic filtering, quoting, and a sensible EXPLAIN-first recommendation. Could have mentioned a few more nuances: (a) `system.query` requires connector to be reachable from coordinator only at planning, but actual SELECT happens with a single split (no parallelism), which matters for large JSONB scans; (b) the result is treated as opaque so column types are inferred from Postgres and may surprise (`jsonb` may come back as `varchar`); (c) write operations are blocked. These omissions are minor for this question.
- Production fit (20%): 5/5 — Fits Trino 467 + JDBC PostgreSQL connector + OPA exactly. Explicit OPA bypass call-out is the right warning for the on-prem multi-tenant SaaS environment described in `prod_info.md`. Join-with-Iceberg-on-MinIO note matches the production stack.
- Clarity (15%): 4/5 — Bullet-list format is dense and actionable. However, the answer does not include a full worked SQL example with the GIN-indexed JSONB filter (e.g., `... WHERE properties @> '{"plan":"pro"}'`), which would make it more directly copy-pasteable for the engineer. Concepts are clear, but a 4–5 line SQL snippet would push this to 5.

Weighted: 5×0.40 + 4.5×0.25 + 5×0.20 + 4×0.15 = 2.00 + 1.125 + 1.00 + 0.60 = **4.725**

## What was correct
- `system.query(query => '...')` invoked inside `TABLE(...)` is the documented syntax
- ORDER BY non-preservation matches official Trino docs verbatim
- Outer WHERE not pushed back into the inner Postgres query (table-function results are opaque to the planner)
- JOIN with Iceberg works on Trino workers with dynamic filtering on the Iceberg side
- Single-quote escaping requirement
- OPA / row-filter bypass is a real, documented limitation — security caution appropriate for the prod environment
- GIN index unused by `json_extract_scalar` is accurate
- Recommending EXPLAIN before reaching for system.query is good defensive advice

## Errors or gaps
- No concrete SQL example showing the JSONB `@>` operator with the GIN index inside the passthrough — would have made the answer immediately copy-pasteable
- Did not mention that `system.query` executes as a single split (no parallelism) which matters when the inner query returns large result sets
- Did not mention that result column types are inferred from the Postgres-side query and `jsonb` typically maps to `varchar` in Trino
- Did not call out that the inner SQL must return a table (no DDL/DML)

## Verification
- WebSearch + WebFetch against trino.io/docs/current/connector/postgresql.html confirmed: syntax `SELECT * FROM TABLE(example.system.query(query => '...'))`, ORDER BY not preserved (verbatim docs quote), and "Only the data source performs validation or security checks" — matches the OPA-bypass concern.
- Searched Trino docs and GitHub issues for outer-WHERE pushdown into table functions: confirmed table functions are opaque to the optimizer (ConnectorTableFunctionHandle is opaque), so outer predicates run in Trino after pulling the full inner result. Answer is correct.
- Searched for OPA + system.query: confirmed known issues with file-based access control and table functions/procedures (issue #23278); OPA-equivalent caution is appropriate.
