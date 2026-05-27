# Iter 221 Q1 — MySQL DATETIME Timezone Cross-Catalog Join: Why Your Timestamps Are Off

## Answer

Your confusion stems from a real and often-undetected mismatch between how MySQL stores naive timestamps and how Trino and PostgreSQL interpret them when joined together. Here's what's actually happening and how to fix it.

### How MySQL DATETIME and TIMESTAMP Map to Trino

When Trino's MySQL connector reads data, it maps MySQL types as follows:

- **MySQL `DATETIME(n)`** → Trino `TIMESTAMP(n)` **without time zone** (naive wall-clock value). Trino stores the literal value and does no timezone conversion.
- **MySQL `TIMESTAMP(n)`** → Trino `TIMESTAMP(n) WITH TIME ZONE` (timezone-aware). Trino stores it with UTC offset information.

This mapping is where your problem begins. Your MySQL `invoices.created_at` is a `DATETIME` (naive), so it appears in Trino as a plain `TIMESTAMP` with no timezone attached. Meanwhile, your Postgres `orders.created_at` is `TIMESTAMPTZ`, so it appears in Trino as `TIMESTAMP WITH TIME ZONE`.

### The Trino JVM Timezone Effect on MySQL Connections

Here's the critical gotcha: **MySQL's JDBC driver mirrors the Trino JVM's default timezone onto every MySQL session when it opens a connection.** Concretely:

- If your Trino JVM is set to UTC (configured via `-Duser.timezone=UTC` in `jvm.config`), every JDBC connection to MySQL automatically runs `SET time_zone = 'UTC'` at connect time.
- **But this only affects how MySQL itself interprets and stores timezone-aware types (`TIMESTAMP`)** — it does NOT change how a naive `DATETIME` is read back.
- When Trino reads a MySQL `DATETIME`, the JDBC driver returns the literal wall-clock value stored in MySQL with no conversion applied — not "midnight in the JVM's timezone," just "whatever is written in the cell."

### Why Your Join Timestamps Are Off by N Hours

When you write a join comparing MySQL `DATETIME` against Postgres `TIMESTAMPTZ`:

```sql
SELECT *
FROM billing_mysql.billing.invoices i
JOIN app_pg.public.orders o
  ON i.customer_id = o.customer_id
WHERE i.created_at >= '2024-01-01'
  AND o.created_at >= '2024-01-01'
```

You are joining a **naive `TIMESTAMP`** (from MySQL `DATETIME`) against a **timezone-aware `TIMESTAMP WITH TIME ZONE`** (from Postgres `TIMESTAMPTZ`). Trino compiles and executes the join, but the comparison is semantically broken:

- Trino treats the MySQL value as a literal wall-clock value with **no timezone attached**.
- Trino treats the Postgres value as a moment-in-time **with a UTC offset**.
- When comparing them, Trino does not have enough information to convert one to the other's reference frame. The join may appear to succeed and return "correct-looking" rows, but if MySQL's `DATETIME` column stores UTC while your code is comparing it against a different timezone context, the rows that "should match" will be off by that offset.

**Example**: suppose both systems intend to store `2024-01-15 14:00:00 UTC`:

- MySQL side: `invoices.created_at` stores the naive literal `2024-01-15 14:00:00` (no timezone)
- Postgres side: `orders.created_at` stores `2024-01-15 14:00:00+00:00` (explicit UTC offset)

When Trino reads the MySQL value, it gets `TIMESTAMP '2024-01-15 14:00:00'` — no timezone. The Postgres value comes in as `TIMESTAMP WITH TIME ZONE '2024-01-15 14:00:00+00:00'`. Trino cannot safely cast the naive timestamp to a timezone-aware one without knowing which timezone the MySQL value was "supposed to be in." If the assumption is wrong, rows don't match.

**There is no Trino-level safety net.** The types are different enough that the join compiles, but the semantics are silently wrong.

### How to Fix It: Align the Timestamps in the Query

**Option 1: Use AT TIME ZONE to explicitly declare MySQL's naive DATETIME as UTC**

```sql
SELECT *
FROM billing_mysql.billing.invoices i
JOIN app_pg.public.orders o
  ON i.customer_id = o.customer_id
  AND (i.created_at AT TIME ZONE 'UTC') = o.created_at
WHERE (i.created_at AT TIME ZONE 'UTC')
  >= TIMESTAMP '2024-01-01 00:00:00 UTC'
  AND o.created_at
  >= TIMESTAMP '2024-01-01 00:00:00 UTC'
```

This says explicitly: "interpret MySQL's naive wall-clock value as if it were already in UTC, then compare it to the Postgres timezone-aware value." The `AT TIME ZONE` function is explicit about the semantic assumption.

**Option 2: CAST naive TIMESTAMP to TIMESTAMP WITH TIME ZONE**

```sql
WHERE CAST(i.created_at AS TIMESTAMP WITH TIME ZONE) >= ...
```

This cast from naive `TIMESTAMP` to `TIMESTAMP WITH TIME ZONE` assumes the input value is in UTC and attaches the `+00:00` offset. Now both sides are comparable.

### Mandatory Check Before Production

Before shipping a federated timestamp join in production: **pick one known row from each side and verify manually that the timestamps match what you expect.** Document every timestamp column's timezone convention in every catalog (MySQL, Postgres, Iceberg). Run a test join and confirm the rows actually align. There is no automated safety net in Trino — the burden is on you.

### Best Practice Going Forward

1. **In MySQL**: use `TIMESTAMP` columns for timezone-aware data (they store UTC internally), or document that every `DATETIME` column is stored in a specific timezone (e.g., "all `DATETIME` columns are UTC").
2. **In Postgres**: use `TIMESTAMPTZ` for timezone-aware data (standard practice).
3. **In Trino**: before writing a federated timestamp join, add a comment documenting the timezone assumption:

```sql
-- i.created_at is MySQL DATETIME, assumed UTC.
-- o.created_at is Postgres TIMESTAMPTZ, stored in UTC.
SELECT *
FROM billing_mysql.billing.invoices i
JOIN app_pg.public.orders o
  ON i.customer_id = o.customer_id
  AND (i.created_at AT TIME ZONE 'UTC') = o.created_at
```
