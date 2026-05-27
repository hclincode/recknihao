# Iter 235 Q2 — PostgreSQL vs MySQL Connector Differences in Trino

## Answer

Yes, you should absolutely think about these two connectors differently. They look similar on the surface, but there are critical differences in what pushes down to the database, how they handle parallelism, and what write operations work. Here's what matters for your architecture:

### 1. Predicate Pushdown — the Biggest Behavioral Gap

This is where MySQL and PostgreSQL diverge most dramatically.

**PostgreSQL pushes aggressively:**
- Numeric equality and range predicates: `WHERE id = 42`, `WHERE created_at > TIMESTAMP '2026-05-01'` — both push down.
- String equality: `WHERE status = 'active'` — **YES, this pushes down on PostgreSQL.**
- Simple LIKE patterns: `WHERE name LIKE 'foo%'` — pushes down by default in Trino 467.
- IS NULL / IS NOT NULL on any column type — pushes down.
- IN-lists on strings, numbers, dates — all push down.

**MySQL pushes conservatively:**
- Numeric equality and range predicates push down — same as Postgres.
- String equality: `WHERE status = 'active'` — **NO, this does NOT push down on MySQL.** Trino fetches the entire table over JDBC and filters in memory. This is the single biggest behavioral surprise.
- LIKE patterns — **NO, none of them push down on MySQL**, regardless of pattern complexity.
- IN-lists on strings — **NO, they do NOT push down.** IN-lists on numeric/date columns work fine.
- IS NULL / IS NOT NULL on text columns — **NO, these are considered textual predicates and stay in Trino.**

**Practical implication:** If your MySQL `invoices` table has millions of rows and your query filters by `WHERE status = 'paid'`, Trino will pull the entire table over a single JDBC connection. This is catastrophic. Your workaround on MySQL is to **pair the VARCHAR filter with a pushable date or numeric filter** so MySQL returns fewer rows:

```sql
-- BAD for MySQL: pulls the full table
SELECT * FROM billing_mysql.invoices WHERE status = 'paid';

-- GOOD for MySQL: MySQL applies the date filter first, Trino filters the smaller result set
SELECT * FROM billing_mysql.invoices 
WHERE created_at >= DATE '2026-05-01'   -- pushes to MySQL
  AND status = 'paid';                  -- filtered in Trino memory
```

Your Postgres side doesn't need this workaround — `status = 'paid'` alone pushes cleanly.

### 2. Parallelism — Neither Connector Parallelizes Reads in OSS Trino 467

Both MySQL and PostgreSQL have the same limitation here: **neither connector creates multiple splits per table scan.** Each unpartitioned table produces exactly **one split = one JDBC connection per query**, regardless of table size.

If you're familiar with Spark JDBC options like `partitionColumn`, `numPartitions`, `lowerBound`, `upperBound` — **those do not exist for Trino's MySQL or PostgreSQL connectors.** Adding them to the catalog file will cause a startup error. This is a hard limitation tracked as open issue trinodb/trino#389 since 2019.

**Your production strategy for large tables:** Do not try to parallelize the JDBC read. Instead:
1. **Snapshot the data into Iceberg** (via Spark, CDC pipeline, or Trino CTAS). Once it's in Iceberg on MinIO, Trino can parallelize the scan across your cluster.
2. **Use dynamic filtering** when joining a large Iceberg fact table to a small MySQL/Postgres dimension. MySQL/Postgres reads the dimension once (small, single split), and the resulting IN-list prunes the Iceberg side.
3. **Keep MySQL/Postgres connectors for small tables only** (under ~5M rows, or anything that fits in a single-threaded scan).

### 3. Write Support — MySQL and PostgreSQL Differ Subtly

Both support INSERT, UPDATE, and DELETE, but with differences:

**INSERT:**
- PostgreSQL: transactional by default (safe, slightly slower).
- MySQL: also transactional by default. To enable fast non-transactional bulk insert, set `insert.non-transactional-insert.enabled=true` in the catalog or use `SET SESSION billing_mysql.non_transactional_insert = true;` (note: underscores in session form).

**UPDATE:**
- Both connectors support only **constant assignments**: `UPDATE t SET status = 'inactive' WHERE id = 42` works.
- Both reject expressions: `UPDATE t SET balance = balance + 100` fails on both.

