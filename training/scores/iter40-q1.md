# Iter40 Q1 Score

**Question**: Is `write.data.retention.days` a per-tenant Iceberg property, and when should mixed-retention tenants get separate tables?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Feedback**: Strong answer that directly closes the user's actual confusion — it correctly states that `write.data.retention.days` is a table-level snapshot-retention control (verified against Iceberg/Snowflake docs: snapshot age expiration, not row deletion) and that no per-tenant retention property exists. The shared-table row-level DELETE pattern (WHERE tenant_id AND occurred_at) plus the 3-step physical cleanup chain (rewrite_data_files → expire_snapshots → remove_orphan_files) matches the expected key points and is correct for the prod stack. The 10x retention-spread heuristic gives the engineer a concrete decision rule. Minor gaps: (1) no explicit warning that partition DROP is NOT a valid shortcut here (a day-partition contains multiple tenants' rows so a DROP PARTITION would wipe other tenants — this is exactly the gotcha flagged in state.json notes for resource 05); (2) Spark CALL syntax shown without noting Trino uses `ALTER TABLE ... EXECUTE` — an engineer on Trino 467 will hit a syntax error (recurring issue from Iter 11 Q3 / Iter 12 / state.json resource 17 callout); (3) jargon like "snapshot," "orphan files," "partition key" used without inline glosses costs a beginner-clarity point.
