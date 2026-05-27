# Score: iter270-q2

**Score**: 4.88 / 5.0
**Pass**: YES (pass threshold: 4.50)

## Dimension scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All Trino-specific claims verified against official docs: `TABLE(catalog.system.query(query => '...'))` is correct, parameter is `query`, catalog is in function path, single-quote doubling is correct, ORDER BY is not preserved, query must return a table, only the data source validates the SQL. The "no outer predicate pushdown" claim is accurate (passthrough functions are opaque to Trino's optimizer). Schema-inference and empty-result caveats are well-known practical behaviors for polymorphic table functions. JSONB examples (`->>`, `?`, `#>>`) are valid Postgres syntax. `json_extract_scalar(col, '$.key')` is the correct Trino syntax. OPA `ExecuteFunction` framing is conceptually right for production environment. |
| Beginner clarity | 5 | Opens with a one-line definition of what `system.query()` does. Each code example is annotated. The "Three Critical Rules" callout makes the easy-to-miss syntax errors explicit. The BAD vs GOOD predicate example is excellent pedagogically. No unexplained jargon. |
| Practical applicability | 5 | Decision table maps real situations to the right approach. Explicit catalog name `app_pg` fits the production stack naming. Mentions production-relevant concerns: OPA, catalog-level credentials, SQL injection. Cross-catalog join example shows how to use it alongside Iceberg, which matches the production setup. Engineer knows exactly what to write. |
| Completeness | 4.5 | Covers syntax, when to use, when not to use, limitations, safety, decision guide. Minor gap: does not mention that the result columns from `system.query()` are unnamed/positional unless aliased (the join example uses `AS pg(id, plan_id)` aliasing but doesn't call out *why* that's needed). Also does not mention that Trino 467 supports calling without the catalog prefix when already in a Postgres catalog session. These are minor. |
| **Average** | **4.88** | |

## What the answer got right
- Exact correct syntax: `TABLE(app_pg.system.query(query => '...'))` with `query` as the named parameter
- Correctly notes single-quote doubling inside the string literal
- Accurately warns that outer WHERE predicates do NOT push into `system.query()` — this is one of the most common production footguns and the BAD/GOOD example nails it
- Correctly notes ORDER BY is not preserved by Trino's distributed execution
- Correctly states that the data source (Postgres) does its own validation/security, not Trino
- Correctly identifies that `system.query()` bypasses optimizer/parallelism/dynamic-filtering benefits
- Production-fit: uses `app_pg` catalog naming, references OPA `ExecuteFunction` for access control, mentions catalog-level credentials (matches on-prem Trino 467 + JWT/OPA setup)
- Solid decision guide that tells the engineer when NOT to use it (Trino-native first)
- Correct `json_extract_scalar(col, '$.key')` syntax for the Trino-native alternative

## Gaps or errors
- Minor: the cross-catalog join example uses column aliasing `AS pg(id, plan_id)` but doesn't explain that result columns from `system.query()` need explicit aliasing because the function's output schema comes from the wrapped query — a beginner might wonder why the alias list is needed
- Minor: does not mention the alternative short form `TABLE(query(query => '...'))` available when the session catalog is already the Postgres catalog (documented in Trino 481, also valid in earlier versions)
- The "Schema inferred from first row" and "Empty results break schema inference" claims are practical realities but are not explicitly called out in the official Trino docs — they are stated with appropriate hedging ("Trino may infer wrong types"), which is fine
- No SQL injection warning is good and explicit, but could mention parameterization is not supported (the query string is purely literal)

## Verified sources
- [PostgreSQL connector — Trino documentation](https://trino.io/docs/current/connector/postgresql.html) — confirms `TABLE(catalog.system.query(query => '...'))` syntax, named parameter `query`, ORDER BY not preserved, read-only, data source does its own validation
- [Polymorphic table functions blog](https://trino.io/blog/2022/07/22/polymorphic-table-functions.html) — confirms PTF design and why outer predicates cannot push into the opaque function body
- [JSON functions and operators — Trino docs](https://trino.io/docs/current/functions/json.html) — confirms `json_extract_scalar(json, json_path)` syntax with `$.key` JSON path
- [Table functions — Trino docs](https://trino.io/docs/current/develop/table-functions.html) — confirms `TABLE(...)` wrapper requirement
