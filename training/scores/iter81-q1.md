# Iter 81 Q1 — Judge Score
**Topic**: Multi-tenant analytics
**Score date**: 2026-05-25

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.75 |
| Practical applicability | 5.0 |
| Completeness | 4.75 |
| **Average** | **4.75** |

## Points covered
1. **Hidden partitioning** — Correctly explained that `WHERE event_time >= '2026-05-01'` is automatically translated to partition boundaries; no need to wrap in `day()` function. Matches Trino "Just the right time date predicates with Iceberg" blog post and Iceberg docs.
2. **No tenant pruning for cross-tenant aggregate** — Correctly identifies that with no tenant filter, all tenant files in the date range must be opened.
3. **Date-only vs (date, tenant_id) tradeoff** — Correctly characterized in summary table: both scan the same files for billing query, but (date, tenant_id) makes per-tenant follow-up queries fast. The "better file locality" nuance for the billing query is plausible (sequential vs interleaved reads).
4. **Parquet metadata for COUNT(*)** — Mentions the optimization. Slightly imprecise for this specific query (see issue below).
5. **Partition skew if tenant_id is first** — Captured in the table: `tenant_id` only = slow for cross-tenant date-range queries (no date pruning).
6. **Recommended layout** — `ARRAY['day(event_time)', 'tenant_id']` with rationale; valid Trino/Iceberg partition spec syntax verified.
7. **Compaction follow-up** — `EXPLAIN ANALYZE` diagnosis + `ALTER TABLE events EXECUTE optimize` (Trino) AND `CALL iceberg.system.rewrite_data_files(...)` (Spark), properly engine-labeled.

## Issues
1. **Metadata-only COUNT(*) slightly over-promised for GROUP BY case**: The answer says "Trino can use Parquet column statistics (row count per row group) to skip reading actual row data... just the row counts from each file's metadata." This is precise for a bare `SELECT COUNT(*)` (and requires `optimizer.optimize-metadata-queries=true` to apply broadly). For `COUNT(*) GROUP BY tenant_id` (the actual query), Trino still must read the `tenant_id` column values to assign rows to groups — it cannot answer purely from file footer counts unless tenant_id is itself a partition column (which is part of the recommended spec, in which case grouping can leverage partition metadata). The nuance is partially preserved by the recommended `(day(event_time), tenant_id)` layout, but the answer doesn't explicitly call out that the metadata-only optimization is strongest when tenant_id is in the partition spec.
2. **Minor**: "Row groups" and "Parquet footer metadata" are used without a brief glossary aside; an OLAP-novice reader may have to infer.
3. **Minor**: No mention of `optimizer.optimize-metadata-queries` session/config property that gates parts of the metadata-only optimization.

## Accuracy verification
- Trino hidden partitioning + automatic timestamp-predicate transformation: verified via Trino blog "Just the right time date predicates with Iceberg" (trino.io/blog/2023/04/11/date-predicates.html).
- Iceberg partition spec syntax `partitioning = ARRAY['day(event_time)', 'tenant_id']`: verified via Trino Iceberg connector docs and Iceberg partitioning docs.
- `ALTER TABLE ... EXECUTE optimize` (Trino) and `CALL iceberg.system.rewrite_data_files` (Spark) engine attribution: correct.
- COUNT(*) metadata-only optimization: real and supported by Trino; correctly described for the bare COUNT(*) case, mildly over-stated for the GROUP BY tenant_id case.

## Resource fix needed?
Small clarification in `resources/05-multi-tenant-analytics.md` (or a partition-design resource): when answering "Will COUNT(*) GROUP BY tenant_id read all rows?" — clarify that:
- Bare `SELECT COUNT(*)` can be answered from Parquet footer row counts (metadata-only).
- `COUNT(*) GROUP BY tenant_id` requires reading the `tenant_id` column values UNLESS `tenant_id` is a partition column — in which case Trino can derive counts per tenant from manifest-level row counts per partition without reading row data. This makes `(day(event_time), tenant_id)` partitioning the metadata-only optimal layout for the billing pattern.

## Updated topic average: 4.395 / 78 questions
(4.418 × 77 + 4.75) / 78 = (340.186 + 4.75) / 78 = 344.936 / 78 ≈ **4.422** across 78 questions. PASSED.
