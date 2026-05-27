# Answer to Q1: Adding a new field to an existing STRUCT column in Iceberg (Iter 326)

## The correct DDL syntax

To add a new field `sso_enabled` to your `metadata` STRUCT column in Iceberg on Trino 467, use the **dotted-path form** of `ALTER TABLE ADD COLUMN`:

```sql
ALTER TABLE iceberg.analytics.events ADD COLUMN metadata.sso_enabled BOOLEAN;
```

This syntax works identically in both Spark SQL and Trino 467 — you address nested fields inside a STRUCT using a dot (`.`) to separate the parent column name from the nested field name.

## Why `ALTER COLUMN metadata ADD` doesn't work

The syntax you tried — `ALTER TABLE iceberg.analytics.events ALTER COLUMN metadata ADD sso_enabled BOOLEAN` — is **not valid Iceberg DDL**. Iceberg does not support an `ALTER COLUMN ... ADD` form for adding fields to nested structures. The only way to add a field to a STRUCT is with `ALTER TABLE ADD COLUMN` using the dotted-path form shown above. This is how Iceberg distinguishes between adding a top-level column (no dot: `ADD COLUMN sso_enabled`) and adding a nested field inside a STRUCT (dotted path: `ADD COLUMN metadata.sso_enabled`). If you submit the `ALTER COLUMN` syntax to Spark SQL, it will reject the statement with a parser error. Trino will similarly return a syntax error.

## What happens to existing rows — NULL behavior

**The operation is metadata-only — no data files are rewritten.** When you run `ADD COLUMN metadata.sso_enabled BOOLEAN`, Iceberg assigns a new unique numeric **field ID** to the new field and updates the table schema metadata. The underlying Parquet files on MinIO remain completely untouched.

**Existing rows return NULL for the new field.** When you query old data files (those written before the `ADD COLUMN` statement), Iceberg reads them using the current table schema. Because the old Parquet files do not have a column chunk for the new field ID, the read automatically returns NULL for `metadata.sso_enabled` on every historical row. This happens silently and correctly — no error or corruption.

**New writes immediately include the field.** After the DDL runs, any Spark ingestion job writing to the table will see `metadata.sso_enabled` as part of the schema and can write actual values. New rows will have the field physically stored in their Parquet files.

**Why this is safe — the field ID mechanism.** Iceberg matches data columns to schema columns by **numeric field ID**, not by column name. An old Parquet file has no chunk with the new field ID, so it returns NULL. A new file has the field ID and carries actual values. Rename the column tomorrow and the old files still match correctly (the field ID stays the same). This ID-based matching is why `ADD COLUMN`, `DROP COLUMN`, and `RENAME COLUMN` are all metadata-only operations — no rewrite needed.

## Handling the new field in your Spark ingestion job

Once the DDL is deployed, your ingestion pipeline needs to start populating the new field for incoming rows:

```python
from pyspark.sql.functions import col, struct

# After reading from your source (Postgres JDBC, Kafka, etc.)

# Extract sso_enabled from source
df = df.withColumn("sso_enabled", col("source_sso_column"))

# Rebuild the metadata STRUCT with the new field included
df = df.withColumn(
    "metadata",
    struct(
        col("account_tier").alias("account_tier"),
        col("region").alias("region"),
        col("feature_flags").alias("feature_flags"),
        col("contract_start").alias("contract_start"),
        col("contract_end").alias("contract_end"),
        col("seat_count").alias("seat_count"),
        col("billing_cycle").alias("billing_cycle"),
        col("support_tier").alias("support_tier"),
        col("sso_enabled").alias("sso_enabled")   # new field
    )
)

df.writeTo("iceberg.analytics.events").append()
```

**Backfill for historical rows (optional):** If you want old rows to reflect SSO status rather than staying NULL, run a one-time Spark job after the DDL:

```python
from pyspark.sql.functions import col, coalesce, lit

df = spark.read.table("iceberg.analytics.events")
df_updated = df.withColumn(
    "metadata",
    col("metadata").withField("sso_enabled", coalesce(col("metadata.sso_enabled"), lit(False)))
)
df_updated.writeTo("iceberg.analytics.events").overwritePartitions()
```

Without this backfill, queries like `WHERE metadata.sso_enabled = true` will silently exclude all historical rows. This is the most common gotcha with STRUCT schema evolution — dashboards show zero historical data with no obvious error.

## STRUCT schema evolution vs top-level columns

| Operation | Top-level column | Nested STRUCT field |
|---|---|---|
| Add field | `ADD COLUMN new_field BOOLEAN` | `ADD COLUMN metadata.new_field BOOLEAN` |
| Drop field | `DROP COLUMN field` | `DROP COLUMN metadata.field` |
| Rename field | `RENAME COLUMN field TO new_name` | `RENAME COLUMN metadata.field TO metadata.new_name` |
| Cost | Metadata-only | Metadata-only |
| Old rows | Return NULL | Return NULL |

Key distinctions:
- **Cannot use `MODIFY COLUMN` or `ALTER COLUMN ... ADD`** for STRUCT field addition — dotted-path `ADD COLUMN` is the only valid form.
- **New STRUCT fields are always nullable** — you cannot add a `NOT NULL` nested field via `ADD COLUMN`. Old rows genuinely have no value for the new field.
- **Field ID matching** means renames are safe and retroactive — old files immediately match the renamed field without rewrite.

## Timeline for your SSO rollout

1. Run `ALTER TABLE iceberg.analytics.events ADD COLUMN metadata.sso_enabled BOOLEAN` from Trino 467 or Spark SQL.
2. (Optional) Run a backfill job to populate `sso_enabled` for historical rows.
3. Deploy the ingestion job update that writes `sso_enabled` for new events.
4. Verify: `SELECT COUNT(*) FROM iceberg.analytics.events WHERE metadata.sso_enabled IS NULL` — should be zero for recent dates post-backfill.

The new field is immediately queryable from Trino after the DDL runs — no restarts or synchronization needed.
