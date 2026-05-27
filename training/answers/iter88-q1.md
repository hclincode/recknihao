# Iter88 Q1 — Answer

**Question**: 80 tenants sharing Iceberg table. Want per-tenant storage/file-count breakdown to identify "heavy" tenants before deciding on dedicated tables. How to query Iceberg metadata tables?

---

## Answer

You're right to be curious about Iceberg metadata tables — they're your fast-lane tool for this exact question. Concrete SQL queries below.

### What Iceberg metadata tables expose

When you create an Iceberg table, it stores **metadata about layout separately from the actual data rows**. Instead of scanning millions of event rows to understand storage distribution, you can query special `$`-suffix tables that Iceberg exposes. These metadata tables give you file-level and partition-level statistics **without touching a single data row**.

For your 80-tenant shared analytics table partitioned by `tenant_id`, two metadata tables are relevant:

- **`$files`** — lists every Parquet file, its size in bytes, and which partition it belongs to
- **`$partitions`** — aggregates per partition: how many rows, how many files, total size

### The query: per-tenant storage and file count

```sql
-- Run as an admin principal (not a tenant user).
SELECT partition.tenant_id, COUNT(*) AS file_count,
       ROUND(SUM(file_size_in_bytes)/1024/1024/1024, 1) AS total_gb
FROM iceberg.analytics."events$files"
GROUP BY 1 ORDER BY 3 DESC LIMIT 20;
```

Replace `iceberg.analytics."events$files"` with your actual catalog and table name. The `partition.tenant_id` accessor pulls the partition key value from Iceberg's metadata.

**What the output tells you:**
- `file_count` — high counts (hundreds) for small tenants signal the small-files problem from fragmented incremental writes. These tenants benefit from compaction but don't need dedicated tables.
- `total_gb` — raw storage footprint. This is what matters most for the migration decision.

A typical result: 3 tenants > 50 GB, 10 tenants in 5–50 GB, everyone else under 1 GB. **Migrate the top 3.** They dominate compaction and maintenance cost on every shared-table job — isolating them means routine maintenance no longer bears their cost.

### Secondary query: row-count skew

```sql
SELECT partition.tenant_id, record_count, file_count
FROM iceberg.analytics."events$partitions"
ORDER BY record_count DESC LIMIT 20;
```

A tenant with 500M rows in 50 GB (dense, small events) behaves differently under query load than a tenant with 10M rows in 50 GB (sparse, large payloads). Both are migration candidates, but high row count means higher query volume risk.

### How to use the output

1. **Run both queries weekly via cron.** Trend over time — which tenants are growing fastest?
2. **Alert when any single tenant exceeds 30% of the shared table's total GB.** That's your migration trigger.
3. **Tenants under 1 GB almost never benefit from isolation.** Keep them in the shared table. The operational burden (per-tenant schema migration, longer Hive Metastore listings) outweighs any noisy-neighbor risk.
4. **Tenants in the 1–5 GB range stay shared.** Only the 3–5 largest, and only if growing, warrant dedicated tables.

### Critical security note

These metadata tables expose your entire customer roster (all `tenant_id` values), which customers are large, and their relative scale. **Never grant tenant principals access to `$files` or `$partitions`.** Only admin principals should run these queries. Your OPA policy must deny tenant access to any table with a `$` suffix.

### After identifying heavy tenants: the safe migration sequence

Once you know which 3–5 tenants to migrate, follow this safe cutover sequence:

1. **INSERT INTO** `analytics.acme_events` SELECT * FROM `analytics.events` WHERE `tenant_id = 'acme'`
2. **Verify**: `SELECT COUNT(*) FROM analytics.acme_events` must match `SELECT COUNT(*) FROM analytics.events WHERE tenant_id = 'acme'`
3. **Swap view**: `CREATE OR REPLACE VIEW tenant_acme.events AS SELECT * FROM analytics.acme_events`
4. **Only then DELETE**: `DELETE FROM analytics.events WHERE tenant_id = 'acme'`

**Never delete before swapping the view.** Cross-table writes are non-atomic in Iceberg — if the view swap hasn't happened yet and you delete from the shared table, the tenant's data disappears until you restore from a snapshot.
