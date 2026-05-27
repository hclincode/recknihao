# Iter240 Q1 — MySQL vs PostgreSQL Connector Differences

## Why MySQL Shows "1 Split" and Feels Slower Than PostgreSQL

You've identified a real architectural difference between how Trino reads MySQL versus PostgreSQL. This is not something you configured wrong — it's fundamental to how the MySQL connector works.

### What "1 split" means and why it matters for parallelism

A **split** in Trino is a unit of work that one worker can execute in parallel. Think of it like a task that gets distributed across your cluster of workers.

- **Iceberg**: If you have a table stored as 80 Parquet files on MinIO, Trino creates 80 splits — each worker grabs one file and reads it simultaneously. A 20-worker cluster can process ~20 files at the same time.
- **PostgreSQL**: A regular Postgres table gets 1 split (the entire table). One worker reads it over a single JDBC connection while your other 19 workers sit idle for that scan. Postgres is single-threaded per query, even though your Trino cluster is multi-worker.
- **MySQL**: Exactly the same as PostgreSQL — 1 split = 1 JDBC connection = 1 worker actually doing work.

The "1 split" you're seeing is Trino telling you: "I can only read this table one thread at a time." That's why the scan feels slower even though the table has millions of rows. You're not getting parallelism the way you might with Iceberg.

**Why is this a hard limit for MySQL?** The Trino MySQL connector (in OSS Trino 467) has never implemented partition-column-based splitting. If you've used Spark JDBC before, you might remember setting `partitionColumn`, `lowerBound`, `upperBound`, and `numPartitions` to parallelize reads — Trino's MySQL connector does not have these options. This is an open feature request since 2019 but has not been implemented in open-source Trino. You cannot add these properties to your MySQL catalog file — Trino will reject them at startup.

### Why MySQL doesn't filter as aggressively: the VARCHAR pushdown wall

Here's the second surprise: **the MySQL connector refuses to push down VARCHAR (text) predicates to the database.** This includes equality (`=`), `IN` lists, `LIKE` patterns, and even `NULL` checks on text columns.

**PostgreSQL behavior (what you're used to):**
- `WHERE status = 'active'` — **pushes to Postgres** ✓
- `WHERE name IN ('alice', 'bob')` — **pushes to Postgres** ✓
- `WHERE user_id IS NULL` (text column) — **pushes to Postgres** ✓

**MySQL behavior (the hard stop):**
- `WHERE status = 'active'` — **stays in Trino, full table scan over JDBC** ✗
- `WHERE name IN ('alice', 'bob')` — **stays in Trino, full table scan over JDBC** ✗
- `WHERE user_id IS NULL` (text column) — **stays in Trino, full table scan over JDBC** ✗

Why does MySQL block this? The MySQL connector team is conservative about collation correctness. MySQL has configurable collations (like `utf8mb4_0900_ai_ci`, which is case-insensitive and accent-insensitive), while Trino's string comparison is bytewise. Pushing a VARCHAR filter could match different rows in MySQL than Trino expects, causing silent bugs. The safest answer is: don't push VARCHAR at all.

**What this means for your query performance:**
If your `subscription_events` table has a `status` column and you write:
```sql
SELECT * FROM billing_mysql.events.subscription_events
WHERE status = 'active';
```
Trino pulls **every row** from that table over JDBC, then filters for `status = 'active'` in worker memory. Millions of rows travel across the network for no reason.

**Numeric and date predicates DO push down:**
The MySQL connector is happy to push numeric and date filters:
- `WHERE event_id >= 1000000` — **pushes to MySQL** ✓
- `WHERE created_at > DATE '2026-05-01'` — **pushes to MySQL** ✓

### The practical workaround: pair your VARCHAR filter with a pushing filter

Since your `subscription_events` table likely has both a text column (like `status`) and a timestamp (like `created_at`), you can structure your query strategically:

```sql
SELECT * FROM billing_mysql.events.subscription_events
WHERE created_at >= DATE '2026-05-20'         -- This DOES push to MySQL
  AND status = 'active';                      -- This does NOT push
```

What happens:
1. MySQL applies the date filter server-side (the efficient part).
2. MySQL ships only rows from May 20 onward over JDBC.
3. Trino applies the `status = 'active'` filter in memory — but now it's filtering a small, recent result set instead of the entire table.

This is drastically faster than a VARCHAR-only filter on millions of rows.

### A different strategy: use MySQL for dimension tables only

The OSS Trino MySQL connector is genuinely designed for **small, reference tables** — things like product catalogs, user profiles, or statuses. Rule of thumb: keep MySQL tables under ~5M rows in your Trino federation layer.

For large fact tables like `subscription_events`, the production pattern is:
1. **Replicate the MySQL table to Iceberg** via a nightly Spark job or CDC pipeline.
2. Query the Iceberg version in Trino (you get 100+ splits, parallelism, aggressive pushdown on any column type).
3. Join to small MySQL dimensions when needed (e.g., enrich with customer metadata).

If you need near-real-time freshness and can't wait for nightly replication, keep the MySQL table but make sure it has selective date/numeric predicates in your WHERE clause — leverage those pushdown-friendly columns to reduce the network traffic.

### One more thing: dynamic filtering and VARCHAR join keys

If you're joining your Iceberg fact table to the MySQL dimension using a text-based key (like a string UUID), dynamic filtering won't push the IN-list to MySQL either. The fix is the same: use a numeric surrogate key for the join (`customer_id BIGINT` instead of `customer_uuid VARCHAR`), or move the dimension table to PostgreSQL instead (Postgres pushes VARCHAR equality by default).

**Summary table for quick reference:**

| Aspect | PostgreSQL | MySQL |
|---|---|---|
| **Scan parallelism** | 1 split (same limitation) | 1 split (same limitation) |
| **VARCHAR equality pushdown** | Yes ✓ | No ✗ |
| **Numeric/date pushdown** | Yes ✓ | Yes ✓ |
| **IS NULL on text columns** | Yes ✓ | No ✗ |
| **IN-lists on VARCHAR** | Yes ✓ | No ✗ |
| **Best use case** | Large fact tables OR text-filtered queries | Small dimension/reference tables only |
