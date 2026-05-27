# Iter 231 Q1 — MySQL Reads Slow Even for Small Tables (Per-Split Model)

## Answer

### The Root Cause: No Parallelization for Non-Partitioned JDBC Tables

Trino's JDBC connectors (which MySQL uses) **do not parallelize reads across multiple workers the way Iceberg does**. The exact mechanism:

**For non-partitioned MySQL tables, Trino creates exactly one split (one logical piece of work), which means:**
- One split = one worker task = **one JDBC connection to MySQL**
- Even if you have 50 Trino workers available, only **one worker is doing the MySQL read**
- The other 49 workers sit idle during the table scan

This is fundamentally different from Iceberg: when Iceberg has many Parquet files, Trino can open hundreds of splits and process them in parallel across all workers. MySQL sends all its data through a single connection, so you get no parallelization regardless of table size or how many workers you have.

**Why the WHERE clause doesn't help much**: Even with a WHERE clause that returns 5,000 rows instead of 50,000, you still have one split accessing one connection. The filter either happens after Trino reads from MySQL (pulled to worker memory) or is pushed down to MySQL — but either way, you're limited by the throughput of that single JDBC socket.

### Diagnostics: Confirm the Bottleneck

```sql
EXPLAIN ANALYZE
SELECT <your_columns>
FROM mysql_catalog.database.your_table t
JOIN iceberg.analytics.some_fact_table f ON t.id = f.id
WHERE <your_filter>;
```

Look at the MySQL side of the output:
- **`Physical Input:` bytes** — how much data Trino actually read from MySQL
- **`CPU:` vs `Scheduled:`** — if Scheduled is much higher than CPU, the worker is blocked waiting on the network socket. This is the smoking gun.
- **Task count** — count how many worker tasks touched the MySQL table. It should be 1, not your worker count.

If you see one task handling all the bytes while 49 other workers are idle, that's the parallelization bottleneck.

### Concrete Mitigations

**1. Enable MySQL-side partitioning (if your schema supports it)**

The MySQL connector supports a `partition-column` property that tells Trino to split the scan into N parallel ranges:

```properties
# etc/catalog/mysql_catalog.properties
connector.name=mysql
connection-url=jdbc:mysql://mysql-replica:3306/database
connection-user=trino_reader
connection-password=${ENV:MYSQL_PASSWORD}

# Split the table into 10 ranges based on customer_id
partition-column=customer_id
partition-num-partitions=10
partition-lower-bound=1
partition-upper-bound=10000
```

**Important caveats:**
- The partition column **must be numeric** (not a string/VARCHAR).
- Trino will open `partition-num-partitions` parallel connections to MySQL — budget your connection pool accordingly.
- Works best when your partition column has **even distribution**. Skewed data means skewed splits.

**2. Pre-aggregate or denormalize on the MySQL side**

Create a materialized summary table on MySQL and join against that instead:

```sql
-- On MySQL: create a rolled-up table
CREATE TABLE customer_summary AS
SELECT customer_id, account_name, plan_tier, COUNT(*) AS event_count
FROM raw_customers
GROUP BY customer_id, account_name, plan_tier;
```

Trino still gets one split, but that split covers far fewer rows.

**3. Increase JDBC fetch size**

This doesn't fix parallelization but reduces round-trips on the single connection:

```properties
connection-url=jdbc:mysql://mysql-replica:3306/database?defaultRowFetchSize=5000&socketTimeout=60000&connectTimeout=10000
```

- `defaultRowFetchSize=5000` — fetch 5000 rows per network round-trip (default is much lower). Reduces round-trips, uses more memory.
- `socketTimeout=60000` — 60-second timeout. Note: **MySQL Connector/J uses MILLISECONDS** (unlike PostgreSQL which uses seconds). `socketTimeout=60000` = 60s, NOT `socketTimeout=60`.

**4. Cache the MySQL data in Iceberg if it's reference/dimension data**

If the MySQL table is a slowly-changing dimension (e.g., customer master data updated weekly), periodically ingest it into Iceberg:

```sql
-- Run nightly via Trino or Spark
CREATE TABLE iceberg.analytics.customers_snapshot AS
SELECT * FROM mysql_catalog.database.customers;
```

Then join against the Iceberg copy. Now Trino can parallelize the read across all workers.

### Why Is This By Design?

Trino treats JDBC connectors (MySQL, PostgreSQL) as **live OLTP databases**, not big-data stores. The assumptions:
- These tables are small-to-medium (thousands to millions of rows, not billions).
- Opening too many connections to a live OLTP database would overwhelm it.
- You're doing real-time federated joins, not analytical scans of massive tables.

For your case — joining Iceberg fact tables (which parallelize beautifully) against MySQL dimensions (which don't) — the mitigations above are the production-standard solutions.

### Quick Checklist

- Use `EXPLAIN ANALYZE` to confirm one MySQL split is the bottleneck
- Try MySQL-side partitioning if your schema has a numeric column you can range-scan
- Pre-aggregate or denormalize the MySQL table if it's a dimension
- Cache the MySQL data in Iceberg if it's reference data that doesn't change continuously
- Increase `defaultRowFetchSize` to reduce round-trips (MySQL Connector/J, in milliseconds)
- Always query a **read replica**, never the OLTP primary
