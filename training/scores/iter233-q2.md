# Iter 233 Q2 Score

**Score: 4.75 / 5.0**
**Pass: YES** (threshold is 4.5 in extended/final phase)

## What was correct
- Correctly identifies the cause: Trino fetches table/column metadata from MySQL during query planning on every query when caching is disabled.
- Correctly states `metadata.cache-ttl` default is `0s` (caching disabled) for the MySQL connector.
- Correctly identifies `metadata.cache-missing` as a real property and explains its purpose (cache "table not found" responses to avoid round-trips for non-existent tables).
- Correct syntax for flushing: `CALL billing_mysql.system.flush_metadata_cache();` with no parameters.
- Correctly distinguishes MySQL/JDBC connector's parameterless `flush_metadata_cache()` from Hive/Delta connectors (which accept `schema_name`/`table_name`). Verified against trino PR #10385 and Hive docs.
- Sensible TTL recommendation (30s–60s) with explicit trade-off discussion (stale schema after DDL changes).
- Mentions catalog reload requirement after changing TTL — correct (config-level properties require catalog reload; Trino 458+ supports dynamic catalog management but a reload is still needed).
- Good practical framing for SaaS use case (stable schema with infrequent migrations vs constant schema changes).
- Concrete file path example (`etc/catalog/billing_mysql.properties`) makes the fix actionable.

## What was wrong or missing
- Does not explicitly state the default of `metadata.cache-missing` is `false` (minor — recommendation to set `=true` is still correct).
- Could mention that `metadata.cache-ttl` also affects per-query planning latency, not just MySQL load (planning round-trip time matters too).
- Minor: "Reloading the catalog" section is slightly understated — in Trino 458+, dynamic catalog management (via `catalog.management=dynamic`) allows reloads without a full coordinator restart; the answer mentions hot-reload generically, which is fine but could be more specific.
- Does not mention related properties that often pair with these (`case-insensitive-name-matching.cache-ttl`, which also defaults to 0s and can contribute to MySQL load when case-insensitive matching is used).

## Verification notes
Verified via WebSearch and WebFetch against trino.io/docs/current/connector/mysql.html:
- `metadata.cache-ttl` defaults to `0s` (caching disabled) — confirmed.
- `metadata.cache-missing` defaults to `false` — confirmed.
- `CALL system.flush_metadata_cache()` for JDBC connectors takes no parameters — confirmed via PR #10385 history.
- Hive's `flush_metadata_cache` accepts `schema_name`/`table_name`/partition parameters; JDBC connectors do not — confirmed.
- Catalog property changes generally require catalog reload; dynamic catalog management exists in newer Trino versions.

## Recommendation for teacher
The MySQL federation / metadata caching resource is in strong shape. Minor enhancements that would push to 5.0:
1. Add explicit default values inline for both `metadata.cache-ttl` (0s) and `metadata.cache-missing` (false) so the responder consistently states defaults.
2. Add a brief mention that planning latency (not just replica load) improves with caching — useful for SaaS engineers debugging query response time.
3. Add `case-insensitive-name-matching.cache-ttl` as a related property worth setting if case-insensitive matching is enabled.
4. Clarify the catalog reload story for Trino 458+ (dynamic catalog management vs full restart) since the production stack is Trino 467.
