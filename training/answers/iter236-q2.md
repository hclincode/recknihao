# Iter 236 Q2 — Cross-Catalog INSERT: Iceberg Query Results into MySQL

## Answer

Yes, Trino can do cross-source INSERT with a few important caveats.

### 1. Can Trino run INSERT INTO a MySQL table from a cross-catalog query?

Yes. Your statement would look like:

```sql
INSERT INTO mysql_catalog.db.summary_table
SELECT 
    customer_id,
    COUNT(*) AS event_count,
    MAX(event_date) AS latest_event,
    SUM(event_value) AS total_value
FROM iceberg_catalog.analytics.events
JOIN mysql_catalog.app_db.active_customers USING (customer_id)
WHERE event_date >= CURRENT_DATE - INTERVAL '30' DAY
GROUP BY customer_id;
```

The cross-catalog JOIN executes on Trino workers — the Iceberg side reads files from MinIO, the MySQL side reads via JDBC, Trino performs the join in memory, and then writes the result to MySQL.

### 2. Exact Syntax

The syntax is standard SQL — no special Trino syntax required:

```sql
INSERT INTO <mysql_catalog>.<schema>.<table>
SELECT ... FROM <iceberg_catalog>.<schema>.<fact_table>
JOIN <mysql_catalog>.<schema>.<operational_table> ON ...
WHERE ...;
```

The MySQL catalog properties file (in `etc/catalog/`) configures the connector exactly like Postgres — a JDBC URL pointing to your MySQL server.

### 3. Critical Gotchas — Non-Transactional Semantics and Single JDBC Connection

**Default behavior is transactional**: By default, `INSERT INTO` a MySQL table uses a **temporary-table-and-rename wrapper**. Trino writes to a temporary table, and only on successful completion of the entire INSERT does it atomically rename the temp table into the target. This is safe and all-or-nothing. The cost is a rename/data-movement step at the end that adds latency proportional to row count.

**Non-transactional flag exists for bulk loads**: If you enable `insert.non-transactional-insert.enabled=true` (catalog property) or `SET SESSION <catalog>.non_transactional_insert = true;` (session property), Trino writes rows directly to the target without the temp table wrapper. This is faster but **unsafe for partial failures** — if the INSERT fails halfway through, the first half's committed rows stay in MySQL with no automatic cleanup. Only use this for idempotent bulk loads you can tolerate rerunning.

**Single JDBC connection, no parallelism on the read side**: Your MySQL `active_customers` table will be read via a single JDBC connection — the MySQL connector does not support parallel reads (unlike Spark's `partitionColumn` / `lowerBound` / `upperBound` options, which do not apply to Trino's MySQL connector). For the **write** side, the INSERT itself is a single operation sent to MySQL.

**Partial-failure semantics on non-transactional INSERT**: If you enable non-transactional mode and the INSERT fails halfway through, rows already committed to MySQL will **not be rolled back**. This differs from the default transactional mode, which leaves the target table untouched if anything goes wrong. Only safe when re-running the same INSERT produces the same final state (idempotent operations).

### 4. CREATE TABLE AS SELECT (CTAS) Targeting MySQL

Yes, `CREATE TABLE ... AS SELECT` works:

```sql
CREATE TABLE mysql_catalog.db.new_summary AS
SELECT customer_id, COUNT(*) AS cnt, ...
FROM iceberg_catalog.analytics.events
JOIN mysql_catalog.app_db.active_customers USING (customer_id)
GROUP BY customer_id;
```

Same transactional-by-default behavior as INSERT. If your computed summary could be hundreds of millions of rows, a Spark job with checkpointing is safer than a Trino CTAS — Trino has no resume-from-failure; if the query times out or the network drops, you re-run from scratch.

### 5. When This Is Good Enough vs When to Use Spark

**Use Trino INSERT/CTAS when:**
- The result set is under a few million rows (transactional default is safe, no partial-failure risk)
- You are computing once and writing once (not streaming or handling retries with checkpoints)
- Freshness tolerance is ad-hoc or batch (a few minutes of latency is fine)
- You don't need resume-from-failure — you can re-run from scratch if the query fails
- The MySQL write is idempotent or you're using the default transactional mode

**Use Spark instead when:**
- The result is tens of millions of rows or more — Spark's distributed writes with checkpoints handle volume better
- You are streaming or micro-batching — Spark Structured Streaming recovers from failures elegantly; Trino has no checkpointing
- You need true transactional guarantees across a large write
- The pipeline runs repeatedly and you want idempotency guarantees built into the framework

**Middle-ground pattern**: Compute the 30-day summary in Trino against Iceberg, materialize it as an Iceberg table, then MERGE the result into MySQL once a day. This separates analytical compute (fast, isolated) from the operational write (transactional, bounded scope).

### Bonus: Using MySQL MERGE for Idempotent Upserts

If you want "insert new summaries, update existing ones by customer_id" in one statement, MySQL MERGE is available — but you must enable the non-transactional flag first:

```sql
SET SESSION mysql_catalog.non_transactional_merge_enabled = true;

MERGE INTO mysql_catalog.db.summary AS target
USING (
    SELECT customer_id, COUNT(*) AS event_count, ...
    FROM iceberg_catalog.analytics.events
    JOIN mysql_catalog.app_db.active_customers USING (customer_id)
    WHERE event_date >= CURRENT_DATE - INTERVAL '30' DAY
    GROUP BY customer_id
) AS source
ON target.customer_id = source.customer_id
WHEN MATCHED THEN
    UPDATE SET event_count = source.event_count, ...
WHEN NOT MATCHED THEN
    INSERT (customer_id, event_count, ...) VALUES (...);
```

MERGE on MySQL requires `merge.non-transactional-merge.enabled=true` in the catalog (or the session property shown above). It's safe for this use case because the operation is idempotent — re-running it on the full source produces the same final state. The session property name is `non_transactional_merge_enabled` (with `_enabled` suffix, underscores).
