# Iter 232 Q2 Score

**Score: 3.25 / 5.0**
**Pass: NO** (threshold is 4.5 in extended/final phase)

## What was correct

- Correctly identifies the delay as a query **planning** delay (not execution), and correctly decomposes it into HMS metadata lookup, MySQL metadata/statistics fetch, and dynamic filtering wait.
- Correctly states that the Iceberg connector contacts HMS during planning to resolve the current `metadata.json` pointer, and that each Iceberg table adds a roundtrip.
- Correctly states the JDBC `dynamic-filtering.wait-timeout` default is **20s** and the Iceberg connector default is **1s** (verified against trino.io docs).
- Correctly identifies that `dynamic-filtering.wait-timeout` is a per-catalog property set in the catalog `.properties` file.
- Correctly notes that VARCHAR predicates do not push down to MySQL (a real Trino federation gotcha).
- Concrete file paths (`/etc/trino/catalog/iceberg.properties`, `/etc/trino/catalog/<mysql_catalog>.properties`) and HA HMS URI examples fit the on-prem k8s production environment.
- Good summary table with durations + fixes makes the answer actionable for an oncall SaaS engineer.
- Increasing Iceberg-side `dynamic-filtering.wait-timeout` from 1s to 15s is a defensible fix for MySQL-dim joins.

## What was wrong or missing

- **CRITICAL — `metadata.cache-ttl` fix is inverted.** The answer says "Reduce from typical 60s-300s to 5s." The actual documented default is `0s` (caching disabled — verified via Trino 480/current MySQL connector docs). To reduce planning latency caused by `information_schema` fetches, you must **INCREASE** the TTL (e.g., to `30s`–`10m`), not decrease it. Setting it to `5s` from `0s` would only modestly help; recommending users "reduce" it implies the wrong mental model entirely. A SaaS engineer following this advice on a fresh catalog would set TTL to 5s when they could safely use 60s+ with stable schemas. This is the same class of factual error that has caused regressions in this topic before.
- **`metadata.cache-missing=true` is misleading in this context.** It controls caching of *missing* tables (i.e., negative lookups), not general schema caching. Pairing it with "more aggressive refresh" misrepresents what it does.
- **Numeric magnitudes for HMS lookup are inflated.** Claiming "2-5 seconds" for HMS lookup of 1-3 Iceberg tables is high. The answer earlier correctly says a single HMS call is <10ms; even with serialization, 1-3 tables should be well under 1 second on a same-VPC HMS. The 2-5s figure is not justified and could mislead diagnosis.
- **MySQL metadata fetch magnitude is also high.** "5-10 seconds" for `information_schema` fetch is large; a more realistic range is hundreds of ms to a couple seconds depending on table count and replica latency.
- **Missing**: How to *measure* the planning delay (e.g., `EXPLAIN ANALYZE`, `system.runtime.queries.queued_time`/`planning_time` columns, the Trino UI "Planning Time" field). The engineer cannot confirm the diagnosis without a measurement method.
- **Missing**: Mention that the on-prem MySQL is "on-prem" while Trino is on the same on-prem k8s — the question explicitly says "on-prem MySQL," so cross-network-segment latency between k8s and MySQL is the most likely real culprit and should be called out as something to measure with a simple `SELECT 1` from `mysql_catalog.information_schema.tables`.
- **Missing**: Recommendation to use `EXPLAIN (TYPE IO)` or check `query_stats` planning time vs execution time to confirm planning is the bottleneck before changing config.
- **Minor**: The "Fix 4" example uses `SELECT *` against an events table, which is poor practice in a teaching example.

## Verification notes

Verified via WebSearch and WebFetch against trino.io docs (Trino 480 / current):

- **MySQL connector `metadata.cache-ttl`**: default is `0s` (caching disabled). Source: trino.io/docs/current/connector/mysql.html. The answer's "typical 60s-300s" framing is wrong — there is no such typical default; it's disabled out of the box. The directionally correct advice is to INCREASE it, not reduce it.
- **MySQL connector `dynamic-filtering.wait-timeout`**: default is `20s`. Confirmed by docs.
- **Iceberg connector `dynamic-filtering.wait-timeout`**: default is `1s`. Confirmed by docs. It is a per-catalog property in the Iceberg general configuration table.
- **HMS planning bottleneck for Iceberg**: real phenomenon — the Iceberg connector must consult HMS to resolve the current `metadata.json` pointer per table during planning. Documented in Trino metastores docs.
- **MySQL `information_schema` planning fetch**: real behavior — JDBC connectors fetch column metadata and statistics during planning, which blocks query start.

## Recommendation for teacher

1. **BLOCKING fix**: Correct the `metadata.cache-ttl` guidance. The default is `0s` (disabled). To reduce planning-time `information_schema` fetches against MySQL, **INCREASE** the TTL (recommend `30s` to `5m` based on schema stability), do NOT reduce it. Add an explicit note: "Default is 0s = disabled; increase, don't decrease."
2. Clarify what `metadata.cache-missing` actually does (caches negative lookups for missing tables/schemas) and when to use it.
3. Add realistic latency budgets: HMS lookup is typically <100ms total for a handful of tables on same-network HMS; MySQL `information_schema` is typically a few hundred ms for small schemas. The 2-5s / 5-10s claims overstate normal cases and should be reserved for explicitly degraded scenarios.
4. Add a "How to measure planning time" subsection: Trino UI Planning Time field, `EXPLAIN ANALYZE`, querying `system.runtime.queries` for `planning_time_ms` (or equivalent column in Trino 467).
5. Add a quick on-prem connectivity sanity check: `SELECT * FROM mysql_catalog.information_schema.tables LIMIT 1` to measure raw JDBC roundtrip time and isolate whether the bottleneck is the network or the metadata volume.
6. Cross-reference the iter231 dynamic-filtering deep-dive resource so federation answers consistently lead with: (a) measure planning vs execution split, (b) increase MySQL metadata cache TTL, (c) tune Iceberg dynamic-filtering.wait-timeout, (d) push down predicates that MySQL can use.
