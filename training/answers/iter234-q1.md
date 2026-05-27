# Iter 234 Q1 — MySQL Writes Through Trino: INSERT, UPDATE, DELETE, MERGE

## Answer

Yes, **Trino's MySQL connector supports INSERT, UPDATE, DELETE, and even MERGE**, but with important caveats around non-transactional semantics, predicate pushdown limitations, and MySQL-specific constraints.

### What's Actually Supported

| Operation | Supported | Default behavior | Key caveat |
|---|---|---|---|
| **INSERT** | YES | Transactional (temporary table → rename) by default | Fast non-transactional mode available but unsafe for failures |
| **UPDATE** | YES | Constant assignments only | `UPDATE t SET status = 'inactive' WHERE id = 42` works; `UPDATE t SET balance = balance + 100` fails |
| **DELETE** | YES | Predicates must be pushdownable | VARCHAR predicates do NOT push down on MySQL; only numeric/date predicates work |
| **MERGE** | YES | Disabled by default; requires explicit flag | Must enable `non_transactional_merge_enabled = true` to use |

### Critical Gotcha 1: Non-Transactional Semantics

Your test INSERT worked because Trino wraps INSERT in a transactional model (temporary table → atomically rename) by default, which is safe.

However, Trino does **NOT** wrap UPDATE and DELETE in any transaction. If your nightly job does an UPDATE and something fails halfway through, **the partially-modified rows stay committed in MySQL with no automatic rollback**. This is fundamentally different from your application's normal MySQL write path, which runs inside `BEGIN ... COMMIT` with atomicity guarantees.

**For nightly summary writes, this is probably okay** if your job is idempotent (re-running it produces the same final state). But if you need true atomicity, write through your application's MySQL connection instead.

### Critical Gotcha 2: DELETE Predicate Pushdown Failure

On MySQL specifically, **VARCHAR predicates do NOT push down** to the server. This breaks DELETE on text columns:

```sql
-- This FAILS at planning time:
DELETE FROM mysql.mydb.summary_table WHERE status = 'archived';
-- Error: predicate does not push down (status is VARCHAR)
```

The workaround is to pair the non-pushing VARCHAR filter with a pushdownable numeric or date predicate:

```sql
-- This works:
DELETE FROM mysql.mydb.summary_table
WHERE summary_date = DATE '2026-05-27'  -- pushes to MySQL (date)
  AND status = 'archived';              -- filtered in Trino memory
```

### Critical Gotcha 3: MERGE Requires an Explicit Flag

MERGE is **disabled by default** on the MySQL connector. Enable it:

```properties
# In etc/catalog/billing_mysql.properties:
merge.non-transactional-merge.enabled=true
```

Or as a session override (note: exact property name differs between catalog and session):

```sql
SET SESSION billing_mysql.non_transactional_merge_enabled = true;
-- Note: session property uses catalog name prefix and underscores with _enabled suffix
```

**Critical naming difference:**
- **Catalog property** (config file): `merge.non-transactional-merge.enabled=true` (hyphens)
- **Session property** (SQL): `non_transactional_merge_enabled` (underscores, ends in `_enabled`)

Mixing these up is a common mistake.

### Critical Gotcha 4: MERGE Non-Idempotency Risk

**If a MERGE processes 6,500 of 10,000 rows and then fails, the first 6,500 rows stay committed in MySQL.** Your nightly MERGE is safe only if it's **idempotent** — re-running it produces the same final state.

The canonical idempotent pattern (upsert by primary key):

```sql
MERGE INTO mysql.mydb.summary_table AS target
USING (
    SELECT
        DATE_TRUNC('day', NOW()) AS summary_date,
        COUNT(*) AS total_events,
        COUNT(DISTINCT user_id) AS unique_users
    FROM iceberg.analytics.events
    WHERE DATE_TRUNC('day', occurred_at) = DATE_TRUNC('day', NOW())
) AS source
ON target.summary_date = source.summary_date
WHEN MATCHED THEN UPDATE SET total_events = source.total_events, unique_users = source.unique_users
WHEN NOT MATCHED THEN INSERT (summary_date, total_events, unique_users)
    VALUES (source.summary_date, source.total_events, source.unique_users);
```

If this fails halfway, re-running it produces the same final state — safe.

### UPDATE Limitation: Constant Assignments Only

UPDATE only supports constant values, not expressions:

```sql
-- Works:
UPDATE mysql.mydb.accounts SET tier = 'enterprise' WHERE account_id = 42;

-- Fails (expression-based update):
UPDATE mysql.mydb.accounts SET event_count = event_count + 100 WHERE account_id = 42;
```

### What You Should Avoid

- Don't use Trino writes for transactional OLTP tables (orders, payments) — use your application
- Don't use non-transactional INSERT for critical data (only safe for recoverable bulk loads)
- Don't write complex DELETE logic with VARCHAR predicates — you'll hit planning errors
- Don't assume `UPDATE ... SET col = col + 1` works — it fails; only constant assignments are supported
- Non-idempotent MERGEs with `WHEN MATCHED THEN DELETE` or running totals are unsafe

### Production Checklist

1. Make your operation idempotent — re-running from the start produces the same result
2. Test failure recovery — kill the query mid-MERGE and verify the partial state and re-run behavior
3. Measure latency — Trino writes to MySQL are 10-50× slower than Iceberg-native writes (single JDBC connection)
4. Set a MySQL-side timeout — `SET GLOBAL max_execution_time = 300000` (5 min, in milliseconds) prevents runaway locks
5. Check OPA permissions — on your production stack, INSERT/UPDATE/DELETE likely requires explicit grants
