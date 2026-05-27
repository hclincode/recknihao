# Score: iter243-q2 — Query Cancellation + ProxySQL vs PgBouncer

**Score: 4.8 / 5.0**

## What was correct

1. **JDBC Statement.cancel() propagation on Trino query cancel (verified)**: The answer correctly describes that when a Trino query is cancelled (timeout or user-initiated), the worker calls `Statement.cancel()` on open JDBC statements. The pgjdbc driver translates this into a PostgreSQL CancelRequest, which delivers SIGINT to the backend process — the same mechanism `pg_cancel_backend()` uses. Trino PR #7819 ("Cancel query when JDBC connection or statement is closed") confirms this is the implemented behavior. Stating the row in `pg_stat_activity` disappears within seconds is operationally accurate.

2. **Edge case where Statement.cancel() never fires (verified)**: Correctly identifies that JVM OOM kills, k8s pod evictions, and network partitions prevent the JDBC cancel from running. The list of Postgres-side backstops (`tcp_keepalives_idle`, `statement_timeout`, `idle_in_transaction_session_timeout`) is accurate. `tcp_keepalives_idle` default of 2 hours is correct for Linux.

3. **`ALTER ROLE trino_reader SET statement_timeout = 1800000` syntax (verified)**: Valid PostgreSQL syntax. `statement_timeout` units are milliseconds (1,800,000 ms = 30 min). The expected error string `ERROR: canceling statement due to statement timeout` matches what Postgres emits.

4. **PgBouncer is PostgreSQL-only (verified)**: Confirmed via pgbouncer.org — PgBouncer speaks only the PostgreSQL wire protocol. It cannot front MySQL. The hard "PgBouncer does not work for MySQL — it's PostgreSQL-specific" callout is correct and useful.

5. **ProxySQL is the correct MySQL pooler (verified)**: ProxySQL is the leading MySQL proxy with native connection pooling that multiplexes client connections onto persistent backend connections — the direct MySQL analog to PgBouncer's role.

6. **`prepareThreshold=0` for PgBouncer transaction mode (verified)**: Correct prescription for pgjdbc + PgBouncer transaction pooling on PgBouncer < 1.21. Disables the client-side switch to server-side named prepared statements, preventing the "prepared statement does not exist" error when PgBouncer reuses a backend for a different client. (Note: PgBouncer 1.21+ supports tracking prepared statements with `max_prepared_statements`, but `prepareThreshold=0` remains a safe default and is the right answer for the OSS Trino 467 + on-prem PgBouncer stack described in prod_info.md.)

7. **MySQL `max_execution_time` in milliseconds (verified)**: Confirmed at dev.mysql.com — units are milliseconds; default 0 means unlimited. The explicit warning that `SET GLOBAL max_execution_time = 300` would actually be 300 ms (and kill every query instantly) versus `300000` for 5 minutes is exactly the kind of unit-confusion bug that hits production. This is the most operationally valuable bit of the answer.

8. **MySQL `WITH MAX_USER_CONNECTIONS N` syntax (verified)**: Valid per dev.mysql.com 8.0/8.4/9.x reference manual section 8.2.21 ("Setting Account Resource Limits"). Goes after IDENTIFIED BY clause in CREATE USER. Correctly limits simultaneous connections per account.

9. **Production-stack fit**: All recommendations (PgBouncer in k8s, role-level CONNECTION LIMIT, ProxySQL, MySQL role-level cap, Trino resource groups for catalog isolation) are on-prem-k8s compatible per prod_info.md. No public-cloud-only tooling recommended.

10. **Summary table**: The 4-row comparison table at the end is genuinely useful and consolidates the two databases' differences in a way an engineer can paste into a runbook.

## What was wrong or missing

1. **MINOR — MySQL JDBC cancel claim is asserted without caveat**: The summary table row "When Trino cancels — MySQL — Same: JDBC cancel terminates MySQL session" is broadly correct (MySQL Connector/J Statement.cancel sends KILL QUERY), but the body of the answer never demonstrates this for MySQL the way it does for PostgreSQL. Asserting parity in the table without showing MySQL's KILL QUERY mechanism is a small completeness gap; an engineer who only reads the table won't know the MySQL-side cleanup verb is `SHOW PROCESSLIST` + KILL, not `pg_stat_activity`.

2. **MINOR — Trino-known ProxySQL+MySQL connector caveat omitted**: trinodb/trino issue #18279 documents that the MySQL connector cannot use ProxySQL's schema-based multi-cluster routing because the connector does not pass schema names through on the connection. For straight pooling (the question's actual use case) ProxySQL works fine, but a sophisticated answer would mention this corner case as a "if you later use ProxySQL for multi-cluster routing, watch out" note.

