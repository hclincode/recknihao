# Judge Score — Iter 325 Q1

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Every load-bearing claim verified against official docs. `optimize_manifests` confirmed added in Trino 470 (Feb 5, 2025) via PR #14821. Spark `CALL iceberg.system.rewrite_manifests(table => '...')` named-arg syntax matches official Iceberg Spark procedures docs. 7-day min-retention floor for both `expire_snapshots` and `remove_orphan_files` confirmed (catalog properties `iceberg.expire-snapshots.min-retention` / `iceberg.remove-orphan-files.min-retention`, default 7d). Manifest-rewrite-from-Spark fallback for Trino 467 is correct. Maintenance sequence (optimize → expire → orphan → manifests) matches resources/17 and the production runbook order. Trino-native `OPTIMIZE` and `expire_snapshots(retention_threshold => '30d')` syntax both correct. No fabrications detected. |
| Beginner clarity | 5 | Opens with a concrete plain-English definition of manifest files (lists data files + per-column min/max stats). The "Trino must deserialize and scan all 50,000 before it can tell your query which data to read" sentence makes the metadata-vs-data distinction clear without OLAP jargon. The 50,000 manifests → 30s → <1s contrast gives a beginner an immediate intuition for impact. No assumed knowledge of snapshot/manifest internals beyond what is explained inline. |
| Practical applicability | 5 | Engineer knows exactly what to run next: the immediate fix is one Spark statement (`CALL iceberg.system.rewrite_manifests(table => 'analytics.events')`), with both invocation methods spelled out (spark-sql CLI command line; nightly CronJob/Airflow). Schedule guidance (weekly, paired with snapshot expiry, off-peak). 4-step weekly maintenance sequence is copy-pasteable with engine labels. Summary table at the end maps each procedure to which engine to use on Trino 467. The Trino 470+ upgrade path is mentioned as the longer-term fix. Fits the prod stack (Trino 467 + Iceberg 1.5.2 + Spark + k8s on-prem). |
| Completeness | 5 | Hits every part of the multi-part question: (1) what manifest files are, (2) why they slow planning rather than data reading, (3) what to actually run on Trino 467 instead of `optimize_manifests`, (4) whether Trino has a different command or Spark is required. Bonus: explains the 7-day retention floor (relevant to the broader maintenance sequence), version gate on Trino 470, expected post-fix latency, and the order rationale for the full 4-step sequence. No nuance missed. |
| **Average** | **5.00** | **PASS** |

## What Worked

- **Diagnosis-then-fix structure.** Explains what manifests are and why they bottleneck planning BEFORE telling the engineer what to run. The "Trino must read ALL the manifest files to build a plan — before any actual data is touched" sentence is the single most useful sentence for a beginner trying to understand why their query is slow before any rows are read.
- **Version-gate precision.** Correctly identifies Trino 470 (Feb 2025) as the version that introduced `optimize_manifests`. Verified against the Trino 470 release notes — exact match.
- **Engine routing is unambiguous.** Every code block is labeled with the engine. The summary table makes the "run from Spark, not Trino" decision visible at a glance. Spark CALL syntax uses correct `table => 'schema.table'` named-arg form matching the Iceberg Spark procedures docs.
- **Concrete numbers.** "50,000 manifests → 30+ seconds planning → <1 second after rewrite" gives the engineer a testable expectation. The "10–30 seconds before your query even begins" range matches what's documented in the resources.
- **Full maintenance sequence.** Doesn't just answer the narrow question — provides the complete 4-step runbook with correct ordering (compaction → expire → orphan → manifests) and an explanation of why each step needs the previous one. This is what an engineer with a slow table actually needs.
- **7-day floor mentioned proactively.** Even though the engineer didn't ask about it, the 7-day Trino floor on `expire_snapshots` and `remove_orphan_files` is the next thing they'll trip on when running step 2/3 of the sequence. Mentioning it preemptively (with the GDPR escape hatch) saves a follow-up question.

## What Missed

- Minor: `optimize` is shown without a `WHERE` clause — could mention that per-tenant compaction is supported on partition columns, though this is tangential to the question.
- Minor: doesn't mention the `events$manifests` metadata table as a diagnostic for confirming "yes, you have too many manifests right now" before running the fix. This would let the engineer measure the problem (e.g., `SELECT COUNT(*) FROM iceberg.analytics."events$manifests"`) before and after. Resources/17 covers this in the broader maintenance docs but the answer doesn't surface it.
- Minor: doesn't mention `dry_run` is Spark-only for `remove_orphan_files` (relevant to step 3 of the sequence shown). Resources/17 covers it but the answer treats `remove_orphan_files` as a clean Trino call.

None of these gaps are large enough to drop the score — they're nice-to-haves, not omissions of load-bearing content.

## Technical Accuracy (verified)

1. **`optimize_manifests` introduced in Trino 470 (Feb 5, 2025).** VERIFIED. Trino 470 release notes confirm: "Add the `optimize_manifests` table procedure. (#14821)". Released 2025-02-05. The answer says "version 470 (released February 2025)" — exact match.
2. **Spark alternative is `rewrite_manifests` with `CALL iceberg.system.rewrite_manifests(table => '...')`.** VERIFIED against iceberg.apache.org/docs/latest/spark-procedures. The named-arg form `CALL iceberg.system.rewrite_manifests(table => 'db.sample')` matches the official docs exactly.
3. **7-day floor for `expire_snapshots` and `remove_orphan_files` on Trino 467.** VERIFIED. Catalog properties `iceberg.expire-snapshots.min-retention` (default 7d) and `iceberg.remove-orphan-files.min-retention` (default 7d) — the property names were renamed in Release 464 (Oct 30, 2024) to use hyphens, and Trino 467 inherits this floor. Procedure fails with "Retention specified ... is shorter than the minimum retention configured in the system" when called with a shorter value. Spark has no such floor — accurate.
4. **Maintenance order (compaction → expire → orphan → manifests).** VERIFIED. Matches resources/17 and the canonical Iceberg maintenance runbook. Compaction first creates new big files (orphaning the old small ones in the current snapshot); expire_snapshots then drops prior snapshots that still referenced the old small files; remove_orphan_files sweeps any stragglers; rewrite_manifests compacts metadata last because previous steps may themselves have generated new manifests. Correct.
5. **`CALL iceberg.system.expire_snapshots` (Spark-only) and Trino `ALTER TABLE ... EXECUTE expire_snapshots`.** VERIFIED — the Spark `CALL` form is Spark-only for the four routine procedures; Trino exposes them only via `ALTER TABLE ... EXECUTE`. Matches resources/17 and Trino docs.

All four verification asks pass. No fabrications. No version mismatches between claims and the production Trino 467 / Iceberg 1.5.2 stack.

## Rubric Update

- Iceberg table maintenance: prior avg 4.561 across 22 questions → (4.561 × 22 + 5.00) / 23 = (100.342 + 5.00) / 23 = 105.342 / 23 ≈ **4.580 across 23 questions**. Status: **PASSED**.

Sources:
- [Trino Release 470 (5 Feb 2025)](https://trino.io/docs/current/release/release-470.html)
- [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html)
- [Iceberg Spark procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Trino PR #14821 — optimize_manifests](https://github.com/trinodb/trino/issues/14821)
- [Trino Release 464 (30 Oct 2024) — property rename](https://trino.io/docs/current/release/release-464.html)
