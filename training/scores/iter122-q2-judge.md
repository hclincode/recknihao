# Iter122 Q2 — Judge Score

**Score**: 2.9 / 5 (Tech 2, Clarity 4, Practical 3, Completeness 3.5)

## Verdict
The answer is well-structured, beginner-friendly, and correctly reframes the "cloud bill" question for an on-prem stack. However, the centerpiece of "Part 1: Identifying Your Most Expensive Queries" relies on SQL queries that will not run on Trino 467 because they reference columns that do not exist on `system.runtime.tasks` (no `cpu_time_ms`, `peak_memory_bytes`, `execution_time_ms`, `completed_at`, or `query` text column) and also pick the wrong system table (per-query history lives in `system.runtime.queries`, which itself does not expose byte/memory counters). Diagnosis logic (small files, partition pruning, snapshot growth) is solid, but the most actionable section is technically broken.

## What was verified correct (via WebSearch)
- `physical_input_bytes` exists in `system.runtime.tasks` (added in PR #2803 / release 330) — confirmed against trino source.
- `system.runtime.queries` contains: `query_id, state, user, source, query, resource_group_id, queued_time_ms, analysis_time_ms, planning_time_ms, created, started, last_heartbeat, end, error_type, error_code` — confirmed via QuerySystemTable.java.
- Iceberg metadata tables `$files` and `$snapshots` exist and expose file_size_in_bytes and committed_at as used.
- `expire_snapshots` and `rewrite_data_files` are valid Iceberg Spark procedures with the CALL syntax shown — confirmed against iceberg.apache.org/docs/1.5.1/spark-procedures.
- General optimization advice (partition pruning sensitivity to function wrapping, small files hurting open cost, snapshot growth → storage debt, maintenance order: compact → expire → orphan) all align with Iceberg docs.
- The on-prem cost reframe ("marginal query cost is nearly zero, hardware is paid") is appropriate context-correction for an on-prem stack with no per-query cloud billing.

## Errors or gaps
- **HIGH**: The "query history" SQL in Part 1 references `system.runtime.tasks` with columns that don't exist on that table: `cpu_time_ms` (actual column is `split_cpu_time_ms`), `peak_memory_bytes` (not present), `execution_time_ms` (not present), `completed_at` (actual column is `end`), and the `query` SQL text column (not on tasks — only on `system.runtime.queries`). These queries will fail with "column cannot be resolved" the moment a user runs them.
- **HIGH**: Wrong system table choice. For per-query history (the question being asked), the correct table is `system.runtime.queries`, not `system.runtime.tasks`. Tasks are per-stage-per-node fragments and grouping by `query` is impossible there because the SQL text column doesn't exist on tasks.
- **HIGH**: Even `system.runtime.queries` does NOT expose `physical_input_bytes`, `cpu_time_ms`, `peak_memory_bytes`, or `execution_time_ms`. To get those, the answer would need to JOIN tasks (for bytes / split_cpu_time) back to queries (for query text). A correct query would aggregate `SUM(physical_input_bytes)` and `SUM(split_cpu_time_ms)` from tasks GROUP BY query_id, then join to queries for the SQL text. This nuance is completely missing.
- **HIGH**: For long-term query history (more than a few minutes / cluster restart), `system.runtime.*` is in-memory and ephemeral. The answer doesn't mention the event listener (e.g., HTTP event listener, file event listener, or Kafka event listener) or external monitoring (Prometheus + JMX) which are the real tools for a 6-months-into-prod cost retrospective.
- **MEDIUM**: Maintenance commands are given only in Spark CALL syntax. Trino 467 itself supports `ALTER TABLE x EXECUTE optimize`, `ALTER TABLE x EXECUTE expire_snapshots(retention_threshold => '7d')`, `ALTER TABLE x EXECUTE remove_orphan_files`, which would let the engineer schedule these directly from Trino without switching to Spark. Since the stack has both Spark and Trino, both options should be presented with trade-offs.
- **MEDIUM**: The framing assumes a "cloud bill" but production is on-prem (correctly caught), yet the answer never re-anchors what "cost" actually means on-prem (worker pod CPU/memory utilization, MinIO disk consumption, k8s resource quotas, query queueing latency). The user's real KPIs are different from cloud spend and should be named explicitly.
- **LOW**: The "10–50 ms per file open" figure is plausible but not sourced; for MinIO on the same on-prem network, latency is typically lower than S3 cloud.
- **LOW**: `event_date >= TIMESTAMP '2026-05-01 00:00:00'` is shown as "guaranteed to prune" — true for an `event_date TIMESTAMP` column, but the surrounding example earlier in the answer uses `event_date` as if it were a DATE. Type consistency between the partition column and the literal matters for pruning and should be called out.
- **LOW**: No mention of the resource group / query queue mechanism, which is a major SaaS cost-control lever on Trino (limiting per-tenant concurrency, memory caps).

## Resource fix recommendations
- Add a verified, copy-pasteable "find expensive queries on Trino 467" recipe using the real schemas:
  - JOIN `system.runtime.tasks` (for `physical_input_bytes`, `split_cpu_time_ms`, `processed_input_bytes`) with `system.runtime.queries` (for `query`, `query_id`, `created`, `end`).
  - Note that these tables are in-memory and short-lived; for retrospective cost analysis, the engineer must configure an **event listener** (file, HTTP, or Kafka) to persist QueryCompletedEvent to durable storage and query that instead.
- Document the Trino-native Iceberg maintenance syntax: `ALTER TABLE ... EXECUTE optimize`, `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')`, `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')`, including the `iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention` config defaults (7d). Compare with Spark CALL procedures and explain when to prefer each.
- Add an on-prem-specific section on what "cost" means without a cloud bill: worker CPU/memory utilization in k8s, MinIO disk and object count, query queueing delay, per-tenant resource group caps.
- Add a section on Trino resource groups and per-tenant query concurrency limits as a SaaS cost-control mechanism.

## Topic state
- **Cost considerations for analytical workloads at SaaS scale**: PASSED status (current avg 4.50). This answer scores ~2.9, dragging the running average down. Since this is the third+ angle on the topic and the technical accuracy is materially broken, this should be flagged for resource correction even though the topic remains "PASSED" overall.
- **Iceberg partition design / small-files / compaction**: touched lightly; the partition-pruning and small-file diagnoses are reasonable, no major correction needed beyond the syntax fix above.
- **Iceberg table maintenance (compaction, snapshot expiry, orphan files)**: touched. The maintenance ordering and cadence guidance is correct; the issue is only that the Trino-native ALTER TABLE EXECUTE option is omitted in favor of Spark-only.
