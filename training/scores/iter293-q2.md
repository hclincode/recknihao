# Iter293 Q2 Score

**Question**: What does SELECT * actually cost in Trino vs Postgres? At what layer does Trino stop reading data it doesn't need in columnar storage?

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Parquet's column-chunk-as-contiguous-byte-range model is correct; the three-layer pruning order (manifest file pruning → row-group stats pruning → column-chunk projection) matches Iceberg+Trino+Parquet behavior. Decompress + decode (dictionary/delta) steps named correctly. `Physical Input` is the right field in EXPLAIN ANALYZE output. Row group ~128 MB matches Parquet defaults (technically configurable to 128–512 MB but 128 is the historical default). Postgres row-page fetch behavior described correctly. |
| Beginner clarity | 5 | Contrast is framed in concrete terms a Postgres engineer instantly recognizes ("same page was read, dropping unused columns happens later"). No unexplained jargon — "column chunk", "row group", "manifest" each get a layer header with what they do. The concrete 50-column example anchors the abstraction. |
| Practical applicability | 5 | Engineer leaves with: (1) named columns rule for prod, (2) SELECT * acceptable for `LIMIT 10` exploration with partition filter, (3) wide-dashboard fallback (pre-aggregated rollup table via dbt — fits the on-prem dbt-supported stack), (4) measurement method (EXPLAIN ANALYZE `Physical Input` diff between named-cols and SELECT *). All four are immediately actionable in the MinIO+Iceberg+Trino 467 production environment. |
| Completeness | 5 | All three layers covered with correct ordering. Both halves of the question answered: cost comparison vs Postgres AND the specific layer (column chunk read in Layer 3) where Trino stops reading unneeded data. Decompress + decode CPU cost (not just I/O) mentioned. Minor internal inconsistency: short-answer says "25x more I/O" but the worked example says "16x more I/O" (50/3 ≈ 16.7) — slightly sloppy framing but doesn't change the conclusion. Not enough to dock a point. |

**Average**: 5.0
**Pass**: YES (threshold 3.5)

## Topic updates

- `SQL query best practices for OLAP: partition column in WHERE, avoid SELECT *, approximate functions, EXPLAIN verification, type-safe predicates, avoiding pushdown-breaking patterns` — already PASSED (4.517, 8 questions). Add this 9th data point at 5.0 → new avg ≈ 4.571.
- `Columnar storage` topic also touched — answer correctly describes per-column contiguous byte ranges and the decompress/decode cost.

## Notes

The answer is production-aligned: MinIO as the byte-source over network, dbt as the rollup-table tool, EXPLAIN ANALYZE `Physical Input` as the measurement primitive — all match the on-prem Trino 467 + Iceberg 1.5.2 stack in prod_info.md. The "25x vs 16x" wording mismatch in the short-answer is the only flaw worth noting for the teacher; not score-affecting at this magnitude.

Verified via WebSearch:
- trino.io EXPLAIN ANALYZE docs confirm physical input tracking and projection pushdown
- parquet.apache.org confirms row group / column chunk model and 128 MB default
