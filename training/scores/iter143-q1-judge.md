# Iter143 Q1 — Judge Score

**Question topic**: Iceberg table maintenance — six-month-old setup with growing MinIO storage despite deleted rows; user does not understand why storage keeps climbing.

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter143-q1.md`

---

## Score Breakdown

| Dimension | Score | Notes |
|---|---|---|
| **Technical accuracy** | 5 | All Trino 467 syntax, retention floor, and ordering claims verified against trino.io and iceberg.apache.org docs. |
| **Clarity (beginner)** | 5 | Git analogy is excellent; "compaction goes UP not down" warning preempts the most common confusion; no unexplained jargon. |
| **Practical usefulness** | 5 | Exact, copy-pasteable `ALTER TABLE ... EXECUTE` statements; diagnostic `$files`/`$snapshots` queries; concrete schedule (nightly/weekly + window guidance). |
| **Completeness** | 4.5 | Covers immutability, snapshot retention, three-step sequence in correct order, 7-day floor, diagnostics, scheduling, ordering rationale. Minor gaps: doesn't mention manifest cleanup (`rewrite_manifests`), doesn't mention position/equality delete files specifically, doesn't address "dropped old data" via `DROP PARTITION` / `DELETE` distinction in depth. |

**Average** = (5 + 5 + 5 + 4.5) / 4 = **4.875**

---

## What was verified correct (via WebSearch)

1. **`ALTER TABLE iceberg.x.y EXECUTE expire_snapshots(retention_threshold => '30d')`** — confirmed correct Trino syntax. trino.io docs show this exact form.
2. **`ALTER TABLE iceberg.x.y EXECUTE remove_orphan_files(retention_threshold => '7d')`** — confirmed correct.
3. **7-day minimum retention floor** — confirmed. Trino enforces `iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention`, both default to 7d. Docs error message verified: "Retention specified (1.00d) is shorter than the minimum retention configured in the system (7.00d)".
4. **`ALTER TABLE x EXECUTE optimize(file_size_threshold => '128MB')`** — confirmed correct Trino syntax.
5. **`$files` and `$snapshots` metadata tables with double-quoted name** (`"events$files"`) — confirmed correct per Trino Iceberg connector docs.
6. **Three-step order (compaction → expire_snapshots → remove_orphan_files)** — confirmed against Apache Iceberg maintenance docs. The expire-before-orphan ordering is the documented safe order.
7. **Race condition warning for `remove_orphan_files`** — confirmed: Iceberg docs explicitly warn that aggressive orphan cleanup can delete in-flight uncommitted files. The 7-day default exists precisely as the safety window.
8. **Spark `CALL iceberg.system.*` syntax** — labeled "Spark SQL only" correctly throughout. The `older_than => current_timestamp - interval '30' day, retain_last => 10` form is standard Iceberg Spark procedure syntax.
9. **`optimize` writes new files but doesn't delete old ones** — correct; old files remain referenced by the previous snapshot until expiration.
10. **`expire_snapshots` removes metadata then `remove_orphan_files` deletes data** — accurate description of the two-stage GC.

---

## Errors or gaps found

**Minor**:
- One slightly awkward sentence: "This removes old snapshot metadata, so the data files only those snapshots referenced become eligible for deletion." — wording is garbled (missing "that"). Should read "so the data files that only those snapshots referenced…".
- `expire_snapshots` is described as cleaning data files directly — in reality `expire_snapshots` in Trino does delete data files exclusively referenced by expired snapshots in the same operation, then `remove_orphan_files` catches anything else (truly orphaned uploads that were never committed). The answer's framing is close enough and doesn't mislead in practice, but a more precise version would distinguish: (a) files referenced only by expired snapshots are removed by `expire_snapshots` itself, and (b) `remove_orphan_files` targets files in the table directory that no metadata references at all (e.g., failed write artifacts).
- Doesn't mention manifest file accumulation or `rewrite_manifests` (Spark-only). For a 6-month-old table this is also a likely storage and query-planning cost contributor, though minor compared to data files.
- Doesn't mention position/equality delete files (MoR), which is a real source of growth if the table uses merge-on-read for CDC. Given the production stack uses Debezium 2.x → Spark/Iceberg, MoR is plausible.

**Not errors but worth noting**:
- The "race condition" framing in the answer focuses on in-flight Spark writes vs. orphan deletion. This is correct but the more precise concern is: if you run `remove_orphan_files` with a retention shorter than the longest in-flight write, files actively being uploaded but not yet committed can be deleted. Trino's 7-day floor is the safety net.
- The advice "run from Spark instead" to bypass the 7-day floor for GDPR is correct — but the answer could also mention adjusting the Trino catalog property (`iceberg.expire-snapshots.min-retention=0s`) as an alternative if the team controls Trino config.

---

## Production fit (prod_info.md check)

- Trino 467 ✓
- Iceberg connector via Hive Metastore ✓
- MinIO storage references ✓
- Spark labeled clearly as alternate engine for sub-7d retention ✓
- Kubernetes CronJobs mentioned as a scheduler option (fits on-prem k8s stack) ✓
- No incompatible recommendations (no AWS, no Snowflake, no S3 lifecycle policies that wouldn't work on MinIO) ✓

---

## Resource fix recommendations

**Optional polish (LOW priority)** — the resource that produced this answer is already in good shape (this topic has avg 4.612 across 10 prior questions and PASSED long ago). Two small improvements would push answers from 4.875 to ~4.95+:

1. **Precision fix**: In the `expire_snapshots` description, clarify that it deletes both metadata AND data files exclusively referenced by expired snapshots — while `remove_orphan_files` targets files that no metadata references at all (e.g., failed/uncommitted write artifacts). The current answer slightly conflates them.
2. **Add a paragraph on delete files / manifest bloat** as additional sources of growth beyond data files — relevant when CDC (Debezium) is in the stack and merge-on-read produces delete files that accumulate alongside data files.

Neither is required for PASS. Both are nice-to-haves.

---

## Verdict

**PASS** (4.875 ≥ 4.5)

This is a strong answer. All technical claims verified against official Trino and Apache Iceberg documentation. Syntax is correct for Trino 467. The "MinIO usage often goes UP after compaction" pre-emptive warning is exactly the insight a confused beginner needs. Engine labeling (Trino vs Spark) is consistent. The Git analogy makes immutability click immediately for an OLTP engineer. Schedule and ordering rationale make this directly executable.

Topic: **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup** — running avg updates to (4.612 × 10 + 4.875) / 11 = **4.636** across 11 questions. Status: **PASSED** (well above 3.5 threshold).
