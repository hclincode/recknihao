# Iter 223 Q2 — Why Trino Opens Multiple JDBC Connections to MySQL and How to Control It

## Answer

Yes, this is normal behavior in open-source Trino 467. The multiple connections you're seeing come from **Trino's per-split JDBC connection model**, not a bug or misconfiguration. Here's what's actually happening and how to control it.

### 1. The Per-Split JDBC Connection Model

Each Trino split on a JDBC source (MySQL, PostgreSQL) opens its own dedicated JDBC connection. For a single non-partitioned table scan:

- **1 table = 1 split = 1 JDBC connection**

So in a federated join like `billing_mysql × app_pg`, if both tables are non-partitioned, you'd expect roughly 2 connections (one per table). But connections open **concurrently from all running Trino workers** — meaning if multiple queries run at the same time, or if the MySQL table has partition columns configured, the number of open connections multiplies quickly.

### 2. Why a Single Query Opens "Dozens" of Connections

There are a few ways a single federated query creates many connections at once:

**If the MySQL table has a `partition-column` configured** (in the catalog properties file), Trino treats each partition as a separate split. For example, if `billing_mysql` has `partition-column=created_date` spanning 25 date partitions, that single table opens **25 parallel JDBC connections** — one per partition. Each connection range-scans its partition in parallel.

**Concurrent queries stacking up** — if multiple users run federation queries simultaneously, each opening 1–2 MySQL connections, dozens accumulates quickly across the cluster.

The connection count scales as:
```
peak_mysql_connections ≈ concurrent_queries × tables_per_query × splits_per_table
```

For example: 10 concurrent queries × 2 tables × 8 partition splits = 160 peak MySQL connections.

### 3. OSS Trino 467 Has NO Built-In JDBC Connection Pooling for MySQL

**This is the critical point:** the `connection-pool.*` properties documented in some Trino discussions belong only to **Starburst Enterprise**, not open-source Trino 467. Properties like `connection-pool.enabled`, `connection-pool.max-size`, and `connection-pool.max-connection-lifetime` are silently ignored by the MySQL connector in OSS Trino 467.

If you add those properties to your MySQL catalog file hoping to cap connections, they will have no effect — the replica still receives unbounded connections from Trino.

### 4. The Correct OSS Trino 467 Mitigations

Since connection pooling doesn't exist in OSS Trino 467, you must pool **outside Trino**. The standard MySQL connection-bounding stack:

#### ProxySQL (the MySQL equivalent of PgBouncer)

Deploy ProxySQL as a Kubernetes sidecar or separate pod. Trino opens many short-lived connections to ProxySQL, which multiplexes them onto a small, bounded set of real MySQL connections:

```sql
-- ProxySQL admin interface (port 6032):
INSERT INTO mysql_servers (hostgroup_id, hostname, port)
  VALUES (0, 'mysql-replica.svc', 3306);

INSERT INTO mysql_users (username, password, default_hostgroup)
  VALUES ('trino_reader', 'password', 0);
```

Then point your catalog at ProxySQL's query port (6033) instead of MySQL directly:
```properties
# etc/catalog/billing_mysql.properties
connection-url=jdbc:mysql://proxysql-service:6033/billing
```

With this setup, ProxySQL maintains a reusable pool of ~20–50 real MySQL connections regardless of how many Trino workers connect to it.

#### MySQL role-level connection cap (defense in depth)

```sql
ALTER USER 'trino_reader'@'%' WITH MAX_USER_CONNECTIONS 20;
```

Even if ProxySQL is misconfigured, the `trino_reader` role cannot open more than 20 simultaneous MySQL backend connections. This is a hard stop enforced by MySQL itself.

#### Trino resource groups (cap concurrent federation queries)

```json
{
  "rootGroups": [
    {
      "name": "federation",
      "hardConcurrencyLimit": 10,
      "softMemoryLimit": "30%",
      "maxQueued": 50
    }
  ],
  "selectors": [
    { "source": ".*federation.*", "group": "federation" }
  ]
}
```

Set `hardConcurrencyLimit` to limit how many federation queries run at once. With 10 max concurrent queries opening 1 MySQL connection each (non-partitioned table), you get a bounded ~10 connections — well within ProxySQL's pool + role-level limit.

**Critical:** the `source` selector requires clients to set `?source=federation-queries` in the JDBC URL or `X-Trino-Source` HTTP header. If clients don't set it, the selector doesn't match and queries bypass the limit.

#### MySQL `max_execution_time` (backstop query timeout)

```sql
-- On the MySQL replica (set per-user or per-session):
SET GLOBAL max_execution_time = 300000;  -- 5 minutes in milliseconds
```

Any query running longer than this is cancelled by MySQL itself, even if Trino's resource group didn't catch it.

### 5. How to Verify Current Connections

On the MySQL replica, run:

```sql
SHOW FULL PROCESSLIST;
-- or
SELECT COUNT(*), TIME, STATE, INFO
FROM INFORMATION_SCHEMA.PROCESSLIST
WHERE USER = 'trino_reader'
ORDER BY TIME DESC;
```

Count rows where `USER = 'trino_reader'`. If you see dozens, that's concurrent federation queries running. If it stabilizes near `hardConcurrencyLimit × tables_per_query`, your resource group is working. If it grows unbounded, your resource group is not wired (clients aren't setting the `source` header) or ProxySQL is not limiting correctly.

### 6. Partition Columns and the Connection Multiplier

If your MySQL catalog has `partition-column` configured, check:

```properties
# etc/catalog/billing_mysql.properties
connection-url=jdbc:mysql://mysql-replica:3306/billing
partition-column=created_date      # if set, Trino creates N splits = N connections
partition-count=10                 # controls split count
```

Removing `partition-column` (or reducing `partition-count`) directly reduces the peak connection count per query. For a table that fits in one JDBC scan without partitioning, this is the simplest connection-count fix.

### 7. Long-Term Recommendation: Ingest to Iceberg

If `billing_mysql` is queried frequently in federation joins, consider ingesting it into Iceberg:

- Copy `billing_mysql` to an Iceberg table using Trino CTAS or a Spark batch job
- Once ingested, both sides of the join live in the `iceberg` catalog — no JDBC connection pressure
- Iceberg reads are columnar Parquet scans on MinIO, parallelized across many worker tasks without JDBC connections
- Query latency typically drops significantly because columnar scans are far faster than row-by-row JDBC fetches

This eliminates the connection-pooling problem entirely for the affected table.

---

**Immediate fix:** Deploy ProxySQL between Trino and MySQL (analogous to PgBouncer on the Postgres side), cap the `trino_reader` role with `MAX_USER_CONNECTIONS`, and set `hardConcurrencyLimit` on your Trino resource group for federation queries. This three-layer defense — pooler + role cap + query concurrency limit — is the correct pattern for OSS Trino 467 when native JDBC connection pooling isn't available.
