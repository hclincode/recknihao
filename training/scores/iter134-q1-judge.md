# Judge Score — Iter134 Q1

**Score**: 4.00 / 5 (Tech 3, Clarity 5, Practical 5, Completeness 3)

## Verdict
The answer is structurally excellent for a beginner — it cleanly separates the three "skipping" mechanisms (column projection, row-group pushdown, partition pruning) with concrete examples, EXPLAIN ANALYZE diagnostics, and three pragmatic fixes tied to the production stack (Trino/Iceberg/MinIO). However, it contains a material technical inaccuracy: it tells the engineer that Iceberg's file-level min/max statistics are only useful (or even only tracked) when the column is in the partition spec. In reality, Iceberg's manifest entries store lower_bounds/upper_bounds for **all** columns by default (truncate(16) for strings), and file-skipping via those bounds works for non-partition columns too — it just depends on whether the data is clustered enough for the bounds to be selective. This misframes the root cause and could lead the engineer to incorrectly conclude that the only way to skip files on `plan_type` is to partition by it.

## Technical claims verified
- Parquet stores per-column min/max/null_count at the row-group level — CORRECT.
- Trino pushes predicates down to skip Parquet row groups using those statistics — CORRECT.
- Iceberg manifest files store per-file column statistics (min/max) — CORRECT.
- Claim that file-level statistics "may not be tracked at the file level" unless the column is a partition column — INCORRECT. Iceberg manifests store lower/upper bounds for all columns by default (truncate(16) for strings). The Iceberg spec explicitly defines lower_bounds/upper_bounds as per-column on every data file entry.
- Claim that "Trino can skip entire files based on Iceberg's file-level statistics only if the column is part of the table's partition spec — or if the data happened to be sorted so that files are pure-plan-type" — PARTIALLY CORRECT. The "or" clause is right (file skipping does work without partitioning when bounds are tight), but the framing makes partition spec sound like a hard requirement for file skipping when it is not. The real driver is data clustering / sort order, not membership in the partition spec.
- The diagnostic suggestion that `EXPLAIN ANALYZE` exposes file counts — CORRECT. Trino's Iceberg connector reports `scanned_files_count` and related metrics in EXPLAIN ANALYZE output.
- The three remediation options (always pair with partition filter, add plan_type to partition spec, build a rollup table) — all appropriate for the on-prem Trino 467 / Iceberg 1.5.2 / MinIO stack.
- ALTER TABLE SET PROPERTIES partitioning syntax — CORRECT for Trino Iceberg connector.

## Errors or gaps
- HIGH: Misleading framing that file-level pruning requires plan_type to be in the partition spec. The mechanism that's actually failing is **data clustering** (rows are interleaved by arrival order so per-file bounds for plan_type span basic..starter on every file). The correct nuance: Iceberg tracks bounds for plan_type on every file, but because every file contains all four plan_types, the bounds are useless. The fix isn't only "partition by it" — sorting/Z-ordering data on plan_type during write (or via `rewrite_data_files` with sort order) would also tighten bounds and enable file skipping without partitioning. The answer never mentions sort-order or rewrite_data_files as a remediation.
- MEDIUM: Omits mention of Iceberg sort orders and `OPTIMIZE` / `rewrite_data_files` with a sort order as Option 4. This is the standard non-partition fix and fits the production stack (Spark Actions API in Iceberg 1.5.2).
- LOW: Omits Parquet bloom filters as another row-group-level pruning mechanism (relevant since plan_type is low-cardinality, where bloom filters help). Trino's Iceberg connector supports them via table property `write.parquet.bloom-filter-enabled.<col>`.
- LOW: The "128 MB row group" figure is a common default but configurable; not wrong, just stated as if universal.
- LOW: Trade-off analysis for Option 2 (partition by plan_type) is too soft — partitioning a 4-value column directly is a known anti-pattern that creates skew (enterprise tier likely much larger). Worth a sharper warning, or recommend bucket(N, plan_type) instead.

## Resource fix recommendations
- `resources/14-iceberg-partition-design.md` (or the file-pruning resource): Add an explicit subsection titled something like "File-level min/max pruning works for ALL columns, not just partition columns — but only if data is clustered." Clarify that Iceberg manifest entries store lower_bounds/upper_bounds for every column by default (truncate(16) for strings) per the Iceberg spec, and that the deciding factor for file skipping is data clustering (sort order / write order), not partition spec membership.
- Add a new remediation pattern to the same resource: "Sort during write or run `rewrite_data_files` with a sort order on the filter column." Include the Spark Actions example for Iceberg 1.5.2 and a Trino-side equivalent if any.
- Add a short section on Parquet bloom filters for low-cardinality predicates (perfect fit for plan_type), with the Iceberg table property syntax and a note that Trino 467's Iceberg connector reads them.
- Add a "partition anti-patterns" note: partitioning directly by a low-cardinality column (4 values) creates skew; prefer `bucket(N, col)` or pair it with a higher-cardinality partition.