3. **MINOR — PgBouncer 1.21+ native prepared-statement support not mentioned**: `prepareThreshold=0` is still correct and safe, but the answer could note that PgBouncer 1.21+ supports prepared statements in transaction mode natively via `max_prepared_statements`. This is a small completeness gap, not an error.

4. **MINOR — Cancellation signal cannot interrupt a stuck backend immediately**: The Postgres backend only checks for the cancel signal at certain query checkpoints. If the backend is blocked waiting on a lock, the cancel will not take effect until that lock is acquired. The answer's "row disappears within seconds" framing is true for most cases but is slightly optimistic for lock-blocked or system-call-stuck backends. This is a nuance worth flagging in the resource for completeness.

5. **MINOR — `max_execution_time` only applies to SELECT in MySQL**: Per the MySQL docs, `max_execution_time` is SELECT-only (does NOT affect INSERT/UPDATE/DELETE/DDL). For Trino federation this is fine (Trino reads from MySQL are SELECTs), but the resource should note this scope limitation so the engineer doesn't expect it to backstop a runaway federated MERGE/INSERT.

## Verification notes

- **PgBouncer protocol scope**: pgbouncer.org and github.com/pgbouncer/pgbouncer confirm PgBouncer is PostgreSQL-protocol-only. No MySQL support. CORRECT.
- **ProxySQL as MySQL pooler**: proxysql.com, severalnines, Microsoft Azure docs all confirm ProxySQL is the canonical MySQL connection pooler with built-in pooling/multiplexing. CORRECT.
- **PostgreSQL JDBC cancel → SIGINT**: cybertec-postgresql.com confirms postmaster delivers SIGINT to the backend on receiving a CancelRequest, equivalent to `pg_cancel_backend()`. Trino PR #7819 confirms Trino JDBC connector wires Statement.cancel() into this path. CORRECT — but with the caveat that signal handling waits for the next cancellation check point in the backend.
- **MySQL `max_execution_time` units**: dev.mysql.com confirms milliseconds, GLOBAL default 0 = unlimited, SELECT-only. The answer's "300 vs 300000" warning is exactly right.
- **`WITH MAX_USER_CONNECTIONS N`**: dev.mysql.com 8.0/8.4/9.x reference manual 8.2.21 confirms exact syntax. CORRECT.
- **`prepareThreshold=0` for PgBouncer transaction mode**: Multiple sources (PgBouncer FAQ, Crunchy Data, hibernate forum, github issue #1067) confirm. Still required for PgBouncer < 1.21 with pgjdbc. CORRECT for the OSS Trino 467 on-prem stack.
- **`statement_timeout` units (milliseconds)**: PostgreSQL docs confirm milliseconds. `1800000` = 30 min is correct.

## Recommendation for teacher

The resource (`resources/22-trino-federation-postgresql.md`) appears to already cover most of these claims correctly. The answer reflects the corrections that have accumulated over prior iterations (PgBouncer + `prepareThreshold=0`, OSS-Trino-no-native-pool callout, MySQL ms-vs-seconds unit traps, ProxySQL for MySQL). To push from 4.8 to consistent 5.0 on this question family, add small clarifications:

1. **LOW — JDBC cancel mechanism for MySQL connector**: Add a brief subsection (analogous to the PostgreSQL cancel section) explaining that MySQL Connector/J's Statement.cancel() issues `KILL QUERY <thread_id>` against MySQL, and that `SHOW PROCESSLIST` is the MySQL equivalent of `pg_stat_activity` for verifying cleanup. This closes the "MySQL parity claim without demonstration" gap.

2. **LOW — PgBouncer 1.21+ native prepared-statement support**: One-line note in section 8.2A that PgBouncer 1.21+ supports prepared statements in transaction mode via `max_prepared_statements`, with `prepareThreshold=0` remaining the safer default for OSS Trino 467 on-prem until the operator confirms PgBouncer version.

3. **LOW — `max_execution_time` SELECT-only scope**: Add a single line noting that `max_execution_time` applies to SELECT only — it does NOT backstop INSERT/UPDATE/DELETE/DDL from federated Trino MERGE flows. For non-SELECT runaway protection, rely on `wait_timeout`/`interactive_timeout` and Trino-side `query.max-execution-time`.

4. **LOW — Cancel-checkpoint nuance**: One-line note in the cancellation section that the PostgreSQL backend checks for cancel signals only at certain points; a backend stuck on a lock will not exit until the lock is acquired. Setting expectations correctly avoids "I cancelled but the row is still in pg_stat_activity" support tickets.

5. **LOW — ProxySQL + Trino MySQL schema-routing caveat**: One sentence referencing trinodb/trino issue #18279: ProxySQL multi-cluster routing by schema name is NOT compatible with Trino's MySQL connector. Straight pooling/multiplexing is fine. Helps engineers who later try to use ProxySQL for sharded MySQL routing.

None of these would have meaningfully affected the score on this question — they are pre-emptive fixes for future variants of the question.
