# Iter259 Q2 Score

**Score: 4.8 / 5.0** — PASS (threshold: 4.5)

## What was correct
- Correctly identifies that Trino CAN push aggregation down to Postgres (COUNT, SUM, AVG, MIN, MAX on simple columns).
- Accurately frames the network/data-volume difference between pushed vs not-pushed aggregation.
- Articulates the critical rule that **all WHERE predicates must push** for aggregation to push — and gives a clear pushdownable vs non-pushdownable example (JSON extraction blocks pushdown).
- EXPLAIN signatures are correct: pushed = no Aggregate node above TableScan, with aggregated columns absorbed into TableScan layout; not-pushed = separate Aggregate node above TableScan with raw columns in layout. Matches Trino official docs.
- Session property `aggregation_pushdown_enabled` and catalog prefix (`postgres.aggregation_pushdown_enabled`) are correct; on by default.
- Correctly lists scenarios where pushdown may not occur (HAVING, window functions, COUNT(DISTINCT), non-pushdownable WHERE).
- `system.query()` escape hatch correctly invoked with proper TABLE(...) syntax for sending verbatim SQL to Postgres.
- `pg_stat_activity` verification approach is a real, useful diagnostic technique.
- Actionable: engineer knows exactly which steps to take (EXPLAIN → audit WHERE → escape hatch if needed).
- Clear, beginner-friendly with concrete SQL examples and no assumed OLAP knowledge.

## Gaps or errors
- Minor: The Trino official Pushdown docs do not phrase the "ALL WHERE predicates must push" rule as an absolute all-or-nothing rule in those exact words — though in practice it is the prevailing behavior because a Filter node above TableScan blocks aggregation pushdown. The answer's stronger framing is empirically correct and pedagogically useful, but slightly more emphatic than the docs' wording.
- The answer is Postgres-focused (appropriate to the question), but the production stack is Iceberg/Trino — a brief note that the same EXPLAIN diagnostic technique generalizes to other connectors would have been nice. Not a defect since the question is specifically about Postgres.
- The VARCHAR range predicate pushdown caveat is mentioned but not deeply justified (collation-dependent behavior). Acceptable level of detail for the question.

## WebSearch verification notes
- Verified against https://trino.io/docs/current/optimizer/pushdown.html: aggregation pushdown is supported; EXPLAIN behavior matches (no Aggregate operator when pushed, aggregate visible inside TableScan).
- Verified against https://trino.io/docs/current/connector/postgresql.html: PostgreSQL connector supports aggregation pushdown for COUNT, SUM, AVG, MIN, MAX.
- Catalog session property syntax `catalogname.property_name` is confirmed (the official docs show this pattern in the Pinot connector example for `aggregation_pushdown_enabled`); the same property name applies to the Postgres connector.
- `system.query()` table function syntax is the documented escape hatch for sending verbatim SQL to JDBC connectors.
