# Judge — Iter 106 Q1

**Topic**: Multi-tenant analytics
**Score**: 4.81 / 5 (Tech 4.75, Clarity 4.75, Practical 5.0, Completeness 4.75)

## Verdict
Outstanding answer that correctly walks through the full GDPR/right-to-be-forgotten lifecycle for a shared multi-tenant Iceberg table: export, logical delete, file rewrite, snapshot expiry, orphan cleanup, and multi-angle verification. The engine attribution (Trino for DELETE/CTAS, Spark for CALL procedures) is consistent and matches the production stack. The legal confirmation template, the silent-holders table, and the explicit "why order matters" callout make this directly actionable for both the engineer and the legal team. Minor concerns are around an assumed partitioning scheme and an aggressive `older_than` for orphan cleanup.

## What was verified correct (via WebSearch)
- `CREATE TABLE ... AS SELECT` is a valid CTAS pattern for the Trino Iceberg connector — verified against trino.io/docs/current/connector/iceberg.html and trino.io/docs/current/sql/create-table.html.
- Trino Iceberg DELETE uses merge-on-read and creates position delete files rather than rewriting data files — verified against trino.io and Starburst Iceberg DML blog. The answer's framing ("creates position delete files… original Parquet data files are NOT rewritten") is accurate.
- `CALL iceberg.system.rewrite_data_files(table => ..., where => ..., options => map(...))` is correct Spark SQL named-parameter syntax — verified against iceberg.apache.org/docs/latest/spark-procedures and AWS prescriptive guidance.
- `CALL iceberg.system.expire_snapshots(table => ..., older_than => ..., retain_last => ...)` is correct Spark procedure signature — verified against Iceberg docs.
- `CALL iceberg.system.remove_orphan_files(table => ..., older_than => ...)` is correct, and using an `older_than` boundary is the documented safety mechanism — verified against Iceberg Spark procedures docs.
- Trino's `iceberg.expire-snapshots.min-retention` defaults to 7d and enforces a hard floor (procedure errors with "Retention specified (X) is shorter than the minimum retention configured in the system (7.00d)"). The answer's claim that Spark must be used for sub-7-day compliance windows is accurate — verified against Starburst forum and Trino issue #19096.
- Spark's procedures have no equivalent floor — `older_than => current_timestamp` works.
- Lifecycle ordering (rewrite → expire snapshots → remove orphan files) matches the documented best-practice order from iceberg.apache.org/docs/latest/maintenance.

## Errors or gaps
- The `events$files` metadata query uses `WHERE partition.tenant_id = '…'`. This syntax only works if `tenant_id` is an actual partition column in the table's current partition spec. The question states tenants share the table with a `tenant_id` column — it does NOT confirm partitioning by `tenant_id`. If the table is partitioned by event date or by `bucket(tenant_id, N)`, this query will fail or return misleading results. The answer should have either: (a) added a precondition check on `$partitions`, or (b) offered a fallback metadata check using `lower_bounds`/`upper_bounds` on `$files`, or (c) called out the assumption explicitly.
- `remove_orphan_files(older_than => current_timestamp - interval '1' day)` is more aggressive than the Iceberg default of 3 days. While the answer justifies the 1-day window, it does not warn that any concurrent Spark or Trino writers (e.g., the ingestion pipeline) staging files during that window risk having in-flight uncommitted files deleted. For a compliance purge, the safer pattern is to pause ingestion first, then run with a small `older_than`. Worth a one-line caution.
- The MinIO grep verification (`aws s3 ls … | grep -i "departing-customer"`) only catches the tenant ID if it appears in the file path. Iceberg data file paths are content-hashed/UUID-named, so `tenant_id` rarely appears in the path itself. This verification step will almost always return zero — even on a buggy delete — and gives false confidence. A real byte-level check requires inspecting Parquet column stats or grep'ing the file contents.
- The export step uses `CREATE TABLE iceberg.exports.customer_offboard AS SELECT …`. This creates another Iceberg table — also on MinIO — and the answer correctly tells the engineer to clean it up, but does not show the cleanup statement (`DROP TABLE … PURGE` and its own orphan cleanup). The export table itself becomes "data the customer's bytes still exist in" until explicitly purged.
- Minor: `CREATE TABLE … AS SELECT` to Iceberg writes Parquet but the answer says "your customer's technical team can download the Parquet files via the MinIO S3 API" — this assumes the customer can navigate raw Parquet plus Iceberg's directory layout (metadata files, manifests, partition subdirs). In practice, a cleaner export is `INSERT INTO temp_table` (matching the documented prod_info.md ad-hoc export pattern) or unloading to a single flat Parquet/CSV directory the customer can consume without an Iceberg reader.

## Resource fix recommendations
- **MEDIUM** — Add a note to `resources/05-multi-tenant-analytics.md` (or the maintenance resource) that `$files` metadata queries using `partition.<col>` only work when `<col>` is a current partition column, with a fallback pattern using `lower_bounds[X] = upper_bounds[X] = '<tenant>'` for non-partitioned tenant columns.
- **MEDIUM** — Add a "compliance purge pre-flight checklist" callout: (1) pause/drain ingestion before running `remove_orphan_files` with sub-default `older_than`, (2) explicitly DROP and re-orphan-clean the export table after handoff, (3) prefer Parquet unload directory or `INSERT INTO temp_table` over Iceberg CTAS for customer-consumable exports (matches the prod_info.md pattern).
- **LOW** — The MinIO grep step in verification should be replaced with a more reliable check (e.g., `$files` row count + verification that the post-rewrite snapshot's manifest list contains no entry whose lower/upper bound for `tenant_id` overlaps the departing tenant).

## Updated topic state
- Multi-tenant analytics: 101 questions / running avg **4.452** ((4.448 × 100 + 4.81) / 101 = 4.4516)
