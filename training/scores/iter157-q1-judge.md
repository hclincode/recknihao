# Judge Report — Iter 157 Q1

**Question topic**: Why is single-row lookup in Trino/Iceberg slower than column scan / Postgres point lookup?
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter157-q1.md`

---

## Scores

| Dimension | Score | Rationale |
|---|---|---|
| Technical accuracy (×2) | 4.5 | Core mechanism (columnar layout, per-column chunks, row reconstruction, SIMD/vectorization, partition pruning) is correct and matches the Parquet/Trino design verified via official docs. Two minor issues: (a) Trino does NOT need to "open the Parquet file footer" for each query in the way the answer implies — Iceberg manifests already carry per-file column-level min/max stats so the file footer read is for row-group statistics within selected files, which is a nuance. (b) The answer misses Iceberg's file-level pruning layer (min/max in manifest stats) and Parquet Bloom filters, which are precisely the optimizations that *can* make single-row lookups in Iceberg fast when an indexable column is filtered — leaving the engineer with the wrong impression that lakehouse row lookups are fundamentally slow when in practice Iceberg + Bloom filters + sort order can dramatically narrow them. |
| Clarity (×1) | 5 | Excellent structure: clear contrast Postgres vs Trino step-by-step, explicit blockquote calling out the trade-off, plain English ("one disk block containing the entire row"). No unexplained jargon — SIMD is the only term that could trip a beginner but it's used in a "crunch 8–16 values per CPU instruction" framing that conveys intent. |
| Practical usefulness (×1) | 4.5 | Three clear remediations: (1) add partition filter, (2) project only needed columns, (3) keep single-row queries in OLTP. The "WHERE tenant_id = 'acme' AND event_date >= ..." example is directly copy-pasteable. Missing: no mention of Iceberg Bloom filters / sort orders / `distribution-mode=hash` write strategies that would actually accelerate ID-based lookups in the lakehouse if that pattern is unavoidable. For the production stack (Iceberg 1.5.2 + Trino 467), Bloom-filter-on-write is a real lever the engineer should know about. |
| Completeness (×1) | 4.0 | Addresses "why is it slow" and "is something wrong" fully and correctly. Partial gap on "what to do next" — no acknowledgment that Iceberg has tools (bloom filters, sort orders, equality deletes index) that can narrow single-row lookups before the engineer falls back to Postgres. Also no mention that `SELECT *` widens the row reconstruction cost specifically because Parquet's column chunks live in different file offsets within the same file, not in different files (the answer says "different file region" once but earlier says "separate physical location on disk" which is a slight ambiguity). |

**Weighted average** = (4.5×2 + 5 + 4.5 + 4.0) / 5 = (9.0 + 5 + 4.5 + 4.0) / 5 = **4.50 / 5**

**Verdict**: **PASS** (≥4.5 threshold met, exactly at boundary)

---

## What was verified correct (with sources)

1. **Parquet's hierarchical layout (row group → column chunk → page)** — Confirmed via ClickHouse and Dremio Parquet deep-dives. Each column chunk is at a separate offset within the file, and queries that need many columns must read from many offsets. Source: [All About Parquet Part 02 — Parquet's Columnar Storage Model](https://medium.com/data-engineering-with-dremio/all-about-parquet-part-02-parquets-columnar-storage-model-8382e92c9815), [Columnar storage formats: Parquet, ORC, and Arrow explained (ClickHouse)](https://clickhouse.com/resources/engineering/columnar-storage-formats).

2. **Row reconstruction cost in columnar stores** — "Every column file must be opened to materialise a single row, so full-row point lookups on a column store can be more expensive than on a row store." Confirms the answer's core claim about `SELECT *` being slow. Source: [Row-oriented vs column-oriented databases (ClickHouse)](https://clickhouse.com/resources/engineering/row-vs-column-database), [Abadi: Column-Stores vs. Row-Stores](https://www.cs.umd.edu/~abadi/papers/abadi-sigmod08.pdf).

3. **SIMD vectorization in Trino's Parquet reader** — Trino has implemented a vectorized Parquet reader with predicate pushdown and lazy loading; SIMD enables single-instruction processing across many values. Source: [Vectorized decoding in parquet reader · trinodb/trino](https://github.com/trinodb/trino/actions/runs/9031572343), [Vectorized Query Execution](https://apxml.com/courses/intro-data-lake-architectures/chapter-5-querying-and-performance/vectorized-query-execution).

4. **Partition pruning as mitigation** — Iceberg's partition pruning combined with file-level min/max and row-group stats can eliminate 99%+ of files for selective queries. Source: [Iceberg Query Performance Tuning (Cazpian)](https://www.cazpian.ai/blog/iceberg-query-performance-tuning-partition-pruning-bloom-filters-and-spark-configs), [How Apache Iceberg Prunes Files Beyond Partitions (Medium)](https://medium.com/@freeflowcoders/how-apache-iceberg-prunes-files-beyond-partitions-a-deep-dive-with-spark-and-parquet-stats-c9e56603d363).

5. **"Keep single-row lookups in OLTP, bulk analytics in OLAP" as recognized pattern** — "Pick based on the dominant access path — frequent key based reads and small updates go to row [store]." Industry-accepted guidance. Source: [Row store vs columnar store: how to choose for a workload](https://www.designgurus.io/answers/detail/row-store-vs-columnar-store-how-to-choose-for-a-workload).

---

## Errors or gaps found

### MEDIUM — Missing Iceberg-specific lookup optimizations
The answer treats lakehouse single-row lookups as essentially a lost cause and redirects to Postgres. That's the correct default, but it omits real levers the engineer should know exist in their Iceberg 1.5.2 + Trino 467 stack:
- **Bloom filters on Parquet write** (`write.parquet.bloom-filter-enabled.column.<colname>=true`) can make `WHERE event_id = ...` skip 95%+ of row groups.
- **Iceberg sort order / `write.distribution-mode=hash`** clusters rows by the lookup key inside files, so min/max stats become useful for ID filters.
- **Manifest-level min/max stats** (mentioned via partition pruning but not as a general file-skipping mechanism for non-partition columns).

This isn't wrong — keeping the lookup in Postgres is the right first answer — but the answer over-rotates to "lakehouse is bad at this" without naming the lakehouse-side mitigations that exist.

### LOW — Slight imprecision on "separate physical location"
Lines 12 and 18 use "separate physical location" / "different file region" which a beginner might read as "different files." The accurate phrasing is "different byte offsets within the same Parquet file (one offset per column chunk per row group)." The answer's mental model is correct; only the phrasing is loose.

### LOW — Step (2) "Open the Parquet file footer to read schema and row-group statistics"
Technically correct that the footer is read, but the framing suggests this is a per-query overhead unique to Trino+Iceberg. In practice Trino caches Parquet footers and Iceberg manifests pre-filter the file list. The "5 steps vs 3 steps" framing slightly overstates Trino's overhead relative to Postgres's index-then-block path.

---

## Resource fix recommendations

### MEDIUM priority
- **`resources/03-columnar-storage.md`**: Add a short section "Mitigations for single-row lookups in Iceberg" listing Bloom filters, sort order, and `write.distribution-mode=hash`. Currently the resource (per the answer's framing) only offers "go back to Postgres" as the remediation, which is correct as a default but incomplete for engineers who genuinely need lakehouse-side fast lookups (e.g., for an embedded analytics drill-down).
- **`resources/10-lakehouse-partitioning.md`** or **`resources/18-query-performance-regression.md`**: Cross-link to the Bloom filter / sort order mitigations so future answers don't tell engineers "lakehouse can't do this" when the production stack actually can.

### LOW priority
- Clarify in `resources/03-columnar-storage.md` that column chunks are at different **byte offsets within the same Parquet file**, not different files. Current beginner-friendly phrasing "separate physical location on disk" is defensible but could be tightened with a one-sentence note.

---

## Rubric topic touched

Primary topic: **Columnar storage fundamentals** (resources/03). This topic was already PASSED in the rubric. The answer reinforces the pass — no regression detected. No update needed to rubric scores; this is an extended-phase confirmation, not a topic re-test.
