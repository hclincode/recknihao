# Iter46 Q1 Answer — Postgres→Trino datetime fix

**Question**: I'm trying to write a Trino query that finds users who signed up in the last 30 days and also computes how many days it's been since their first event. I wrote this and it's breaking: `WHERE signup_date > NOW()::DATE - 30` and for the duration: `SELECT DATEDIFF(NOW(), first_event_at) AS days_active`. Can you fix these for Trino?

---

You've hit two common Trino syntax issues that trip up engineers migrating from Postgres. Both are fixable — here's what's breaking and how to fix it.

### Issue 1: The WHERE clause with `NOW()::DATE - 30`

Your line uses two Postgres idioms that Trino doesn't support:

1. `NOW()::DATE` — the `::` cast syntax is PostgreSQL-specific. Trino uses `CAST(ts AS DATE)` or the shorter `date(ts)`.
2. Subtracting an integer from a date — Trino doesn't allow `date - 30`. You need an INTERVAL, and Trino requires the unit *outside* the quotes, singular, and uppercase (not the plural `'days'` that works in Postgres).

**Fixed WHERE clause:**

```sql
WHERE signup_date > current_date - INTERVAL '30' DAY
```

Or if `signup_date` is a timestamp (not just a date):

```sql
WHERE signup_date > date(current_timestamp) - INTERVAL '30' DAY
```

Note: `current_date` in Trino returns today's DATE (no time component). If your column is a timestamp and you want to compare apples-to-apples, wrap it in `date()`.

### Issue 2: The DATEDIFF for computing days since first event

`DATEDIFF(NOW(), first_event_at)` doesn't exist in Trino — that's MySQL syntax. Trino uses `date_diff(unit, start_time, end_time)`, and the unit must be quoted.

**Broken:**
```sql
SELECT DATEDIFF(NOW(), first_event_at) AS days_active
```

**Fixed:**
```sql
SELECT date_diff('day', first_event_at, current_timestamp) AS days_active
```

Notice the order: `date_diff('day', earlier_timestamp, later_timestamp)`. It computes `later - earlier` in the unit you specify. Other examples:

- Hours since first event: `date_diff('hour', first_event_at, current_timestamp)`
- Days since signup: `date_diff('day', signup_date, current_date)` (if both are dates)

### Why Trino is different

Trino follows ANSI SQL more strictly than Postgres does. Postgres is forgiving with type coercion (`::` casts, `INTERVAL '90 days'` with plurals), but Trino enforces the spec. Think of Trino as "strict but consistent" — once you learn the patterns (unit outside quotes, singular uppercase, `CAST()` instead of `::`), every query follows the same rules.

### Your full corrected query

Putting it together:

```sql
SELECT 
  user_id, 
  signup_date,
  date_diff('day', first_event_at, current_timestamp) AS days_active
FROM iceberg.analytics.users
WHERE signup_date > current_date - INTERVAL '30' DAY
ORDER BY signup_date DESC;
```

This finds users who signed up in the last 30 days and computes how many days it's been since their first event. Both columns will now run without syntax errors in your Trino 467 environment on Iceberg tables.
