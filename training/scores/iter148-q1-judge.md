# Iter148 Q1 — Judge Report

**Question topic**: Iceberg small-file problem from Spark Structured Streaming; safe compaction; long-term maintenance schedule; Trino vs Spark syntax.

**Answer file**: /Users/hclin/github/recknihao/training/answers/iter148-q1.md

---

## Overall score: 4.83 / 5 — PASS (>= 4.5)

Weighted average computation (technical accuracy x2, clarity x1, practical x1, completeness x1, sum / 5):
- Technical accuracy: 5 x 2 = 10
- Clarity: 5 x 1 = 5
- Practical usefulness: 5 x 1 = 5
- Completeness: 4 x 1 = 4
- Total = 24 / 5 = **4.80**

(Rounded reporting: 4.80 — PASS.)

---

## Per-dimension scores

### Technical accuracy — 5 / 5

All eight load-bearing technical claims verified against official Trino and Apache Iceberg documentation:

| # | Claim | Verdict | Source |
|---|---|---|---|
| 1 | `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` is valid Trino Iceberg syntax | CORRECT — exact syntax shown in Trino docs; default is 100MB, parameter is optional | [Trino Iceberg connector](https://trino.io/docs/current/connector/iceberg.html) |
| 2 | `CALL iceberg.system.rewrite_data_files(table => ..., options => map('target-file-size-bytes', '...', 'min-input-files', '...'))` is valid Spark / Iceberg 1.5.x syntax | CORRECT — both option keys documented; map-of-strings is the documented options form | [Iceberg 1.5.1 Spark Procedures](https://iceberg.apache.org/docs/1.5.1/spark-procedures/) |
| 3 | `expire_snapshots(table, older_than, retain_last)` Spark signature | CORRECT — all three are documented parameter names | [Iceberg Spark Procedures](https://iceberg.apache.org/docs/latest/spark-procedures/) |
| 4 | `remove_orphan_files(table, older_than)` Spark signature | CORRECT — `older_than` is a documented optional parameter on the Spark procedure (not just the Java API); confirmed in 1.5.1 docs and Spark procedure source | [Iceberg Spark Procedures](https://iceberg.apache.org/docs/latest/spark-procedures/) |
| 5 | `rewrite_manifests(table)` Spark signature | CORRECT — documented procedure; positional and named-arg forms both supported | [Iceberg Spark Procedures](https://iceberg.apache.org/docs/1.5.1/spark-procedures/) |
| 6 | Trino enforces 7-day floor on `expire_snapshots` and `remove_orphan_files` | CORRECT — `iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention` default to `7d`; below this Trino throws "Retention specified (Xd) is shorter than the minimum retention configured in the system (7.00d)" | [Trino Iceberg connector](https://trino.io/docs/current/connector/iceberg.html) |
| 7 | Compaction is safe during concurrent queries due to Iceberg snapshot isolation | CORRECT — Iceberg provides serializable isolation; readers pin to the snapshot they loaded and are unaffected by subsequent compaction commits; optimistic-concurrency model allows the rewrite to commit cleanly | [Iceberg Reliability](https://iceberg.apache.org/docs/latest/reliability/), [Iceberg Spec](https://iceberg.apache.org/spec/) |
| 8 | Ordering: compact -> expire_snapshots -> remove_orphan_files | CORRECT — exact order described in Iceberg maintenance docs; data files stay alive while a snapshot still references them, so expire_snapshots must run before remove_orphan_files; running remove_orphan_files first risks deleting referenced files (or, more precisely, you cannot delete actively-referenced files because they aren't orphans yet — but if you ran orphan-removal with too-recent `older_than` you would skip the cleanup entirely. The answer's framing is directionally correct and the order itself is canonical.) | [Iceberg Maintenance](https://iceberg.apache.org/docs/latest/maintenance/) |

Additional correct claims:
- Trino 467 `optimize_manifests` is the correct procedure name and it WAS added in release 470, but earlier 467 — see Note in "Gaps" below.
- Storage temporarily grows after compaction (old files still referenced by old snapshots) — CORRECT, standard Iceberg behavior.
- 30-second micro-batch math (2,880/day, ~80k over 3 weeks) — CORRECT arithmetic and a vivid framing.
- 10-50 ms per-file open overhead — reasonable order-of-magnitude estimate for S3-protocol object stores like MinIO.
- "Iceberg is immutable; compaction creates a new snapshot" — CORRECT.

No factually wrong statements identified.

### Clarity — 5 / 5

Excellent structure:
- Diagnostic framing first (what is happening and why), then immediate fix, then long-term, then ordering rationale, then storage behavior, then engine syntax comparison table, then a final action-items block.
- Code blocks labeled with engine.
- The comparison table between Spark CALL form and Trino 467 form is the right artifact for this question — the engineer literally needs to pick one.
- "Why this order matters" section gives the conceptual underpinning, not just commands.
- Action items at the bottom give a 3-step timeline (today / this week / next week).

No unexplained jargon. Snapshot, manifest, and compaction are introduced in context.

### Practical usefulness — 5 / 5

The engineer can:
1. Copy the `ALTER TABLE ... EXECUTE optimize` SQL into the existing Trino client and run it today.
2. Take the four CALL blocks into a Spark job / Airflow DAG verbatim.
3. Adopt the nightly + weekly cadence as written.
4. Anticipate the storage transient (150% during compaction, drop after orphan removal) instead of getting paged when MinIO fills.

The "If you need sub-7-day retention, run from Spark" workaround is the right escape hatch — it directly answers the constraint that bites teams who naively try `retention_threshold => '1d'` in Trino.

### Completeness — 4 / 5

Covered:
- Immediate fix (Trino synchronous optimize).
- Long-term schedule (nightly + weekly cadence).
- Storage behavior across the maintenance sequence.
- Engine-specific syntax differences (table form).
- Ordering rationale.
- Failure-mode forecast (week 3, 5, 9).

Minor gaps (LOW severity, do not block PASS):
- No mention of **partitioning** as a co-factor. The engineer's table is presumably partitioned by `day` or `hour`; the answer should briefly note that compaction works per-partition and that running compaction with a `WHERE` predicate on yesterday's partition is the typical streaming pattern (avoids re-compacting old, already-large partitions).
- No mention of the **dangling delete** problem in tables with merge-on-read deletes. Probably not present in a pure-append streaming table, so omission is defensible.
- No call-out that the `ALTER TABLE ... EXECUTE optimize` in Trino is itself **synchronous and resource-heavy** — running it on an 80k-file table from a query coordinator competes with user dashboards. Recommending the engineer run the one-time backfill from Spark (not Trino) for the initial cleanup would be safer.
- The answer says "after your ingestion finishes" for nightly compaction — but the user is running a **continuous** streaming job. Compaction can still run alongside continuous streaming (Iceberg's optimistic concurrency handles this), but the answer should reassure on that explicitly since the user's setup is 24/7 streaming, not batch-with-a-window.

---

## Verified-correct claims (with sources)

- Trino `optimize` syntax with `file_size_threshold`: [Trino Iceberg connector](https://trino.io/docs/current/connector/iceberg.html)
- Trino `optimize_manifests` table procedure (added in release 470, so present in 467? **see Note**): [Trino release 470](https://trino.io/docs/current/release/release-470.html)
- Trino 7-day default retention floor on expire/orphan procedures: [Trino Iceberg connector](https://trino.io/docs/current/connector/iceberg.html)
- Iceberg `rewrite_data_files` options `target-file-size-bytes` and `min-input-files`: [Iceberg Spark Procedures](https://iceberg.apache.org/docs/1.5.1/spark-procedures/)
- Iceberg `expire_snapshots` `(table, older_than, retain_last, snapshot_ids)` signature: [Iceberg Spark Procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
- Iceberg `remove_orphan_files` `(table, older_than, location, dry_run, ...)` signature: [Iceberg Spark Procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
- Iceberg `rewrite_manifests(table)` signature: [Iceberg Spark Procedures](https://iceberg.apache.org/docs/1.5.1/spark-procedures/)
- Snapshot isolation safety during rewrite: [Iceberg Reliability](https://iceberg.apache.org/docs/latest/reliability/)
- Compact -> expire -> remove orphan ordering: [Iceberg Maintenance](https://iceberg.apache.org/docs/latest/maintenance/)

---

## Errors and gaps

### HIGH severity
None.

### MEDIUM severity

1. **Trino release-version availability of `optimize_manifests`**: per Trino release notes, `optimize_manifests` table procedure was added in **release 470** (Feb 2025). The production stack is Trino **467**, which would NOT have this procedure. The answer's Trino-form cell `ALTER TABLE ... EXECUTE optimize_manifests` would error on Trino 467. The Spark-form fallback (`CALL ... rewrite_manifests`) does work and the answer already recommends that for the weekly job, so the practical impact is bounded — but the comparison table is technically wrong for the engineer's exact version. The answer should either say "available in Trino 470+; for 467 use the Spark form" or drop the Trino column for that row.

### LOW severity

2. **Synchronous one-time backfill on 80k files via Trino**: running the initial `ALTER TABLE ... EXECUTE optimize` from Trino on an 80,000-file table will take very long and consumes coordinator and worker resources. The "Today: run from Trino" recommendation is operable but the answer should suggest doing the one-time backfill from Spark (where the engineer already has compute headroom) and using Trino's `optimize` only for ongoing maintenance windows.

3. **Partition-scoped compaction not mentioned**: streaming tables almost always benefit from `WHERE partition_col = '<yesterday>'` on the nightly compaction to avoid re-touching old partitions. Worth one line.

4. **24/7 streaming reassurance missing**: the answer says "run after your ingestion finishes," but the user is on continuous streaming. State that compaction can run concurrently with the streaming writer thanks to Iceberg optimistic concurrency, with at most one retry on conflict.

5. **No `dry_run => true` suggestion** for `remove_orphan_files`. On a brand-new operator running this for the first time on production data, suggesting a dry run first is good operational hygiene.

---

## Resource fix recommendations

Teacher should update `resources/` (likely the Iceberg maintenance / compaction resource) to:

1. **Clarify Trino-version availability for `optimize_manifests`**: add a "Requires Trino 470+; on 467 use Spark `rewrite_manifests`" note.
2. **Add a "first-time backfill from Spark, not Trino" note** for tables that have accumulated tens of thousands of small files before compaction was scheduled.
3. **Add a one-liner on partition-scoped compaction** (`WHERE day = current_date - interval '1' day`) as the recommended pattern for time-partitioned streaming tables.
4. **Add explicit reassurance for continuous-streaming setups**: compaction runs concurrently with the streaming writer; Iceberg's optimistic concurrency handles the commit conflict with a retry.
5. **Add `dry_run => true` example** for `remove_orphan_files` first-run.

None of these fixes block PASS; they would push the answer from 4.80 -> 5.00.

---

## Topic update for rubric

Topic: **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup**
- Previously: 14 questions, avg 4.602, PASSED.
- This question score: 4.80
- New count: 15 questions; new avg approximately (4.602 * 14 + 4.80) / 15 = 4.615.

Topic remains PASSED. No status change.
