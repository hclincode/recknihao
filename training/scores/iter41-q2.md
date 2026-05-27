# Iter41 Q2 Score

**Question**: Is it safe to DROP partitions on a day-partitioned shared Iceberg events table to remove a churning tenant?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.25** |

**Feedback**: The headline verdict is correct and well-explained — dropping `event_date` partitions on a shared multi-tenant table would delete every tenant's data for those days, and the responder leads with that landmine. The DELETE statement scoped by `tenant_id AND event_date` is the right corrective approach, and the 3-step cleanup sequence (rewrite_data_files -> expire_snapshots -> remove_orphan_files) covers the physical-removal path for GDPR-style erasure. Two production-stack issues drop the technical/practical scores: (1) all cleanup SQL uses Spark `CALL iceberg.system.*` syntax with no engine label — production query engine is Trino 467, where the equivalent is `ALTER TABLE ... EXECUTE rewrite_data_files`, `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '30d')`, and `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` — an engineer pasting these into Trino will get syntax errors; this is the same recurring CALL-vs-EXECUTE gap flagged in iter11 Q3 and noted in state.json as still unresolved. (2) The `expire_snapshots` call uses `current_timestamp - interval '0' day` with `retain_last => 1`, which is dangerously aggressive — it would expire the snapshot containing the just-completed rewrite, breaking time travel and risking concurrent reader failure; a 1-7 day retention window is the safer recommendation. The bonus point about partition DROP being safe only when each partition holds exactly one tenant's data (e.g., partitioned by tenant_id alone or `(tenant_id, day)`) is mentioned but blurred with a partition-evolution warning that overstates the risk. Sources verified against [Apache Iceberg Maintenance docs](https://iceberg.apache.org/docs/latest/maintenance/) and [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html).
