# Iter 224 Q1 — AT TIME ZONE vs CAST for MySQL DATETIME in Cross-Catalog Joins

## Answer

The difference is critical and directly affects correctness in cross-catalog joins. Your teammate is right — `AT TIME ZONE 'UTC'` is the safer choice. Here's why.

### How the types map from MySQL and Postgres to Trino

- **MySQL `DATETIME(n)`** → Trino `TIMESTAMP(n)` WITHOUT timezone (naive, wall-clock value only)
- **MySQL `TIMESTAMP(n)`** → Trino `TIMESTAMP(n)` WITH TIME ZONE (timezone-aware)
- **Postgres `TIMESTAMPTZ`** → Trino `TIMESTAMP WITH TIME ZONE` (timezone-aware)

In your case: the MySQL DATETIME column becomes a **naive** Trino timestamp, and the Postgres TIMESTAMPTZ becomes a **timezone-aware** Trino timestamp. That's the tension you're resolving in the join.

### Why CAST is wrong (or at least dangerous)

When you write `CAST(mysql_datetime_col AS TIMESTAMP WITH TIME ZONE)`, Trino does **not** unconditionally attach UTC. Instead, it attaches **whatever the current session timezone is** — the result of `current_timezone()`.

On Trino 467 with your on-prem setup, if the JVM default is UTC (typical config with `-Duser.timezone=UTC`), the CAST happens to attach UTC. **But if the session timezone is anything else** — for example, if a client issues `SET TIME ZONE 'America/New_York'`, or if a Trino node has a different JVM timezone — the CAST attaches that zone instead. Your `TIMESTAMP WITH TIME ZONE` ends up with the wrong timezone attached, and the join silently produces **wrong rows** — no error, just incorrect data.

### Why `AT TIME ZONE 'UTC'` is correct

The `AT TIME ZONE` operator explicitly names the zone:

```sql
SELECT i.paid_at AT TIME ZONE 'UTC' AS paid_at_utc
FROM billing_mysql.billing.invoices i
JOIN app_pg.public.orders o 
  ON (i.paid_at AT TIME ZONE 'UTC') = o.completed_at
WHERE (i.paid_at AT TIME ZONE 'UTC') >= TIMESTAMP '2026-01-01 00:00:00 UTC';
```

This tells Trino: "take the naive wall-clock value from MySQL and interpret it as UTC." It produces a `TIMESTAMP WITH TIME ZONE` with UTC explicitly attached, **regardless of what `current_timezone()` returns**. Same behavior on every Trino node, every session, every time.

The function-form equivalent is `with_timezone(ts, 'UTC')`:

```sql
SELECT with_timezone(i.paid_at, 'UTC') AS paid_at_utc
FROM billing_mysql.billing.invoices i
JOIN app_pg.public.orders o
  ON with_timezone(i.paid_at, 'UTC') = o.completed_at
```

Use `with_timezone` when building complex expressions where `AT TIME ZONE` operator precedence gets confusing, or inside `CASE` branches.

### The silent danger of CAST

The worst part of using bare `CAST` is that it **works and returns results**, so the bug is invisible. Your join compiles, your dashboard renders, your queries return rows — but if the session timezone drifts from UTC (on a client config change, a JVM restart, or a node reconfiguration), the join suddenly compares the wrong moments in time.

There is no Trino-level safety net. The only defense is the SQL itself.

### How MySQL DATETIME gets read

When Trino opens a JDBC connection to MySQL, the MySQL connector automatically mirrors the JVM's timezone to the MySQL session. If your JVM is UTC (typical production), every MySQL connection runs `SET time_zone = 'UTC'` at connect time. For `DATETIME` columns (naive), MySQL returns the literal wall-clock value with **no conversion**. For `TIMESTAMP` columns (timezone-aware), MySQL converts to UTC before returning.

This is why the wall-clock value from MySQL *usually* matches UTC in practice — but that's a **convention**, not a guarantee enforced by the type system.

### Before-production validation

Before deploying this join to production:

```sql
-- 1. Confirm your session timezone
SELECT current_timezone() AS session_tz;

-- 2. Validate with a known row
SELECT 
  i.paid_at,
  with_timezone(i.paid_at, 'UTC') AS mysql_as_utc,
  o.completed_at,
  (with_timezone(i.paid_at, 'UTC') = o.completed_at) AS matches
FROM billing_mysql.billing.invoices i
JOIN app_pg.public.orders o ON with_timezone(i.paid_at, 'UTC') = o.completed_at
WHERE i.invoice_id = 'known_invoice_id'
LIMIT 1;
```

Verify the timestamps align with what you expect. Document in your table comments whether DATETIME columns store UTC — Trino cannot enforce this for you.

**Bottom line:** Use `AT TIME ZONE 'UTC'` or `with_timezone(ts, 'UTC')` in the join condition. If you must use `CAST`, verify `SELECT current_timezone()` returns `'UTC'` first — but don't rely on that. Explicit is safer than implicit when timezones are involved.
