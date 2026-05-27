# Iter61 Q2 — Answer

**Question**: We're pulling data from Postgres into Iceberg via JDBC and something weird happened with one of our tables. The Postgres column is defined as `numeric(18,4)` — it's a dollar amount. The ingestion job ran fine, no errors. But when we query the Iceberg table in Trino, some of the values look slightly off — like a value that should be `1234.5600` is coming out as `1234.56` and losing the trailing zeros, and I'm worried we might have actual precision loss somewhere, not just formatting. Also, we have a `created_at` column in Postgres that's `timestamp with time zone`, and we're in a mixed environment where some app servers write in UTC and others apparently wrote in US/Central at some point. When that column landed in Iceberg, I don't know if the timezone info was preserved or if Trino is just showing me everything in some default zone. How do I verify the data actually came through correctly, and what should I have set up in the JDBC connector or the Iceberg schema to avoid these problems?

---

## Answer

You're dealing with two separate issues. The numeric one is almost certainly cosmetic (a display difference, not data loss). The timestamp one has a real subtlety worth understanding.

### The numeric(18,4) trailing-zero issue: likely display-only

When Spark reads `numeric(18,4)` from Postgres via JDBC, the pgjdbc driver maps it to `DECIMAL(18, 4)` — precision and scale are preserved in transit. Iceberg stores it as `DECIMAL(18, 4)` in Parquet. Trino exposes it as `DECIMAL(18, 4)`. The bits are preserved end-to-end.

The trailing zeros disappearing is how numeric libraries display decimal values — `1234.5600` and `1234.56` are mathematically identical, and most query clients strip trailing zeros by default.

**Verify it's display-only:**

```sql
-- In Trino: cast to VARCHAR to see the raw representation
SELECT CAST(dollar_amount AS VARCHAR) AS str_value
FROM iceberg.analytics.your_table
LIMIT 10;
```

If you see `1234.56` as a string output, the trailing zeros were stripped during Parquet storage. If you see `1234.5600`, they're stored correctly and only the display layer trimmed them.

**If precision loss actually occurred**, the culprit is almost always a cast to FLOAT or DOUBLE somewhere in the pipeline:

```python
# NEVER do this for financial data — FLOAT/DOUBLE are binary floating-point
# and cannot represent decimal values exactly
df = df.withColumn("dollar_amount", col("dollar_amount").cast("double"))  # WRONG

# Correct: let DECIMAL flow through without casting
# The pgjdbc driver provides DecimalType(18,4) automatically
```

**Prevent it at schema definition time:**

```sql
-- In Trino/Iceberg DDL: explicitly declare DECIMAL type
CREATE TABLE iceberg.analytics.your_table (
    dollar_amount DECIMAL(18, 4),
    ...
)
WITH (format = 'PARQUET');
```

And use display formatting in your BI tool to show trailing zeros (`$1,234.56` format) rather than relying on the raw number representation.

### The timestamp with time zone issue: understand what is and isn't preserved

This is more nuanced. Postgres `timestamp with time zone` (timestamptz) always stores the UTC instant internally — it normalizes everything to UTC regardless of the offset that was written. The timezone offset is metadata about how the value was recorded; the instant itself is always UTC.

When JDBC reads timestamptz, it gets the UTC instant. Spark's `TimestampType` stores that UTC instant. Iceberg writes it to Parquet as a UTC timestamp. Trino reads it back as the UTC instant.

**The instant-in-time is preserved. The original timezone offset is not.**

So if Postgres stored `2026-05-22 14:30:00-05:00` (2:30 PM Central), Iceberg will have `2026-05-22 19:30:00` (UTC equivalent). They represent the same moment; only the zone label is gone.

**How to verify the instant was preserved correctly:**

Step 1 — in Postgres, find the UTC equivalent:
```sql
SELECT
  id,
  created_at,
  created_at AT TIME ZONE 'UTC' AS utc_time
FROM your_table
WHERE id = 12345;
```

Step 2 — in Trino, check the same row:
```sql
SELECT created_at
FROM iceberg.analytics.your_table
WHERE id = 12345;
```

If the Trino value matches the `utc_time` from Postgres, the data is correct.

**The Iceberg column type to use:**

```sql
-- Use TIMESTAMP(6) WITH TIME ZONE
-- This preserves microseconds and marks the column as timezone-aware
CREATE TABLE iceberg.analytics.your_table (
    created_at TIMESTAMP(6) WITH TIME ZONE,
    ...
);
```

Without `WITH TIME ZONE`, the column is stored as local time with no zone information — a landmine for analytics across timezones.

**The JDBC timezone pitfall:**

If the JVM running Spark is not set to UTC, Postgres timestamptz values can shift during the JDBC read. The JDBC driver applies the JVM's default timezone to interpret the timestamp. Fix this by setting the session timezone in JDBC properties:

```python
PG_PROPS = {
    "user": PG_USER,
    "password": PG_PASS,
    "driver": "org.postgresql.Driver",
    "sessionInitStatement": "SET timezone = 'UTC'",  # Forces UTC for the JDBC session
}
```

Or pass `-Duser.timezone=UTC` to the Spark JVM. Either ensures consistent behavior across all ingestion jobs regardless of the server's local timezone.

### The mixed UTC/Central writers issue

If some app servers wrote with a UTC offset and others with a Central offset, **Postgres handled this correctly** — timestamptz always normalizes to the UTC instant at write time. The moments in time are correct; Postgres never conflates "what time was it in Central?" with "what moment did this happen?"

What you might see as a consequence: if your old Central-timezone writes stored `14:30:00-05:00` and your new UTC writes stored `19:30:00+00:00`, both correctly represent the same instant. But when you look at the `created_at` values in Postgres without normalizing, you'll see different time-of-day values for what might be the same event type at the same moment — confusing but not data corruption.

**Diagnostic in Trino** (check if dates look right):

```sql
SELECT
  DATE(created_at) AS event_date,
  COUNT(*) AS events
FROM iceberg.analytics.your_table
WHERE event_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
GROUP BY 1
ORDER BY 1;
```

If the dates look reasonable (events distributed across the month you expect), the UTC instants are correct. If you see events shifted by exactly 5 or 6 hours (appearing on the wrong date), that's a timezone conversion problem in your JDBC pipeline — check the `sessionInitStatement` setting above.

### Summary checklist

| Problem | Cause | Fix |
|---|---|---|
| Trailing zeros gone on DECIMAL | Display formatting, not precision loss | Use CAST to VARCHAR to verify; format in BI tool |
| Actual decimal precision lost | Cast to FLOAT/DOUBLE in pipeline | Never cast financial columns; keep as DECIMAL |
| Timestamps shifted by hours | JVM timezone ≠ UTC during JDBC read | Add `sessionInitStatement = SET timezone = 'UTC'` |
| Timezone offset lost | Expected behavior: Iceberg stores UTC instant only | Use `TIMESTAMP(6) WITH TIME ZONE`; store offset separately if needed |
