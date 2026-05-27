# Iter257 Q1 Score

**Score: 4.8 / 5.0** — PASS (threshold: 4.5)

## What was correct
- `metadata.cache-ttl` default is `0s` (caching disabled) — verified against trino.io PostgreSQL connector docs.
- Correctly distinguishes metadata (table names, column names, types, statistics) from row data.
- `metadata.cache-missing` default of `false`, and accurate description of its purpose (caching "table not found" / missing-metadata responses).
- `CALL <catalog>.system.flush_metadata_cache()` syntax with catalog-qualified form is valid (the docs also show `USE <catalog>...; CALL system.flush_metadata_cache()`; the catalog-prefixed call form works equivalently).
- Strong explanation of why the second query is faster even with caching off: JDBC connection reuse, OS-level TCP/DNS state — this is the most likely real cause and the answer leads with it.
- Clear, beginner-friendly trade-off table for `metadata.cache-ttl` values.
- Correct location guidance: `etc/catalog/<catalog>.properties` (not `config.properties`).
- Practical runbook showing the DDL → flush → DESCRIBE sequence is exactly what a SaaS engineer needs.
- Schema-evolution consequences (renamed/dropped columns, `SELECT *` views silently missing new columns) are accurately stated.

## Gaps or errors
- Minor: the official docs example uses `USE <catalog>.<schema>; CALL system.flush_metadata_cache();` — the answer's `CALL app_pg.system.flush_metadata_cache()` form also works but is not the form the docs show first; a brief mention of the `USE`-then-`CALL` alternative would have been ideal.
- Minor: does not mention that PostgreSQL connector also has separate `statistics.cache-ttl` (and related stats cache settings) — small completeness gap but not core to the question.
- The answer does not tie advice to the production environment in `prod_info.md` (Trino 467, on-prem, k8s). The advice is still fully applicable, but explicit grounding would be a nice touch (no real loss for this question since it's a generic JDBC-connector behavior).

## WebSearch verification notes
- Verified via https://trino.io/docs/current/connector/postgresql.html:
  - `metadata.cache-ttl` default = `0s` (caching disabled). MATCHES answer.
  - `metadata.cache-missing` default = `false`; purpose is to cache the fact that metadata/stats are not available. MATCHES answer.
  - `flush_metadata_cache()` procedure exists for the PostgreSQL connector and flushes JDBC metadata caches; docs example uses `USE <catalog>.<schema>; CALL system.flush_metadata_cache();`. The catalog-prefixed form used in the answer (`CALL app_pg.system.flush_metadata_cache()`) is also valid Trino syntax.
- Connection-reuse explanation is consistent with how Trino's JDBC-based connectors work; this is a credible and correct framing for "why is the second query faster even with caching off."
