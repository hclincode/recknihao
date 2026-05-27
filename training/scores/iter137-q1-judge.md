# Iter 137 Q1 — Judge Score

## Question
"EXPLAIN shows 'files: 12 out of 847 total' with no date/tenant filter, only `WHERE event_type = 'upgrade'`. How is Trino skipping 835 files without reading them? Does Parquet store a summary of what's inside before the actual data?"

## Score summary
- Technical accuracy: 5/5
- Clarity: 5/5
- Practical utility: 5/5
- Completeness: 5/5
- **Overall: 5.00 / 5**

## Verdict
**PASS** (>= 4.0)

---

## What was verified correct (with sources)

1. **Iceberg manifests store per-column lower_bounds / upper_bounds for every column, not just partition columns.** Verified against the Iceberg spec — manifest files store value_counts, null_counts, lower_bounds, upper_bounds as field-id maps; FULL/TRUNCATE/COUNTS/NONE metrics modes apply per-column. Source: [Apache Iceberg Spec](https://iceberg.apache.org/spec/), [Iceberg Performance docs](https://iceberg.apache.org/docs/latest/performance/).

2. **File-level pruning via range comparison against the filter value.** The answer's logic — check whether the filter value lies within `[lower_bound, upper_bound]` — matches how the manifest reader skips files. The string-ordering example (`'upgrade' > 'signup'`) is correct lexicographic comparison. Verified via [Iceberg performance docs](https://iceberg.apache.org/docs/latest/performance/) and the Trino blog ["Iceberg internals deep dive"](https://trino.io/blog/2021/08/12/deep-dive-into-iceberg-internals.html).

3. **Parquet stores row-group min/max in the footer.** Verified against [Apache Parquet docs](https://parquet.apache.org/docs/concepts/) — statistics (min, max, null_count, distinct_count) are stored within the row group metadata in the file footer. The answer's note that min/max are per row-group (not per-file at the Parquet layer) is correct; Iceberg manifests are the per-file aggregation layer.

4. **Two-layer pruning hierarchy (manifest → row group).** Matches both Iceberg spec and Trino's predicate pushdown implementation. Source: [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html).

5. **`$files` metadata table availability in Trino.** Verified — `SELECT * FROM "test_table$files"` exposes `lower_bounds`/`upper_bounds` maps keyed by field id. Source: [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html).

6. **Sort-based compaction syntax** `CALL iceberg.system.rewrite_data_files(table=>..., strategy=>'sort', sort_order=>...)`. Verified against [Iceberg Spark procedures docs](https://iceberg.apache.org/docs/latest/spark-procedures/). The procedure is a **Spark-only** procedure — the answer correctly placed it inside a `spark.sql(...)` block, signaling Spark execution (which is right for this on-prem stack where ingestion runs on Spark and Trino-side `OPTIMIZE` lacks global sort).

7. **Iceberg 1.5.x bloom-filter table property** `write.parquet.bloom-filter-enabled.column.<col>=true`. Verified against [Iceberg configuration docs](https://iceberg.apache.org/docs/latest/configuration/) and Iceberg dev mailing list discussion. Property name and syntax are exactly correct.

8. **Clustering is required for non-partition column pruning to be effective.** Conceptually correct — if data is randomly ordered, min/max ranges become wide and pruning loses selectivity. Matches Iceberg performance documentation guidance on sort orders.

---

## Errors or gaps found

**None of HIGH severity.**

**LOW (minor / nitpick):**
- The example shows `data_file_1` with `lower_bound = 'upgrade'` and `upper_bound = 'upgrade'` (single distinct value). This is fine but a slightly more realistic example (e.g., bounds `'signup'`..`'upgrade'`) would make the "clustering reduces range width" point even sharper. Not a correctness issue.
- The "Spark reads the Parquet footers and aggregates per-file min/max" step is slightly simplified — in practice the Iceberg writer collects per-row-group stats during writing and aggregates them, not via a separate post-write footer scan. Functionally equivalent description, no engineer would be misled.
- The bloom-filter recommendation is correct but does not mention that Trino's **read** path for Parquet bloom filters works from version 406+. On Trino 467 this is fine (well above the threshold), so the recommendation is sound. Worth a one-line note in future revisions but not an error here.
- The string comparison example assumes ASCII/lexicographic order, which is the default for Parquet stats on STRING columns in Iceberg v1 — fully correct, but a beginner might appreciate one line stating "string min/max use lexicographic order."

**No MEDIUM or HIGH issues found.**

---

## Resource fix recommendations
None required for this answer. Optional polish for `10-lakehouse-partitioning.md` or a future "metadata pruning deep-dive" resource:
- Add a short note that Iceberg writer aggregates stats from row-group footers during write (not via post-write scan) for technical precision.
- Add one line about Trino bloom-filter read support starting at version 406+.

---

## Notes
- Answer fits the production stack exactly: on-prem Iceberg 1.5.2 + Spark + Trino 467 + MinIO. `CALL` procedure correctly attributed to Spark via `spark.sql()` wrapper. Bloom filter property is valid for Iceberg 1.5.2.
- Answer directly addresses all three sub-questions from the engineer (how Trino knows, whether files must be opened, whether Parquet stores summaries).
- The `$files` SELF-VERIFICATION query is excellent practical guidance — engineer can directly reproduce the EXPLAIN ratio with SQL.
- Two-layer (manifest + row group) explanation gives the engineer the right mental model.
