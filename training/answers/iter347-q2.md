# Answer to Q2: Column Rename Through Debezium CDC into Iceberg (Iter 347)

Your worry is justified, but the good news: **Iceberg treats a rename as a rename, not as a drop-plus-add.** Historical data stays with the column — preserved under the new name.

## How Iceberg handles the rename

Iceberg tracks columns by **field ID**, not by name. When a column is renamed in Postgres and Debezium streams the change, the Iceberg column ID stays the same — only the column name changes. This means:

- All historical Parquet files that contain data for that column still have the data, and Iceberg can still read it under the new name.
- You run one metadata-only ALTER (milliseconds, no file rewrites).
- No data is stranded, no queries break, no storage duplication.

## The timeline in your scenario

1. **Postgres side**: `ALTER TABLE users RENAME COLUMN user_name TO username` runs (instant, catalog-only).
2. **Postgres WAL**: Postgres does NOT emit a DDL event for the rename. Debezium doesn't see it yet.
3. **Next write to that table**: The next `INSERT`, `UPDATE`, or `DELETE` generates a WAL RELATION message describing the current column layout — which now says `username`, not `user_name`.
4. **Debezium picks it up**: The connector reads the RELATION message, updates its cached schema, and **starts emitting events with the `username` column name**.
5. **Your Spark consumer tries to write**: If your consumer does `MERGE INTO` and you haven't updated the Iceberg schema yet, the merge fails — the source DataFrame has `username` but the Iceberg table still expects `user_name`.

## The fix: one metadata-only ALTER

The moment Debezium starts emitting `username` in events, pause your consumer, then run:

```sql
-- From Trino or Spark — syntax is identical in both:
ALTER TABLE iceberg.analytics.events RENAME COLUMN user_name TO username;
```

This is metadata-only in Iceberg's catalog. It completes in milliseconds. No data files are rewritten. No downtime beyond consumer pause/resume.

## Historical data is safe

All existing data in `user_name` remains readable:
- Old Parquet files still contain the bytes for that column.
- The column ID that Iceberg tracks internally hasn't changed.
- When you query `SELECT * FROM iceberg.analytics.events`, the column appears under `username` and all historical values are there.

## Warning: do NOT rely on auto-evolution for renames

If your consumer has `write.spark.accept-any-schema=true` and `mergeSchema=true` enabled, there is a real risk: the consumer might auto-create a new `username` column (with a NEW column ID) instead of recognizing that `user_name` was renamed. You'd end up with two columns in the schema — one with historical data under the old field ID, one empty under the new field ID.

**Always run the explicit `ALTER TABLE RENAME COLUMN` first.** Auto-evolution safely handles nullable ADD COLUMN — it cannot understand rename intent.

## Concrete production runbook

1. Pause the Spark consumer.
2. Run the rename in Iceberg:
   ```sql
   ALTER TABLE iceberg.analytics.events RENAME COLUMN user_name TO username;
   ```
3. Update any consumer code that hard-codes the column name.
4. Resume the consumer.

**Time to complete:** seconds. **Risk of data loss:** zero. Iceberg's field-ID tracking guarantees this is safe.

**Resources cited:** `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
