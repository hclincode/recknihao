# Iter 219 Q1 — MySQL vs PostgreSQL Connector in Trino 467: Key Differences and Cross-Catalog Join Gotchas

## Answer

Your teammate is right to warn you — there ARE meaningful differences between how Trino handles MySQL and PostgreSQL connectors, even though they're both JDBC-based. Let me walk you through the specific concerns you mentioned.

### 1. Catalog Properties — The Basic Setup

First, the good news: the **core catalog properties are nearly identical**. Your `billing_mysql.properties` file will look almost identical to `app_pg.properties`:

```properties
# etc/catalog/billing_mysql.properties
connector.name=mysql

# JDBC URL — critical difference is the protocol and driver
connection-url=jdbc:mysql://billing-db-replica.billing.svc.cluster.local:3306/billing?defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10

connection-user=${ENV:BILLING_MYSQL_USER}
connection-password=${ENV:BILLING_MYSQL_PASSWORD}
```

The key difference from Postgres: you're using `jdbc:mysql://` instead of `jdbc:postgresql://`. MySQL JDBC drivers accept the same JDBC URL parameters (`defaultRowFetchSize`, `socketTimeout`, `connectTimeout`) that Postgres does.

**Important**: Just like PostgreSQL, **MySQL connector in OSS Trino 467 has NO native connection pooling**. Don't try to add `connection-pool.*` properties. Use the same mitigations as Postgres: connection timeouts in the JDBC URL, statement timeouts on the database, and (if needed) a connection proxy like ProxySQL for MySQL.

### 2. Predicate Pushdown — The Real Gotcha

Here's where the differences matter most. Both PostgreSQL and MySQL connectors support predicate pushdown, but **MySQL has a narrower set of pushdownable predicates**.

From the resource material, the official pushdown rules for MySQL:

- `WHERE invoice_id = 42` — pushes down (equality)
- `WHERE status IN ('paid', 'pending')` — pushes down (IN-list)
- `WHERE invoice_number LIKE 'INV-2026%'` — pushes down (simple prefix pattern)
- `WHERE customer_name LIKE '%acme%'` — does NOT push down (substring/suffix pattern)
- `WHERE created_date > '2026-01-01'` — does NOT push down by default on VARCHAR/CHAR columns (string range)

**Key implication**: if your billing schema has VARCHAR date columns (instead of DATE/DATETIME types) and you filter on them with range predicates, those filters execute on Trino workers after pulling rows over JDBC. This is the same limitation as Postgres, but it catches people by surprise with MySQL because legacy schemas often use VARCHAR for dates.

**How to verify in your query plan**: Run `EXPLAIN (TYPE DISTRIBUTED)` on your join query. If you see a `ScanFilterProject` or `Filter` node sitting ABOVE the `TableScan` for your billing_mysql tables, the predicate didn't push down — Trino is filtering rows in-memory after the JDBC pull.

### 3. Enabling Experimental String Range Pushdown

If your billing_mysql schema uses VARCHAR for date ranges and you need to filter them efficiently, there's an experimental flag (same as Postgres):

```properties
# In etc/catalog/billing_mysql.properties (requires coordinator restart)
mysql.experimental.enable-string-pushdown-with-collate=true
```

Use with caution — this involves collation risk. Test first with EXPLAIN to confirm the pushdown actually fires. The flag does NOT affect `LIKE` (simple patterns already push down) or `ILIKE` (still don't push down even with the flag).

### 4. Data Type Mapping — MySQL-Specific Quirks

MySQL and PostgreSQL have different native types. The mapping is generally straightforward for common types (INTEGER → BIGINT, VARCHAR → VARCHAR, DATETIME → TIMESTAMP), but there are notable gotchas:

- **MySQL `DATETIME` and `TIMESTAMP`**: Both map to Trino `TIMESTAMP`. But MySQL `DATETIME` is **NOT timezone-aware** — it stores wall-clock time in the server's local timezone. If your billing DB stores UTC timestamps in a `DATETIME` column but your app_pg stores them as `TIMESTAMPTZ`, **you must handle the timezone conversion explicitly in your Trino query** — the connectors won't do it for you.

- **No timezone column mapping in MySQL**: Unlike PostgreSQL (`TIMESTAMPTZ`), MySQL doesn't have a native timezone-aware type. When Trino joins MySQL timestamps against Postgres timestamps, both appear as Trino `TIMESTAMP` type — so the comparison succeeds at the type level — but the actual wall-clock values may mismatch if the databases were configured with different server timezones.

**Best practice**: Store all timestamps in UTC in both databases, document that invariant in your schema comments, and explicitly verify one row manually before shipping a cross-catalog join on timestamp columns.

### 5. Cross-Catalog Joins — What You Need to Know

This applies to **all Trino JDBC connectors, including MySQL**:

> **No cross-catalog join pushdown**: the join itself always executes on Trino workers. Postgres doesn't see the MySQL table; MySQL doesn't see the Postgres table. **Only each side's own predicates push down.**

Applied to your situation:

```sql
SELECT u.user_id, u.email, i.total_amount
FROM app_pg.public.users u
JOIN billing_mysql.public.invoices i ON u.id = i.user_id
WHERE u.tenant_id = 'acme' AND i.status = 'paid'
```

What happens:
1. **Postgres side**: `WHERE u.tenant_id = 'acme'` pushes down to Postgres. Postgres returns maybe 5,000 users instead of 50 million.
2. **MySQL side**: `WHERE i.status = 'paid'` pushes down to MySQL. MySQL returns the matching invoices.
3. **The join itself**: Trino receives rows from both sides, then runs the join in-memory on Trino workers.

Trino CAN use dynamic filtering to send an IN-list from the smaller side to the larger side at runtime — but only if the large side is the probe (scanned second). Verify with `EXPLAIN ANALYZE` and look for `dynamicFilters = {...}` on the probe-side scan.

### 6. Timezone Handling — The Most Common Gotcha

When joining timestamp columns cross-catalog, verify explicitly that both databases are treating timestamps identically:

```sql
-- Explicit UTC handling to avoid silent mismatches:
SELECT 
  app_pg.public.orders.created_at AT TIME ZONE 'UTC' AS order_time_utc,
  billing_mysql.public.invoices.created_at AS invoice_time  -- assume documented as UTC
FROM app_pg.public.orders
JOIN billing_mysql.public.invoices 
  ON app_pg.public.orders.id = billing_mysql.public.invoices.order_id
```

If both databases are UTC-compliant but one is configured differently, joins on timestamp columns will silently produce wrong results (matching rows dropped, or non-matching rows included).

### 7. Deployment Checklist for billing_mysql.properties

1. **Point at a read replica**: Never hit the primary billing database from Trino.
2. **Include JDBC parameters**: `defaultRowFetchSize=1000`, `socketTimeout=60`, `connectTimeout=10` in the JDBC URL.
3. **Test predicate pushdown**: Run a query with filters on your most-queried columns, then `EXPLAIN` to confirm the predicates push down. `ScanFilterProject` above `TableScan` means the predicate stayed in Trino.
4. **Test cross-catalog join with EXPLAIN ANALYZE**: Run a representative join between `app_pg.users` and `billing_mysql.invoices`. Confirm each side's filters push down (`constraint` inside the `TableScan`) and dynamic filtering appears (`dynamicFilters = {...}` on the probe-side scan).
5. **Timezone verification**: Before joining on timestamp columns, manually verify one row where you know the timestamp values in both MySQL and Postgres — your best insurance against silent timezone mismatches.
