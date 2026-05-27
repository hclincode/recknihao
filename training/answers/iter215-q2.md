# Iter 215 Q2 — Three-Source Federation Resilience: What Happens When a JDBC Source Goes Down

## Answer

## Query Failure on MySQL (or JDBC Source) Unavailability

### Immediate Failure — No Retry for JDBC Sources

When any JDBC-connected data source (MySQL, Postgres, SQL Server, Oracle) becomes temporarily unavailable **mid-query**, Trino's behavior is straightforward: **the entire query fails immediately and hard**. Here's what actually happens:

1. **Connection error occurs** (network timeout, connection refused, service down)
2. **Trino's JDBC layer catches the exception** (e.g., `SQLException` from MySQL, `PSQLException` from Postgres)
3. **The exception is propagated as a hard query failure** to the user — there is no built-in retry logic for JDBC connector failures
4. The query terminates with an error, and the user or application receives the full stack trace

This applies equally whether it's your MySQL instance going down, or any other JDBC source. **There is no graceful degradation or silent failover at the connector level.**

### Fault-Tolerant Execution (FTE) Does NOT Help Here

You might be wondering about Trino's "fault-tolerant execution" (FTE) feature (enabled with `retry-policy=TASK` or `retry-policy=QUERY`). The critical clarification from the resources:

> **FTE covers WORKER failures, NOT source unavailability.** When a Trino worker task fails (pod OOM, eviction, hardware failure), FTE retries the failed task on another worker without restarting the query. But **it does nothing to protect against a data source becoming unavailable**. If your MySQL catalog is down, FTE will not retry the query or attempt to recover.

FTE requires an exchange manager (like a file-based spill to PVC or MinIO) so intermediate shuffle results survive worker death — but again, that's for worker resilience only. It is not HA for your data sources.

### Three-Source Joins Are All-or-Nothing

**Graceful degradation is not possible for cross-catalog joins.** Here's why:

- When you write `SELECT ... FROM iceberg_table JOIN postgres_table JOIN mysql_table ON ...`, Trino's planner builds a distributed query plan that depends on **all three sources being available throughout execution**.
- The join itself executes on Trino workers (there is no cross-catalog join pushdown — MySQL and Postgres don't see the Iceberg table and vice versa).
- If MySQL becomes unavailable **after the join plan has started but before the MySQL side finishes fetching its rows**, the workers cannot proceed, and the entire query fails.
- **There is no partial-result mode.** Trino does not return rows from Iceberg and Postgres while skipping MySQL; it fails the query.

### Real Mitigation Strategies

Since federation creates an ongoing operational dependency on JDBC source availability for analytics, here are the actual approaches:

#### 1. **Reduce Dependency via Change Data Capture (CDC)**

Move the MySQL data into Iceberg on a near-real-time schedule (via Debezium + Kafka, or equivalent streaming pipeline). Once the data lands in Iceberg, your analytical queries no longer need MySQL at all — only Kafka and the streaming pipeline depend on MySQL. Benefits:

- Queries become independent of MySQL availability
- You get full Iceberg columnar performance (partition pruning, predicate pushdown)
- The dependency shifts from "all queries need MySQL available" to "data freshness depends on the streaming pipeline"

Use this if MySQL has UPDATE/DELETE traffic, or if the table is large enough that nightly full-refresh is expensive.

#### 2. **Use Batch Ingestion Instead of Federation**

For MySQL tables with append-only patterns or where hourly freshness is acceptable, run a scheduled batch job (`INSERT INTO iceberg.x SELECT * FROM mysql_catalog.x WHERE id > <last_id>`). This decouples analytics from MySQL entirely after the batch completes.

#### 3. **High Availability for the MySQL Instance Itself**

Deploy MySQL with replication, failover, and health checks so downtime is minimal. However, **do not point Trino at your MySQL primary** (same rule as Postgres) — use a dedicated read replica. Set aggressive `statement_timeout` on the replica so a runaway Trino query doesn't run forever.

#### 4. **Application-Level Retry and Graceful Messaging**

Since Trino will fail the query, **your application** must handle the failure:

- Catch the query error on the client side
- Log it with a clear message ("MySQL was unavailable; this query needs all three data sources")
- Retry after a delay, or fall back to a stale-data query if one exists
- Alert your team to restore MySQL availability

**There is no way to write the query itself to degrade gracefully.** You cannot write SQL like `SELECT ... FROM iceberg LEFT JOIN mysql ...` and expect the LEFT JOIN to return NULLs if MySQL is down — Trino will still fail the entire query if the MySQL source is unavailable.

### Summary Table

| Aspect | What happens |
|--------|---|
| **MySQL goes down mid-query** | Immediate hard failure, user sees JDBC exception |
| **Built-in retry logic** | None for JDBC sources |
| **Fault-tolerant execution** | Covers worker failures only, not source unavailability |
| **Graceful degradation** | Not possible — joins are all-or-nothing |
| **Partial results** | Trino does not return rows from available sources while skipping unavailable ones |
| **Long-term solution** | Move MySQL data to Iceberg via CDC or batch; decouple analytics from OLTP availability |
