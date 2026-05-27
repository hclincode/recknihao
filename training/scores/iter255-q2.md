# Iter255 Q2 Score

**Score: 4.9 / 5.0** — PASS (threshold: 4.5)

## What was correct
- Diagnosis is exactly right: PgBouncer transaction-pooling mode rotates backend connections between transactions, and PostgreSQL server-side prepared statements are connection-scoped, so the second backend cannot find the `PREPARE` issued on the first. The "prepared statement S_1 does not exist" symptom is correctly identified.
- Correctly explains the pgjdbc default `prepareThreshold=5` behavior (switch to server-side prepare on the 5th execution), and the resulting "fine for a while, then intermittent failure" pattern.
- Correct fix #1: set `prepareThreshold=0` in the JDBC URL (`?prepareThreshold=0`) — this is the documented and widely-recommended workaround.
- Correct fix #2: PgBouncer 1.21+ (released October 2023) added native prepared-statement tracking via `max_prepared_statements > 0` — version and configuration parameter are verified accurate.
- Connection model is correct: OSS Trino's PostgreSQL connector emits 1 split per non-partitioned table, so a single-table scan uses 1 JDBC connection on 1 worker thread; multi-table queries open one connection per table.
- Separate-pool guidance is correct: app server (session mode, prepared statements preserved) and Trino (transaction mode, `prepareThreshold=0`) should not share a pool. Concrete pattern given (different ports, or sidecar).
- The JDBC URL placement is right: `prepareThreshold=0` belongs in `connection-url` in the catalog `.properties` file. Correct format with `&` separator for additional parameters.
- Bonus material (defaultRowFetchSize, socketTimeout, connectTimeout, four-layer defense with PgBouncer pool size + Postgres role CONNECTION LIMIT + Trino resource groups + statement_timeout) is accurate and actionable for the on-prem k8s production stack.
- Catalog example uses a sensible k8s DNS name (`pgbouncer.app.svc.cluster.local:6432`) consistent with the prod environment.

## Gaps or errors
- Minor: the answer says "OSS Trino does NOT support parallel sharded reads of a single Postgres table" — strictly true for the default behavior, but Trino's PostgreSQL connector does support some parallel/partitioned reads when source-side partitioning metadata exists. Not a meaningful gap for the asked question (the user is dealing with an OLTP app DB).
- Minor: the four-layer defense table lists `hardConcurrencyLimit=10` as illustrative; in real deployments this is tuned per workload. Reader should treat numbers as starting points (the answer implies this but does not state it).
- Could briefly mention `preparedStatementCacheQueries=0` as a belt-and-suspenders option some sources recommend alongside `prepareThreshold=0`, but `prepareThreshold=0` alone is sufficient and is the canonical fix, so this omission is not a real gap.

## WebSearch verification notes
- Verified at pgbouncer.org and pgjdbc docs: `prepareThreshold=0` disables server-side prepared statements in pgjdbc (default is 5). Confirmed this is the documented workaround for PgBouncer transaction pooling.
- Verified at pgbouncer.org/2023/10/pgbouncer-1-21-0 and PostgreSQL.org announcement: PgBouncer 1.21.0 was released October 16, 2023 ("The one with prepared statements"), adding `max_prepared_statements` for transparent prepared-statement support in transaction mode. Answer's version and date are accurate.
- Verified at trino.io PostgreSQL connector docs and Trino developer/connector docs: non-partitioned JDBC tables return a single split, leading to one connection / one worker per table — exactly as the answer describes. Starburst's "dangers of the JDBC bottleneck" article corroborates the single-thread throughput characterization.
- Verified the connection-scoped nature of server-side prepared statements in Postgres (multiple sources including Crunchy Data and Tiger Data blogs) — diagnosis is correct.
