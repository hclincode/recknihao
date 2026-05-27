# Iter258 Q1 Score

**Score: 1.8 / 5.0** — FAIL (threshold: 4.5)

## What was correct
- The `system.query()` escape hatch syntax (`TABLE(app_pg.system.query(query => '...'))`) is correctly shown and would work as a valid workaround.
- The verification methods (EXPLAIN ANALYZE row counts, `pg_stat_activity` on the Postgres side) are technically valid investigation techniques.
- The conceptual explanation of why topN pushdown matters (avoiding pulling all rows over JDBC) is reasonable in the abstract.
- Predicate pushdown contrast example (WHERE clause appearing inside TableScan constraint) is accurate.
- The pre-materialized recent_events table workaround is a sensible architectural pattern.

## Gaps or errors
- **CRITICAL FACTUAL ERROR — the central claim is wrong.** The answer states "Trino does NOT push ORDER BY ... LIMIT (topN) down to Postgres in OSS Trino" and "no optimizer rule for topN pushdown ... not implemented for JDBC connectors." This is **false**. The official Trino PostgreSQL connector documentation explicitly lists **Top-N pushdown** as a supported pushdown type, alongside join, limit, aggregate, and predicate pushdown. This has been supported in OSS Trino since at least the JDBC topN pushdown work (PR #6847) and is documented in trino.io/docs/current/connector/postgresql.html.
- **CRITICAL FACTUAL ERROR — the EXPLAIN plan is wrong.** The answer claims you will see `TopN [topN=100, orderBy=[created_at DESC]]` as a Trino-side operator above TableScan. The actual EXPLAIN plan for a query that pushes topN down shows **no** TopN operator in Trino fragments — instead, the TableScan node contains `sortOrder=[created_at:timestamp ... DESC NULLS LAST] limit=100` directly. The documented contrast in trino.io is exactly the opposite of what this answer claims.
- **The recommended workaround is therefore unnecessary in OSS Trino.** Telling the engineer their query is "catastrophically slow" and pushing them toward `system.query()` is misleading — the original query `SELECT * FROM app_pg.public.events ORDER BY created_at DESC LIMIT 100` should push topN to Postgres natively and use the `created_at` index without any rewrite.
- The answer's confident assertion that "your Postgres index is completely wasted" would cause the engineer to take corrective action where none is needed, and likely lose trust in Trino's pushdown story overall.
- The session property `topn_pushdown_enabled` (controlling this behavior) is not mentioned, even though it would be the right knob to discuss if pushdown weren't occurring.
- Production environment note (Trino 467) is not addressed, but topN pushdown was available well before 467 so the answer should have confirmed it works in the production version.

## WebSearch verification notes
- Verified against https://trino.io/docs/current/connector/postgresql.html — PostgreSQL connector explicitly supports Top-N pushdown (listed alongside join, limit, aggregate, predicate pushdowns).
- Verified against https://trino.io/docs/current/optimizer/pushdown.html — official documentation uses a PostgreSQL example to demonstrate successful Top-N pushdown, showing `sortOrder=... limit=N` inside the TableScan node and the **absence** of a TopN operator in Trino fragments as the signature of a successful pushdown.
- Verified GitHub PR #6847 "Add support for TopN pushdown in JDBC connectors" — JDBC topN pushdown has been merged and is generally available.
- Verified system.query() syntax — the `TABLE(catalog.system.query(query => '...'))` form shown in the answer is correct, but it is the wrong recommendation here because native pushdown already handles the case.
