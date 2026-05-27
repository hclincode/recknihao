# Answer to Q1: Column Rename Detection in CDC Pipeline (Iter 321)

## Understanding Debezium's Handling of Column Renames

Your situation is a classic CDC gotcha. Here's what actually happened:

### How Debezium Detects Column Operations

Debezium **does NOT detect column renames as renames**. Instead, it sees a rename as two separate operations: a column dropping off the schema and a new column appearing in its place.

When someone runs `ALTER TABLE your_table RENAME COLUMN old_name TO new_name` in Postgres:

1. Debezium does not receive an explicit "rename this column" message in the replication stream.
2. Instead, the next time a row is written to that table (INSERT/UPDATE/DELETE), Postgres emits a **WAL relation message** — essentially a schema snapshot showing the current column layout.
3. Debezium compares this new relation message to its cached schema and sees: "old column is gone, new column exists."
4. Depending on your Spark consumer's configuration, this triggers one of two outcomes:
   - **Default**: Silent column drop. The old column name disappears from events. The new column name never appears in the target Iceberg table. Data silently vanishes.
   - **With auto-evolution enabled**: The old column is dropped from Iceberg (metadata-only) and the new column is added. But your Spark job's hardcoded column list probably still references the old name, so you miss the data anyway.

**This is why your Iceberg table still has the old column name with no data — Debezium never created an event for the new column name.**

### Why This Happens: Postgres Doesn't Send Rename Events

Postgres's logical replication protocol is designed to track *table structure*, not *DDL history*. It tells Debezium "here are the columns that exist now" but never says "you renamed something." This is different from MySQL/MariaDB/SQL Server, which use a separate schema-history Kafka topic for DDL events.

### The Safe Path: Don't Rename in Postgres. Migrate Instead.

When the backend team needs to rename a column, the safe pattern is:

1. **Add a new column in Postgres** with the desired name (nullable, no default needed).
2. **Let CDC cycles run** so Debezium sees the new column and your Iceberg table gets `ADD COLUMN` (metadata-only, instant).
3. **Update your Spark job** to populate both old and new columns during transition.
4. **Update consuming code** (dashboards, reports, downstream jobs) to use the new name.
5. **After a safety window** (days or weeks), drop the old column from Postgres.

### If You've Already Renamed in Postgres: The Repair Pattern

**Step 1: Add the new column to Iceberg.**

```sql
ALTER TABLE iceberg.analytics.your_table ADD COLUMN new_name VARCHAR;
```

**Step 2: Update your Spark job** to reference the new column name from Kafka events:

```python
# Updated to use new column name from Debezium events
spark.sql("""
  MERGE INTO iceberg.analytics.your_table AS t
  USING source_data AS s
  WHEN MATCHED THEN UPDATE SET 
    t.col1 = s.col1,
    t.new_name = s.new_name
  WHEN NOT MATCHED THEN INSERT (col1, new_name) VALUES (s.col1, s.new_name)
""")
```

**Step 3: Backfill the new column** with historical values from the old column:

```sql
UPDATE iceberg.analytics.your_table
SET new_name = old_name
WHERE new_name IS NULL AND old_name IS NOT NULL;
```

**Step 4: Once data is stable**, optionally drop the old column from Iceberg:

```sql
ALTER TABLE iceberg.analytics.your_table DROP COLUMN old_name;
```

### Prevention: Detect Renames Before They Cause Data Loss

Your preflight schema-diff check catches renames as a "DROP old + ADD new" pair. When you see both sides flagged simultaneously on the same table, treat it as a likely rename — alert on-call and pause the consumer until the Iceberg schema is updated.

Also, avoid implicit column matching in MERGE INTO. Use explicit column lists so schema mismatches cause errors (visible immediately) rather than silent data loss.

**Key takeaway**: Postgres column renames are invisible to Debezium because they don't flow through the logical replication stream as rename events. Always treat a Postgres rename as "old column removed, new column added" and make the equivalent changes in your Iceberg schema + Spark job before resuming.
