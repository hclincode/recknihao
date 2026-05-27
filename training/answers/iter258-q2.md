# Iter258 Q2 — Joining Postgres + MySQL + Iceberg in One Trino Query

## Answer

Yes, Trino absolutely supports joining across all three systems (Postgres, MySQL, and Iceberg) in a single SQL statement. Here's what you need to know to make it work in production.

### Yes — One SQL Query Can Join All Three

```sql
SELECT 
  c.customer_id,
  c.name,
  s.subscription_tier,
  COUNT(e.event_id) as event_count
FROM app_pg.public.customers c
JOIN billing_mysql.billing_db.subscriptions s 
  ON c.customer_id = s.customer_id
JOIN iceberg.analytics.events e 
  ON c.customer_id = e.customer_id
WHERE c.created_at >= DATE '2026-05-01'
GROUP BY c.customer_id, c.name, s.subscription_tier
```

Trino will execute this, and the database systems do not need to know about each other.

### Where the Join Actually Happens

**The join itself always runs inside Trino's workers, not in any of the underlying systems.** When a join crosses catalogs (Postgres + MySQL + Iceberg), there is no "cross-catalog join pushdown" — it doesn't exist and structurally cannot. Postgres doesn't know what Iceberg is; Iceberg doesn't know what MySQL is. Trino fetches rows from all three, brings them into its worker cluster, and executes the join there.

### Predicate Pushdown Still Works Per Catalog

Even though the join happens in Trino, **WHERE clauses still push down to each source independently.** Your `WHERE c.created_at >= DATE '2026-05-01'` predicate pushes to Postgres — Postgres applies it server-side, and only matching rows are shipped back to Trino.

Important caveat: **what pushes to each system is different**. Postgres pushes most predicates (equality, ranges, IS NULL on text columns). MySQL is more restrictive — only numeric and date predicates push reliably. Text/VARCHAR filters on MySQL stay in Trino and execute in-memory. If you filter MySQL subscriptions by `WHERE status = 'paid'`, MySQL ships all rows back and Trino filters them locally.

### Dynamic Filtering — The Real Production Lever

Trino can derive a filter from the **small side of a join** and push it into the **large side** to skip unnecessary work. Example: If your Postgres `customers` table (after filtering by date) returns 5,000 rows, Trino extracts the 5,000 customer IDs and creates an IN-list: `WHERE customer_id IN (id1, id2, ..., id5000)`. That filter is pushed into the Iceberg `events` table scan. Iceberg's manifest-level statistics can prune entire Parquet files that don't contain those IDs — turning a 500M-row scan into 50M rows (10× reduction).

**Dynamic filtering is what makes cross-catalog joins survivable in production when one side is large.**

### The Practical Catches

**1. Planning complexity grows with more catalogs.** Each catalog requires metadata lookups — Trino queries `information_schema` on Postgres and MySQL, scans Iceberg manifests. With joins across multiple catalogs, planning alone can take 4–8 minutes before the first row is read. Solution: simplify the join topology or materialize frequently-joined tables into Iceberg first.

**2. JDBC sources (Postgres and MySQL) are single-threaded per table.** Each non-partitioned Postgres or MySQL table produces **exactly 1 split** → 1 JDBC connection → 1 worker → single-threaded scan. Scanning a large Postgres table without a selective WHERE clause runs at 50K–200K rows/second with no way to add workers to speed it up. Iceberg parallelizes across many Parquet files.

**3. MySQL has zero VARCHAR pushdown.** A filter like `WHERE status = 'paid'` on a MySQL text column doesn't push; MySQL ships all rows, and Trino filters them in-memory. Only numeric and date predicates push reliably on MySQL.

**4. No cross-catalog transaction atomicity.** Federation is for reads only. There's no distributed transaction guarantee across systems. Each system commits independently.

### When to Restructure Instead of Federating

If any JDBC table is **large and unsharable**, federation gets expensive:

- **Large Postgres table without selective filter**: materialize to Iceberg nightly via Trino federated INSERT or a Spark job. Then query the Iceberg copy — parallel reads, column pruning, manifest skipping.
- **Large MySQL table with text filter**: add a date predicate that pushes (`AND created_at >= DATE '2026-01-01'`), or materialize to Iceberg.
- Once large Postgres/MySQL tables move to Iceberg, joins become 10× faster — no schema change, no OLTP load.

### Query Structure Recommendation

**Make Iceberg the probe side (large fact table) and small JDBC tables the build sides:**

```sql
SELECT ...
FROM iceberg.analytics.events e           -- large fact table (PROBE side)
JOIN app_pg.public.customers c            -- small dimension (BUILD side)
  ON e.customer_id = c.customer_id
JOIN billing_mysql.billing_db.subscriptions s  -- small dimension (BUILD side)
  ON e.customer_id = s.customer_id
WHERE e.created_at >= DATE '2026-01-01'   -- selective WHERE on Iceberg
  AND c.status = 'active'                 -- selective WHERE on Postgres
```

Why this works:
- Postgres and MySQL are scanned first (small dimensions, single JDBC connection each — fast).
- Trino extracts customer IDs and derives IN-lists from the results.
- Those IN-lists push into the Iceberg scan, which prunes Parquet files; workers parallelize the read across many splits.
- Final join happens in Trino workers after both sides are pre-filtered to manageable size.

**Key configuration**: On the Iceberg catalog, set `iceberg.dynamic-filtering.wait-timeout=15s` (default is 1s, too short for JDBC build sides that may be slow). This gives the JDBC sides time to finish before the Iceberg probe starts scanning.

### Summary in One Sentence

**The join works, but predicate pushdown and parallelism are per-system — Postgres is all-or-nothing, MySQL is text-hostile, and Iceberg dominates. One large unfiltered JDBC table kills the query. Make Iceberg the probe side and small JDBC tables the build sides, or materialize the large JDBC table to Iceberg first.**
