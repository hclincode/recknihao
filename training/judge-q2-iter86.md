# Judge Score — Iter 86 Q2

## Score: 4.75 / 5.0

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 4 |
| Completeness | 5 |

## Points covered

- `$files` metadata table with correct column name `file_size_in_bytes` — verified accurate against Trino Iceberg connector docs.
- Bucketed size distribution query — practical, easy to read, immediately actionable.
- Spot-check smallest-files query with `file_path`, `size_mb`, `partition` columns — useful diagnostic.
- Conceptual explanation of why small files are slow: per-file open overhead (10-50 ms each), worked example (10k files = 100-500s of file-open time alone before any data read). Makes the cost concrete.
- 128-256 MB sweet spot explained with reasoning (selective queries vs parallelism vs file-open amortization), and >512 MB drawback (parallelism loss) noted.
- Clear framing that partitioning vs file size are orthogonal concerns ("partitioning controls which files, not how fast opening them").
- `rewrite_data_files` shown with correct `CALL iceberg.system.*` syntax, both `target-file-size-bytes` (268435456 = 256 MB) and `min-input-files` options — both verified valid Iceberg options.
- Explicitly labels the procedure as "Run in Spark — NOT in Trino" — matches production stack reality (Spark 1.5.2 for ingestion).
- Storage doubling warning during compaction + `expire_snapshots` follow-up to reclaim space, with sensible defaults (`older_than` = 30 days, `retain_last` = 10).
- Scheduling guidance: nightly compaction after ingestion completes, conflict-avoidance with active writes, weekly cadence for low-volume tables.
- Post-fix verification step (re-run the distribution query, check Trino UI planning time) — closes the loop.
- Bonus: `EXPLAIN ANALYZE` "physical input size vs rows returned" as an orthogonal signal that distinguishes partition-pruning failure from small-files overhead.

## Accuracy notes

Verified against trino.io and iceberg.apache.org:
- `$files.file_size_in_bytes` — correct column name in Trino Iceberg connector.
- `rewrite_data_files` is Spark-only — correct. Trino does NOT support `CALL iceberg.system.rewrite_data_files`.
- `min-input-files` and `target-file-size-bytes` are valid options for `rewrite_data_files`.
- `expire_snapshots` with `older_than` and `retain_last` — correct procedure signature.
- 128-256 MB target — defensible. Iceberg's `write.target-file-size-bytes` default is 512 MB, but 128-256 MB is a widely-adopted target in practice for query-heavy lakehouse workloads; the answer's reasoning (parallelism vs open-cost amortization) is sound.

## Issues / gaps

1. **Missing Trino-native alternative**: The production stack uses Trino 467 as the query engine. Trino supports `ALTER TABLE <table> EXECUTE optimize(file_size_threshold => '128MB')` for Iceberg tables — a native compaction command that does NOT require switching to Spark. The answer correctly states `rewrite_data_files` is Spark-only, but does not mention the Trino `optimize` command as a simpler alternative for ad-hoc compaction. For a user already in a Trino session investigating slow queries, this would be a more accessible first fix than spinning up a Spark job. This is the main practical-applicability gap — knocks Practical applicability from 5 to 4.
2. **Minor**: The default file-open overhead estimate (10-50 ms) is reasonable but environment-dependent; on MinIO/on-prem it could be faster or slower. Phrased as "roughly" so this is not an accuracy issue.
3. **Minor**: The `month` partition in the user's setup wasn't questioned. Month is often too coarse for high-volume tables (every query scans 30 days minimum). Mentioning that month-partitioning combined with hourly writes is itself a small-files amplifier (lots of small writes funneled into one big partition) would have strengthened the diagnostic framing. Not penalized — the user asked specifically about file sizes, not partition granularity.

## Resource fix needed?

Yes — moderate priority. The Iceberg partition / maintenance resource should add a section on Trino's native `ALTER TABLE ... EXECUTE optimize(file_size_threshold => 'X')` syntax as the Trino-side counterpart to Spark's `rewrite_data_files`, with a comparison table:

| Need | Use |
|---|---|
| Quick ad-hoc compaction from a Trino session | `ALTER TABLE t EXECUTE optimize(file_size_threshold => '128MB')` |
| Scheduled, full-control compaction with `min-input-files`, partition filter, sort orders, etc. | Spark `CALL iceberg.system.rewrite_data_files(...)` |

This pattern (Trino-native first, Spark for advanced) reflects how engineers actually work in this stack and would close the only meaningful gap in an otherwise excellent answer.
