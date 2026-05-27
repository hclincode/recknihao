# Iter 229 Q2 — MySQL "Too Many Connections" at High Concurrency

## Answer

Trino's MySQL connector in open-source Trino 467 has no built-in connection pooling. And no, this is not something you configure in Trino — it's a limitation of the connector itself. The solution requires adding a connection pooler in front of MySQL, not changing Trino.

### Why this happens

When Trino runs a query against your MySQL catalog, it opens a JDBC connection for each table being scanned. Under high concurrency, when many dashboard queries run simultaneously, those connections pile up rapidly. If you have 10 concurrent queries each hitting 2 MySQL tables, that's potentially 20 connections all at once. Scale that across your peak hour, and you hit MySQL's `max_connections` limit.

### The wrong path (things that don't work)

You might have seen properties like `connection-pool.enabled`, `connection-pool.max-size`, or `connection-pool.max-connection-lifetime` in some documentation. **Do not add these to your MySQL catalog config file** — they belong to Starburst Enterprise (a commercial fork), not open-source Trino 467. Trino will silently ignore them, and your "too many connections" problem will persist.

### The right solution: ProxySQL

The correct approach is to deploy **ProxySQL** — a MySQL-native connection pooler that sits between Trino and MySQL. Think of it as an intermediary that accepts many short-lived connections from Trino and multiplexes them onto a smaller, bounded set of long-lived connections to your MySQL instance.

**How to configure it:**

1. **Deploy ProxySQL** as a Kubernetes Deployment in your cluster, pointing at your MySQL replica. Do not connect Trino directly to MySQL anymore.

2. **Update your Trino MySQL catalog file** to point at ProxySQL instead:
   ```properties
   # OLD (direct to MySQL, causes "too many connections"):
   connection-url=jdbc:mysql://mysql-replica.internal:3306/billing
   
   # NEW (through ProxySQL):
   connection-url=jdbc:mysql://proxysql.internal:3306/billing
   ```

3. **Configure ProxySQL's connection pool** to cap the actual MySQL connections. A typical setup for a 20-worker cluster: ProxySQL accepts up to 1000 client connections (from Trino) but maintains only 50–100 real backend connections to MySQL.

### Layered protection (do all three)

Once ProxySQL is in place, add defense-in-depth guards:

1. **MySQL user-level cap**: Create a dedicated MySQL user for Trino with a hard connection limit:
   ```sql
   CREATE USER trino_reader@'%' ... WITH MAX_USER_CONNECTIONS 50;
   ```
   If anything goes wrong (ProxySQL misconfigured, a stray direct connection), MySQL itself rejects the 51st connection.

2. **Trino resource groups**: Limit how many federation queries can run concurrently against the `billing_mysql` catalog. Fewer concurrent queries = fewer simultaneous MySQL connections, regardless of pooling:
   ```json
   {
     "name": "federation_mysql",
     "hardConcurrencyLimit": 10
   }
   ```
   At most 10 queries run at once; the rest queue.

3. **MySQL `max_execution_time`**: Set a statement timeout on your MySQL read replica to kill long-running queries before they accumulate.

### Peak connection math (for capacity planning)

With ProxySQL in front:
```
Peak connections to MySQL ≈ concurrent_federation_queries × mysql_tables_per_query
```

With `hardConcurrencyLimit = 10` and 2 MySQL tables per query: **10 × 2 = 20 peak connections**. ProxySQL's pool size should be set higher (50–100) to buffer normal variance.

### Quick checklist

- Deploy ProxySQL between Trino and MySQL
- Update your Trino catalog `connection-url` to point at ProxySQL
- Set ProxySQL's `default_pool_size` to match your expected peak load
- Add a MySQL user-level `MAX_USER_CONNECTIONS` cap
- Use Trino resource groups (`hardConcurrencyLimit`) to cap concurrent queries
- Do not add `connection-pool.*` properties to your catalog file — that won't work in OSS Trino 467
