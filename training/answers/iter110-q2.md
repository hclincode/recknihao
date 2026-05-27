# Iter110 Q2 — Answer

**Question**: We have about 400 tenants in our SaaS product. Most of them are small — maybe 10,000 rows of event data each. But we have 3 or 4 enterprise customers with 50 to 100 million rows each. When one of those big tenants runs a dashboard query, even with a `WHERE tenant_id = ?` filter, it seems like Trino is still doing a lot of work. A smaller tenant with the same query runs in under a second. Is this just a fact of life because they have more data, or is there something about how we've set up the table — like how we're organizing or storing the data — that's making it worse than it needs to be?

---

## Answer

The poor performance for large tenants is **not just a fact of life** — it's a sign that your table's partition strategy is not filtering files effectively for tenant-specific queries. A `WHERE tenant_id = ?` filter should allow Trino to skip most files, but if `tenant_id` is not a partition column, it cannot.

### The root cause: `tenant_id` not in the partition spec

If your events table is partitioned only by time (e.g., `day(event_ts)`) without `tenant_id`, here's what happens:

- A query with `WHERE tenant_id = 'enterprise_acme'` still reads **every file in the date range** to find Acme's rows
- Iceberg's partition pruning skips files only on partition boundaries — if `tenant_id` is not a partition column, Iceberg cannot use it to skip files
- Column statistics (min/max) can help somewhat, but still require opening many files
- A 50–100M row enterprise tenant mixed with other tenants' data means Trino opens hundreds or thousands of files per query

**Why small tenants are fast by accident:** their rows cluster in just a few files or a single partition, so even a full date-range scan touches minimal files.

### The fix: add `tenant_id` to the partition spec

Partition by `(day(event_ts), tenant_id)` instead of time alone:

```sql
-- Trino syntax (new table)
CREATE TABLE iceberg.analytics.events (
  event_id    VARCHAR,
  tenant_id   VARCHAR,
  user_id     VARCHAR,
  event_ts    TIMESTAMP(6),
  payload     VARCHAR
)
WITH (
  partitioning = ARRAY['day(event_ts)', 'tenant_id']
);
```

With `tenant_id` in the partition spec, `WHERE tenant_id = 'enterprise_acme' AND event_ts >= ...` prunes directly to Acme's files. Trino skips every other tenant's files entirely — no file opens, no wasted I/O.

### For an existing table: partition evolution

If your table already exists, change the spec for new data, then rewrite old data:

```sql
-- Step 1: Change partition spec for new writes going forward (Trino)
ALTER TABLE iceberg.analytics.events
SET PROPERTIES partitioning = ARRAY['day(event_ts)', 'tenant_id'];
```

```python
-- Step 2: Rewrite old data under the new spec (Spark SQL only — schedule during low traffic)
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table => 'analytics.events',
        options => map('target-file-size-bytes', '268435456')
    )
""")

-- Step 3: Expire old snapshots to reclaim MinIO storage
spark.sql("""
    CALL iceberg.system.expire_snapshots(
        table => 'analytics.events',
        older_than => current_timestamp() - INTERVAL '7' DAY,
        retain_last => 5
    )
""")
```

After the rewrite, queries on old data prune correctly too. Until the rewrite completes, pre-rewrite data still does full scans — that's the transition cost.

### Why `day(event_ts), tenant_id` order (day first)

- **Per-tenant dashboard queries** (`WHERE tenant_id = 'acme' AND event_ts >= ...`) prune to one tenant's files within the date range — fast
- **Cross-tenant internal queries** (`WHERE event_ts >= ...`) read files grouped by day, which compress better and keep manifest metadata manageable
- Reversing to `tenant_id, day(event_ts)` still prunes both fields correctly (this is a common misconception — order does NOT affect pruning), but clusters files per-tenant rather than per-day, degrading compression for cross-tenant queries

Stick with day-first for mixed workloads.

### Secondary issue: small files

If your table also has many small files from frequent micro-batch ingestion without compaction, add a nightly compaction job:

```python
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table => 'analytics.events',
        options => map(
            'target-file-size-bytes', '268435456',
            'min-input-files', '5'
        )
    )
""")
```

Even with correct partitioning, thousands of small Parquet files slow queries. Healthy 256 MB files minimize per-file overhead.

### Immediate diagnostic

Confirm the issue is partitioning:

```sql
-- Shows files per tenant for a recent date — run in Trino as admin
SELECT
  partition.tenant_id,
  COUNT(*) AS file_count,
  ROUND(SUM(file_size_in_bytes) / (1024.0 * 1024.0), 1) AS total_mb
FROM iceberg.analytics."events$files"
WHERE partition.day >= CAST(CURRENT_DATE - INTERVAL '1' DAY AS VARCHAR)
GROUP BY 1
ORDER BY total_mb DESC
LIMIT 10;
```

If enterprise tenants show hundreds of files while small tenants show 1–2, `tenant_id` is not a partition column — proceed with partition evolution above.

Note: `partition.tenant_id` in this query only works if `tenant_id` IS already a current partition column. If it isn't, you'll see a column-not-found error — that itself confirms the diagnosis.
