# Iter71 Q2 Score

## Scores
| Dimension | Score |
|---|---|
| Completeness | 4.75 |
| Accuracy | 5 |
| Clarity | 5 |
| No hallucination | 5 |
| **Final** | **4.94** |

## Points covered

All 5 required points fully addressed:

1. **Spark JDBC partitioned read** (`partitionColumn`, `lowerBound`, `upperBound`, `numPartitions`) — COVERED. Explicit code example using `id` as `partitionColumn`, with correct caveat that wrong bounds cause skew not data loss. Recommends 16–64 partitions range. Notes that bounds split the range into equal slices and that partitions are independent JDBC connections.
2. **`fetchsize` must be set (default 0 OOMs)** — COVERED EXCELLENTLY. The answer explicitly labels this "the critical one" and warns that pgjdbc's default `fetchsize=0` "fetches ALL rows at once into memory" causing OOM "before it reads a single Spark partition." `fetchsize=10000` recommendation matches resource guidance.
3. **Iceberg snapshot atomicity: crash before commit leaves orphans, readers see old snapshot** — COVERED with a 4-step timeline (Parquet writes → checksum → metadata commit → atomic pointer swap). Explicitly states "Iceberg never sees them" for pre-commit crash files and "No partial data is ever visible." Clean treatment of the atomicity guarantee.
4. **Resumability via batched ID-range OR MERGE INTO** — COVERED. Two clear strategies presented in priority order: batched append by ID range (10 × 50M batches, each independently retryable, recommended as primary path) and MERGE INTO as the idempotent alternative. Tradeoff analysis between them is given.
5. **Orphan file cleanup** — COVERED via `CALL iceberg.system.remove_orphan_files(...)` mentioned in part (b).

Bonus content: production-environment fit (Kubernetes Jobs / Airflow for batch orchestration), summary table consolidating all three concerns, and explicit final recommendation ("batched append, 10 batches, each as a separate Kubernetes Job").

## Issues found

WebSearch verification of all three accuracy concerns came back clean:

1. **Spark JDBC `partitionColumn`/`lowerBound`/`upperBound`/`numPartitions` semantics**: Confirmed correct per Spark JDBC docs and multiple authoritative blog references. `partitionColumn` must be numeric/date/timestamp; `lowerBound`/`upperBound` define partition stride (not filter); `numPartitions` controls JDBC connection count. The answer's note that "wrong bounds cause skew (uneven partitions), not data loss" is precisely correct.
   - Source: https://luminousmen.com/post/spark-tips-optimizing-jdbc-data-source-reads/
   - Source: https://jozef.io/r926-spark-jdbc-partitioning/

2. **pgjdbc default `fetchsize=0` fetches all rows into memory**: Confirmed correct. Default is 0, which loads entire result set; non-zero enables cursor-based streaming. Memory spiked from 6.67 MB to 454 MB on 2M rows in test. The answer's warning is accurate.
   - Source: https://shaneborden.com/2025/10/14/understanding-and-setting-postgresql-jdbc-fetch-size/
   - Source: https://franckpachot.medium.com/oracle-postgres-jdbc-fetch-size-3012d494712

3. **Iceberg atomicity: crash before commit leaves orphans, readers never see partial data**: Confirmed correct. "Readers never see partial writes... entire write is visible or invisible." Engine crash after writing data files but before pointer swap leaves orphan files. The answer's 4-step timeline accurately describes the commit mechanism.
   - Source: https://iceberg.apache.org/docs/latest/maintenance/
   - Source: https://iomete.com/resources/blog/apache-iceberg-acid-transactions-catalog

### Minor completeness gaps (-0.25 Completeness)

- **No mention of `older_than` safety parameter on `remove_orphan_files`**: The recommended `CALL iceberg.system.remove_orphan_files(...)` is shown without the critical `older_than => current_timestamp() - INTERVAL '3' DAYS` (or similar) guardrail. Running `remove_orphan_files` with default `older_than` (3 days) is fine, but the answer doesn't explain the guardrail exists. An engineer with the same problem in production who runs a tighter window risks deleting files from in-flight concurrent writes.
- **MERGE INTO performance characterization is slightly misleading**: The answer says MERGE INTO "must compare every source row against every target row." For a fresh empty target table (true initial full load), the target scan is empty, so the cost is much closer to a plain INSERT. The full-scan concern matters more on incremental MERGE INTO against an already-populated table. For this specific question's one-time historical load, MERGE INTO and append have similar cost.
- **First-batch creation pattern not addressed**: The batched-append approach implies the target table already exists. For a first-ever load, batch 1 needs `createOrReplace()` or `create()` (or `CREATE TABLE` DDL upfront), then subsequent batches `append()`. The answer skips this detail.
- **Engine context for `CALL iceberg.system.remove_orphan_files`**: The answer correctly uses Spark `CALL` syntax (which is right — Trino's equivalent is `ALTER TABLE ... EXECUTE remove_orphan_files`), but doesn't explicitly label this as Spark-only. Engineer might try to run it in Trino.

### Production stack fit (5/5)

All advice fits the prod stack:
- Iceberg + Hive Metastore + MinIO + Spark on k8s — correctly referenced (`writeTo("iceberg.analytics.large_table")` matches the prod catalog naming)
- Kubernetes Jobs and Airflow orchestration mentioned as the natural batch driver — correct for on-prem k8s
- No cloud-only services suggested
- `CALL iceberg.system.remove_orphan_files` uses the correct Spark-side procedure invocation for the prod stack (Spark owns ingest/maintenance per resources/13)

No hallucinations. No incorrect claims.

## Resource fix needed?

No blocking fix. Optional minor enhancement to `resources/13-postgres-to-iceberg-ingestion.md`:
1. Add a "Large initial full load" subsection that consolidates the three-part pattern (parallel JDBC read + atomicity + batched resumability) explicitly for first-time historical loads of 100M+ row tables. This would let future answers pull the structure directly rather than recompose it.
2. Add a worked example of the first-batch-creates-target pattern (batch 1 uses `createOrReplace()`, batches 2–N use `append()`), since the batched-append answer pattern is increasingly common and the createOrReplace-vs-append seam is a real engineer trip point.
3. Reinforce the `older_than` guardrail on `remove_orphan_files` (already covered in resources/17 but not consistently in resources/13).
