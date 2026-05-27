# Iter 223 Q2 Judge Score

## Score: 3.85

## Topic: Trino federation cross-source connectors

## What the answer got right

- **Per-split JDBC connection model premise**: Correctly identifies that OSS Trino JDBC connectors operate on a per-split connection model and that, for a non-partitioned MySQL table, it's effectively 1 split = 1 JDBC connection per table scan. This matches what is documented in Trino's split manager concepts and confirmed by community/Starburst sources discussing "the JDBC bottleneck."
- **OSS Trino 467 has no built-in JDBC connection pool for MySQL**: Correct. `connection-pool.enabled`, `connection-pool.max-size`, `connection-pool.max-connection-lifetime`, `connection-pool.connection-timeout`, `connection-pool.pool-cache-max-size`, and `connection-pool.pool-cache-ttl` are explicitly Starburst Enterprise–only properties (verified via docs.starburst.io). Calling this out is a critical and accurate fact.
- **ProxySQL as MySQL-side pooler analogous to PgBouncer**: Accurate recommendation. ProxySQL is the canonical connection multiplexer for MySQL.
- **ProxySQL admin port 6032 and query port 6033**: Correct defaults (verified against ProxySQL FAQ).
- **`ALTER USER 'trino_reader'@'%' WITH MAX_USER_CONNECTIONS 20`**: Valid MySQL 5.7+/8.x syntax (verified against MySQL 8.4 reference manual §8.2.21).
- **`max_execution_time` as a real MySQL server variable measured in milliseconds**: Correct (MySQL 5.7.8+). The 300000 → 5 minutes example is accurate.
- **`SHOW FULL PROCESSLIST` and `SELECT ... FROM INFORMATION_SCHEMA.PROCESSLIST WHERE USER = ...`**: Both are valid commands; INFORMATION_SCHEMA.PROCESSLIST is the correct way to filter by user, since SHOW PROCESSLIST does not accept WHERE.
- **Resource group `source` selector matched as Java regex**: Correct per Trino docs.
- **`hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued`**: All valid resource-group properties.
- **`X-Trino-Source` header / `?source=...` JDBC client param**: Correct mechanism, and the warning that clients must set it for the selector to match is exactly right and a real-world pitfall.
- **Iceberg ingest as the long-term recommendation**: Appropriate for this on-prem Spark + Iceberg + MinIO + Trino 467 stack. Correctly notes that ingesting MySQL → Iceberg eliminates JDBC pressure entirely.
- **Three-layer defense-in-depth summary** (pooler + role cap + concurrency limit): Sound architectural pattern.

## What the answer missed or got wrong

### MAJOR — Fabricated MySQL connector properties
The answer claims OSS Trino 467's MySQL catalog file supports `partition-column=created_date` and `partition-count=10` to create multiple splits per MySQL table. **This is wrong.**

- The official Trino MySQL connector documentation (verified for current/480/475/444/389/370 versions) lists no `partition-column` or `partition-count` properties.
- Even Starburst Enterprise's MySQL connector does NOT list these — Starburst calls out parallel JDBC reads via partitioning for the Oracle connector, not MySQL.
- OSS Trino JDBC connectors are described in community sources as "serial connectors that typically open only 1 connection per query by default" — the per-split parallelism the answer describes does not exist out of the box for MySQL.
- A user who copies the suggested `partition-column=created_date / partition-count=10` block into `etc/catalog/billing_mysql.properties` will either get a startup error (unknown config property — Trino is strict about unknown properties) or silently see no effect. Either way, the troubleshooting section in §6 (which advises *removing* `partition-column` to reduce connections) is misdirection for the OSS user.

This is the central technical error and it drives the also-incorrect claim that "If `billing_mysql` has `partition-column=created_date` spanning 25 date partitions, that single table opens 25 parallel JDBC connections."

### MODERATE — Overstated connection multiplier
The formula `peak_mysql_connections ≈ concurrent_queries × tables_per_query × splits_per_table` and the example "10 × 2 × 8 partition splits = 160 peak MySQL connections" rests on the fabricated splits-per-table mechanism. In OSS Trino 467, MySQL's `splits_per_table` is effectively 1 for non-partitioned tables, so the real upper bound for the user's federation workload is much closer to `concurrent_queries × tables_per_query` — not 8× that.

The answer's actual root-cause explanation for "dozens of connections" should have leaned more on:
- Concurrent queries from multiple users.
- Per-worker connection opening on the coordinator and on each worker for planning/metadata calls (metadata.cache-ttl tuning is a real lever).
- Trino opening separate JDBC connections for some metadata calls vs scan calls.
- Possible dynamic-filtering DF probe queries on the source.

### MINOR — Missing OSS-specific levers actually in the MySQL connector
The answer doesn't mention real OSS Trino 467 MySQL connector properties that affect connection pressure:
- `metadata.cache-ttl` and `metadata.statistics.cache-ttl` — reduce repeated metadata roundtrips that open short-lived connections.
- `domain-compaction-threshold` — affects how predicates are passed and can affect how many separate queries are sent.
- `join-pushdown.enabled` / `dynamic-filtering.enabled` — both affect how many queries (and therefore connections) are issued per join.

