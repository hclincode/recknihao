# Iter 174 Q1 — When to Give Up on Federation and Ingest into Iceberg

## Answer

Your team's intuition is correct: this specific table needs to move to Iceberg. Here's the full picture.

### (1) The Core Ceiling: JDBC is Single-Threaded Per Table Scan

OSS Trino 467's PostgreSQL connector connects via JDBC, and **each table scan opens a single connection to your Postgres read replica.** While Trino workers can run in parallel, each individual worker's read from the Postgres table is single-threaded. For an 80-million-row table, that thread is the bottleneck.

Contrast with Iceberg: when Trino scans an Iceberg table, it reads multiple Parquet files in parallel across workers. A partition might be split across 40 files — Trino opens all 40 simultaneously. The Postgres connector doesn't get this parallelism — it reads one connection's result stream sequentially.

Your predicate pushdown is working, but the rows still arrive over JDBC one at a time. Even with excellent filtering, the serialization and network latency of row-by-row JDBC fetch becomes the wall at 80M rows.

### (2) Concrete Signals That Federation Has Hit Its Limit

Your situation has all four red flags:

**A. Query takes minutes despite correct pushdown.** You've verified the WHERE clause is pushing to Postgres. Postgres is filtering server-side. But even "matching rows" from an 80M table, streamed over JDBC, accumulate network latency and serialization overhead faster than Iceberg's columnar Parquet reads do.

**B. Large result set even after filtering.** If filtering to 500K rows, those 500K rows over single-threaded JDBC are expensive. A Parquet column scan of the same 500K rows on Iceberg, across multiple files and workers, finishes faster.

**C. The table is being joined analytically, not point-looked-up.** In a cross-catalog join, Trino must pull the filtered Postgres rows completely into memory before the join can proceed. The entire Postgres-side network transfer must complete before the join phase begins — if that takes 2 minutes over JDBC, your query is blocked for 2 minutes regardless of how fast Iceberg can scan.

**D. You've already added indexes in Postgres.** Indexes help Postgres *filter* but don't help the *transfer*. Rows Postgres filtered to still arrive over the wire at the same rate. Once the remaining problem is the network transfer of the filtered result set, you've hit the ceiling.

### (3) What You Gain by Ingesting into Iceberg

**Parallel columnar reads.** 80M rows ingested as Parquet files partitioned by a key (e.g., `day(created_at)`) can be read across multiple workers in parallel. Each worker reads only the columns it needs. A 10 GB table as 40–80 Parquet files, read in parallel, finishes in seconds — not minutes.

**No Postgres connection pressure.** Every federated query opens fresh JDBC connections against your replica. Even with PgBouncer, you're multiplying connection load across every Trino worker. Ingestion eliminates that: Postgres is hit once per ingest job.

**Partition pruning.** Partitioned by date and filtering by date → Trino prunes entire partitions without opening files. Partitioned by tenant and filtering by tenant → tenant-specific scans skip 99% of files. Iceberg's file-level pruning is a structural advantage over Postgres pushdown.

**Compaction under your control.** You control when to compact files, independent of Postgres VACUUM and bloat.

### (4) What You Lose (The Real Trade-Off)

**Real-time access is gone.** Once the table is in Iceberg, it's only as fresh as your ingestion schedule. Federation shows live data updated within seconds; Iceberg shows yesterday's data (or last hour's, depending on your schedule).

But here's the key insight: most analytical joins don't need second-level freshness. A query asking "what happened this week?" can tolerate hourly or nightly staleness. The freshness requirement is what determines whether federation stays in the picture.

### (5) The Hybrid Pattern — Best of Both Worlds

Before moving everything, consider this pattern: **ingest the historical bulk into Iceberg, federate only the live tail (the last hour or two)**.

```sql
CREATE OR REPLACE VIEW analytics.my_80m_table_live AS
-- Historical: ingested nightly, all data older than 2 hours
SELECT * FROM iceberg.analytics.my_80m_table
WHERE created_at < current_timestamp - INTERVAL '2 HOURS'

UNION ALL

-- Live tail: last 2 hours from Postgres (fresh, but small volume)
SELECT * FROM app_pg.public.my_80m_table
WHERE created_at >= current_timestamp - INTERVAL '2 HOURS';
```

Why this works: analytical dashboards asking "give me yesterday's data" hit the Iceberg side and run fast. Real-time monitoring asking "what happened in the last hour?" hits the Postgres side — but the Postgres side is only 2 hours of data, making single-threaded JDBC fast. A 2-hour tail is manageable; an 80M-row full table is not.

### (6) Decision Framework

| Situation | Right Choice |
|---|---|
| Real-time widget: last 30 seconds | Federate the live tail (hybrid) |
| Daily/weekly analytical report | Ingest to Iceberg |
| Joining 80M Postgres + 500M Iceberg events | Ingest — both in Iceberg, cross-catalog join becomes intra-catalog with columnar benefits |
| One-off investigation: "does value match Postgres?" | Federate (don't build a pipeline for 2 queries) |
| Table ≤ ~1M rows, point-lookup pattern | Federate — JDBC overhead is tolerable |

**For your 80M Postgres event table joined to Iceberg**: ingest. The table is queried repeatedly (not one-off), joined analytically (not point-looked-up), and taking minutes despite correct pushdown — all the signals that JDBC single-threaded fetch is the bottleneck.

### Concrete Next Steps

1. Confirm with `EXPLAIN ANALYZE`: look at `Input: N rows (size)` on the Postgres TableScan. If Input rows are in the millions even after filtering, JDBC latency is the bottleneck.
2. Calculate ingest cost: Spark can read 1–5M rows/second via JDBC depending on row width. An 80M table might take 10–20 minutes to ingest nightly — acceptable for most analytics use cases.
3. Choose ingest pattern: full refresh (simplest — overwrite Iceberg table nightly) or incremental + hybrid view (more complex, better freshness SLO).
4. Add compaction: after ingestion, run `CALL iceberg.system.rewrite_data_files()` to collapse small files from incremental writes.
