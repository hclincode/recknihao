# Iter263 Q2 Score

Score: 4.8

## Verdict
PASS (PASS = 4.5+)

## Strengths
- Correctly states that OSS Trino's PostgreSQL connector has **no built-in JDBC connection pooling** and explicitly flags `connection-pool.enabled` / `connection-pool.max-size` as Starburst Enterprise-only properties. Verified against Starburst docs and Trino GitHub issue #15888 — the OSS connector lacks this feature, while Starburst's enhanced connector exposes `connection-pool.enabled`.
- Connection-per-split model is accurate: the Trino JDBC framework opens one JDBC connection per table scan / split, not one per worker or one per query. This matches official guidance describing the same connection pressure pattern.
- PgBouncer recommendation is the canonical production fix for capping connections. `pool_mode=transaction` is the right pool mode for federation workloads.
- **`prepareThreshold=0` is correctly identified as mandatory** for PgBouncer transaction mode. The explanation (Postgres server-side prepared statements are session-scoped, PgBouncer transaction mode reuses backend connections) is technically accurate and matches the pgjdbc / PgBouncer FAQ guidance.
- Defense-in-depth layering (PgBouncer pool size + Postgres `CONNECTION LIMIT` per role + Trino resource group `hardConcurrencyLimit` + `statement_timeout`) is excellent practical guidance. `hardConcurrencyLimit` verified as a valid concurrency throttle in Trino docs.
- Concrete numbers tied to the user's exact situation (60 used, 40 left, reserve 10, give Trino 30) make the advice immediately actionable.
- Catalog file example with `connection-url` parameters is production-quality. Uses `${ENV:...}` for secrets which is current Trino best practice.
- Fits the production environment well: on-prem k8s, Trino 467, MinIO/Iceberg side untouched, no cloud-only tools recommended.

## Gaps / Errors
- Minor: The formula `peak_postgres_connections ≈ concurrent_queries × tables_per_query × splits_per_table` is a reasonable heuristic but the "10–20 concurrent single-table federation queries" upper bound is hand-wavy — a single Postgres scan typically produces one split (no split parallelism unless `parallel-mode` is enabled in newer Trino versions), so the math is closer to 40 concurrent single-table queries. Not a critical error, just conservative.
- Could briefly mention that Trino 467's PostgreSQL connector does have **parallel reads** via `postgresql.parallel-mode` (with partitioned tables), which would multiply the connection count per query — relevant to the "is it one or several?" question.
- Does not mention that connection-per-split also applies to **joins between two Postgres tables in the same query** (each side opens its own connections) — a small clarification that would tighten the answer.

## Technical accuracy notes
- Verified via WebSearch + WebFetch against https://trino.io/docs/current/connector/postgresql.html: the OSS PostgreSQL connector page documents no `connection-pool.*` properties. Confirmed.
- Verified via https://docs.starburst.io/latest/connector/postgresql.html and GitHub issue #15888: `connection-pool.enabled` is a Starburst Enterprise feature; OSS Trino users have been requesting it since 2023. Answer's claim that these properties are "silently ignored" in OSS is correct.
- Verified via https://www.pgbouncer.org/faq.html and pgjdbc issue #869: `prepareThreshold=0` is the documented JDBC fix for PgBouncer transaction-pool-mode prepared-statement errors. The mechanism explanation in the answer is correct.
- Verified via https://trino.io/docs/current/admin/resource-groups.html: `hardConcurrencyLimit` does cap concurrent running queries — valid throttle for federation traffic.
- Verified the one-connection-per-table-scan model via Trino issue tracking and Starburst docs ("JDBC connectors consume one JDBC connection per table scan").

Sources:
- [Trino PostgreSQL connector docs](https://trino.io/docs/current/connector/postgresql.html)
- [Starburst PostgreSQL connector (connection-pool.enabled)](https://docs.starburst.io/latest/connector/postgresql.html)
- [Trino issue #15888 — Enable connection pooling for PostgreSQL](https://github.com/trinodb/trino/issues/15888)
- [PgBouncer FAQ](https://www.pgbouncer.org/faq.html)
- [Trino Resource Groups docs](https://trino.io/docs/current/admin/resource-groups.html)
