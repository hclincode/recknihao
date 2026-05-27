# Iter 225 Q2 Judge Score

## Score: 4.85

## Topic: Trino federation cross-source connectors

## What the answer got right

1. **Correctly identified metadata caching as the root cause** — Trino's MySQL connector caches schema/table metadata; this is the canonical explanation for "MySQL has the new column but Trino shows the old one."
2. **`metadata.cache-ttl` default is `0s` (caching disabled)** — VERIFIED against https://trino.io/docs/current/connector/mysql.html. Doc says: "Defaults to `0s` (caching disabled)." Exact match.
3. **`metadata.cache-missing` default is `false`** — VERIFIED. Doc says: "Defaults to `false`." Exact match.
4. **`CALL billing_mysql.system.flush_metadata_cache()` is the correct procedure** — VERIFIED. The MySQL connector exposes this procedure under the `<catalog>.system` schema.
5. **MySQL connector's `flush_metadata_cache()` takes NO parameters** — VERIFIED. The official docs show the call with no arguments. This is the exact opposite of the Hive connector, which accepts `schema_name` / `table_name` / `partition_columns` / `partition_values`.
6. **CRITICAL warning about NOT passing `schema_name => 'app'` / `table_name => 'invoices'` is accurate and very useful** — these named-parameter forms exist on Hive and Delta Lake connectors but NOT on JDBC connectors (MySQL/PostgreSQL/Oracle/SQL Server). Passing them produces a runtime "Procedure not registered" error. This is directly aligned with prior iteration feedback (iter224 Q2 fabrication of remove_orphan_files signatures), and the answer pre-empts a real footgun.
7. **Trino view column-list freezing is accurate** — when a view is created, Trino persists the analyzed schema (column names and types) at CREATE time. Renaming an underlying column does not propagate; `CREATE OR REPLACE VIEW` (or `DROP` + `CREATE`) is required.
8. **`CREATE OR REPLACE VIEW` is valid Trino SQL** — VERIFIED at https://trino.io/docs/current/sql/create-view.html. Grammar: `CREATE [ OR REPLACE ] VIEW view_name ... AS query`.
9. **Practical "wait for TTL to expire" alternative is correct** — accurate fallback if user can tolerate the delay.
10. **Best-practice tuning suggestion (`metadata.cache-ttl=60s` + `metadata.cache-missing=true`) is reasonable** — reduces metadata-fetch load against the MySQL replica during high-concurrency query planning. The answer also correctly notes the tradeoff: for actively-evolving schemas, leave caching off.
11. **Mentions "cluster-wide" cache invalidation on a single `CALL`** — accurate: the procedure runs on the coordinator and the cache is held in the catalog manager per-coordinator; on each worker, metadata is fetched fresh on next access.
12. **Clear, well-structured answer with concrete catalog-properties file path (`etc/catalog/billing_mysql.properties`)** — engineer knows exactly what to inspect and edit.

## What the answer missed or got wrong

1. **Minor: did not mention `metadata.cache-maximum-size` (default `10000`) or the sub-TTL knobs** (`metadata.schemas.cache-ttl`, `metadata.tables.cache-ttl`, `metadata.statistics.cache-ttl` — all default to the master `metadata.cache-ttl`). Not strictly required to answer the question, but a complete picture would mention these.
2. **Minor: did not mention statement cache / JDBC prepared-statement cache** (`statistics-cache-ttl` etc.) for completeness. Again not required.
3. **Minor nit: "cluster-wide" phrasing could be more precise** — the coordinator's metadata cache is what's flushed; workers do not maintain a separate connector metadata cache for JDBC connectors but receive splits from the coordinator. The user-visible effect IS cluster-wide, but technically only the coordinator holds the cache. Not a factual error per se, just imprecise phrasing.
4. **No mention of OPA / production fit** — the production stack uses OPA for authorization; in principle a CALL to flush_metadata_cache may need OPA permission. Not a major omission for this question (the user is debugging schema visibility, not authz) but worth noting.

None of these gaps are factual errors. They are completeness nits.

## WebSearch verification notes

- https://trino.io/docs/current/connector/mysql.html (Trino 480/current) — verified `metadata.cache-ttl` default `0s`, `metadata.cache-missing` default `false`, `metadata.cache-maximum-size` default `10000`, and confirmed `CALL system.flush_metadata_cache()` is parameterless on the MySQL connector.
- https://trino.io/docs/current/connector/postgresql.html (for cross-reference) — same JDBC-base behavior; identical signature.
- https://trino.io/docs/current/connector/hive.html — confirms that the named-parameter form (`schema_name`, `table_name`, `partition_columns`, `partition_values`) is a Hive-specific extension; this matches the answer's CRITICAL warning.
- https://trino.io/docs/current/sql/create-view.html — confirms `CREATE [ OR REPLACE ] VIEW` syntax is valid.
- https://github.com/trinodb/trino/pull/10251 — Hive metadata cache flush procedure with optional schema/table params.
- https://github.com/trinodb/trino/pull/16466 — Delta flush_metadata_cache with optional params.

All key technical claims in the answer hold up against official documentation. The named-parameter warning is particularly valuable because it directly prevents the exact failure mode that has tripped up prior iterations (iter224 Q2 had a similar fabrication around remove_orphan_files Spark-vs-Trino parameter names).

## Recommendation for teacher

Resources are in great shape on this topic. Minor enhancements only:

1. **LOW** — In the MySQL/JDBC federation resource (likely `resources/22-trino-federation-postgresql.md` or a sibling MySQL resource if one exists), add a small "All JDBC metadata-cache knobs" table listing: `metadata.cache-ttl` (0s), `metadata.cache-missing` (false), `metadata.cache-maximum-size` (10000), `metadata.schemas.cache-ttl`, `metadata.tables.cache-ttl`, `metadata.statistics.cache-ttl`. Each sub-TTL inherits from `metadata.cache-ttl` by default.

2. **LOW** — Add an explicit "Procedure parameter compatibility matrix" callout in the federation resource:
   - MySQL/PostgreSQL/Oracle/SQL Server JDBC connectors: `CALL system.flush_metadata_cache()` — parameterless ONLY.
   - Hive connector: accepts `schema_name`, `table_name`, `partition_columns`, `partition_values`.
   - Delta Lake connector: accepts `schema_name`, `table_name`.
   - Iceberg connector: parameterless (and operates on metadata.json caching, not the JDBC schema cache).
   This pre-empts the named-parameter footgun across all federation flavors.

3. **LOW** — Briefly note OPA implications: in a stack using OPA-backed Trino authz, calling system procedures (like `flush_metadata_cache`) is itself a privileged action and may need a policy allowance. Defer specific policy content to the external governance document.

The weak-ai-responder's answer here is one of the stronger federation answers in recent iterations and supports continued PASS status for the topic.
