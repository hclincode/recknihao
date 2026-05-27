# Score — Iter283 Q2

**Score: 4.70/5.0 PASS**

## Breakdown
- Technical accuracy (40%): 4.7/5 — Structural costs are correct (JDBC single connection, no pre-computed join). `dynamicFilterSplitsProcessed` is a real operator stat in Trino. Domain compaction default of 256 is confirmed. The "single-task" framing is slightly imprecise — the PostgreSQL connector is single-split/single-connection for an unpartitioned scan, which effectively serializes the read. Saying "single task" is colloquially close but a more accurate phrasing is "single split / single JDBC connection." Minor wording issue, not a correctness failure.
- Completeness (25%): 4.8/5 — Covers federate-vs-ingest decision threshold (2s after tuning), CTAS initial load, MERGE INTO incremental sync with 2-hour overlap watermark, hybrid UNION ALL view, broadcast join benefit. Decision summary table provides clear thresholds. Could mention deletion handling / hard-delete reconciliation, but the SCD lens is well covered.
- Production fit (20%): 4.7/5 — Fits Trino 467 + Iceberg 1.5.2 + MinIO + Hive Metastore on-prem stack. CTAS + MERGE INTO are supported in Iceberg 1.5.2. Broadcast join sizing (150-300MB) is realistic for the 20M-row table. Hybrid UNION ALL pattern is achievable on-prem without extra infra.
- Clarity (15%): 4.6/5 — Numbered structural costs, ordered tuning steps, decision summary table, and clear threshold ("if still >2s"). A SaaS engineer can execute step-by-step.

## What was correct
- Three structural costs of JDBC federation accurately identified
- Tuning-first approach (dynamic filtering, predicate pushdown, EXPLAIN ANALYZE) before resorting to ingestion
- `dynamicFilterSplitsProcessed > 0` is the correct stat to look for in EXPLAIN ANALYZE
- Domain compaction threshold of 256 verified as Trino default (per official docs across MySQL/PostgreSQL/SQL Server connectors)
- Iceberg session property `<catalog>.dynamic_filtering_wait_timeout` confirmed as correct
- 20M rows ≈ 150-300MB Parquet sizing is reasonable, enables broadcast join
- CTAS + MERGE INTO incremental sync with overlap watermark is sound SCD handling
- Hybrid view pattern (Iceberg historical + Postgres tail) is a legitimate freshness solution
- Decision threshold tied to measurable outcome (>2s after tuning)

## Errors or gaps
- "Single-task in OSS Trino" should more precisely be "single split / single JDBC connection per scan." OSS Trino can have multiple tasks per stage; the bottleneck is that the PostgreSQL connector emits one split per table scan (no parallel JDBC reads), which forces one driver to read the table.
- Session property syntax should include the catalog prefix (e.g. `iceberg.dynamic_filtering_wait_timeout` is correct only if the catalog is literally named `iceberg`). A note that the prefix is the catalog name would prevent confusion.
- No mention of how to handle hard deletes in Postgres (MERGE INTO with watermark only catches inserts/updates within the window); for true SCD with deletes, a periodic full reconciliation is needed.
- "Domain compaction at IN-list ≥256" is correct, but worth noting it is configurable via `domain_compaction_threshold` session property if pushdown is needed for larger IN lists.

## Verification
- WebSearch confirmed `domain-compaction-threshold` default of 256 across JDBC connectors (Trino official docs).
- WebSearch confirmed PostgreSQL connector uses single JDBC connection / single split per scan (long-standing limitation in OSS Trino, ref issue #389). The answer's "single task" framing is colloquially close but technically the constraint is at the split/connection layer.
- WebSearch confirmed `<iceberg-catalog>.dynamic_filtering_wait_timeout` is the correct session property pattern.
- WebSearch confirmed `dynamicFilterSplitsProcessed` is a real OperatorStats metric added in PR #3217 and reported in EXPLAIN ANALYZE for ScanFilterProject nodes.
