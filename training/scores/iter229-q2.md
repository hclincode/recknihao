# Score: iter229-q2
Score: 4.75
Topic: Trino federation / cross-source connectors

## What was correct

- **OSS Trino 467 MySQL connector has no built-in connection pooling**: Verified against trino.io/docs/current/connector/mysql.html — the documented config properties are only `connection-url`, `connection-user`, `connection-password`, `credential-provider.type`, and credential-handling variants. There is no `connection-pool.*` property family in OSS. Answer is correct.
- **`connection-pool.enabled` / `connection-pool.max-size` are Starburst Enterprise-only**: Verified against docs.starburst.io/latest/connector/mysql.html. The answer's explicit warning ("Do not add these to your MySQL catalog config file — they belong to Starburst Enterprise") is accurate and high-value because Trino silently ignores unknown catalog properties (engineer would otherwise believe pooling is enabled).
- **ProxySQL as the recommended OSS pooling layer**: Aligns with community/practitioner guidance (ProxySQL multiplexing is the established MySQL-native pooler). The answer correctly frames it as an intermediary that multiplexes many short-lived JDBC connections onto a bounded backend pool. The known caveat (GitHub issue trinodb/trino#18279: schema-name routing limitation) is not relevant here because the engineer uses one catalog per MySQL endpoint.
- **Per-query connection-per-table model**: Directionally correct — JDBC connectors open one or more connections per table scan; under high query concurrency these accumulate quickly. The "10 queries × 2 tables = 20 connections" worked example is a fair illustration even if the exact connection-per-split count can vary with split count.
- **Resource groups field name `hardConcurrencyLimit`**: Verified against trino.io/docs/current/admin/resource-groups.html. Correct spelling (camelCase), correct semantics (cap on concurrent running queries; rest queue).
- **MySQL `MAX_USER_CONNECTIONS` defense-in-depth**: Valid MySQL feature (dev.mysql.com), correctly framed as a hard backstop if the pooler is misconfigured.
- **Production fit**: ProxySQL as a k8s Deployment fits the on-prem k8s production stack described in prod_info.md. No cloud-only tools recommended.
- **Layered architecture**: The "do all three" structure (ProxySQL + MySQL user cap + Trino resource group) is correct defense-in-depth thinking.
- **Catalog URL swap example**: Concrete before/after `connection-url` swap is exactly what an engineer needs to act on.

## What was wrong or missing

- **Minor — per-split vs per-table connections**: Answer says "opens a JDBC connection for each table being scanned." More precise statement: JDBC-based connectors in Trino open at least one connection per split, and a single table scan typically produces one split per worker for non-partitioned tables (MySQL connector has no partition-count/partition-column properties per trinodb/trino#389). The "per table" framing is a useful simplification but technically underestimates connection count when many workers are involved.
- **Minor — ProxySQL deployment details**: Mentions `default_pool_size` but doesn't note ProxySQL's two ports (admin 6032 / mysql 6033) or the multiplexing caveat (transactions, user variables, and certain session settings disable multiplexing). For a SaaS dashboard read-only workload this is fine, but a brief callout would help.
- **Minor — `max_execution_time` units**: The MySQL `max_execution_time` server variable is in milliseconds; answer doesn't specify units or give an example value.
- **Missing — MySQL JDBC driver pool param alternative**: The Trino docs note that pooling could in theory be configured via JDBC URL parameters appended to `connection-url`, though this is not officially documented/supported for the OSS MySQL connector. Worth mentioning as "not recommended" rather than absent.
- **Missing — diagnostic queries**: No mention of how to verify the problem (e.g., `SHOW PROCESSLIST` on MySQL, `system.runtime.queries` on Trino to count concurrent federation queries, or MySQL `SHOW STATUS LIKE 'Threads_connected'`).
- **Missing — selector wiring for the resource group**: The JSON snippet shows the group definition but not the matching `selectors` entry that routes federation queries (e.g., by `source` or `catalog` regex) to `federation_mysql`. A copy-pasteable selector would close the loop.

## Verdict

PASS. The answer is technically accurate on every load-bearing claim (no OSS pooling, `connection-pool.*` is Starburst-only, ProxySQL is the right fix, `hardConcurrencyLimit` field name correct, `MAX_USER_CONNECTIONS` is a real MySQL feature). It fits the on-prem k8s production stack. The minor gaps (per-split vs per-table nuance, ProxySQL ports/multiplexing caveats, diagnostic queries, resource-group selector wiring) keep it from a 5.0 but do not introduce any incorrect or production-dangerous guidance. This is above the 4.5 raised threshold for the federation topic.

Dimension scores:
- Technical accuracy: 4.7 (correct on all critical claims; minor imprecision on "connection per table")
- Beginner clarity: 4.8 (analogy "intermediary that accepts many short-lived connections and multiplexes them" is clear; before/after URL example is concrete)
- Practical applicability: 4.8 (engineer knows exactly what to deploy, what to change, what NOT to add)
- Completeness: 4.6 (missing selector wiring, diagnostics, ProxySQL port/multiplexing caveats)

Average: **4.75**
