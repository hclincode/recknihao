# Iter 229 Q1 — MERGE Source-Deduplication Failure ("multiple source rows match the same target row")

## Answer

### What "multiple source rows match the same target row" means

When you run a `MERGE INTO` operation, Trino evaluates the join condition you specify — the `ON` clause that says which source rows should match which target rows. If your join condition is `ON target.customer_id = source.customer_id`, the system is finding that **multiple rows in your source table have the same customer_id value, all trying to match a single row in the target**.

`MERGE INTO` is designed to perform at most one action per target row. The SQL says "for each target row, either update it or insert a new one." But when two or more source rows match the same target row via your join key, the database doesn't know which one to use — should it update the target with data from source row A or source row B? This ambiguity is an error because it would produce undefined or unpredictable results.

### Why this happens when your data looks fine

You said your source data "looks fine" with one row per customer ID — but the error is thrown at query execution time when the join is evaluated. Common causes:

1. **Your join key isn't actually unique in the source.** The source Iceberg table may have duplicate customer_ids that aren't obvious in manual inspection (e.g., rows from different partitions, late-arriving rows from multiple ingestion batches, or rows from a watermark window that overlaps multiple batches).

2. **The source includes rows you didn't expect.** If you're pulling from a staging table or transformation layer, that intermediate may have duplicates before they're surfaced to MERGE.

3. **You're joining on a non-unique column.** If the ON clause uses something other than a primary key (like a name or email that might appear twice), you'll get multiple matches.

### How to fix it

Before running the MERGE, **deduplicate the source data to ensure each join-key value appears exactly once**. In SQL (using a subquery before the MERGE):

```sql
MERGE INTO billing_mysql.billing_db.customer_usage AS target
USING (
    -- Deduplicate: keep only the latest row per customer_id
    SELECT * FROM (
        SELECT *,
               ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rn
        FROM iceberg.analytics.customer_aggregates
        WHERE compute_date = DATE '2026-05-27'
    ) WHERE rn = 1
) AS source
ON target.customer_id = source.customer_id
WHEN MATCHED THEN
    UPDATE SET total_usage = source.total_usage, tier = source.tier
WHEN NOT MATCHED THEN
    INSERT (customer_id, total_usage, tier)
    VALUES (source.customer_id, source.total_usage, source.tier);
```

The `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC)` pattern keeps only the newest row per customer ID, guaranteeing each join-key value appears exactly once in the source.

### This is a hard SQL requirement, not a Trino quirk

One-source-row-per-target-row is a standard SQL requirement for MERGE, not specific to Trino or your connector setup. It exists in standard SQL (ISO SQL:2003 MERGE semantics) because allowing multiple source rows to match one target row makes the result non-deterministic. Trino enforces this at runtime.

### Prevention for incremental ingestion pipelines

If you're doing incremental ingestion (reading changed rows from MySQL with a watermark on `updated_at`), this deduplication is critical because late-arriving rows can appear multiple times across batches when the watermark window overlaps. Always deduplicate on the primary key before the MERGE target, taking the latest row by timestamp. This should be a standard step in any MERGE-based upsert pipeline, not an afterthought.
