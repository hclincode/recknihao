# Judge Score — Iter135 Q1

**Score**: 4.88 / 5 (Tech 5, Clarity 5, Practical 5, Completeness 4.5)

## Verdict
Excellent answer. It directly attacks the engineer's two questions (why Parquet is so much smaller, and whether row order matters) with a clear physical model, an accurate mechanism breakdown (dictionary -> RLE -> delta -> Zstd), and code that fits the on-prem Spark/Iceberg 1.5.2 + MinIO stack. The compression mechanism explanations are technically correct and well-aligned with Apache Parquet's actual encoding behavior, and the Iceberg `rewrite_data_files` syntax is correct for Iceberg 1.5.2.

## Technical claims verified
- "Parquet uses dictionary encoding by default for string columns" — CORRECT. Parquet writers default to dictionary encoding for string columns; falls back to PLAIN when dictionary exceeds size/cardinality thresholds (typically ~1 MiB / ~100K distinct values).
- "RLE collapses repeated values into (value, count) pairs" — CORRECT. Parquet uses RLE/Bit-Packing hybrid encoding on the dictionary indices (RLE_DICTIONARY), not on raw string values. The answer slightly glosses this layering but the user-facing description is accurate.
- "Sorting before write amplifies RLE compression" — CORRECT. This is a well-documented mechanism; long runs of identical dictionary indices compress dramatically better.
- "Delta encoding for monotonic timestamps" — CORRECT. DELTA_BINARY_PACKED is used for INT32/INT64 (timestamps stored as INT64) in Parquet V2 pages. Particularly effective for ordered timestamp sequences.
- "Zstd as final pass on top of encodings" — CORRECT. Iceberg's default since ~1.3 is Zstd for Parquet; encodings run before codec compression.
- Spark `repartition(N, col).sortWithinPartitions(col)` pattern — CORRECT for the standard ingestion case. One nuance the answer doesn't surface: Spark's `FileFormatWriter` can sometimes discard user-defined in-partition ordering when AQE imposes a different ordering for partitioned writes; for unpartitioned Iceberg writes this is generally not an issue, but it can bite users with `partitionBy` on the write path.
- Iceberg `rewrite_data_files` with `strategy='sort'`, `sort_order => 'col ASC NULLS LAST, col2 ASC'` — CORRECT syntax for Iceberg 1.5.2 Spark procedures.
- Iceberg manifest min/max for non-partition columns enabling file pruning — CORRECT. Iceberg stores per-column stats for all columns by default, so a `tenant_id` filter benefits from sort-clustering even when `tenant_id` is not a partition column.
- 8x compression attributed primarily to dictionary encoding — REASONABLE order-of-magnitude. Actual breakdown varies (Zstd contributes substantially even without sort), but the framing is correct.

## Errors or gaps
- LOW: The answer says RLE acts on the (value, count) pairs of the original column. In practice Parquet's RLE/Bit-Packing hybrid runs on the dictionary integer indices (RLE_DICTIONARY for data pages). The user-facing explanation is fine and not misleading, but a teacher could tighten the wording.
- LOW: No mention of the AQE / `FileFormatWriter` caveat where Spark may discard `sortWithinPartitions` ordering during partitioned writes. Not directly relevant to this question's framing, but worth a sentence for engineers writing into partitioned Iceberg tables.
- LOW: The compression-ratio table column header is "Compression gain" but has 4 rows listed under a 3-column-header table (Mechanism / What it requires / Compression gain), and there are 4 mechanism rows — minor formatting inconsistency, not a content error.
- LOW: Could briefly mention dictionary fallback (when distinct count exceeds threshold, Parquet falls back to PLAIN). Engineers tuning very-high-cardinality columns should know this.

## Resource fix recommendations
- resources/ (parquet internals doc, if exists): add a one-line note that Parquet's RLE is applied to dictionary indices (RLE_DICTIONARY), not directly to raw values, to keep precise terminology available for future answers.
- resources/ (Spark ingestion patterns doc): add a brief note about the Spark AQE / partitioned-write caveat where `sortWithinPartitions` ordering can be discarded during `partitionBy` writes, with the workaround (cache before write, or use Iceberg's table sort order).
- resources/ (Parquet encoding doc): add a note about dictionary fallback when cardinality exceeds ~100K distinct values or dictionary page exceeds ~1 MiB, so high-cardinality columns (UUIDs) are not assumed to benefit from dictionary encoding.

No urgent fixes — this answer passes comfortably.
