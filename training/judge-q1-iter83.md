# Judge Score — Iter 83 Q1

## Score: 4.75 / 5.0
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |

## Points covered
For the "Multi-tenant analytics: isolating customer data in SaaS" topic, this question hit a GDPR right-to-erasure angle (multi-tenant compliance):
- Snapshot mechanics and time-travel semantics for tenant data
- The interaction between snapshot retention and audit/compliance windows
- The full four-step GDPR purge sequence: DELETE -> rewrite_data_files -> expire_snapshots -> remove_orphan_files
- Why current-state metadata-table verification (`$files`) is the auditor-grade proof rather than time-travel
- Operational separation of two retention policies: cost-driven weekly maintenance (30-day) vs. compliance-driven on-demand purge (0-day)
- Clear warning not to mix the aggressive zero-day expiry into weekly scheduled maintenance
- Tenant-scoped DELETE pattern (`WHERE tenant_id = 'acme'`) consistent with the multi-tenant model

## Accuracy notes
Verified via WebSearch against Trino docs, Iceberg docs, Dremio, and Ryft GDPR guides:

1. **Trino `FOR SYSTEM_TIME AS OF TIMESTAMP '...'`** — Valid. Trino accepts both the SQL-standard `FOR SYSTEM_TIME AS OF` and the more commonly documented `FOR TIMESTAMP AS OF`. Either is correct.
2. **Spark `FOR VERSION AS OF <snapshot_id>`** — Valid Spark/Iceberg syntax. Also valid in Trino. The `@snapshot_id` alternate syntax shown for Trino is also correct.
3. **`expire_snapshots` with `older_than => CURRENT_TIMESTAMP - INTERVAL '0' DAY, retain_last => 1`** — Syntactically valid. In practice the table property `history.expire.min-snapshots-to-keep` (default 1) and `history.expire.max-snapshot-age-ms` may need to be set to allow expiring very recent snapshots; some engines also require the procedure-level setting. Answer does not mention this subtle gotcha, but the call itself is well-formed and `retain_last => 1` correctly anchors the current snapshot.
4. **Four-step GDPR sequence** — DELETE -> rewrite_data_files -> expire_snapshots -> remove_orphan_files is the canonical sequence endorsed by Dremio and Ryft compliance guides. Order in the answer is correct.
5. **`events$files` with `partition.tenant_id = 'acme'`** — Correct. The `$files` metadata table exposes a `partition` column as a struct; if `tenant_id` is the partition column, dot access works in Trino. Accurate verification pattern.

## Issues / gaps
Minor deductions on Beginner clarity (4 instead of 5):
- The phrase "delete file" is introduced briefly but a true beginner may conflate it with "deleting a file." A one-line note distinguishing position/equality delete markers from physical Parquet files would help.
- The distinction between "snapshot metadata is gone" and "Parquet bytes still on disk" is explained well, but could benefit from a tiny diagram or numbered timeline showing what `expire_snapshots` deletes vs. what `remove_orphan_files` deletes.

No deductions on Technical accuracy, Practical applicability, or Completeness:
- The crucial conceptual reframing — "do not use time-travel as compliance proof; use current metadata-table verification" — is exactly what an auditor would want.
- The two-window operational pattern (weekly 30-day vs. on-demand 0-day) is the right production pattern.
- The bottom-line wrap-up directly answers the engineer's question: "Is time-travel reliable for compliance?" Answer: yes for current state via metadata tables; conditional for historical state.
- Uses Spark+Iceberg+Trino+MinIO references aligned with the on-prem production stack in prod_info.md.

Optional enhancements (not deducted):
- Could mention capturing the metadata-table verification result + snapshot history into an immutable audit log (e.g., write to a separate audit Iceberg table) so the proof itself survives.
- Could caveat that delete files may require Iceberg V2 format for some procedures.

## Resource fix needed?
No urgent fix. The resources clearly support this answer well. Optional minor enhancement for resources/13 or resources/05-multi-tenant-analytics.md:
- Add a short "GDPR audit pattern" callout showing the metadata-table verification queries plus capture-to-audit-table idiom.
- Add a one-line caveat on `expire_snapshots` zero-day usage about `history.expire.min-snapshots-to-keep` and `max-snapshot-age-ms` table properties potentially needing to be relaxed.
