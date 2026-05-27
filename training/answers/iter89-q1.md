# Iter89 Q1 — Answer

**Question**: Nightly compaction job gets slower every week, dominated by large tenants. Small tenants end up uncompacted. Is there a way to run compaction per-tenant?

---

## Answer

## The core problem

When you run compaction as one global job across all tenants, the job processes partitions sequentially and the biggest tenants dominate the runtime. In Iceberg, `rewrite_data_files` scans the table's partitions and compacts whichever ones have enough small files, without any built-in way to say "only work on tenant X's files." The result: your 3 large tenants soak up 90% of the job's runtime, and by the time it gets to smaller tenants, it's already 4 AM and they're left uncompacted.

## The solution: per-tenant compaction with a WHERE clause

`rewrite_data_files` in Apache Spark supports a **`where` filter option**. You can scope compaction to a single tenant by adding a filter that limits which partitions are candidates.

Instead of this global compaction:

```sql
-- DON'T DO THIS — hits all tenants indiscriminately
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',
    'min-input-files',        '5'
  )
);
```

Do this per-tenant version:

```sql
-- CORRECT — compaction scoped to a single tenant
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',
    'min-input-files',        '5',
    'where',                  'tenant_id = "acme"'
  )
);
```

The `where` clause tells Iceberg's compaction to **only consider Acme's partitions** — read only Acme's small Parquet files, merge them, skip everyone else's data entirely. The job finishes in minutes instead of hours because it's working on a fraction of the data.

## Fair scheduling: the per-tenant batch pattern

**Option A: Separate job per tenant**

Create one nightly scheduled job per tenant, each running in a sequence that finishes by business hours:

```bash
# In compact-tenant.py, run the tenant-scoped compaction:
# CALL iceberg.system.rewrite_data_files(
#   table => 'analytics.events',
#   options => map('where', f'tenant_id = "{tenant}"', ...)
# )
```

**Option B: Batch small tenants, separate large ones** (recommended)

Identify your large and small tenants using the Iceberg metadata query:

```sql
SELECT partition.tenant_id, COUNT(*) AS file_count,
       ROUND(SUM(file_size_in_bytes)/1024/1024/1024, 1) AS total_gb
FROM iceberg.analytics."events$files"
GROUP BY 1 ORDER BY 3 DESC LIMIT 20;
```

Then create a schedule like:

- **1:00 AM**: Batch job compacting all tenants < 5 GB together:
  ```sql
  CALL iceberg.system.rewrite_data_files(
    table   => 'analytics.events',
    options => map(
      'where', 'tenant_id IN ("small_1", "small_2", "small_3")'
    )
  );
  ```

- **2:00 AM**: Separate compaction for each large tenant, running one after another:
  ```sql
  CALL iceberg.system.rewrite_data_files(
    table   => 'analytics.events',
    options => map('where', 'tenant_id = "acme"')
  );
  CALL iceberg.system.rewrite_data_files(
    table   => 'analytics.events',
    options => map('where', 'tenant_id = "beta"')
  );
  ```

- **3:30 AM**: Weekly maintenance (expire snapshots, remove orphans — these run globally because they're metadata operations):
  ```sql
  CALL iceberg.system.expire_snapshots(
    table       => 'analytics.events',
    older_than  => current_timestamp - interval '30' day,
    retain_last => 10
  );
  ```

## Key implementation details

**The `where` option is a string, not a parsed SQL fragment**

The filter is evaluated by Iceberg at partition-selection time (before file rewriting starts). Use simple equality/IN predicates on partition columns. Do NOT use complex expressions — stick to `tenant_id = "X"` or `tenant_id IN (...)`.

**Compaction is atomic per job**

Each `rewrite_data_files` call writes one new Iceberg snapshot for that tenant. If it fails, the old partition is untouched. A failure compacting Acme does **not** affect Beta's data or snapshots.

## Trino cannot do per-tenant compaction

If you wanted to run this from **Trino** (`ALTER TABLE ... EXECUTE optimize`), Trino's version does NOT expose a `where` option — it only has `file_size_threshold`. Use Spark for scheduled, per-tenant compaction. Trino's `OPTIMIZE` is fine for ad-hoc single-table compaction but not for multi-tenant batch scheduling.

## Summary

Run `rewrite_data_files` with a `where` filter for each tenant (or batch of small tenants) on a staggered schedule. Large tenants get their own time slots; small tenants batch together. Everything finishes before business hours start.
