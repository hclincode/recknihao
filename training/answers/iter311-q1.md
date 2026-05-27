# Answer to Q1: $path Hidden Column and Other Metadata Bypass Vectors (Iter 311)

The dollar-sign table block is a **necessary but insufficient** defense by itself. Denying tables starting with `$` covers the most obvious Iceberg metadata leak, but there are several other paths a tenant could use to discover file locations and system structure.

## What Dollar-Sign Denial Protects

Blocking `$files`, `$snapshots`, `$manifests`, and `$partitions` prevents tenants from directly querying Iceberg's metadata tables, which would otherwise expose:
- Individual file paths on MinIO (the `file_path` column in `$files`)
- Your complete customer roster (all `tenant_id` values from `$partitions`)
- Storage footprint per tenant (from `$files` and `$partitions` aggregates)
- Snapshot history and operation types

In your production environment with OPA as the authorization backend, a single rule that denies any `$`-suffix table access for tenant principals is the right foundation.

## Other Exposure Paths That Bypass Dollar-Sign Blocks

**1. The `system` catalog (separate from `$`-suffix tables)**

A tenant principal who can connect to Trino can query `system.runtime.queries` to see every query run in your cluster — including queries from other tenants. This reveals:
- SQL submitted by competing tenants (potential exposure of their schema structure, business logic)
- Tenant identities and which queries are expensive (competitive intelligence)
- Your internal admin queries if they appear in the table during the window the tenant is looking

Your OPA policy must independently deny access to the entire `system` catalog for tenant principals. This is **not** covered by the `$`-suffix rule. A tenant can run `SELECT * FROM system.runtime.queries` and get results even if they can't touch `$files`.

**2. The `$path` hidden column**

Even after you block `$files` metadata tables, a tenant can run:
```sql
SELECT "$path", event_type FROM tenant_acme.events LIMIT 10;
```

The `$path` hidden column returns the underlying Parquet file path for each row — the same information as `$files.file_path`, but accessible via a per-row hidden column on the view itself. A tenant who reads their view via `$path` learns MinIO file paths for their own data, which tells them the full warehouse layout (`s3://lakehouse/warehouse/analytics/events/...`).

OPA must explicitly deny queries that reference the `$path` column by name. The `$`-suffix table block does not cover this because `$path` is a column reference, not a table name.

**3. Direct MinIO Access**

Even if Trino's metadata tables are locked down, if a tenant principal's MinIO IAM policy allows direct S3 reads, they can bypass Trino entirely. They can:
- Enumerate all buckets and prefixes to find where tenant data is stored
- Read Parquet files directly and infer partition structure from file paths
- Download files from their own scratch tables (created via CTAS) and see where those files landed on disk

If a tenant has any direct S3 read access to the warehouse bucket, they can walk the file tree and enumerate everything. The fix: no direct MinIO credentials for tenant principals, or strictly path-scoped IAM limited to their own scratch space.

**4. `DESCRIBE` and `SHOW` Commands**

If a tenant can `DESCRIBE iceberg.analytics.events`, they learn the column names and types, and thus the data structure. Your OPA policy should restrict which tables tenants can even *see* via metadata introspection — denying them `SELECT` on a table should also deny them `DESCRIBE` and `SHOW TABLES` on it.

**5. Query Result Inference via Column Statistics**

A secondary concern: tenants can infer min/max statistics by running COUNT(*) grouped by a suspect column, or `SELECT MIN(created_at), MAX(created_at)` on queries they're allowed to make. On small datasets or tightly clustered tenant data, this leaks information about value ranges. This matters more in competitive B2B contexts.

## Recommended Full Fix

1. **Deny `$`-suffix metadata tables for tenants** (you have this).
2. **Deny the entire `system` catalog for tenants** (separate OPA rule, not covered by `$`-suffix block).
3. **Deny queries referencing the `$path` hidden column** — OPA can inspect the column list in the query context.
4. **Restrict MinIO IAM** so tenants cannot read raw Parquet files. If bulk export is needed, route through a controlled export endpoint that produces a signed URL to a temporary, tenant-isolated result file.
5. **Deny `DESCRIBE`, `SHOW TABLES`, and `SHOW COLUMNS` on tables tenants don't own.** OPA's `FilterCatalogs` and metadata-listing events let you filter schema enumeration by user.

Items 1–3 are critical and non-negotiable. Items 4–5 depend on your risk appetite: a B2B SaaS where tenants are competitors should do all five.
