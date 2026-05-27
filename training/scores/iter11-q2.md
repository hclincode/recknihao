# Iter 11 Q2 — GDPR physical deletion: proving bytes are gone from MinIO

## Question summary
A SaaS engineer ran `DELETE FROM events WHERE tenant_id = 'acme'` on Iceberg via Trino, got a zero-count SELECT, and is now being asked by their legal team to prove the bytes are physically gone from MinIO — not just hidden from queries. They want to know whether the SELECT is sufficient or whether more steps are required.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | The 3-step sequence (DELETE → rewrite_data_files → expire_snapshots) is correct per official Iceberg documentation. expire_snapshots does physically delete data files that are no longer referenced by any live snapshot ("will remove old snapshots and data files which are uniquely required by those old snapshots" — iceberg.apache.org). The `older_than => current_timestamp() - INTERVAL '0' DAY, retain_last => 1` combination correctly expires all non-current snapshots immediately. Both `current_timestamp()` (with parens) and `current_timestamp` are valid and identical in Spark SQL. The `where` parameter in rewrite_data_files is valid in Iceberg 1.5.x. The distinction between Trino (step 1) and Spark (steps 2 and 3) is accurate for the prod stack. |
| Beginner clarity | 5 | Excellent beginner framing throughout. Leads with the key conceptual gap ("Iceberg does not erase Parquet files — it creates a marker file") before any SQL appears. Each step explains what happened on disk, not just what ran. "Delete file," "snapshot," "compaction" are all defined inline or clearly described in context. The "prove it to your legal team" section closes with a concrete MinIO verification command (`mc ls --recursive`). The rollback window note is framed accessibly ("Between step 2 and step 3, the deletion is reversible"). No unexplained jargon remains. |
| Practical applicability | 5 | The engineer has a complete, ordered checklist they can follow start to finish. The Spark vs Trino distinction is explicit (steps 1, 2, 3 each named by engine). The `mc ls` verification command gives the legal team the specific physical-layer evidence they asked for. The `older_than / retain_last` parameters are explained so the engineer understands why the non-default values matter. The rollback window caution ("sanity-check the tenant ID before starting") is exactly the operational guardrail needed before running an irreversible compliance procedure. The "repeat for every Iceberg table" note avoids partial-erasure mistakes. |
| Completeness | 5 | Directly answers both halves of the question: (1) Is a zero-count SELECT enough? No — explained why clearly. (2) What more is needed? All three steps with runnable SQL, engine attribution, disk-state explanation per step, legal-team audit checklist, and rollback warning. The answer matches the resource (resources/05-multi-tenant-analytics.md GDPR section) closely and correctly. The one omission a strict auditor might raise — whether remove_orphan_files is also needed — is not a material gap: official Iceberg documentation confirms expire_snapshots does issue physical deletes for unreferenced files from completed snapshots (orphan_file cleanup is for a different class of files abandoned by failed writes, not for expired snapshot data). |
| **Average** | **5.00** | |

## Topic updated

**Topic**: Multi-tenant analytics: isolating customer data in SaaS

- Prior avg: 3.75 (5 questions)
- New score this question: 5.00
- New running avg: (1.75 + 4.75 + 4.75 + 4.25 + 3.25 + 5.00) / 6 = **3.958**
- Status: PASSED (avg 3.958 >= 3.5 threshold, 6 questions)

## Key finding

This is the strongest multi-tenant answer in the training run and directly validates that the GDPR right-to-erasure section added to `resources/05-multi-tenant-analytics.md` (the Bug 1 fix from Iter 10 feedback) is working correctly. The previous Iter 10 Q1 answer on essentially the same topic scored 3.25 because it stopped at step 2 and omitted expire_snapshots entirely. This answer scores 5.00 across all dimensions — the resource fix produced a complete reversal of the failure pattern.

The answer also demonstrates that the resource's rollback-window framing and the MinIO verification recipe transferred cleanly to the responder without distortion.

## Resource gap

No resource gaps identified for this answer. The resource (`resources/05-multi-tenant-analytics.md`) already contains the complete GDPR section with the 3-step sequence, audit checklist, rollback window explanation, and common-mistake warning about default expire_snapshots retention. The responder reproduced all of it accurately and at the right level of abstraction for a beginner audience. The topic's running average (3.958) remains above threshold but is the weakest passing topic. A 7th question from a different angle (e.g., partial erasure — "acme has multiple user_ids to erase, not the whole tenant") would help build confidence in the depth of understanding.
