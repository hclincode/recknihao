# Iter 227 Q2 — Federated Query Timeout Layering: Trino vs MySQL vs JDBC

## Answer

When your federated queries to both the `iceberg` catalog and `billing_mysql` catalog hang for 5-10 minutes before timing out, you're dealing with **three distinct timeout layers**, each controlled separately. The vague "query was cancelled" error makes it hard to pinpoint which one is firing. Here's how to identify and configure each layer.

## The Three Timeout Layers (from outer to inner)

**1. Trino's dynamic filtering wait-timeout (outermost)**

When Trino joins Iceberg and MySQL data, it uses "dynamic filtering" — after the smaller table builds a hash table, Trino derives a filter (an IN-list of values) and tries to push it to the larger table's scan to reduce data movement. This process has a timeout:

- **Default**: 20 seconds for both `iceberg.dynamic_filtering_wait_timeout` and `billing_mysql.dynamic_filtering_wait_timeout`
- **What it does**: If the build side (smaller table) is slow and takes longer than 20s to produce filter values, Trino gives up waiting and launches the probe scan (larger table) unfiltered
- **Symptom**: Large table scan with no filter applied, pulling millions of unneeded rows

To tune this per session (the most direct way):

```sql
-- If Iceberg is the large table being scanned:
SET SESSION iceberg.dynamic_filtering_wait_timeout = '30s';

-- If MySQL is the large table being scanned:
SET SESSION billing_mysql.dynamic_filtering_wait_timeout = '30s';
```

**2. MySQL's own statement timeout (middle layer)**

MySQL has its own execution limit on the replica:

- **Default**: depends on your MySQL replica's `max_execution_time` session variable (may be unlimited if not set)
- **What it does**: MySQL aborts the query server-side if it runs longer than this limit
- **Symptom**: MySQL connection closes, Trino reports "query was cancelled" with no clear indication why

To check and set on your MySQL replica:

```sql
-- On the MySQL replica (NOT through Trino):
SELECT @@max_execution_time;  -- check current value (0 = unlimited)

-- To set a reasonable limit for analytics (5 min = 300000 milliseconds):
SET GLOBAL max_execution_time = 300000;
```

**3. JDBC socket timeout (innermost)**

The underlying JDBC connection between Trino and MySQL has a socket-level timeout that causes the connection to drop if no data arrives for N seconds:

- **Default**: 60 seconds if set via the `socketTimeout` JDBC parameter (undefined/unlimited if not set)
- **What it does**: JDBC read operation times out, connection dies, query fails
- **Symptom**: "No more data to read from socket" or connection-reset errors in Trino logs

To set this (requires coordinator restart), in `etc/catalog/billing_mysql.properties`:

```properties
connection-url=jdbc:mysql://billing-replica:3306/billing?defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
```

The `socketTimeout=60` means "fail if no data for 60 seconds." For long-running federated queries, raise this to match your expected query duration.

## Practical Troubleshooting: Which Layer Is Timing Out?

**If queries hang for ~20 seconds then start returning data but scan too much:**
→ Dynamic filtering wait-timeout hit. Raise `billing_mysql.dynamic_filtering_wait_timeout` via SET SESSION.

**If the query dies cleanly with an error after a few minutes (e.g., 5 min):**
→ MySQL's `max_execution_time` is probably 300 seconds. Check MySQL replica with `SELECT @@max_execution_time`.

**If the connection abruptly drops with a socket error after ~60 seconds of no data:**
→ JDBC `socketTimeout` is too low. Increase the `socketTimeout=` JDBC URL parameter and restart.

## Debugging: Enable MySQL Slow-Query Logging

To see exactly which layer is failing, enable slow-query logging on MySQL:

```sql
-- On MySQL replica:
SET GLOBAL long_query_time = 1;  -- log queries slower than 1 second
SET GLOBAL slow_query_log = ON;
```

When a query hangs, check the MySQL slow log to see if the query even arrived there or if it was killed before reaching the replica.

## Configuration Summary

| Layer | Setting | Default | Where to configure |
|---|---|---|---|
| **Trino dynamic filter wait** | `<catalog>.dynamic_filtering_wait_timeout` | 20s | `SET SESSION billing_mysql.dynamic_filtering_wait_timeout = '30s'` (no restart) |
| **MySQL execution time** | `max_execution_time` | 0 (unlimited) | `SET GLOBAL max_execution_time = 300000` on MySQL replica |
| **JDBC socket timeout** | `socketTimeout` JDBC parameter | not set (unlimited) | `connection-url=...?socketTimeout=60` in catalog properties (restart required) |

**Start here**: Raise the Trino dynamic filtering timeout to 30-45 seconds per session (no restart), verify whether the query still hangs, then work backward to determine which lower layer is the bottleneck. This gives you the fastest path to diagnosis without coordinating multiple restarts.
