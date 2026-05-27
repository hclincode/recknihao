# Iter21 Q3 Score

**Question**: CS team wants per-tenant query cost report — which tenants consume most compute? How to pull query metrics from Trino and surface to CS for data-driven conversations.
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.81** |

**Feedback**: Very thorough. Both collection methods (REST API polling and HTTP event listener) are accurate. JWT principal → tenant_id mapping correctly connects to existing resource group setup. Three CS-facing metrics (CPU-hours, GB scanned, P50/P95 wall time) are practical and correctly defined. SQL dashboard query is usable. Compressed bytes note (totalBytes = Parquet bytes, 5-10x smaller than uncompressed) is a useful accuracy note. Minor docks: (1) Python code writes to PostgreSQL mid-answer then mentions Iceberg — slightly inconsistent with the production stack; (2) FastAPI + HTTP event listener configuration is dense for a beginner without deployment experience. Implementation roadmap helps ground it. No technical errors.