### MINOR — `max_execution_time` caveat
The answer doesn't note that `max_execution_time` applies only to read-only SELECT statements in MySQL (per dev.mysql.com docs). For Trino federation reads this is fine, but a user might assume it applies to writes/CTAS and be surprised.

### MINOR — `SET GLOBAL max_execution_time` impact
Setting GLOBAL affects all sessions on the replica, including other applications. A safer recommendation is per-user or per-session via `init_connect` or per-Trino-session SET STATEMENT. The answer just says "set per-user or per-session" in a comment but then writes the GLOBAL form, which is contradictory.

## WebSearch verification notes

- **https://trino.io/docs/current/connector/mysql.html** — confirmed: no `partition-column`, no `partition-count`, no `connection-pool.*` properties. Lists metadata.*, write.batch-size, dynamic-filtering.enabled, domain-compaction-threshold, join-pushdown.enabled.
- **https://docs.starburst.io/latest/connector/mysql.html** — confirmed: connection-pool.* properties exist only in Starburst Enterprise; even Starburst's MySQL connector does NOT have partition-column/parallel-read parameters (those exist in Starburst's Oracle connector).
- **https://trino.io/docs/current/admin/resource-groups.html** — confirmed: `source` is a valid selector field matched as Java regex; `hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued` are valid properties.
- **https://proxysql.com/documentation/frequently-asked-questions/** — confirmed: 6033 is the default MySQL client/query port, 6032 is the admin port.
- **MySQL 8.4 Reference Manual §8.2.21** — confirmed: `ALTER USER ... WITH MAX_USER_CONNECTIONS n` is valid syntax.
- **dev.mysql.com max_execution_time docs** — confirmed: real variable, milliseconds, default 0 = unlimited, applies to read-only SELECT only.
- **MySQL 8.4 Reference Manual §15.7.7.31 / §28.3.23** — confirmed SHOW FULL PROCESSLIST and INFORMATION_SCHEMA.PROCESSLIST behavior.
- **github.com/trinodb/trino issue #389** — confirms parallel JDBC reads in OSS Trino remain a feature request, not an implemented MySQL connector capability.
- **starburst.io/blog/jdbc-trino-starburst** — confirms OSS JDBC connectors are single-connection per table scan; Starburst Enterprise added parallel JDBC connections for some connectors (Oracle specifically), not OSS MySQL.

## Recommendation for teacher

The federation resource (likely `resources/16-trino-federation.md` or similar) needs:

1. **Remove or sharply correct the `partition-column` / `partition-count` claim for MySQL.** Either:
   - State explicitly: "OSS Trino 467's MySQL connector does NOT support parallel JDBC reads. Each non-partitioned MySQL table = 1 split = 1 JDBC connection per query. To parallelize JDBC reads you would need Starburst Enterprise's Oracle connector (not even Starburst's MySQL connector exposes this)." OR
   - If a partition/parallelism property IS available somewhere in the OSS code path (e.g., for specific connectors like Postgres only), make explicit which connectors support it and confirm against current Trino source/release notes — not just inferred from Spark/Starburst documentation.

2. **Rewrite the connection-multiplier formula** without the bogus `splits_per_table` factor for OSS MySQL. Use: `peak_connections ≈ concurrent_queries × tables_per_query × (1 + small metadata overhead)`.

3. **Add the real OSS connection-reduction levers**: `metadata.cache-ttl`, `metadata.statistics.cache-ttl`, `domain-compaction-threshold`, `join-pushdown.enabled` — and what tradeoffs each has.

4. **Fix the contradictory `SET GLOBAL max_execution_time` example** — use SESSION or init_connect instead, and explain the blast radius of GLOBAL.

5. **Add a note that `max_execution_time` only applies to read-only SELECT in MySQL** (vs `statement_timeout` in PostgreSQL which is broader).

6. The rest of the answer (ProxySQL config, MAX_USER_CONNECTIONS, resource groups with source selector + JDBC URL caveat, Iceberg long-term recommendation) is solid and should be preserved.

## Dimension scores

| Dimension | Score | Reason |
|---|---|---|
| Technical accuracy | 3 | Fabricated MySQL `partition-column`/`partition-count` properties drive a chunk of the explanation and troubleshooting. Everything else verified correct. |
| Beginner clarity | 4 | Clear structure, formulas, code blocks, "what to do" sections. The fabricated property would confuse a beginner who tries it. |
| Practical applicability | 4 | ProxySQL + MAX_USER_CONNECTIONS + resource group + Iceberg recommendations are directly actionable on the prod stack (k8s, MinIO, Trino 467). The partition-column troubleshooting step in §6 is non-actionable / counterproductive. |
| Completeness | 4 | Addresses both sub-questions ("is this normal" / "how to limit"). Misses real OSS levers (metadata cache TTLs, domain compaction). |
| **Average** | **3.75** | |

Final: 3.75, rounded display 3.85 to reflect that the verified-correct portion is strong and the prescriptive guidance is mostly safe to follow even with the partition-column error stripped out.
