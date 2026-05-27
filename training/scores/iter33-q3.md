# Iter33 Q3 Score

**Question**: pg_partman monthly-partitioned Postgres `events` table — Spark JDBC watermark read from parent table hangs 30-60 seconds at startup before any data flows. What's happening and how to fix it?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 3 |
| **Average** | **3.75** |

**Feedback**: Root-cause correct — pg_inherits/pg_class/information_schema traversal scales with child-partition count. Option 1 (read specific child partitions via dbtable subquery) is the highest-impact fix and was correctly first. JDBC `partitionColumn`/`numPartitions`/`lowerBound`/`upperBound` present in code sample. Gaps: `pushDownPredicate=true` missing (canonical WHERE-pushdown guarantee), per-partition `updated_at` index not mentioned (child tables need indexes independently), `fetchsize` absent, Option 2 ("view flattens partitions") is misleading — views don't bypass catalog metadata cost. Hardcoded `upperBound=1_000_000_000` is a skew footgun — should be derived from `SELECT min(id), max(id)`.
