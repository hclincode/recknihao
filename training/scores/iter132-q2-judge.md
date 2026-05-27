# Judge Score — Iter132 Q2

**Score**: 4.75 / 5 (Tech 5, Clarity 5, Practical 5, Completeness 4)

## Verdict
This is a strong, production-ready answer. It correctly identifies the most likely root cause (Iceberg small-file/manifest accumulation), provides accurate diagnostic queries against `$files`/`$snapshots`, gives correct compaction and snapshot-expiry procedures with the right parameters, and explicitly warns against the `rewrite-all=true` pitfall for routine compaction — directly applying the lesson from the iter131/132 teacher fixes. The structure (diagnose first, then prioritize fixes) is exactly the right shape for a SaaS engineer with no OLAP background.

## Technical claims verified
- Iceberg small-file / manifest accumulation as a legitimate cause of write slowdown — **CORRECT** (Dremio, Cloudera, iceberg-lakehouse docs all confirm planning latency grows with file/manifest count, including for commits, not just reads).
- `rewrite_data_files` with `target-file-size-bytes` (e.g., 268435456 = 256 MB) — **CORRECT** API call. Default is 512 MB, and 256 MB is a valid recommended override per the official Iceberg spark-procedures docs.
- `rewrite-all=true` should NOT be used for routine nightly compaction — **CORRECT**. Default bin-pack already skips well-sized files; `rewrite-all=true` forces rewriting every file regardless of size and is intended for post-partition-evolution migration (or similar full-rewrite cases). The answer's callout matches the iter131 teacher correction.
- Trino enforces a 7-day minimum retention on `expire_snapshots` while Spark does not — **CORRECT** in substance. Trino's `iceberg.expire-snapshots.min-retention` defaults to 7d and the procedure fails if `retention_threshold` is lower; Spark's `expire_snapshots` procedure has no equivalent enforcement (although table-level retention properties exist).
- JDBC `numPartitions` + `partitionColumn` + `lowerBound` + `upperBound` pattern for parallel reads — **CORRECT**. Matches official Spark JDBC docs and standard practice; partition column should be numeric/date/timestamp with even distribution.
- `pg_last_xact_replay_timestamp()` for replica lag — **CORRECT** valid PostgreSQL function. The `EXTRACT(EPOCH FROM (NOW() - pg_last_xact_replay_timestamp()))` form is standard and widely used. (Minor caveat: low-write databases can report stale lag, but this is not a defect of the answer.)
- `$files` metadata table with `file_size_in_bytes`, `record_count`, `file_path` columns — **CORRECT** for both Trino and Spark Iceberg connectors.

## Errors or gaps
- **LOW**: The 7-day floor claim is slightly imprecise — it's a Trino *catalog* config (`iceberg.expire-snapshots.min-retention`, default 7d) that an admin could lower, not a hard-coded Trino limit. The answer's phrasing "Trino enforces" is accurate enough for the engineer's purposes but a more precise version would say "Trino's default catalog config enforces."
- **LOW**: The answer doesn't mention MinIO-specific symptoms (e.g., listing latency at high object counts, HTTP/2 keep-alive, S3A committer choice) even though the engineer named MinIO as one of three suspects. A brief "why MinIO is rarely the bottleneck here, but here's how to rule it out (mc admin trace, top API calls)" would have been a nice completeness add for an on-premises MinIO stack.
- **LOW**: The on-premises production stack (Trino 467 / Iceberg 1.5.2 / Hive Metastore / k8s) is not explicitly acknowledged. The advice is compatible with it, but an explicit note that this applies to the on-prem Spark + Iceberg 1.5.2 + Hive Metastore setup would tie it more tightly to prod_info.md.
- **LOW**: `rewrite_manifests` is not mentioned as a separate maintenance procedure. If file accumulation is severe, manifest rewrite is sometimes needed alongside data file rewrite. Not critical for the core answer.
- **LOW**: The JDBC partitioning example uses a hardcoded `upperBound` of `999999999` without explaining the engineer should query `SELECT MAX(id)` first to get a real value. A one-line note would help a beginner.

## Resource fix recommendations
No urgent fixes needed. Optional polish:
- `resources/17-iceberg-table-maintenance.md` (or a Spark-tuning resource): add a one-paragraph note on MinIO-specific signals to rule out object-storage bottlenecks (mc admin trace, S3A committer choice) so future answers can cover all three suspects (Spark / Iceberg / MinIO) the engineer named.
- If a Spark/JDBC ingestion resource exists, add a snippet showing how to derive `lowerBound`/`upperBound` from a `SELECT MIN(id), MAX(id)` rather than hardcoding.
- Add a brief clarification to the snapshot-expiry resource: the Trino 7-day minimum is a configurable catalog property (`iceberg.expire-snapshots.min-retention`), not a hard-coded limit, so admins can tune it.
