# Iter249 Q2 — Cross-Catalog Join Limits: Iceberg + Postgres + MySQL

## Answer

You're asking three important questions: whether there are hard limits on cross-catalog joins, what the "1 split" means for performance, and how to improve your query. There are no hard limits on joining three different data sources in one query — but your slow performance is expected given your data sources.

### There are NO hard limits on cross-catalog joins

Trino's federated query engine can join across as many different catalogs as you want in one statement. A "7-way JOIN" across PostgreSQL, MySQL, and Iceberg catalogs simultaneously is a documented real-world example — three sources is well within the normal operating range.

**However**, there IS a practical limit that gets hit earlier: **query planning time**. When Trino plans a federated query with multiple JDBC connectors, the coordinator must fetch metadata and statistics from each source. A complex multi-way join across three catalogs can spend 4–8 minutes just in planning before execution starts. Raise the planning-time limit in `etc/config.properties`:

```properties
query.max-planning-time=15m
```

### The "1 split" issue: why Postgres and MySQL show 1 split per table

This is the critical architectural constraint. Both PostgreSQL and MySQL connectors (both JDBC-based in Trino 467) use a model where **each table produces exactly 1 split**:

- **1 split = 1 JDBC connection = 1 Trino worker thread** reading all rows sequentially
- No matter how large the tables or how many workers you have, **only one worker reads each JDBC table at a time**
- There is **no parallel JDBC read** option in open-source Trino 467 — Spark's `partitionColumn`/`numPartitions` parameters don't exist in Trino
- This is tracked as [trinodb/trino#389](https://github.com/trinodb/trino/issues/389), open since 2019

**This is completely normal** — "1 split" for Postgres and MySQL is expected behavior, not a bug.

### Your actual performance problem

Given you're joining Iceberg (parallelizes across many workers) + Postgres + MySQL (both single-split):

1. **Planning overhead**: Coordinator spends time collecting statistics from Postgres and MySQL before execution starts
2. **JDBC scan bottleneck**: A single JDBC connection reading millions of rows is inherently slow — typically 50K–200K rows/second depending on row width and network

### How to improve performance: three strategies

**Option 1: Dynamic Filtering (best for small dimension tables)**

If either your Postgres or MySQL table is small (a "dimension" table) and Iceberg is the large fact table, make the small table the **build side** of the join. Trino derives an IN-list from the join keys and pushes it into the Iceberg scan, letting Iceberg skip entire Parquet files:

```properties
# etc/catalog/iceberg.properties
dynamic-filtering.enabled=true
dynamic-filtering.wait-timeout=20s
```

Verify with `EXPLAIN ANALYZE VERBOSE` — look for `dynamicFiltersProduced` in the output.

**Option 2: Snapshot MySQL/Postgres tables into Iceberg**

If you're querying these tables repeatedly, snapshot them into Iceberg nightly or hourly via Spark or CDC. Once in Iceberg on MinIO, the join parallelizes across all workers. This is the production-correct path for any JDBC table you scan more than a few times.

**Option 3: Keep JDBC sources small**

If your Postgres and MySQL tables are naturally small (under ~5 million rows), single-split reads are fast enough. Keep them as the build side of the join.

### JDBC connection tuning

For Postgres (`etc/catalog/app_pg.properties`):
```properties
connection-url=jdbc:postgresql://replica:5432/db?defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
metadata.cache-ttl=60s
```

For MySQL (`etc/catalog/billing_mysql.properties`):
```properties
connection-url=jdbc:mysql://replica:3306/db?defaultFetchSize=1000&useCursorFetch=true&socketTimeout=60000&connectTimeout=10000
metadata.cache-ttl=30s
```

**Critical difference**: MySQL `socketTimeout` is in **milliseconds** (60000 = 60 seconds), while Postgres is in **seconds** (60 = 60 seconds). Using the Postgres value in MySQL sets a 60-millisecond timeout that kills every query instantly.

### Summary

- **No hard limit on joining three catalogs** — fully supported
- **"1 split" for Postgres/MySQL is expected** — architectural fact, not a config error
- **Performance is real** — serial JDBC bottleneck + planning overhead from multiple JDBC sources
- **Best fixes**: dynamic filtering (if one source is a small dimension), snapshot to Iceberg (for repeated queries), or keep JDBC tables small
