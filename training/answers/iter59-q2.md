# Iter59 Q2 — Answer

**Question**: We have Debezium set up to stream row changes from our Postgres events table into Iceberg. Everything was working fine until our backend team ran a migration that renamed the `user_id` column to `account_id` and dropped a column called `legacy_source` entirely. Nobody warned us ahead of time. I noticed because dashboard numbers started looking off. What actually happens to the Debezium and Iceberg pipeline when Postgres schema changes like this mid-stream — does Debezium detect it, does Iceberg break, or does data just silently go wrong? And how do we protect against this going forward?

---

## Answer

Your dashboard numbers look wrong because the failure **is entirely silent** — Debezium detects the schema change, but neither Debezium nor Iceberg forces the error to the surface. Instead, the pipeline breaks in a way that looks like it still works.

### What Debezium sees: DDL detection via WAL relation messages

When your backend team ran `ALTER TABLE events RENAME COLUMN user_id TO account_id`, Postgres does **not** emit an explicit "column renamed" event. Instead, the next WAL record written to that table includes a **relation message** — a structural description of the table's current column layout at that moment. Debezium reads this and learns "the table now has `account_id` instead of `user_id`."

This detection is automatic. Debezium does not miss the rename.

**However**: Debezium does not re-emit historical rows with the new schema. Events published before the ALTER TABLE still have `user_id` in the Kafka topic. Events published after have `account_id`. The `legacy_source` column is completely absent from new events — not null, just missing.

### What happens in Iceberg: silent schema drift

Your Spark consumer sees a mix of schemas:
- Old events: `{ user_id: 12345, legacy_source: "mobile", ... }`
- New events: `{ account_id: 12345, ... }` (no `legacy_source`)

If your consumer does not handle schema evolution explicitly, the Iceberg table silently drifts:
- `user_id` column stays in the table — populated for old rows, NULL for all new rows
- `account_id` column is added — NULL for old rows, populated for new rows
- `legacy_source` column stays — old rows have data, all new rows have NULL

**No exception is raised.** Iceberg allows nullable columns to be absent in some data files — this is a feature of schema evolution. So queries still run and dashboards still show numbers. The numbers are just wrong. A query like `WHERE user_id = 12345 AND occurred_at > now() - interval '7' day` returns empty, because `user_id` is NULL for all recent rows.

### Why this fails quietly

Iceberg is designed to allow columns that are present in some data files and absent in others — "partial columns" power safe schema evolution. But in the rename case, the old column name (with data) and the new column name (also with data) both exist in the table simultaneously. Iceberg doesn't know they're logically the same column. No error, just wrong data.

### How to detect drift after the fact

Compare the Iceberg table schema against the live Postgres schema:

```sql
-- In Trino, see what columns Iceberg has:
SHOW COLUMNS FROM iceberg.analytics.events;

-- In Postgres, see what actually exists now:
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'events'
ORDER BY ordinal_position;
```

If Iceberg has both `user_id` (all NULL for recent rows) and `account_id` (populated for recent rows) — that's the smoking gun.

### Safe recovery path: full refresh from Postgres

The safest recovery is to read the entire Postgres table fresh and replace the Iceberg table:

```python
events_df = spark.read.jdbc(
    url=PG_URL,
    table="(SELECT * FROM public.events) t",
    properties=PG_PROPS,
)
events_df.writeTo("iceberg.analytics.events").using("iceberg").createOrReplace()
```

This resets both schema and data to exactly match the current Postgres state. `createOrReplace()` drops the old table first — readers see a brief window where the table is empty or missing. If downtime is unacceptable, use the **staging table + view swap** pattern instead: rebuild into `events_staging`, validate, then atomically swap a Trino view from old to new.

### Why renames are worse than adds or drops

- **Adding a column**: Iceberg handles cleanly — old rows get NULL for the new column, new rows have data.
- **Dropping a column**: Also handled — old data files retain it, new events omit it, queries return NULL for old rows.
- **Renaming a column**: This appears as a DROP + ADD at the replication level. Debezium can't detect "this was a rename" — it just sees the old name gone and a new name appeared. Iceberg ends up with both columns, each with partial data. This is the silent killer.

### Process fixes going forward

**1. Required notification process** (start immediately): Require backend engineers to notify the data team at least 24 hours before any schema migration touching analytics pipeline columns. This catches nearly all issues since most schema changes are planned migrations.

**2. Automated schema-drift detection** (add to Spark job startup):

```python
def preflight_schema_check(spark, pg_table, iceberg_table):
    pg_cols = {row.column_name for row in spark.read.jdbc(
        url=PG_URL,
        table=f"(SELECT column_name FROM information_schema.columns "
              f"WHERE table_schema='public' AND table_name='{pg_table}') t",
        properties=PG_PROPS,
    ).collect()}

    iceberg_cols = {row.col_name for row in spark.sql(
        f"DESCRIBE TABLE iceberg.analytics.{iceberg_table}"
    ).collect() if row.col_name and not row.col_name.startswith("#")}

    new_in_pg = pg_cols - iceberg_cols
    removed_from_pg = iceberg_cols - pg_cols
    if new_in_pg or removed_from_pg:
        alert_slack(f"Schema drift: new={new_in_pg}, removed={removed_from_pg}")
        raise RuntimeError("Schema mismatch — refusing to write drifted data")
```

This stops the job on startup if drift exists, preventing further damage.

**3. Optional: Schema registry** (only if unplanned changes are common): Adopt Confluent Schema Registry or Apicurio so Debezium enforces schema compatibility before events flow to Kafka. The registry either approves the change (compatible) or rejects it (incompatible), forcing an explicit decision. Trade-off: operational overhead (another service, API calls per message).

### Summary

| What happened | Why |
|---|---|
| Debezium detects the rename | WAL relation message after the ALTER TABLE |
| Iceberg silently adds both columns | Nullable column addition is always allowed |
| Queries return wrong data | Old `user_id` is NULL for new rows; `account_id` doesn't exist for old rows |
| No error raised | This is Iceberg's designed behavior for schema evolution |
| **Fix** | Full refresh from Postgres (staging table swap if downtime matters) |
| **Prevention** | Notification process + automated drift detection at job startup |
