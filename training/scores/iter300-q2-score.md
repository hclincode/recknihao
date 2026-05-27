# Iter 300 Q2 Judge Score

## Topic
Column-oriented storage — what it is and why it's faster for analytics

## Scores
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | 5.00 |

## Pass/Fail
PASS (threshold: 3.5)

## Technical accuracy verification

1. **Parquet stores columns together on disk vs row-oriented Postgres** — CORRECT. Verified via Parquet documentation and ClickHouse/Latentview articles: Parquet stores values column by column, while Postgres uses row-oriented heap tuples. The answer's contrast diagram is accurate.

2. **Trino implements projection pushdown / column pruning** — CORRECT. Verified via Trino blog (dereference pushdown) and Parquet documentation: Trino's Parquet reader reads only the column chunks requested and skips others entirely. The phrase "Trino opens and decompresses only those 2 column strips and skips the other 18 entirely" is technically accurate (though strictly Parquet uses "column chunks" within row groups, "column strips" is fine as informal terminology; ORC uses "stripes").

3. **Performance claim of 10–20x for wide tables** — REASONABLE. For an 80-column table where you select 3 columns, the I/O reduction is ~27x (bytes-read), and end-to-end query time often improves 5–20x depending on compute vs I/O balance. The detailed table (10% for narrow tables → up to 100x without partition filter) is realistic and well-calibrated.

4. **`DESCRIBE table_name`** — CORRECT. Verified via Trino 479 docs: `DESCRIBE` is a valid alias for `SHOW COLUMNS`. The qualified form `DESCRIBE iceberg.analytics.events` works.

5. **`TABLESAMPLE BERNOULLI (5)`** — CORRECT. Verified via Trino 481 SELECT docs. Syntax is valid. Minor nuance: BERNOULLI still scans all physical blocks (it does row-level sampling, not block skipping), so for I/O-bound exploration `TABLESAMPLE SYSTEM` might be faster, but the BERNOULLI example is syntactically and semantically valid.

6. **`EXPLAIN (TYPE DISTRIBUTED)`** — CORRECT. Verified via Trino 480/481 EXPLAIN docs. This is valid syntax and does NOT execute the query — it only produces the plan.

7. **Compression amplification claim (5–30x compression per column)** — CORRECT. Same-type adjacent values compress dramatically better than mixed row-interleaved bytes; the cited range matches common observations on Parquet workloads.

8. **MinIO/Iceberg/Trino context** — Properly aligned with prod_info.md (on-prem MinIO via S3, Trino with Iceberg connector). Network I/O from MinIO is correctly identified as the dominant cost.

## What worked

- Perfectly framed the Postgres vs Trino contrast — directly answers the user's "why specifically" question rather than restating generic advice.
- Concrete ASCII diagram showing row-major vs column-major layout — excellent for beginner clarity.
- Quantitative bytes-read math (80 cols → 3 cols → 27x reduction) gives an engineer a defensible number to use in planning.
- Practical impact table calibrated across multiple scenarios (10%, 2-3x, 10-20x, up to 100x) directly answers the user's quantitative question ("10% or 10x?").
- Tied compression amplification to columnar layout — captures a nuance most short answers miss.
- "What to do instead" section is actionable: DESCRIBE for column discovery, partition filters, EXPLAIN (TYPE DISTRIBUTED), TABLESAMPLE for exploration. All verified syntactically valid.
- Production environment fit: references MinIO and Iceberg by name, uses the iceberg.analytics.events catalog form consistent with the Trino+Iceberg+Hive Metastore stack.
- Concise closing "key insight" reinforces the takeaway without over-padding.

## What was wrong or missing

- Minor terminology nit: Parquet uses "column chunks" within "row groups" rather than "column strips" (ORC terminology). Not technically incorrect since the answer doesn't claim Parquet-specific terms, but a stricter answer would use Parquet's vocabulary. This is a very minor polish point and does not warrant a score deduction.
- TABLESAMPLE BERNOULLI does row-level filtering after scanning all blocks, so for pure I/O reduction TABLESAMPLE SYSTEM is sometimes preferred. The answer doesn't mislead but could note this distinction. Minor.
- Could mention Trino's `hive.parquet.use-column-index` / column index optimization for an extra level of detail, but at this depth omission is appropriate to avoid overwhelming the reader.

Overall: an exemplary answer that gets the physics right, frames it for a Postgres engineer, quantifies the impact, and gives 4 actionable next steps fitted to the production stack.

## Suggested topic score update
Old: 4.456 / 7 questions
New avg if this scores 5.00: (4.456*7 + 5.00) / 8 = (31.192 + 5.00) / 8 = 36.192 / 8 = **4.524** across 8 questions. Status: PASSED.
