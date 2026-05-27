# Iter242 Q2 — Cross-Catalog INSERT Write-Back into PostgreSQL

**Yes, Trino absolutely supports `INSERT INTO postgres_catalog.reporting.summary SELECT ... FROM iceberg_catalog.events JOIN postgres_catalog.customers ...` — this is a direct cross-catalog insert that works exactly as you've written it.** Your instinct is sound; it eliminates the round-trip through your application code.

## Does Trino support writing to PostgreSQL via JDBC?

Yes. Trino's PostgreSQL federation connector fully supports INSERT, UPDATE, and DELETE operations. You can JOIN data from Iceberg with PostgreSQL metadata and write the result directly back to PostgreSQL in a single statement.

## What are the transaction semantics? Can it leave partial data?

By default, **INSERT is transactional and atomic.** Here's how it works:

Trino uses a **temporary-table-then-rename pattern** internally. When you execute your cross-catalog INSERT:

1. Trino creates a temporary staging table in PostgreSQL
2. Writes all rows from your query (`SELECT ... FROM iceberg_catalog.events JOIN postgres_catalog.customers`) into that temporary table
3. Atomically renames the temporary table to your final table name (`reporting.summary`)

This ensures that either **all rows are inserted or none are** — PostgreSQL never sees a partial write. The atomic rename step guarantees this. If the query fails halfway through, the temporary table is cleaned up and your target table remains untouched.

## The non-transactional-insert flag and when it matters

There is a flag called `non-transactional-insert` that you can enable if you want faster bulk loads:

```
insert.non-transactional-insert.enabled=true
```

When enabled, Trino skips the temporary-table wrapper and writes directly to your target table. **This is faster but unsafe.** If the query fails partway through, you will have partial data in PostgreSQL with no automatic cleanup. **Do not enable this flag for your use case** — you want the atomic default behavior.

## Important production caveats

1. **PostgreSQL MERGE is not supported in Trino 467.** Your question mentions `INSERT ... SELECT`, which is fine. But if you later want to do upserts (insert new rows + update existing ones in one statement), you cannot use MERGE in Trino 467. Instead, use two separate statements (INSERT + UPDATE) or push that logic to your application using PostgreSQL's native `ON CONFLICT (pk) DO UPDATE` syntax.

2. **Connection pooling and limits.** OSS Trino has no native PostgreSQL connection pool. Set up **PgBouncer** between Trino and PostgreSQL in transaction-pooling mode, and configure a Postgres role-level `CONNECTION LIMIT` on the `trino_reader` role. Otherwise, long-running inserts can exhaust your Postgres connection limit and starve your application.

3. **Run this against a read replica, not your OLTP primary.** Federation is designed for analytical work; a runaway INSERT could lock your production table. Point the federation catalog at a dedicated read replica.

4. **Time the statement.** Trino's cross-catalog INSERT will stream the entire result set from Iceberg, join with PostgreSQL metadata, and insert into Postgres — all in one transaction. For large datasets, monitor query execution time and consider breaking this into smaller batches if individual statements take more than a few minutes.

## The recommendation

Your proposed pattern is **good and safe to use.** It's simpler and more maintainable than application-side inserts:

```sql
INSERT INTO postgres_catalog.reporting.summary
SELECT /* your aggregation logic here */
FROM iceberg_catalog.events
JOIN postgres_catalog.customers
WHERE /* your filters */
```

This is transactional by default, so you don't have to worry about partial writes. Just make sure to configure PgBouncer in front of PostgreSQL and point at a replica.
