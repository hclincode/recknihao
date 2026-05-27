# Score: Iter 298, Q2 — Parquet/Iceberg vs Postgres B-tree on bulk filter

## Question recap
80M-row Postgres table; `event_type = 'page_view'` does a 45s full scan; B-tree index sometimes ignored by planner. Is Parquet/Iceberg actually better? How does it work — index-like or different?

## Score table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All core mechanics correct against official docs. (1) Parquet footer per-row-group min/max for predicate pushdown — verified against parquet.apache.org and DataFusion blog. (2) Iceberg manifest lower_bounds/upper_bounds per file for file-level pruning — verified against Iceberg metadata docs. (3) Dictionary encoding well-suited for low-cardinality columns (≤1 MiB distinct dictionary page) — verified. (4) Default row group size 128 MB — verified (parquet.block.size). (5) Postgres planner correctly chooses seq scan over high-selectivity index lookup due to random I/O on heap fetches — correct OLTP planner behavior. (6) `rewrite_data_files` with `strategy => 'sort'` and `sort_order => '...'` — verified syntax; answer correctly flags "(requires Spark)", which matches the prod stack (Spark is the ingestion engine). Minor nit: the table claim "Files 1–50 contain only 'click'" implies an unrealistically clean physical layout post-sort (real sorts produce range boundaries with overlap on group boundaries), but the answer frames this as illustrative and immediately follows with "Real-world speedups are 10x–100x (perfect assumptions don't hold)" which is honest. No factual errors. |
| Beginner clarity | 5 | Outstanding. The opening contrast ("B-tree locates individual rows; Parquet/Iceberg skips entire files") gives the mental model in one line. The three stacked layers (manifest → row group → column-only I/O) are introduced in order with concrete examples. The "Is it an index?" comparison table makes the trade-off explicit. No unexplained jargon: row group, manifest, dictionary encoding, predicate, selectivity are all explained inline or by example. The B-tree-vs-bulk-filter explanation (40M random heap fetches) directly addresses why the engineer's existing index "doesn't help" — exactly the confusion the question expressed. |
| Practical applicability | 5 | Engineer can act immediately on the prod stack (Trino 467 + Iceberg 1.5.2 + MinIO + Spark for ingestion). Concrete `CALL iceberg.system.rewrite_data_files(... strategy => 'sort' ...)` procedure body with realistic sort_order column choice (`event_type ASC NULLS LAST, occurred_at ASC`). The "(requires Spark)" caveat is the correct call-out for this stack — Trino 467 supports sorted_by on writes and optimize, but the dedicated rewrite_data_files sort strategy is the Spark-side path. The OLAP-vs-OLTP closing ("count all page_view" vs "fetch event_id = abc123") gives the engineer a decision rule for what to keep in Postgres vs route to Trino. |
| Completeness | 5 | Covers all four parts of the question: (a) yes, Parquet/Iceberg is faster — with magnitude (10x–100x), (b) why the B-tree fails on this query (high selectivity + random I/O), (c) the mechanism (three layered skipping reductions), (d) how it differs from an index (problem-solved comparison table). Goes beyond by including: dictionary encoding for low-cardinality columns, the unsorted-vs-sorted layout contrast (which is the actionable lever), the concrete numbers walkthrough (80 GB → 75 MB), and the OLTP-vs-OLAP trade-off. The "how to unlock the speedup" section turns understanding into a runbook step. Nothing important missing. |

## Verification notes

- **Parquet row group / column chunk statistics**: parquet.apache.org/docs/concepts and DataFusion pruning blog confirm per-row-group min/max in footer drives row-group skipping; predicate pushdown operates at row-group AND row level (page filter). Answer's "row groups ~128 MB chunks" matches the parquet.block.size default.
- **Iceberg manifest lower_bounds/upper_bounds**: confirmed per Iceberg metadata documentation and Alex Merced's "Performance and Apache Iceberg's Metadata". Answer's "manifest files — small metadata listing every Parquet file plus min and max values per column for each file" is accurate.
- **Dictionary encoding**: confirmed dictionary encoding fits within ~1 MiB dictionary page limit and is ideal for low-cardinality columns like a 4-value `event_type`. Answer's "~10x compression" is realistic for this case.
- **rewrite_data_files sort strategy**: confirmed in Iceberg Spark procedures docs (`strategy => 'sort'`, `sort_order => 'id DESC NULLS LAST,name ASC NULLS FIRST'`). Answer's syntax is correct. Trino 467 supports `ALTER TABLE ... EXECUTE optimize` with `sorted_by` table property as the native path; answer's "(requires Spark)" parenthetical is accurate for the dedicated sort rewrite procedure and fits the prod stack where Spark handles ingestion.
- **Postgres planner**: standard cost-based behavior — when bitmap heap fetch cost exceeds seq scan, planner picks seq scan. Answer correctly says "isn't a planner bug".

## Topic mapping

Primary: **Query performance basics: partitioning, indexing strategy for analytics** (currently PASSED 4.594 / 4 questions) — covers why columnar + file-level statistics beat row-store B-tree on bulk filters.

Secondary: **Column-oriented storage — what it is and why it's faster for analytics** (currently PASSED 4.125 / 2 questions) — the Layer 3 column-only I/O section and dictionary encoding contribute here.

Tertiary: **OLAP vs OLTP — difference and why it matters for SaaS** (currently PASSED 4.542 / 3 questions) — the closing trade-off section explicitly frames OLTP point-lookup vs OLAP bulk-filter as different problems.

## Verdict

Average: (5 + 5 + 5 + 5) / 4 = **5.00 — PASS**

This is a model answer for the topic: technically airtight, mentally clear, immediately actionable on the prod stack, and complete without padding. The layered explanation (manifest → row group → column-only I/O) is exactly the framing a SaaS engineer needs to internalize before they touch Iceberg query tuning. Recommend no resource changes prompted by this answer.
