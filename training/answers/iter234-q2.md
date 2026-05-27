# Iter 234 Q2 — Federated Queries vs Ingesting into Iceberg: When to Stop Federating

## Answer

The slowness you're seeing is **not primarily a tuning problem — it's a fundamental architectural limitation** of how Trino reads from MySQL via JDBC.

### The Core Issue: The One-Split Limitation

When Trino queries a non-partitioned MySQL table, it creates **exactly one split**. One split means one JDBC connection, one worker, one thread reading rows — even if your Trino cluster has 20 workers. All 19 other workers sit idle during that MySQL scan.

| Connector | Splits | Parallelism on a 20-worker cluster |
|---|---|---|
| **Iceberg** (10 GB table, 80 Parquet files) | 80 splits | All 20 workers in parallel |
| **MySQL** (10 GB non-partitioned table) | 1 split | 1 worker, 19 workers idle |

**This is not configurable in open-source Trino 467.** There is no `partition-column` property or parallel JDBC option for the MySQL connector in OSS Trino. Adding more workers will not speed up a MySQL table scan. Typical JDBC throughput: **50K–200K rows/second** on a single thread.

**Concrete calculation:** A 10M-row scan at 100K rows/sec is ~100 seconds, single-threaded, with no architectural way to parallelize it within OSS Trino.

### What You CAN Tune (in Order of Impact)

**1. Predicate pushdown** (highest impact for selective queries)

If MySQL can use an index to return only 50K rows instead of 10M, you've reduced the JDBC throughput problem dramatically. Verify with `EXPLAIN (TYPE DISTRIBUTED)` — the WHERE clause should be **inside** the MySQL `TableScan` node. If there's a `Filter` node **above** `TableScan`, Trino is pulling all 10M rows and filtering in memory.

**2. Dynamic filtering** (best for Iceberg-fact × MySQL-dimension joins)

When joining a 10M-row MySQL customers table to a large Iceberg events table, Trino can derive an IN-list from the Iceberg side and push it back into MySQL — "only give me customers whose IDs match this list." This turns the 10M scan into a much smaller selective scan. Check that `dynamic-filtering.wait-timeout` in your Iceberg catalog (`etc/catalog/iceberg.properties`) is at least 20s so MySQL has time to return join keys.

**3. Metadata caching**

Set `metadata.cache-ttl=30s` in the MySQL catalog config to reduce schema-lookup latency on every query planning cycle.

**What doesn't help:**
- Adding more Trino workers (still one split, one connection)
- Cluster-level memory/CPU tuning (bottleneck is JDBC throughput, not compute)

### The Hard Truth: When 10M Rows Becomes Unreasonable

Federating against MySQL stops being a reasonable approach when two or more of these are true:

| Signal | Threshold |
|---|---|
| Table size | >5M rows (your 10M+ is already past this) |
| Query latency after tuning | >2s p95 |
| Query frequency | Multiple times per day |
| Join complexity | Need to join >1 source or join with Iceberg at scale |

Additional factors:
- **Cross-catalog consistency gap**: Iceberg is pinned to a snapshot at plan time; MySQL reads under READ COMMITTED as rows stream in. For most analytics this is fine; for regulatory reports, it's not.
- **Non-transactional semantics**: federated writes back to MySQL (if any) don't have rollback.

### Decision Framework: When to Copy into Iceberg

Move the MySQL table to Iceberg when **at least two signals above apply**. Your situation (10M+ rows, queries "crawling") already meets the first two criteria.

**The ingestion path on your stack:**

1. **Spark snapshot job** reads MySQL via JDBC once per hour/day
2. **Spark writes Parquet** to MinIO, partitioned by a sensible key (customer_id, date, etc.)
3. **Register as Iceberg table** — Spark creates the table definition in Hive Metastore
4. **Trino queries it** — all 20 workers can now read in parallel
5. **Schedule the Spark job** — Airflow/cron, refreshing hourly or daily based on freshness needs

Once both sides (customers and events) are in Iceberg: both have snapshot isolation, the CBO can plan broadcast vs. shuffle join properly, and you avoid the JDBC single-split bottleneck entirely. Typical improvement: **100 seconds (single-threaded MySQL) → 1-5 seconds (parallel Iceberg)**.

### Concrete Next Steps

1. Run `EXPLAIN (TYPE DISTRIBUTED)` on your slow join — verify predicate pushdown is working (constraint inside `TableScan`, not a `Filter` above it)
2. Time a bare count: `SELECT COUNT(*) FROM mysql_catalog.db.customers WHERE <your_filter>` — if >30 seconds for 10M rows, JDBC bottleneck is confirmed
3. If predicate pushdown works and it still crawls: federation tuning alone won't save you — start the Iceberg snapshot job
4. Flip the join to use the Iceberg copy after one week of validating correctness
