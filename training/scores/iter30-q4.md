# Iter30 Q4 Score

**Question**: Enterprise customer churned with contractual 72-hour deletion deadline. 2 years / 3TB Iceberg data plus Trino schemas/views/roles and Spark CronJobs still running. Complete decommission checklist and where data silently remains?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 3.0 |
| Beginner clarity | 4.0 |
| Practical applicability | 4.0 |
| Completeness | 4.0 |
| **Average** | **3.75** |

**Feedback**: Phase ordering correct (stop ingestion FIRST via kubectl delete cronjob). "Five hidden data layers" framing directly answers the "where does data silently remain?" question and is a strong teaching device. Runnable kubectl + Spark SQL + Trino SQL + `mc ls` throughout. Critical error: Step 4 labels `remove_orphan_files` as "THE STEP THAT PHYSICALLY DELETES" — wrong; `expire_snapshots` is the procedure that frees data files referenced by prior snapshots; `remove_orphan_files` only cleans files from failed writes. Same recurring error as Iter 10 Q1 and Iter 30 Q2. Engine context missing — CALL statements use Spark syntax next to Trino DDL without labeling the engine. JWT/OPA revocation layer absent. Contractual audit evidence too thin (no MinIO byte-count diff, no snapshot ID audit trail). HTML entities.
