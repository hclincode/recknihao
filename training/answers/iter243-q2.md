# Iter243 Q2 — Query Cancellation + ProxySQL vs PgBouncer

## Query Cancellation on PostgreSQL

When you cancel a Trino query (either via timeout or manual user cancellation), here's what happens on the PostgreSQL side:

**The clean path — JDBC cancellation signal:**

Trino sends an explicit cancel signal to PostgreSQL. When a Trino worker running a federated query receives a cancellation (from the coordinator), it calls `Statement.cancel()` on any open JDBC statements it owns. PostgreSQL then receives this JDBC cancel message and **terminates the backend process** servicing that connection's in-flight query. You can verify the cleanup from the Postgres side by running:

```sql
SELECT * FROM pg_stat_activity WHERE usename = 'trino_reader';
```

The row for the cancelled query disappears within seconds. **There is no zombie connection risk for properly cancelled queries** — the JDBC cancel mechanism cleans them up deterministically.

**The edge case — connection just hangs:**

If a Trino worker dies abruptly (JVM OOM kill, Kubernetes pod eviction), the `Statement.cancel()` path never fires. The PostgreSQL backend keeps running until a backstop fires:
- PostgreSQL's `tcp_keepalives_idle` (default 2 hours — too long)
- PostgreSQL's `statement_timeout` (your Postgres-side safety net)
- PostgreSQL's `idle_in_transaction_session_timeout`

## Statement Timeout as a Backstop

Set a `statement_timeout` on the `trino_reader` role as a final safety net. This kills any query running longer than the limit, **even if Trino's JDBC cancel hasn't fired yet**:

```sql
ALTER ROLE trino_reader SET statement_timeout = 1800000;  -- 1800000 ms = 30 minutes
```

When `statement_timeout` fires on the Postgres side, you'll see this error in Trino's failure logs: `ERROR: canceling statement due to statement timeout`.

## Connection Pooling: PgBouncer for PostgreSQL, ProxySQL for MySQL

Here's the critical difference between your two databases:

**PostgreSQL: PgBouncer**

OSS Trino 467 has no native connection pooling for the PostgreSQL connector. Deploy **PgBouncer** between Trino and PostgreSQL. PgBouncer multiplexes many short-lived Trino connections onto a small, bounded set of real PostgreSQL backend connections.

Point Trino at PgBouncer (not Postgres directly):

```properties
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0
```

The `prepareThreshold=0` is critical when using PgBouncer in transaction-pooling mode — it disables server-side prepared statements, preventing the "prepared statement does not exist" error that occurs when PgBouncer reuses a backend for a different client.

Minimal PgBouncer config (`pgbouncer.ini`):

```ini
[pgbouncer]
pool_mode = transaction
max_client_conn = 1000        # connections from Trino
default_pool_size = 50        # actual backend conns to Postgres
auth_file = /etc/pgbouncer/userlist.txt
```

Set a matching role-level cap on PostgreSQL:
```sql
ALTER ROLE trino_reader CONNECTION LIMIT 50;
```

**MySQL: ProxySQL (NOT PgBouncer)**

This is the critical difference. **PgBouncer does not work for MySQL** — it's PostgreSQL-specific. For MySQL, use **ProxySQL**, which is the MySQL-native connection pooler. It sits between Trino and MySQL exactly the way PgBouncer sits between Trino and Postgres.

The configuration pattern is identical: ProxySQL multiplexes Trino's connections onto a bounded pool of real MySQL backend connections.

The full connection-bounding stack for MySQL:
1. **ProxySQL in front of MySQL** — multiplexes Trino's connections onto a bounded pool
2. **MySQL role-level connection cap**: `CREATE USER trino_reader@'%' ... WITH MAX_USER_CONNECTIONS 20;`
3. **Trino resource groups** — cap concurrent queries touching your MySQL catalog
4. **MySQL `max_execution_time`** — MySQL's equivalent of Postgres `statement_timeout`, **but in MILLISECONDS** (`SET GLOBAL max_execution_time = 300000` for 5 minutes; NOT `300` which would be 300 ms and kill every query instantly)

The reason the tools differ: PgBouncer is built specifically for PostgreSQL's protocol. MySQL's protocol and session model are different enough that you need ProxySQL, which understands MySQL's wire protocol.

## Summary

| | PostgreSQL | MySQL |
|---|---|---|
| **When Trino cancels** | JDBC cancel fires; Postgres backend terminates cleanly | Same — JDBC cancel terminates MySQL session |
| **When worker crashes** | `statement_timeout` backstop required | `max_execution_time` backstop required |
| **Connection pooler** | **PgBouncer** (transaction mode + `prepareThreshold=0`) | **ProxySQL** (PostgreSQL-specific; PgBouncer won't work) |
| **Role-level cap** | `ALTER ROLE trino_reader CONNECTION LIMIT N` | `WITH MAX_USER_CONNECTIONS N` |

When a dashboard user cancels their Trino query: Trino sends JDBC cancel, the database kills the backend query, and the connection returns to the pooler (PgBouncer or ProxySQL). Fast, clean, repeatable — as long as you have the poolers deployed.
