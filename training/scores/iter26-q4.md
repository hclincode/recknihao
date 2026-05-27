# Iter26 Q4 Score

**Question**: Trino query planning takes 10-15 seconds before any data read. DBA says "it's a Trino problem." You suspect Iceberg table health. Who's right, and how do you tell?
**Topic**: Iceberg table maintenance
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4.75 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 4.75 |
| **Average** | **4.75** |

**Feedback**: Correctly diagnoses manifest accumulation as the root cause of slow planning — Trino reads all manifest files during the planning phase to determine which data files to skip; excessive manifests directly inflate planning time with zero data-read benefit. Diagnostic queries using `events$manifests`, `events$snapshots`, and `events$files` system tables are practical and directly actionable. Fix: `CALL iceberg.system.rewrite_manifests()` correctly labeled Spark-only. "It's the table, not Trino" framing concisely resolves the DBA-vs-engineer dispute. After-maintenance expectation (planning drops from 15s to under 2s) gives the engineer a concrete success criterion. `expire_snapshots` correctly identified as the complementary step. HTML entities in code blocks (persistent generation artifact).
