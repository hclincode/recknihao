# Iter22 Q4 Score

**Question**: SELECT tenant_id, COUNT(*) GROUP BY ran in 8s. Added LEFT JOIN to 200-row tenants table for plan_type. Now 7 minutes. Why, and how to fix?
**Topic**: Query performance basics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Feedback**: Perfect answer. Network shuffle / broadcast join explanation is technically correct. OLTP vs OLAP mental model contrast ("Your mind was trained on OLTP where JOINs are cheap. In OLAP, avoiding the JOIN is cheaper than executing it") is the best framing in the training run. Denormalization fix is the correct OLAP recommendation. ALTER TABLE ADD COLUMN as metadata-only in Iceberg is correct. Spark ingestion code with plan_type enrichment is practical. Backfill approach is included. When to denormalize vs keep a JOIN is correctly bounded. EXPLAIN ANALYZE validation step closes the loop.
