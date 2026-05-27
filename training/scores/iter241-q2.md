# Score: iter241-q2 — Iceberg Snapshot Expiration + Time-Travel

**Score: 4.8 / 5.0**

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

## What was correct

1. **Root-cause explanation is precise and correct.** The answer explains the actual failure mode: `expire_snapshots` removes snapshot **metadata** from the table's snapshot list, and once removed, `FOR TIMESTAMP AS OF` cannot resolve a timestamp to that snapshot. The answer correctly distinguishes data-file retention from snapshot-metadata retention and notes the typical follow-on (`remove_orphan_files` later physically deletes the data files). This matches both the Iceberg behavior and the documented Trino behavior (apache/iceberg#8565).

2. **Three-layer mitigation is the right framing.** Table-level retention floor, schedule-and-threshold coordination, and per-snapshot tagging covers all three real defenses. The ordering (long-term → operational → tag) gives the engineer a clear progression rather than a single "do this."

3. **Table-level retention property names and behavior are correct.** `history.expire.min-snapshots-to-keep` and `history.expire.max-snapshot-age-ms` are valid Iceberg properties. The Iceberg defaults are 1 and 5 days respectively; the example raises both. The answer's "the property floor always wins" framing matches Iceberg semantics — table-level properties act as a floor that callers cannot relax with looser `older_than` / `retain_last`.

4. **Trino 7-day minimum-retention floor is correctly named and qualified.** `iceberg.expire-snapshots.min-retention` defaults to 7d on Trino 467, and the answer correctly tells the engineer to switch to Spark for sub-7-day urgency. This is the verified Trino 467 behavior.

5. **Tag immunity to `expire_snapshots` is correct.** Tagged and branched snapshots are preserved from expiration regardless of retention thresholds — this is exactly what the Iceberg spec guarantees (named refs protect their referenced snapshots).

6. **`CREATE TAG` is Spark-only on Trino 467 — correctly stated.** Trino 467 can READ tags via `FOR VERSION AS OF '<tag-name>'` and `$refs`, but tag DDL (`CREATE TAG`, `DROP TAG`) must run from Spark. The answer's call-out "Trino cannot CREATE tags" is the right warning for this stack.

7. **`CREATE TAG ... AS OF VERSION <id> RETAIN 365 DAYS` syntax is correct Spark SQL.** Verified against Iceberg DDL docs. Backticks around the tag name are appropriate for names with hyphens.

8. **`$snapshots` metadata table syntax is correct.** `iceberg.analytics."events$snapshots"` with double-quoting around the table identifier is the standard Trino syntax for Iceberg metadata tables.

9. **`FOR VERSION AS OF <snapshot_id>` is the right "stable" answer.** This is exactly what the engineer asked for — a more deterministic reference than `FOR TIMESTAMP AS OF`. The reasoning ("the query is reproducible — running it again on the same snapshot ID gives the same result") is the right explanation.

10. **Production-stack fit is excellent.** The answer names Trino 467 by version, names Spark for tag DDL and Spark-form `expire_snapshots`, references MinIO/S3 for storage, and gives both syntaxes (Trino `ALTER TABLE ... EXECUTE` and Spark `CALL iceberg.system.*`) — matching prod_info.md exactly.

11. **The federation caveat is a useful bonus.** The note that Trino cannot do PostgreSQL historical queries (so the join is "frozen Iceberg snapshot vs live Postgres") proactively addresses a follow-up the engineer almost certainly has and didn't ask.

## What was wrong or missing

1. **Minor: `history.expire.min-snapshots-to-keep` description slightly under-specified.** The Iceberg semantics are that BOTH conditions must be true to expire (snapshot older than `max-snapshot-age-ms` AND total count exceeds `min-snapshots-to-keep`). The answer's "secondary safety net" framing is roughly right but could be clearer that this is a hard AND, not a single check.

2. **Minor jargon gaps for beginner clarity.** "Snapshot," "manifest," and the conceptual difference between data-file deletion and metadata-snapshot expiration are introduced but not glossed in plain English at the top. A SaaS engineer with no OLAP background who lands on this answer cold will follow the actions but may not fully grok the model. A one-paragraph "what's a snapshot in Iceberg" intro would have raised beginner clarity from 4 to 5.

3. **Missing: `$refs` metadata table mention for verifying tag creation.** The answer shows how to CREATE and DROP tags but doesn't show how to verify tags exist (`SELECT * FROM iceberg.schema."table$refs" WHERE type = 'TAG'`). Operationally useful, not a blocker.

