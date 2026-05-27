# Iter144 Q1 — Answer

**Question**: "We renamed a column in one of our main event tables in the lakehouse — changed `user_id` to `account_id` to match a rebrand. Our data engineers said this was 'safe' because Iceberg handles schema evolution. But now I'm worried: we have two years of old data files sitting in MinIO that were written when the column was still called `user_id`. What actually happens to those old files? Do queries suddenly break, or does something magic happen behind the scenes to stitch the old and new names together?"

---

## How Iceberg Column Rename Works: Field IDs, Old Files, and the Transparency Guarantee

Your data engineers were right: **the rename is safe**. Iceberg handles this situation perfectly, and your old data files remain fully readable after a rename. The mechanism is that **Iceberg tracks columns by numeric field ID, not by column name**. When you rename `user_id` to `account_id`, the underlying field ID stays the same, and old Parquet files transparently follow the new name.

---

## The Key Mechanism: Field IDs, Not Names

In Iceberg's metadata layer, every column is assigned a unique numeric **field ID** when it's first created. That ID never changes. Parquet files are written with field IDs in their footers, and readers use those IDs to locate column data — the column name is just a label on top.

When you run `ALTER TABLE ... RENAME COLUMN user_id TO account_id`, Iceberg only updates the metadata mapping that says "field ID 1 is now called `account_id`" — it does **not** rewrite a single Parquet file. The old files still contain the data at field ID 1, and when a reader asks for the column named `account_id`, Iceberg internally resolves that to field ID 1 and pulls the data from the correct location in those old files.

**Result: queries work transparently.** A query like `SELECT account_id FROM events` will correctly return data from the renamed column, including data from files written two years ago when the column was called `user_id`.

---

## What RENAME COLUMN Actually Does

In Trino 467:
```sql
ALTER TABLE iceberg.analytics.events RENAME COLUMN user_id TO account_id;
```

This is a **metadata-only operation**. Iceberg:
1. Updates the catalog to say field ID (e.g., 1) is now called `account_id` instead of `user_id`
2. Creates a new table metadata version reflecting the schema change
3. Leaves every Parquet file on MinIO completely untouched

The entire operation completes in milliseconds, even on a multi-terabyte table. No data is rewritten, no Spark job is needed, and there's zero downtime.

---

## Old Files Remain Transparent to Queries

At read time:
1. Trino queries the table and asks for column `account_id`.
2. Iceberg's reader consults the current schema metadata: field ID 1 = `account_id`.
3. When reading an old Parquet file written two years ago (when that column was called `user_id`), Iceberg locates the data using field ID 1, not the column name.
4. The data flows to Trino with the current column name (`account_id`).

No special "stitching" required. The old files are not rewritten, not reorganized, not even touched. Engineers and downstream tools see one consistent schema with `account_id`, while old Parquet files continue sitting on MinIO unchanged.

---

## What Can Still Break After a Rename

While Iceberg itself handles the rename safely, **downstream consumers** may break because they reference column names as strings:

### 1. Spark jobs with hardcoded column lists

If a Spark job reads or writes with an explicit column list containing `user_id`:
```python
df.select("user_id", "event_name", ...)  # breaks — column no longer named user_id
```
**Fix:** Update the Spark job's column references to use `account_id`.

### 2. Trino views and dbt models

Any `CREATE VIEW` or dbt model that explicitly references `user_id` will fail:
```sql
-- This breaks after the rename:
CREATE VIEW analytics.user_summary AS
SELECT user_id, COUNT(*) as events FROM events GROUP BY user_id;
-- Error: column "user_id" does not exist
```
**Fix:** Update the view definition and any dbt `.sql` files to use `account_id`.

### 3. Dashboards and BI tools with hardcoded column references

Any analytics tool (Metabase, Tableau, etc.) with a saved query that selects `user_id` will error on the next refresh. **Fix:** Update saved queries in the BI tool.

### 4. Application code with column name mappings

If your app has ORM or config-based column mappings referencing `user_id`, update them to `account_id`.

---

## The Debezium CDC Story: What Happens to New Events

If you're using Debezium to stream changes from Postgres into this Iceberg table:

1. The Postgres source connector detects the Postgres-side column rename via WAL RELATION messages on the next DML against the table.
2. Debezium starts emitting the new column name (`account_id`) in the `after` payload of change events.
3. Your Spark Structured Streaming consumer's `MERGE INTO` must already use the new column name or wildcard syntax.

**Safe sequence for a CDC pipeline:**

1. **Stop the Spark Structured Streaming consumer** (Debezium keeps running and buffers events in Kafka).
2. **Run the Iceberg rename** — `ALTER TABLE iceberg.analytics.events RENAME COLUMN user_id TO account_id`.
3. **Rename the column in Postgres** (if you haven't already) — `ALTER TABLE events RENAME COLUMN user_id TO account_id`.
4. **Update your Spark consumer** to reference `account_id` instead of `user_id`.
5. **Resume the Spark consumer**.

After step 5, new events arriving from Postgres will have `account_id` in Kafka, and MERGE INTO will correctly map them to the `account_id` column in Iceberg. Old rows in Iceberg (from before the rename) will continue to have `account_id` because of the field-ID mechanism.

If your MERGE INTO uses wildcard syntax (`UPDATE SET *`, `INSERT *`), the rename is automatically correct after the Iceberg DDL. If it uses explicit column lists, update those lists to `account_id`.

---

## Summary

| Component | What happens on RENAME COLUMN | Action needed? |
|---|---|---|
| Iceberg metadata | Field ID mapping updated instantly | None (this is the rename) |
| Old Parquet files (2 years) | Untouched — field ID still maps correctly | None |
| Trino queries on the table | Work automatically using new name | None |
| Spark jobs with explicit column lists | Break — reference old string name | Yes — update to `account_id` |
| Trino views / dbt models | Break — reference old string name | Yes — update to `account_id` |
| Debezium events in Kafka | New events use new name after Postgres rename | Yes — update Spark consumer |
| Dashboards / BI tools | Saved queries referencing old name break | Yes — update saved queries |

Your old data is safe. The only work is updating downstream string references from `user_id` to `account_id`. Run a quick sanity check after the rename:

```sql
SELECT account_id FROM iceberg.analytics.events LIMIT 1;
```

If this returns data, the rename succeeded and field-ID mapping is working correctly.
