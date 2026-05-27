# Iter272 Q1 Score

**Score**: 4.75 / 5.0
**Pass/Fail**: PASS

## Dimension scores
- Technical accuracy: 4.5/5
- Beginner clarity: 5/5
- Practical applicability: 5/5
- Completeness: 4.5/5

## What the answer got right
- `CALL <catalog>.system.flush_metadata_cache()` is the correct procedure invocation for the PostgreSQL connector (verified against trino.io PostgreSQL connector docs).
- `metadata.cache-ttl` is the correct property name, with `0s` as the default (caching disabled) — matches Trino 481 docs verbatim.
- The claim that Trino views with `SELECT *` freeze the column list at creation time is correct for Trino specifically: views in Trino persist their schema (column list) as metadata in the metastore at CREATE VIEW time. New columns added to the underlying table are NOT picked up by an existing view's `SELECT *`. This is a real, frequently-misunderstood foot-gun and a strong reason to call it out.
- Correctly identifies the two failure modes (hard error on missing column vs. silent data loss via stale view schema) with concrete, runnable examples.
- The "changing TTL requires a coordinator restart" claim is correct for static catalog management (the default and overwhelmingly common production mode) — catalog properties are read only at catalog load.
- The schema-drift detection query using `app_pg.system.query(...)` passthrough is valid Trino syntax and a genuinely useful CI/CD pattern.
- Operational recommendation (flush as post-migration step in Flyway/Liquibase; `0s` TTL for SaaS products with frequent migrations) is well-targeted to the asker's stated context.
- The trade-off table (0s vs. 60–300s) gives the engineer a clear decision framework.

## Errors or gaps
- **"Cluster-wide" flush claim is slightly imprecise.** Metastore/metadata caching for the JDBC connectors lives on the coordinator only (workers do not cache table metadata). Saying the flush is "cluster-wide" is loose phrasing — it's coordinator-scoped, which in single-coordinator clusters has the same effect, but in multi-coordinator setups would not propagate. Minor wording issue.
- **Missed the granular sub-properties.** Trino exposes `metadata.schemas.cache-ttl` and `metadata.tables.cache-ttl` (both default to the parent `metadata.cache-ttl` value) which allow asymmetric caching of schema-list vs. table-metadata. Worth at least a one-line mention for completeness.
- **No mention of dynamic catalog management** as an alternative to restart for changing `metadata.cache-ttl`. In Trino's dynamic catalog mode, you can DROP CATALOG / CREATE CATALOG without restart.
- **Does not acknowledge the production stack from `prod_info.md`.** The documented prod stack is Trino 467 + Iceberg with Hive Metastore; PostgreSQL connector is not listed as a primary stack component. The answer assumes the connector is in use (which is reasonable given the question), but a brief acknowledgment that this is outside the documented Iceberg-primary stack would have been ideal — especially since the answer's properties-file path advice (`etc/catalog/app_pg.properties`) assumes a static catalog model and on-prem k8s deployment, which happens to be correct for this environment but is never tied to it.
- **`metadata.cache-missing` not mentioned.** This sibling property controls whether negative lookups (missing tables) are cached, which is a related and operationally relevant knob for schema-evolution scenarios.

## WebSearch findings
- Verified at trino.io/docs/current/connector/postgresql.html: `system.flush_metadata_cache()` exists; `metadata.cache-ttl` defaults to `0s` (caching disabled); `metadata.schemas.cache-ttl` and `metadata.tables.cache-ttl` are sub-properties that inherit from the parent.
- Verified at trinodb.github.io and the Trino 369 release notes: granular flush (per-schema/per-table/per-partition) was added in release 369; the procedure was originally introduced in release 328.
- Verified via Trino caching blog and Hive connector docs: metastore/metadata caching is coordinator-only — workers do not maintain a metadata cache. The "cluster-wide" wording in the answer is therefore imprecise.
- Verified the view behavior conceptually: Trino views store their schema (column metadata) at creation time in the metastore (the view "has a schema and is treated much like a table"). New columns added to the underlying table do NOT propagate to an existing view's `SELECT *` resolution. The answer's claim is correct.
- Verified catalog properties reload behavior: static catalog mode (default) requires restart; only dynamic catalog mode allows reconfiguration via CREATE/DROP CATALOG. The answer's restart claim is correct for the common case.

## Topics updated
Trino federation — prior avg 4.481 across 217 questions; new running avg (4.481 × 217 + 4.75) / 218 = (972.377 + 4.75) / 218 = 977.127 / 218 = **4.482 across 218 questions**. Status: NEEDS WORK (4.482 < 4.500 raised threshold for this topic; gap shrunk from 0.019 to 0.018). Gap: need sustained ≥4.875 answers to cross 4.500. Resource on metadata caching is now solid; remaining drag is from earlier iter163/164/165 failures still weighing the average.
