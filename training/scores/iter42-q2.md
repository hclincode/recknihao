# Iter42 Q2 Score

**Question**: CALL iceberg.system.expire_snapshots in Trino throws syntax error; current_timestamp() cutoff breaks live readers.
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 4 |
| **Average** | **4.50** |

**Feedback**: Both mistakes are diagnosed correctly and the Trino vs Spark engine split is stated clearly with the right corrected syntax (`ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')`), which matches the Trino 467 Iceberg connector docs. The explanation of why `current_timestamp()` breaks concurrent readers is accurate and the 7–30 day safe-window guidance fits the production stack (Trino 467 + Spark/Iceberg 1.5.2 on-prem). Minor gaps: it does not mention the catalog-level `iceberg.expire-snapshots.min-retention` constraint that would actually block a too-short retention_threshold in Trino, nor does it acknowledge the legitimate GDPR/hard-delete scenario where an aggressive cutoff with `retain_last=1` is intentionally accepted (trading off time-travel). Adding a one-line note that the SaaS engineer's churned-tenant deletion case may justify a tighter window for compliance — at the cost of losing rollback — would make this a fully complete answer.
