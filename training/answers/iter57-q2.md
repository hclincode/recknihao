# Iter57 Q2 — Answer

**Question**: We have a `product_catalog` table in Postgres — about 8 million rows — that we do a full nightly refresh on into Iceberg, because it has frequent updates and hard deletes that are hard to track incrementally. Right now we use `createOrReplace()` in Spark, which drops the Iceberg table and rebuilds it from scratch. The rebuild takes about 25 minutes, and during that whole window our dashboard queries either fail or return empty results because the table is gone or half-loaded. We can't switch to incremental easily because the source table doesn't have reliable change tracking. How do we reload the entire table every night without that downtime window?

---

## Answer

Your problem is that `createOrReplace()` is destructive — it drops the entire Iceberg table to rebuild it. Any dashboard query during those 25 minutes sees a missing or half-loaded table. The fix is the **staging table pattern with an atomic view swap**: write the full reload into a separate staging table while the live table stays completely available, then switch readers over atomically using a view.

### Why `createOrReplace()` causes the gap

When you call `df.writeTo("iceberg.analytics.product_catalog").using("iceberg").createOrReplace()`, Spark drops the entire table, creates a new empty one, then writes 8 million rows over 25 minutes. Between drop and completion, the table doesn't exist or is partial. Any query during this window fails or returns incomplete data.

### The staging table solution

Write the full reload into a **separate staging table** while the live table remains untouched. Once staging is fully loaded, switch readers atomically via a view.

**Step 1: Create the staging table (one-time setup)**
```sql
CREATE TABLE iceberg.analytics.product_catalog_staging (
    product_id BIGINT,
    name VARCHAR,
    price_cents BIGINT,
    category VARCHAR,
    updated_at TIMESTAMP
) USING iceberg;
```

**Step 2: Write full reload into staging (nightly Spark job)**
```python
# Read all 8M rows from Postgres with parallel partitioned reads
df = (spark.read.format("jdbc")
    .option("url", "jdbc:postgresql://pg-primary:5432/app")
    .option("dbtable", "public.product_catalog")
    .option("partitionColumn", "product_id")
    .option("lowerBound", 1)
    .option("upperBound", 10_000_000)
    .option("numPartitions", 16)
    .load())

# Write into STAGING — safe because it affects staging only, not the live table
df.writeTo("iceberg.analytics.product_catalog_staging").using("iceberg").createOrReplace()
```

During those 25 minutes, staging is being rebuilt, but the live table is completely untouched. Dashboards querying the live table see consistent, complete data the entire time.

**Step 3: Update a view to atomically switch readers**

Readers point their dashboards at a view, not the raw table:

```sql
-- One-time setup: create view pointing at the live table
CREATE VIEW iceberg.analytics.product_catalog_view AS
SELECT * FROM iceberg.analytics.product_catalog;

-- After each nightly Spark job completes successfully, swap to staging:
CREATE OR REPLACE VIEW iceberg.analytics.product_catalog_view AS
SELECT * FROM iceberg.analytics.product_catalog_staging;
```

The view swap is **atomic** — the moment `CREATE OR REPLACE VIEW` commits, all new queries see the complete new data. There is no gap between old and new.

### How Iceberg snapshot isolation makes this safe

Every write to an Iceberg table creates a new immutable snapshot. Readers always see one complete, consistent snapshot — never a partial write. When your 25-minute Spark job finishes, it commits one snapshot containing all 8 million rows. Readers seeing that snapshot get all rows at once, with no partial states possible.

### Keeping a rollback option

Before each nightly job, rotate the previous staging to a backup:

```sql
ALTER TABLE iceberg.analytics.product_catalog_staging RENAME TO product_catalog_staging_prev;
-- Spark job writes fresh data into a new product_catalog_staging
-- After validating the new data is correct:
DROP TABLE iceberg.analytics.product_catalog_staging_prev;
```

If the new load has data quality issues, revert the view back to `product_catalog_staging_prev` and you're instantly back on last night's good data.

### Maintenance after cutover

After a few nightly loads, add compaction and snapshot expiry to your scheduled jobs:

```sql
-- Compact small files
CALL iceberg.system.rewrite_data_files('analytics.product_catalog_staging');

-- Expire old snapshots weekly
CALL iceberg.system.expire_snapshots(
  table      => 'analytics.product_catalog_staging',
  older_than => current_timestamp - interval '7' day,
  retain_last => 1
);
```

### Summary

Write to a staging table instead of the live table → Iceberg's atomic snapshot ensures readers never see partial data → update a view to switch atomically. Dashboards see old data until the view updates, then instantly see the complete new data. Zero-downtime full refresh.
