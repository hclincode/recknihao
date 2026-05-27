# Iter255 Q1 Score

**Score: 4.9 / 5.0** — PASS (threshold: 4.5)

## What was correct
- `domain_compaction_threshold` default of **256** correctly stated — verified against Trino docs (current/PostgreSQL connector).
- Correct mechanism: when an IN-list exceeds the threshold, Trino compacts the predicate to a BETWEEN range using min/max — verified against Trino docs ("Trino compacts large predicates into a simpler range predicate by default").
- Correct explanation that the query remains semantically correct: Trino re-applies the original IN-filter after fetching, so cost is paid in extra rows scanned and shipped over JDBC. This matches the well-known basejdbc behavior.
- `SET SESSION <catalog>.domain_compaction_threshold = 1024;` syntax is exactly correct — verified against trino.io SET SESSION docs (catalog session property syntax `SET SESSION catalog_name.property_name=value`).
- Correctly notes the catalog prefix is mandatory and that bare `SET SESSION domain_compaction_threshold = ...` will fail.
- Correctly distinguishes session property name (underscores) from catalog file property name (hyphens: `domain-compaction-threshold=1024`).
- EXPLAIN guidance is accurate: TableScan shows a `constraint on [col]` block reflecting either an IN-list or a BETWEEN — this matches Trino EXPLAIN output convention.
- `pg_stat_activity` cross-check is a strong, practical "ground truth" diagnostic that fits the SaaS operator workflow.
- Tuning guidance (raise to 1024, prefer per-session over global, beware of planner cost at very high values) is balanced and grounded.
- Sub-tenant scattered-ID scenario is well chosen — explains why the slowdown is dramatic rather than linear for this customer.

## Gaps or errors
- Very minor: the example EXPLAIN constraint snippet quotes integer tenant IDs as `'val1'` etc., which suggests strings. For numeric `tenant_id` columns Trino would render integer literals without quotes. Cosmetic.
- The answer doesn't explicitly mention that this is a basejdbc-family behavior (so the same setting applies to MySQL, SQL Server, etc.) — useful context but not required by the question.
- No mention that the production stack here is Trino 467 — the default has been 256 for several versions including 467, so the advice is still correct, but a stack-version sanity check would have been nice.

## WebSearch verification notes
- Verified `domain_compaction_threshold` default = 256 for current PostgreSQL connector (trino.io/docs/current/connector/postgresql.html). Older versions (e.g., 435) used 32, but for Trino 467 in this production stack, 256 is correct.
- Verified that Trino "compacts large predicates into a simpler range predicate" — i.e., IN list collapses to BETWEEN min/max, exactly as described in the answer.
- Verified SET SESSION syntax `SET SESSION catalog_name.property_name = value` from trino.io/docs/current/sql/set-session.html. Catalog prefix is mandatory for catalog session properties; the answer correctly emphasizes this.
- Verified the underscore-vs-hyphen distinction (session property uses underscores, catalog file property uses hyphens) — standard Trino convention, correctly described.
