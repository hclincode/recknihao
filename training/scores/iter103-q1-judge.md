# Judge — Iter 103 Q1

**Topic**: Iceberg partition design
**Score**: 4.25 / 5 (Tech 4.0, Clarity 4.75, Practical 4.0, Completeness 4.25)

## Verdict
A well-structured, beginner-friendly answer that correctly nails the core mechanics of Iceberg partition evolution (metadata-only ALTER, old files coexist, queries don't break but can't prune on the new column until rewrite). However, after explicitly labeling the ALTER as "Run this in Trino," the answer then drops into Spark SQL `CALL iceberg.system.rewrite_data_files(...)` and `CALL iceberg.system.expire_snapshots(... older_than => current_timestamp() - INTERVAL '7' DAY, retain_last => 5)` without any engine label — a beginner copy-pasting into Trino will hit a parse error. Multiple resources (10 and 17) explicitly call out this Spark-vs-Trino split, and the answer should have labeled the Step 3 / Step 4 SQL blocks the same way Step 1 was labeled.

## What was verified correct (via WebSearch)
- Trino syntax `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id']` is the current documented form (trino.io/docs/current/connector/iceberg.html; Starburst Iceberg-partitioning blog).
- Partition evolution is metadata-only; old files retain their original spec and are not eagerly rewritten (iceberg.apache.org/docs/latest/evolution/).
- Old and new spec files coexist; queries run correctly across mixed-spec files (Iceberg's per-spec predicate translation).
- Old files cannot be pruned on the newly-added partition column until rewritten — this is exactly what the answer describes.
- `rewrite_data_files` is a Spark procedure that rewrites under the table's current spec, so it correctly migrates old files into the new partition layout (iceberg.apache.org/docs/latest/spark-procedures/).
- Snapshot isolation during compaction — readers see a consistent snapshot throughout. Correct.
- Spark `rewrite_data_files` `options => map('target-file-size-bytes', ...)` syntax — correct as written for Spark SQL.

## Errors or gaps
- **Unlabeled Spark SQL in Step 3 (`rewrite_data_files`)**: After explicitly saying "Run this in Trino" for the ALTER, the rewrite block silently switches to Spark SQL syntax with no `-- Spark SQL only` comment. Resource 17 lines 49-56 and 65-70 establish the engine-label convention; the answer broke it. A beginner will try this in Trino and get a parse error.
- **Wrong engine for `expire_snapshots` example**: `CALL iceberg.system.expire_snapshots(table => ..., older_than => current_timestamp() - INTERVAL '7' DAY, retain_last => 5)` is Spark SQL syntax. The Trino equivalent is `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d', retain_last => 5)`. Trino does not have an `older_than` named parameter (confirmed via trino.io/docs/current/connector/iceberg.html; trinodb/trino issue #27357). Also `current_timestamp()` with parens is non-standard; bare `current_timestamp` is the SQL standard.
- **Catalog naming inconsistency**: Step 1 uses fully-qualified `iceberg.analytics.user_events` (Trino convention); Steps 3 and 4 drop the `iceberg.` prefix and use `analytics.user_events` (Spark convention). Correct as written for each engine, but unexplained — same gap flagged in iter 84 Q2.
- **Missing Trino-OPTIMIZE limitation note**: The answer doesn't mention that Trino's `ALTER TABLE ... EXECUTE optimize` cannot use newly-added partition columns as predicates (trinodb/trino #25279). This is the precise reason Spark is the right tool for the rewrite-after-evolution case, and naming it would have made the engine choice well-motivated rather than arbitrary.
- **Missing `bucket(tenant_id, N)` mention**: For an 80-tenant SaaS adding `tenant_id` to the partition spec, the answer should at minimum cross-reference that direct `tenant_id` partitioning is the right call for low-to-moderate tenant counts but `bucket(tenant_id, 32)` or similar becomes preferable past hundreds of tenants per day. Same omission flagged in iter 84 Q2 — a repeated gap.
- **"~2x storage spike"**: Slightly imprecise — only the rewritten snapshots' worth is duplicated until `expire_snapshots` runs, not literal 2x of the whole table. Resource 17 lines 126-141 is more precise about this.
- **Missing progress-monitoring tip**: No mention of `SELECT spec_id, COUNT(*) FROM iceberg.analytics."user_events$files" GROUP BY spec_id` to verify rewrite progress. Same omission flagged in iter 73 Q1 and iter 84 Q2 — a recurring gap on this topic.

## Resource fix recommendations
- **MEDIUM**: When the resource is generating examples for partition evolution + rewrite, the LLM keeps emitting Spark SQL for the rewrite step without the engine label. Resource 10 lines 470-484 (the partition-evolution worked example) has the Spark `CALL` shown with a brief comment "Step 2: rewrite ALL existing data files under the new spec (Spark SQL only)." This is good, but the responder is dropping the label when paraphrasing. Consider adding a more prominent callout box right at the partition-evolution section that says: "If you write this answer for an engineer, ALWAYS label the rewrite step as Spark SQL OR provide both engines. Never show `CALL iceberg.system.*` without that label."
- **MEDIUM**: Add a Trino-form `expire_snapshots` example side-by-side with the Spark form in resource 10's partition-evolution worked example. Currently resource 10 only shows the Spark form; resource 17 has both but they live in a different file. The responder pulled the Spark form from resource 17 but didn't translate it to Trino syntax when the surrounding context was Trino.
- **LOW**: Add a recurring "verify rewrite progress" snippet (`SELECT spec_id, COUNT(*) FROM <table>$files GROUP BY spec_id`) to the partition-evolution section of resource 10. This has been flagged as missing across iter 73, 84, and now 103.
- **LOW**: Add a one-sentence cross-reference in the "adding tenant_id to the partition spec" subsection of resource 10 that says "for >~200 tenants, evaluate `bucket(tenant_id, 32)` instead — see the bucket partitioning section."

## Updated topic state
- Iceberg partition design: 14 questions / running avg (4.554 × 13 + 4.25) / 14 = (59.202 + 4.25) / 14 = 63.452 / 14 = **4.532** across 14 questions. PASSED.
