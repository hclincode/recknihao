# Iter70 Q1 Score

## Scores
| Dimension | Score |
|---|---|
| Completeness | 4 |
| Accuracy | 4 |
| Clarity | 5 |
| No hallucination | 5 |
| **Final** | **4.50** |

## Points covered

1. **Trino HTTP event listener with per-query cost signals (elapsedTime, cpuTime, totalBytes)** — COVERED WELL. Field names correct. Explicit callout that `elapsedTime`/`cpuTime` are ISO-8601 Duration strings (e.g., `"PT2.345S"`), not integer millis, with working Python parser. This is exactly the gotcha most teams hit.
2. **Persistent Iceberg audit/cost table partitioned by date** — COVERED. `CREATE TABLE ... WITH (format='PARQUET', partitioning = ARRAY['day(query_date)'])` is valid Trino-Iceberg DDL.
3. **Per-tenant CPU-hours / GB-scanned SQL aggregation** — COVERED. The reporting query does `SUM(cpu_time_ms)/3600000.0 AS cpu_hours` and `SUM(bytes_scanned)/1073741824.0 AS gb_scanned`, exactly what management wants to see, grouped by `tenant_id`.
4. **Iceberg `$files` / `$partitions` metadata for storage** — COVERED. Uses `iceberg.analytics."events$files"` with `partition.tenant_id` and `SUM(file_size_in_bytes)` — verified correct against Trino docs (https://trino.io/docs/current/connector/iceberg.html). Also includes the snapshot expiry + orphan-file cleanup nuance (correctly noted as Spark-only, which fits the prod stack where Spark owns ingest/maintenance).
5. **Resource groups for caps + security note about `system.runtime.queries`** — PARTIALLY COVERED. Resource groups example is valid (rootGroups → subGroups, `hardConcurrencyLimit`/`softMemoryLimit`/`maxQueued` all valid per https://trino.io/docs/current/admin/resource-groups.html). **However the security caveat that tenants must NOT have access to `system.runtime.queries` is missing.** This was flagged in the rubric as a required point because a tenant who can read that view sees other tenants' query text — a real cross-tenant leak.

## Issues found

1. **SQL schema/query mismatch (minor bug an engineer will hit)**: The `CREATE TABLE tenant_query_costs` DDL has no `query_state` column (only `error_code`), but the reporting query filters `WHERE ... AND query_state = 'FINISHED'`. Copy-pasting both will fail with "column does not exist". Either add `query_state VARCHAR` to the DDL or change the filter to `WHERE error_code IS NULL`.
2. **Missing security note** on `system.runtime.queries` — required point per rubric not addressed. The piece is otherwise security-conscious (resource groups, isolation) but skips this specific tenant-data-leak vector.
3. **Production fit: GOOD overall** — recommends only tools already in the stack (Trino HTTP event listener, Iceberg metadata tables, Spark for maintenance procedures). No mention of cloud-only SaaS billing services. Consistent with on-prem k8s + MinIO + Trino 467 + Iceberg 1.5.2 + Spark + Hive Metastore.

Verified against official sources:
- ISO-8601 Duration serialization confirmed via QueryStatistics.java which imports `java.time.Duration` (Jackson default-serializes Duration to ISO-8601 strings).
- `$files.file_size_in_bytes` and `partition.<column>` ROW-type access syntax confirmed in Trino Iceberg connector docs.
- Resource groups JSON field names (`hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued`) confirmed in Trino 480 resource groups docs.

## Resource fix needed?

YES — minor.

1. `resources/05-multi-tenant-analytics.md` (cost/chargeback section) needs to add the **security note**: tenants must not have access to `system.runtime.queries` (and `system.runtime.tasks`) because the query text column leaks other tenants' SQL. One-line OPA/file-based denial example. This has been flagged in prior iterations (see iter47 Q2 notes line 2131 of rubric.md) and is still propagating into answers without it.
2. The cost-tracking DDL example in resources should ensure the example query and the CREATE TABLE agree on column names — add a `query_state` column to the audit table schema, or change the example aggregation to filter on `error_code IS NULL`. This is a copy-paste fidelity issue not just a content issue.
