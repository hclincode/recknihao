# Iter119 Q1 — Answer

**Question**: We're running Debezium to stream changes from our Postgres database into our Iceberg tables. Last week our backend team added a new column to one of our Postgres tables — it's a `NOT NULL` column with no default value, which required a table rewrite in Postgres. After that happened, our CDC pipeline started throwing errors and we had to restart the Debezium connector. I'm worried this is going to keep happening as our schema changes over time. What actually happens at the Debezium level when you add a `NOT NULL` column with no default to a source table, and how do we stop it from breaking the pipeline every time?

---

# What Happens When You Add a NOT NULL Column to Your Postgres Source (and How to Stop Breaking Your CDC Pipeline)

## The Real Problem: Postgres Table Rewrites and Lock Conflicts

When your backend team added a `NOT NULL` column with no default value to a Postgres table, Postgres had to rewrite the entire table to apply the constraint. Here's what happened at the database level:

1. **Table rewrite in Postgres**: Postgres cannot add a `NOT NULL` column with no default value without rewriting the table. It had to copy every row to assign a default (usually NULL initially, then the constraint kicks in). This is a heavy operation that acquires exclusive locks on the table.

2. **Your Debezium connector became blocked**: While Postgres was rewriting the table, Debezium's logical replication connection couldn't proceed. Debezium reads the Write-Ahead Log (WAL) sequentially; when the rewrite happened, the connector was trying to decode WAL records that were affected by the exclusive lock. The replication slot became stalled.

3. **The connector timed out or errored**: After the table rewrite finished, the connector had to catch up on the accumulated WAL. Depending on your configuration, it either timed out waiting to resume, or threw an error that forced a manual restart.

## Why This Keeps Happening (And How to Fix It)

The root cause is that **schema changes in Postgres require coordination with your CDC pipeline**. Debezium doesn't "break" — rather, your pipeline isn't prepared for large DDL operations on tables it's actively streaming.

### What Happens at the Debezium Level

Here's the precise sequence:

1. **Debezium reads the new relation message**: After the table rewrite completes, the next `INSERT`, `UPDATE`, or `DELETE` on that table causes Postgres to emit a **relation message** in the WAL. This relation message describes the table's new column layout. Debezium reads this inline with the next row-level change and learns about the new `NOT NULL` column.

2. **Schema mismatch in your consumer**: The new column appears in Debezium's events, but your Iceberg table doesn't have the column yet. If you're using a `MERGE INTO` consumer (the standard CDC pattern), it silently **drops** the new column from every row it writes. No error is raised — the column just gets filtered out. This is why you see `NULL` values for the new column in Iceberg, even on rows written *after* the schema change.

3. **On table restart**: Some teams experienced a connector restart or error because they were running with strict schema validation, or the table rewrite caused a temporary replication slot lag that exceeded configured timeouts.

## How to Stop This From Breaking Every Time

The fix has two parts: **planning** and **coordination**. Here's the exact procedure your team should follow for any future schema changes to tables that Debezium streams:

### Step 1: Pause Your Spark Consumer (Not Debezium)

If you're using Spark Structured Streaming to write Debezium events to Iceberg, **pause the consumer job**. This prevents it from silently dropping the new column.

```bash
# Stop the Spark Structured Streaming consumer pod/job.
# Debezium itself continues consuming from Postgres and buffering events in Kafka.
kubectl delete pod <streaming-consumer-pod-name>
# Or however you manage job lifecycle (Kubernetes deployment, Airflow DAG, etc.)
```

Do **NOT** restart the Debezium connector — it doesn't need to restart, and restarting it causes unnecessary WAL replay.

### Step 2: Add the Column to Iceberg (Metadata-Only)

Once the consumer is paused, add the new column to your Iceberg target table. This is **metadata-only** and completes in milliseconds, even on a 100 TB table:

```sql
-- In Trino or Spark SQL
ALTER TABLE iceberg.analytics.your_table ADD COLUMN new_column VARCHAR;
```

If the new column is `NOT NULL` in Postgres but you want it nullable in Iceberg (to handle historical rows), just make it nullable here — old rows will return `NULL` for the new column automatically.

### Step 3: Resume Your Consumer

Restart the Spark consumer job. New Debezium events with the new column will now write successfully:

```bash
# Restart the consumer job
kubectl apply -f <streaming-consumer-deployment.yaml>
# Or restart the Airflow DAG, or however you run it
```

### Step 4: Backfill Historical Rows (Optional)

Rows that arrived in Iceberg **between** the Postgres `ADD COLUMN` and your Iceberg `ALTER TABLE` will have `NULL` for the new column (because the Spark consumer silently dropped it while the column didn't exist in the target schema).

If you need those rows to have the real values, run a one-time backfill from Postgres:

```python
# Read the affected window from Postgres PRIMARY (not a replica)
backfill_df = spark.read.jdbc(
    url=PG_PRIMARY_URL,
    table="""(
        SELECT id, new_column
        FROM your_table
        WHERE updated_at >= '2026-05-18'  # timestamp of the ADD COLUMN in Postgres
    ) t""",
    properties=PG_PROPS,
)
backfill_df.createOrReplaceTempView("backfill")

# MERGE the new values into existing rows
spark.sql("""
    MERGE INTO iceberg.analytics.your_table t
    USING backfill s ON t.id = s.id
    WHEN MATCHED THEN UPDATE SET t.new_column = s.new_column
""")
```

## Why the Pipeline Broke (Root Cause Analysis)

1. **Postgres required a table rewrite** because `NOT NULL` with no default is not instantly applicable. Postgres had to allocate space for the new column on every row.

2. **The rewrite acquired exclusive locks**, which blocked your incremental ingestion jobs and temporarily froze the replication slot's progress.

3. **Debezium correctly continued streaming**, but your Iceberg consumer wasn't prepared for the new schema. `MERGE INTO` quietly dropped the column instead of erroring, so the pipeline appeared to work (offsets advanced, row counts grew) but data was silently lost.

4. **You restarted the connector manually** because you saw an error or staleness — but the real problem was that Iceberg's schema needed updating, not Debezium.

## How to Prevent This Going Forward

1. **Coordinate with your CDC pipeline before any table rewrites.** Before adding `NOT NULL` columns, notify the data team that a schema change is coming.

2. **Use the pause-ALTER-resume sequence above** for any `NOT NULL` additions or other column changes on tables Debezium streams.

3. **If the backend team adds columns without coordinating**, you'll see them arrive in Kafka but not in Iceberg. The defense is a **preflight schema check**: run a periodic SQL query that compares the columns in Postgres to the columns in Iceberg, and alert if any column exists in Postgres but not in Iceberg. This catches the silent-drop problem before dashboards surface stale data.

4. **For very large tables where the pause causes operational pain**, use **Debezium's incremental snapshot feature** to re-snapshot just that table while the rest of your CDC pipeline runs normally. This is advanced and documented in the Postgres → Iceberg ingestion resource under "Debezium 2.x incremental snapshot via signal table."
