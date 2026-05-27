# Iter20 Q2 Score

**Question**: How to read Trino EXPLAIN output for a 12-minute timing-out query — "fragments", "exchanges", and numbers look different from Postgres
**Topic**: Query performance basics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.875** |

**Feedback**: Outstanding beginner-friendly explanation of Trino EXPLAIN. Postgres vs Trino mental model (single-machine pipeline vs distributed fragments) is excellent framing. Three diagnostic patterns (high file count, data skew, network shuffle) are correct and practical. EXPLAIN ANALYZE syntax, Files/Input/Wall metrics are all accurate. Debugging checklist is directly actionable. Minor dock on technical accuracy: `CALL iceberg.system.rewrite_data_files()` mentioned as a fix without labeling it as a Spark command — a beginner might try it in Trino where it won't work.
