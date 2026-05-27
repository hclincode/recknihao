# Iter138 Q1 — Answer

**Question**: "We renamed a column in our `events` Iceberg table a few months ago — the column used to be called `user_id` and we renamed it to `customer_id` to match our new naming convention. We ran the `ALTER TABLE events RENAME COLUMN user_id TO customer_id` command in Trino and it seemed to work fine. But I've been wondering: what actually happened to the old Parquet files sitting in MinIO from before the rename? Do they still have a column named `user_id` in them, and if I query historical data does Trino somehow know to map the old name to the new one, or do those old rows come back with NULLs in `customer_id`? Separately, we have a different column that contains some sensitive PII that we want to remove entirely — if I run `ALTER TABLE events DROP COLUMN pii_field`, does that data actually get deleted from MinIO, or is it still sitting there in the old Parquet files just hidden from queries?"

---

## The Core Principle: Iceberg Uses Field IDs, Not Column Names

The most important thing to understand: **Iceberg tracks columns by a unique numerical field ID, not by human-readable name.** When you renamed `user_id` to `customer_id`, Iceberg updated only the metadata — not the Parquet files.

**Before the rename:**
```
Field ID  │ Column Name
─────────────────────────
     1    │ user_id
     2    │ event_name
     3    │ occurred_at
```

**After `ALTER TABLE events RENAME COLUMN user_id TO customer_id`:**
```
Field ID  │ Column Name
─────────────────────────
     1    │ customer_id   ← only the metadata name changed
     2    │ event_name
     3    │ occurred_at
```

The Parquet files from before the rename still have the original binary column data. That data is **physically labeled as field ID 1** in the Parquet footer — the column name stored in the footer is irrelevant. No Parquet bytes were rewritten. The files on MinIO are untouched.

---

## How Trino Maps Old Names to New Names: Transparent via Field IDs

When you query historical data, Trino performs this mapping automatically:

1. **Reads the current table schema** from Iceberg metadata: `customer_id` = field ID 1.
2. **Opens an old Parquet file** that has field ID 1 (the original `user_id` data).
3. **Maps field ID 1 → "customer_id"** per the current schema and returns it under the new name.

```sql
-- Always returns rows under the CURRENT schema name
SELECT customer_id, COUNT(*) AS events
FROM iceberg.analytics.events
WHERE occurred_at >= DATE '2026-01-01'
GROUP BY customer_id;
```

This works correctly for historical data from before the rename. **You will NOT see NULLs.** The mapping is transparent because Parquet files never had a "column name" that Trino cares about — they had a field ID, and that field ID is consistent across all files.

---

## DROP COLUMN Is Also Metadata-Only — Data NOT Deleted from MinIO

If you run:

```sql
ALTER TABLE events DROP COLUMN pii_field;
```

**What Iceberg does:**
- Updates the table's schema metadata to remove `pii_field` (field ID 7) from the current column list.
- **Does NOT delete or rewrite any Parquet files** in MinIO.
- All existing Parquet files that contained `pii_field` are byte-for-byte unchanged.

**What actually happens to your PII data:**
- The original Parquet files still contain the PII data under field ID 7.
- Trino queries ignore field ID 7 because the current schema says it doesn't exist — `SELECT *` returns only current columns.
- **But if someone gains direct access to MinIO**, the data is still there. A raw Parquet reader (Apache Arrow, Spark with direct MinIO access, AWS CLI + parquet-tools) can inspect the file structure and read field ID 7 even though the Iceberg schema no longer references it.

```python
# A Spark job reading raw Parquet from MinIO bypasses Iceberg schema enforcement
df = spark.read.parquet("s3a://minio/lakehouse/analytics/events/...")
df.printSchema()  # Shows ALL original columns including the "dropped" pii_field
df.select("pii_field").show()  # PII data is readable
```

**The bottom line:** `DROP COLUMN` makes data invisible to Trino queries but does NOT remove the bytes from MinIO. For PII, you must physically rewrite the files.

---

## How to Actually Delete PII Data: Rewrite + Expire + Orphan Cleanup

Physically removing PII from MinIO requires three steps in order:

### Step 1: Rewrite data files (excludes the dropped column)

```python
# Spark — rewrite affected partitions using current schema (which excludes pii_field)
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table   => 'analytics.events',
        options => map('target-file-size-bytes', '268435456')
    )
""")
```

When `rewrite_data_files` reads the old Parquet files, it writes new files using the **current table schema** (which no longer includes field ID 7). The new files contain no PII bytes. The old files are now referenced only by older snapshots.

### Step 2: Expire snapshots referencing the old PII-containing files

```sql
-- Trino 467
ALTER TABLE iceberg.analytics.events
EXECUTE expire_snapshots(retention_threshold => '1d');
```

This removes old snapshots from the table history, making the old Parquet files (which contain the PII) unreferenced orphans.

### Step 3: Remove orphan files from MinIO

```sql
-- Trino 467
ALTER TABLE iceberg.analytics.events
EXECUTE remove_orphan_files(retention_threshold => '1d');
```

This physically deletes the orphaned files from MinIO. The PII bytes are gone.

**All three steps are required.** Steps 1 + 2 alone leave the files in MinIO (just unreferenced). Only step 3 actually deletes the bytes.

If the PII is spread across many partitions and you need a guaranteed full purge:

```python
# Rewrite the entire table (expensive but guaranteed clean)
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table   => 'analytics.events',
        options => map('target-file-size-bytes', '268435456', 'rewrite-all', 'true')
    )
""")
# Then expire_snapshots and remove_orphan_files as above
```

---

## When NULLs Actually Appear (Edge Cases)

Column renaming and dropping don't cause NULLs. NULLs appear when:

**1. You ADD a new column:**
```sql
ALTER TABLE events ADD COLUMN new_field VARCHAR;
```
Old Parquet files have no data for the new field ID. Trino returns NULL for all historical rows on `new_field`. This is expected and correct.

**2. You backfill from a JSON/MAP fallback to a typed column:**
If you promoted a key from a raw JSON string to a top-level column, historical rows that predate the write of the promoted column return NULL until you run a backfill `MERGE INTO`.

**3. Schema mismatch during recovery:**
If you `register_table` against old metadata, column IDs may not align with current files and some columns may return NULL.

**For a simple RENAME or DROP: no NULLs.** The field ID is stable; only the metadata label changes.

---

## Summary

| Operation | Parquet files rewritten? | Data deleted from MinIO? | Risk |
|---|---|---|---|
| `RENAME COLUMN` | No | N/A | None — transparent via field ID mapping |
| `DROP COLUMN` | No | No | PII persists in MinIO; readable via direct file access |
| `rewrite_data_files` + `expire_snapshots` + `remove_orphan_files` | Yes | Yes | Required for true PII deletion |

For your PII column: run all three maintenance steps in sequence after `DROP COLUMN`. Until you do, the data exists physically in MinIO even though Trino queries don't surface it.
