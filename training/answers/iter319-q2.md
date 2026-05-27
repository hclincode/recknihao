# Answer to Q2: Schema Drift Monitoring — Detecting Postgres/Iceberg Column Mismatch (Iter 319)

Your concern is real and happens in production. The silence is the problem — when a developer drops or renames a column in Postgres, your pipeline typically runs green with no errors, and the missing data appears only as NULLs or missing rows in dashboards days later.

## Why pipeline silence happens

- **`SELECT *` ingestion:** the column disappears from the DataFrame silently, never reaches Iceberg
- **Explicit column list ingestion:** a dropped column is excluded from the DataFrame — no error, just missing data
- **CDC (Debezium):** a dropped column stops appearing in Kafka events; Iceberg may retain a stale column

The pipeline succeeds in all three cases. No alerts. No failures.

## The standard solution: preflight schema-diff check

Run a schema comparison **before any data is touched** at job startup. This catches drift the moment it occurs, not days later.

```python
def preflight_schema_check(spark, pg_table, iceberg_table):
    # 1. Fetch live Postgres schema
    pg_cols = spark.read.jdbc(
        url=PG_URL,
        table=f"(SELECT column_name, data_type FROM information_schema.columns "
              f"WHERE table_schema='public' AND table_name='{pg_table}') t",
        properties=PG_PROPS,
    ).collect()
    pg_col_names = {row.column_name for row in pg_cols}

    # 2. Fetch current Iceberg schema
    iceberg_cols = spark.sql(
        f"DESCRIBE TABLE iceberg.analytics.{iceberg_table}"
    ).collect()
    iceberg_col_names = {
        row.col_name for row in iceberg_cols
        if row.col_name and not row.col_name.startswith("#")
    }

    # 3. Diff
    new_in_postgres = pg_col_names - iceberg_col_names      # added to Postgres, not in Iceberg yet
    removed_from_postgres = iceberg_col_names - pg_col_names  # dropped from Postgres, stale in Iceberg

    if new_in_postgres or removed_from_postgres:
        alert_oncall(f"Schema drift on {pg_table}: "
                     f"new={new_in_postgres}, removed={removed_from_postgres}")
        
        if INGESTION_MODE == "incremental":
            # Auto-fix new columns: run ALTER TABLE ... ADD COLUMN
            # Alert and continue (don't block data flow for additions)
            for col in new_in_postgres:
                spark.sql(f"ALTER TABLE iceberg.analytics.{iceberg_table} ADD COLUMN {col} STRING")
        else:
            # Full-refresh: fail loudly — SELECT * query needs updating
            raise SchemaDriftError("Schema mismatch; code update required before proceeding")
```

## What the diff catches

| Change in Postgres | Detected as | Response |
|---|---|---|
| `ALTER TABLE ... ADD COLUMN` | `new_in_postgres` | Auto-add to Iceberg (incremental) or fail (full-refresh) |
| `ALTER TABLE ... DROP COLUMN` | `removed_from_postgres` | Alert; decide whether to DROP in Iceberg or keep for history |
| Column renamed | DROP old + ADD new | Both sides caught; alert |
| Type change | Not caught by name-only diff | Needs type comparison (see below) |

## Alert before proceeding — always

The alert is the most important part. Wire it to your monitoring system (Slack, PagerDuty, whatever you use) and make it loud:

- **Same-day alert**: you want to know about drift the same day a developer runs the migration, not after a customer reports broken dashboards
- **Don't silently continue**: if the job auto-fixes additions, still send an alert so a human reviews the change

## Detecting dropped columns: what to do with the Iceberg column

When a column is dropped from Postgres, you have two options for the Iceberg column:

1. **Keep it for historical queries** (recommended): the Iceberg column retains historical values; new rows get NULL. Useful if dashboards query historical data.
2. **Drop it from Iceberg too**: `ALTER TABLE iceberg.analytics.events DROP COLUMN stale_col`. New files won't contain it; historical files still do, but Iceberg won't surface it.

Note: in Iceberg, DROP COLUMN is **not symmetric** with ADD COLUMN. ADD is metadata-only and instant. DROP is destructive going forward — new Parquet files won't include the column, and the data in old files becomes inaccessible through Trino (though the raw bytes remain in MinIO). This is a one-way operation in practice.

## Extra safety net: periodic reconciliation

For high-stakes fact tables, run a weekly job that compares row counts and aggregates between Postgres and Iceberg for a rolling window:

```sql
-- In Postgres (via Trino's PostgreSQL connector):
SELECT COUNT(*), MAX(updated_at) FROM postgresql.public.events
WHERE updated_at >= CURRENT_DATE - INTERVAL '7' DAY

-- In Iceberg:
SELECT COUNT(*), MAX(updated_at) FROM iceberg.analytics.events
WHERE updated_at >= CURRENT_DATE - INTERVAL '7' DAY
```

A significant mismatch (>1% row count difference, or MAX timestamps don't align) triggers an alert for manual investigation. This catches data-quality issues that a column-name check would miss (e.g., a type change that silently coerces values differently, or a backfilled migration that reused a column name with different semantics).

## Bottom line: monitoring checklist

1. **Preflight schema check** — runs every pipeline execution, alerts on any name mismatch
2. **Auto-fix additions** for incremental jobs (with alert), **fail loud** for full-refresh jobs
3. **Alert on removals** — decide manually whether to drop or retain the Iceberg column
4. **Weekly row-count reconciliation** — safety net for data-quality drift beyond schema changes
5. **Alert routing** — all drift alerts go to the same channel as pipeline failures, with the same SLA

This turns a "days to detect" incident into a "same-day alert" with an actionable diff.
