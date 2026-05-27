# Iter246 Q2 — JDBC 1-Split: Why Postgres Federation Uses Only 1 Worker

## What's happening: The PostgreSQL connector emits only 1 split

This is **not a config problem on your end** — it's a fundamental architectural limitation of how OSS Trino 467's PostgreSQL connector works.

**The core issue:** The PostgreSQL connector in Trino creates exactly **one split per non-partitioned table scan**. Unlike Iceberg, which generates one split per Parquet file and distributes those across your 8 workers, Postgres feeds your entire 50 million row table as a single split to a single worker.

Concretely:
- **1 split = 1 JDBC connection = 1 worker thread** reading all rows sequentially
- The other 7 workers have nothing to do — no splits for them to claim
- All 50 million rows must flow through a single JDBC network pipe

At 100K rows/sec throughput (typical for JDBC), a 50M row scan takes ~500 seconds. Your 4-minute result is actually good JDBC throughput — you're just hitting the single-thread ceiling.

## Why this exists

There is no `partition-column` or `numPartitions` property in your PostgreSQL catalog properties file that enables parallel JDBC reads in OSS Trino 467. Those properties come from Spark and **do not exist in open-source Trino**. This is a tracked feature request (trinodb/trino#389, open since 2019) but unimplemented in OSS Trino. Only Starburst Enterprise (the commercial fork) has native parallel JDBC support for PostgreSQL.

## Real solutions — in order of recommendation

### 1. Snapshot Postgres into Iceberg (best long-term fix)
- Export your Postgres table into Iceberg on MinIO nightly or hourly via Spark or a CDC pipeline
- Query Iceberg from Trino instead of hitting Postgres directly
- Once in Iceberg, Trino creates one split per Parquet file and distributes reads across all 8 workers
- Your 50M row table will scan in seconds, not minutes

### 2. Use dynamic filtering (if you must query Postgres directly)
- Make your Postgres table the **build side** of a join (the smaller table in the join)
- Join it to a larger Iceberg fact table on the **probe side** (the larger, parallelizable table)
- Trino reads Postgres once (1 split, fine because it's the smaller dimension), derives an IN-list of the join keys, and pushes that IN-list into the Iceberg scan to skip irrelevant Parquet files
- Net effect: Postgres's single-split limitation becomes invisible because the parallelizable Iceberg side does the heavy lifting

### 3. Pre-aggregate on the Postgres side
- Create a view in Postgres that does expensive grouping/filtering before Trino reads it
- Trino reads the smaller aggregated view in one split instead of 50M raw rows
- Fewer rows flowing over JDBC = faster absolute time, even single-threaded

### 4. Use Postgres for small dimension tables only
- Rule of thumb: tables under ~5M rows
- At that scale, single-threaded JDBC reads are fast enough that parallelism doesn't matter much
- 5M rows at 100K rows/sec = ~50 seconds (may be acceptable depending on your SLA)

## Not a connection pool issue

You might wonder: "Can I add connection-pool properties to the PostgreSQL catalog file to enable parallel connections?" The answer is **no**. OSS Trino 467 has **no native JDBC connection pooling for the PostgreSQL connector**. Adding such properties silently has no effect.

The connection pooling workaround (if you need it for other reasons like limiting max connections) is to **point Trino at PgBouncer instead of Postgres directly** — PgBouncer becomes the pool layer, configured in transaction-pooling mode with `prepareThreshold=0` in your JDBC URL.

## What to check now

- Verify you're reading from a **dedicated read replica**, not your application's primary database (critical — a 4-minute analytical scan can block VACUUM and cause outages on the primary)
- Set `statement_timeout` aggressively on the replica (e.g., 5 minutes) to prevent runaway queries: `ALTER ROLE trino_reader SET statement_timeout = 300000;` (milliseconds)
- Measure your actual JDBC throughput: note elapsed time and row count, calculate rows/sec — this tells you whether network or Postgres query execution is the constraint

The most realistic fix: snapshot Postgres into Iceberg, and use Trino's native parallelism where it's designed to work.
