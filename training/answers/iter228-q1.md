# Iter 228 Q1 — MERGE on MySQL via Trino (Cross-catalog Upsert from Iceberg to MySQL)

## Answer

Yes, Trino does support MERGE statements that touch both your MySQL and Iceberg catalogs at once — but you need to enable a config flag first.

### How it works

You can write a MERGE statement in Trino that reads from your Iceberg analytics table and writes the upserted results directly back into MySQL. This is the canonical pattern for pushing computed analytics results (rollups, tier reassignments, billing aggregates) back into your operational MySQL database. In SQL, it looks like:

```sql
SET SESSION billing_mysql.non_transactional_merge = true;

MERGE INTO billing_mysql.billing_db.customer_usage AS target
USING (
    SELECT customer_id, total_usage, tier
    FROM iceberg.analytics.customer_aggregates
    WHERE compute_date = DATE '2026-05-27'
) AS source
ON target.customer_id = source.customer_id
WHEN MATCHED THEN
    UPDATE SET total_usage = source.total_usage, tier = source.tier
WHEN NOT MATCHED THEN
    INSERT (customer_id, total_usage, tier) 
    VALUES (source.customer_id, source.total_usage, source.tier);
```

In a single statement, this inserts new customer records and updates existing ones — exactly what you need for a billing sync.

### Required configuration

MERGE on MySQL is disabled by default in Trino. To enable it, add this property to your MySQL catalog file (`etc/catalog/billing_mysql.properties`):

```properties
merge.non-transactional-merge.enabled=true
```

Or, for a one-off test without restarting the coordinator, set it at the session level (as shown in the SQL example above):

```sql
SET SESSION billing_mysql.non_transactional_merge = true;
```

### Critical caveat: partial writes are not rolled back

The flag is called "non-transactional" for a reason. **If your MERGE processes 5,000 of 10,000 rows and then the connection drops, those 5,000 rows stay committed in MySQL** — there is no automatic rollback.

This is safe only if your MERGE is **idempotent**: running it again on the full source data produces the same final state regardless of where the previous attempt failed. The insert-or-update-by-primary-key pattern shown above IS idempotent — the second run will simply UPDATE the rows the first run already INSERTed.

Avoid MERGE through Trino for non-idempotent operations (e.g., deletes with conditional re-inserts, or operations that depend on MySQL state before the MERGE started). For those, use your application's MySQL connection inside a real `BEGIN ... COMMIT` transaction.

### Authorization

Check your OPA policies. On most production stacks, DML write access to the `billing_mysql` catalog is restricted to a dedicated service principal (like a billing-writer account). If your MERGE fails with an authorization error before even reaching MySQL, that's an OPA denial, not a connector misconfiguration.

**Bottom line**: Yes, you can do this in Trino. No need to pull data into your app and run separate INSERT/UPDATE statements. Just enable the `merge.non-transactional-merge.enabled=true` flag and write the MERGE.