4. **Did not mention the `parent_id` chain or `$history` table for deeper audit reconstruction.** For audit-grade questions, `$history` (which captures rollbacks via `made_current_at`) is a different and sometimes better starting point than `$snapshots`. This is in resource 17 but the answer doesn't surface it.

5. **Did not warn about Trino 467's lack of `dry_run` on `remove_orphan_files`.** Not strictly required by the question (which is about `expire_snapshots`, not orphan cleanup), but the answer mentions `remove_orphan_files` as the physical-deletion mechanism without flagging the irreversibility — a future operator reading this might think they can preview deletions from Trino.

None of these missing items are factual errors — they are nuance gaps in an otherwise correct and complete answer.

## Verification notes

| Claim | Verification | Result |
|---|---|---|
| `expire_snapshots` removes snapshot metadata; `FOR TIMESTAMP AS OF` fails when target snapshot is expired | Confirmed via apache/iceberg#8565 and trinodb/trino#8663 — "Snapshot Expiration Behavior Inconsistency with TIMESTAMP AS OF and VERSION AS OF" documents exactly this failure mode | CORRECT |
| `history.expire.min-snapshots-to-keep` (default 1) and `history.expire.max-snapshot-age-ms` (default 5d / 432000000ms) are valid Iceberg table properties | Confirmed via Iceberg docs and Tabular cookbook | CORRECT |
| Table-level retention acts as a floor that overrides per-call arguments | Confirmed — Tabular cookbook states "The min number of snapshots to keep in history takes precedence over age-based expiration" and both conditions must be met to expire | CORRECT (slightly under-explained — both conditions must be true) |
| Tagged snapshots are immune to `expire_snapshots` | Confirmed — Iceberg docs state "snapshots that are still referenced by branches or tags won't be removed" | CORRECT |
| Trino 467 cannot CREATE tags; Spark only | Confirmed via trinodb/trino#16695 — Trino can READ branches/tags via `FOR VERSION AS OF` and `$refs`, but tag/branch DDL is Spark-only | CORRECT |
| `FOR VERSION AS OF <snapshot_id>` is more deterministic than `FOR TIMESTAMP AS OF` | Confirmed — VERSION AS OF resolves to an exact snapshot regardless of expiration boundaries; TIMESTAMP AS OF can return inconsistent results when snapshots near the timestamp are expired | CORRECT |
| Trino 467's 7-day minimum-retention floor for `expire_snapshots` (`iceberg.expire-snapshots.min-retention`, default 7d) | Confirmed via Trino docs and Starburst forum — error message "Retention specified (X.XXd) is shorter than the minimum retention configured in the system (7.00d)" | CORRECT |
| `iceberg.analytics."events$snapshots"` syntax | Confirmed via Trino docs — `$snapshots` and other metadata tables require double-quoting because of the `$` | CORRECT |
| `ALTER TABLE ... CREATE TAG \`name\` AS OF VERSION <id> RETAIN 365 DAYS` Spark syntax | Confirmed via Iceberg DDL docs and Dremio blog: `ALTER TABLE prod.db.table CREATE TAG 'EOW-01' AS OF VERSION 7 RETAIN 7 DAYS` | CORRECT |

All major claims verified. No factual errors found.

## Recommendation for teacher

The resource `resources/17-iceberg-table-maintenance.md` is already in very good shape on this topic — the answer pulled from it cleanly and accurately. Two small additions would close the remaining gaps:

1. **Add a 2-sentence beginner gloss to the snapshot section.** Something like: "A snapshot is a named version of the table at one moment in time. Iceberg keeps these in a list; `expire_snapshots` removes old entries from the list, after which you can no longer query 'as of' that moment — even if the data files themselves haven't been deleted yet." This is exactly what the answer needed for beginner clarity to hit 5.

2. **Add an explicit "for audit jobs, prefer snapshot IDs over timestamps" subsection.** The resource has all the pieces (`$history`, `$snapshots`, `FOR VERSION AS OF`, tagging), but no single paragraph that says: "For a nightly audit job, the correct pattern is: query `$snapshots` to resolve the snapshot ID at your cutoff, then pass that snapshot ID to `FOR VERSION AS OF`. If the job needs to survive routine `expire_snapshots`, tag the snapshot from Spark." That paragraph is what the iter241 answer essentially synthesized on the fly — codifying it in the resource means future answers don't have to.

No factual fixes needed. The answer is strong enough that the topic's running average should comfortably stay in PASSED territory.
