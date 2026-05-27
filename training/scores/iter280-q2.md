Score: 4.30/5.0 FAIL

## Dimension scores
- Technical accuracy (40%): 4/5
- Beginner clarity (25%): 5/5
- Completeness (20%): 5/5
- Actionability (15%): 3/5

## What the answer got right
- Correctly identifies that the PostgreSQL connector exposes `CALL <catalog>.system.flush_metadata_cache()` and that Iceberg does NOT have an equivalent SQL flush procedure — this contrast is accurate.
- Correctly states that `metadata.cache-ttl` defaults to `0s` (caching disabled) and explains TTL tuning tradeoffs.
- Correctly explains the SELECT * view freeze problem: views expand `SELECT *` to a frozen column list at creation time, so `flush_metadata_cache()` alone won't surface the new column through a view — `CREATE OR REPLACE VIEW` is required.
- Good structure with a summary table mapping problems to fixes.
- Beginner-accessible: zero unexplained jargon, walks through cause, fix, and prevention.
- Covers all rubric items: cache mechanism, flush command, scope claim, view freeze, TTL tuning, Iceberg contrast.
- Notes TTL changes require a coordinator restart — correct.

## Errors or gaps
- **INCORRECT named parameters**: The answer shows `CALL app_pg.system.flush_metadata_cache(schema_name => 'public', table_name => 'users')`. Per the official Trino PostgreSQL connector docs (trino.io/docs/current/connector/postgresql.html), `system.flush_metadata_cache()` for the PostgreSQL/JDBC connector takes **no parameters** and operates at the catalog level (with `USE <catalog>.<schema>` to scope context). Those named parameters exist for the Delta Lake and Hive connectors, not the JDBC-based PostgreSQL connector. An engineer who runs this exact statement against a real Trino 467 cluster will get an error. This is a material accuracy and actionability defect.
- The claim that the cache is "coordinator-only" is plausible (JDBC metadata operations flow through the coordinator's connector metadata layer) but is not explicitly stated in the official PostgreSQL connector documentation. The answer states it as a definitive fact without qualification. A safer phrasing would acknowledge that flushing via the catalog handles cluster-wide visibility, without making an unverified architectural claim.
- Minor: `metadata.cache-ttl` default is documented as `0s` in some Trino doc pages and `0ms` in others; both mean the same zero duration, so the answer's `0s` is acceptable.

## Verification notes
- WebSearch + WebFetch against trino.io/docs/current/connector/postgresql.html confirm: `system.flush_metadata_cache()` exists for the PostgreSQL connector and is invoked with no parameters; example given is `USE example.example_schema; CALL system.flush_metadata_cache();`.
- The Trino 481 PostgreSQL docs explicitly state `metadata.cache-ttl` "Defaults to `0s` (caching disabled)" — answer is correct.
- Delta Lake and Hive connectors do support `schema_name => ..., table_name => ...` arguments, but the PostgreSQL JDBC connector's flush procedure does NOT — the answer conflates these.
- Iceberg connector has no equivalent SQL flush procedure — answer's contrast is correct.
- Coordinator-only scope is not explicitly documented in the PostgreSQL connector page; treat as unverified rather than confirmed.

The named-parameter error knocks technical accuracy to 4 and actionability to 3 (an engineer who pastes the scoped-flush example will hit a syntax/argument error). Weighted: 0.40*4 + 0.25*5 + 0.20*5 + 0.15*3 = 1.6 + 1.25 + 1.0 + 0.45 = 4.30. Below the 4.5 pass threshold.
