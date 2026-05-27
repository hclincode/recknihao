# Score: Iteration 16, Question 3

**Date**: 2026-05-24
**Phase**: Final
**Question**: I ran the query-explain tool and it reported 80 MB scanned, but the file in storage is 600 MB. Did the system lie to me, or did it actually skip most of the file?
**Rubric topics covered**: Column-oriented storage — what it is and why it's faster for analytics; Iceberg+Trino query patterns

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | Three-layer mechanism correctly identified and explained: (1) Iceberg manifest pruning using column min/max stats; (2) Parquet row-group pruning using per-chunk stats; (3) column projection (columnar storage reads only queried columns). EXPLAIN ANALYZE hint is correct. All technical claims verified against resources. Minor: row-group stats description says "Bloom filter" — Bloom filters in Parquet are a separate optional structure from row-group min/max stats, and not standard in Iceberg 1.5.2 without explicit enabling. Should say "min/max statistics (and optionally Bloom filters)." |
| Beginner clarity | 4.75 | Excellent "No, the system didn't lie" opener immediately resolves the confusion. Three layers named clearly. The "remove your WHERE clause" diagnostic tip is highly actionable and concrete. |
| Practical applicability | 4.75 | Correctly grounds all three layers in the Trino + Iceberg + Parquet + MinIO production stack. EXPLAIN ANALYZE tip is the right next step for an engineer debugging this. |
| Completeness | 4.50 | Three layers covered. Missing: doesn't explain the vectorized batch processing / SIMD dimension (why the 80 MB that IS read gets processed fast). The question is specifically about the "scanned bytes" discrepancy, so omitting SIMD is defensible — but a complete answer would note that the 80 MB is also processed more efficiently than Postgres would. |
| **Average** | **4.69** | |

---

## What the answer got right

1. Three-layer mechanism: manifest pruning → row-group pruning → column projection — all correct.
2. "EXPLAIN ANALYZE" as diagnostic tool — correct suggestion.
3. "Filtering reduces bytes touched by 100x or more" — directionally accurate.
4. "No, the system didn't lie" opener — exactly the reassurance a confused engineer needs.

## What the answer missed

1. **Bloom filter overstated.** Bloom filters in Parquet are not part of row-group statistics by default in Iceberg 1.5.2. Standard row-group pruning uses min/max only. Should say "min/max statistics" not "and sometimes a Bloom filter."

2. **No mention of decompression or vectorized batch/SIMD.** The question focuses on "skipped bytes" but the complete picture includes: bytes are skipped (the 3 layers), AND the remaining bytes are processed efficiently (vectorized batch + SIMD). Not a critical gap given the question framing, but the resource now includes this chain.

---

## Topic score updates

**Column-oriented storage — what it is and why it's faster for analytics**
- Prior after iter15: avg 4.219 across 4 questions
- This answer: 4.69 (5th angle — EXPLAIN scan bytes / file-skipping cascade)
- New running avg: (16.876 + 4.69) / 5 = **4.313** across 5 questions
- Status: PASSED (improving)

**Analytical query patterns on Iceberg+Trino**
- This answer partially exercises this topic (EXPLAIN ANALYZE, manifest pruning, row-group pruning)
- Not recording as primary question for this topic to avoid double-counting
