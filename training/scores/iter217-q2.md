# Iter 217 Q2 Judge Score

## Score: 4.85

## Topic: Trino federation cross-source connectors

## What the answer got right

- **Leads with the critical, non-obvious fact**: OSS Trino 467's PostgreSQL connector has NO native JDBC connection pool. This is exactly right per trinodb/trino#15888 (still open as of May 2026), and it correctly attributes `connection-pool.enabled` / `connection-pool.max-size` / `connection-pool.max-connection-lifetime` to Starburst Enterprise, not OSS Trino. This is the single most important thing the engineer needs to hear, and it's the first thing on the page.
- **Correct mental model**: "one split = one connection", NOT one per worker, NOT one per query. Also correct that for a single non-partitioned Postgres table, Trino creates exactly 1 split and only one worker does the read while the others sit idle. This directly answers the engineer's literal question ("does it open one connection per query, one per worker node, or something else entirely?").
- **Correct connection-count formula**: `max_concurrent_federation_queries × avg_postgres_tables_per_query × avg_splits_per_table`. Maps cleanly to the 20–30-concurrent-user load the engineer described.
- **Correct PgBouncer recipe**: transaction pooling mode with `pool_mode=transaction`, `default_pool_size=50`, `max_client_conn=1000`, `reserve_pool_size=10`. Configuration is realistic and production-shaped.
- **`prepareThreshold=0` is mandatory and explained correctly**: in PgBouncer transaction mode, successive transactions can land on different backend connections, so server-side prepared statements registered on backend A fail on backend B with "prepared statement does not exist". The explanation matches the pgjdbc / PgBouncer behavior documented in multiple authoritative blogs and the PgBouncer FAQ.
- **Four-layer defense is the right framing**: PgBouncer + Postgres role-level CONNECTION LIMIT + Trino resource group hardConcurrencyLimit + Postgres statement_timeout. This is the canonical OSS-Trino-with-Postgres production pattern.
- **Resource group config has the right pieces**: `hardConcurrencyLimit`, `maxQueued`, `softMemoryLimit`, `schedulingPolicy=fair`, plus the critical operational warning that **clients must set the `X-Trino-Source` header or `source` JDBC param** or the selector won't match and the limit is bypassed. That second point is often missed and is important.
- **Error-message-to-layer mapping table** is excellent: turns the abstract architecture into a debug guide the engineer can actually use during an outage (`FATAL: too many connections` → Postgres native limit, `canceling statement due to statement timeout` → Postgres role timeout, `SocketTimeoutException` → JDBC socketTimeout, etc.).
- **Closes with explicit "do NOT" list**: no `connection-pool.enabled`, not one connection per worker, don't raise hardConcurrencyLimit to fix a Postgres-side exhaustion error. Anti-patterns are as load-bearing as the patterns in this topic.
- **Fits production environment**: uses `pgbouncer.app.svc.cluster.local:6432` (k8s service DNS), references catalog file in `etc/catalog/`, mentions OSS Trino 467 by name — all consistent with `prod_info.md`.

## What the answer missed or got wrong

- **Minor: read-replica framing absent.** The catalog example points at `pgbouncer.app.svc.cluster.local` but never tells the engineer to make sure PgBouncer is pointing at the **read replica**, not the OLTP primary. The resource file says this in the comment block but the answer drops it. Under a 20–30-user dashboard load, hitting the OLTP primary is a real risk.
- **Minor: no mention of PgBouncer 1.21+ native prepared-statement support in transaction mode.** As of PgBouncer 1.21 (Oct 2023), transaction mode can track prepared statements if `max_prepared_statements` > 0, which means `prepareThreshold=0` may not be strictly required on newer PgBouncer. Not a factual error — `prepareThreshold=0` is still the safe default — but it would have been a nice nuance for an engineer who might already be on PgBouncer 1.21+.
- **Minor: 1-split-per-table claim is slightly oversimplified.** For a **single non-partitioned** Postgres table the answer is correct. But Trino's JDBC connector can produce more than 1 split when the connector implements parallel reads (`split.size`, partitioned reads, etc.), and certain connectors override this. For PostgreSQL specifically, OSS Trino's behavior is single-split-per-scan today, so this is functionally correct for the engineer's case — but a careful reader will notice the resource didn't qualify it.
- **Minor: no diagnostic SQL on the Postgres side beyond the role-CONNECTION-LIMIT check.** A `SELECT count(*), state FROM pg_stat_activity WHERE usename = 'trino_reader' GROUP BY state;` query would give the engineer immediate visibility into what's currently in the pool, which is the first thing they'll want to run while debugging.
- **No mention of monitoring/observability** (PgBouncer `SHOW POOLS`, `SHOW STATS`, Prometheus exporter). This is a "what's happening before I can fix it" question, so a metrics path would have been on-topic.

None of the above are correctness errors. The answer is technically clean.

## WebSearch verification notes

Verified against trino.io official docs (current = 481) and primary sources:

1. **trinodb/trino#15888**: Still open as of May 2026. No PR linked, no resolution. OSS Trino PostgreSQL connector has **no native JDBC connection pool**. Answer correct.
2. **Starburst `connection-pool.enabled`**: Confirmed via docs.starburst.io/latest/connector/postgresql.html — this property exists in **Starburst Enterprise**, not OSS Trino. Default is disabled. Answer correct in attributing it to Starburst.
3. **One-connection-per-split model**: Consistent with the Trino JDBC connector framework (each split opens its own JDBC connection through the connection factory). Official docs don't use the phrase "one connection per split" verbatim, but the architecture matches. Answer correct in substance.
4. **`prepareThreshold=0` with PgBouncer transaction mode**: Verified against PgBouncer FAQ, Crunchy Data blog, pganalyze, and the pgjdbc driver docs. The "prepared statement does not exist" failure mode and the `prepareThreshold=0` fix are well-documented. Answer correct, including the explanation of *why*.
5. **PgBouncer 1.21+ prepared statement tracking**: Real, since Oct 2023. Answer doesn't mention it but this is a nuance, not a contradiction.
6. **Resource group `hardConcurrencyLimit` and source-based selectors**: Verified against Trino 481 resource-groups docs — the selector-source-required behavior is correct.

## Recommendation for teacher

The resource (`22-trino-federation-postgresql.md`) is already excellent for this question and the responder used it well. Two small additions would close the remaining gaps:

1. **Add a "diagnose first" subsection to §8.2** with the Postgres-side queries the engineer should run on the live problem before changing config: `pg_stat_activity` grouped by `state` + `usename`, `pg_stat_database.numbackends`, and PgBouncer's `SHOW POOLS` / `SHOW STATS` for per-pool waiters. Right now §8.2 jumps straight to fixes.
2. **Add a one-line note on PgBouncer 1.21+** in the `prepareThreshold=0` section: "If you are on PgBouncer 1.21 or newer with `max_prepared_statements > 0`, prepared statements are tracked across backends and `prepareThreshold=0` becomes optional — but keep it as the safe default unless you have a measured reason to enable server-side preparation."

Neither is critical. The current answer easily clears the raised 4.5 pass threshold for this topic; one more passing answer on a different federation angle should push the running average over the line and move the topic from NEEDS WORK to PASSED.