**DELETE:**
- Both support it **only if the WHERE predicate pushes down to that database.**
- PostgreSQL: `DELETE FROM app_pg.invoices WHERE status = 'paid'` works (string equality pushes).
- MySQL: `DELETE FROM billing_mysql.invoices WHERE status = 'paid'` **fails** at planning time (string equality doesn't push; the connector refuses to execute). Pair it with a pushable predicate: `DELETE WHERE created_at < DATE '2026-01-01' AND status = 'paid'`.

**MERGE (upsert):**
- PostgreSQL: supported by default — transactional, safe.
- MySQL: supported **only if you explicitly enable it** with `merge.non-transactional-merge.enabled=true` in the catalog. Session form: `SET SESSION billing_mysql.non_transactional_merge_enabled = true;` (note: `_enabled` suffix, not just `_merge`). Non-transactional on MySQL means partial failures leave committed rows behind — only use for idempotent operations (e.g., insert-or-update-by-PK).

### 4. Operational Parameter Differences — Critical Units Mismatch

This is a sharp edge that catches everyone:

| Parameter | PostgreSQL | MySQL | Issue |
|---|---|---|---|
| **Fetch size** | `defaultRowFetchSize=N` | `defaultFetchSize=N` **AND** `useCursorFetch=true` | MySQL requires BOTH; `defaultFetchSize` alone is silently ignored. Result: OOM on large table scans. |
| **socketTimeout** | Seconds: `socketTimeout=60` | Milliseconds: `socketTimeout=60000` | PostgreSQL = 60 seconds. MySQL = 60 milliseconds (kills every query immediately). **This is the #1 unit bug.** Pasting Postgres config into MySQL breaks everything. |
| **connectTimeout** | Seconds: `connectTimeout=10` | Milliseconds: `connectTimeout=10000` | Same unit trap as socketTimeout. |
| **Server-side timeout** | `statement_timeout`: `SET statement_timeout = '5min'` | `max_execution_time`: `SET GLOBAL max_execution_time = 300000;` (milliseconds) | Different parameter name AND semantics. Postgres accepts duration strings; MySQL needs raw milliseconds. |

**Concrete example — the wrong and right way for MySQL:**

```properties
# WRONG — copy-pasted from PostgreSQL section
defaultFetchSize=1000
socketTimeout=60
connectTimeout=10

# RIGHT — MySQL Connector/J form
defaultFetchSize=1000
useCursorFetch=true
socketTimeout=60000
connectTimeout=10000
```

### 5. Schema Metadata Caching — Same Mechanism, Different Defaults

Both support `metadata.cache-ttl` to reduce planning latency. Default is `0s` (disabled) on both. For repeated federation queries where the schema is stable, raise it to `30s` or `60s`:

```properties
metadata.cache-ttl=30s
```

Flush with `CALL billing_mysql.system.flush_metadata_cache();` or `CALL app_pg.system.flush_metadata_cache();` — same API, no parameters on JDBC connectors.

### 6. Connection Pooling — Neither Has Native Pooling

OSS Trino 467 has no built-in connection pooling for either connector.

- PostgreSQL: put **PgBouncer** in transaction-pooling mode between Trino and Postgres. Add `prepareThreshold=0` (mandatory in transaction pooling).
- MySQL: put **ProxySQL** between Trino and MySQL (same role, MySQL-native pooler).

### 7. Dynamic Filtering — VARCHAR Join Keys Matter

When joining a huge Iceberg fact table to a small MySQL/Postgres dimension:

1. Trino reads the dimension first (single JDBC connection — fine if it's small).
2. Trino derives an IN-list of the join-key values seen.
3. Trino pushes that IN-list to the Iceberg probe scan, skipping files that don't overlap.

**Critical constraint for MySQL:** The join key must be numeric or date type. If your dimension has a `VARCHAR` join key, the IN-list **will not push to MySQL** (due to collation differences). Workaround: add a parallel numeric key column, or keep that dimension in Postgres instead (Postgres accepts VARCHAR predicates).

**Configuration:**
- Default dynamic-filtering wait-timeout is 20s for JDBC connectors and 1s for Iceberg.
- For batch federation, raise the Iceberg timeout: `SET SESSION iceberg_catalog.dynamic_filtering_wait_timeout = '20s';` — the default 1s almost always times out on Iceberg-probe scenarios.

### 8. Practical Recommendations for Your Setup

**For Postgres (customer accounts):**
- Use string predicates in WHERE clauses freely — they push down.
- Dynamic filtering works with VARCHAR join keys.
- INSERT/UPDATE/DELETE/MERGE semantics are standard and intuitive.

**For MySQL (legacy product data):**
- **Never assume string filters push down.** Always pair VARCHAR predicates with a numeric or date filter. Run `EXPLAIN (TYPE DISTRIBUTED)` to verify.
- If you have a large MySQL table you query repeatedly, snapshot it into Iceberg (nightly Spark job). Let Trino parallelize the Iceberg scan.
- MERGE requires explicit catalog flag (`merge.non-transactional-merge.enabled=true`).
- Copy socket timeout values carefully — milliseconds for MySQL, seconds for Postgres.

**For data movement:**
- Moving data **from** MySQL to Iceberg? Use a Spark CTAS or CDC pipeline — Trino federation is not the right tool for bulk movement.
- Moving computed results **into** MySQL from Iceberg? Use MERGE (with session flag) — idempotent upserts by primary key are the canonical pattern.
