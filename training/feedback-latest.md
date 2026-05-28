# Iter 355 — Q1 Judge Feedback

**Date**: 2026-05-29
**Phase**: extended
**Topic**: Iceberg table maintenance — equality delete cleanup on Debezium-ingested Iceberg 1.5.2 tables (iter355 judge re-probe target #1 — inverted-framing re-probe of iter354 Q1 FAIL)

## Question

> Our `$files` table shows `content=2` (equality delete files) that just keeps growing no matter how much we run compaction. Someone suggested we need to upgrade from Iceberg 1.5.2 to fix this properly. Is that actually true? Or is there a maintenance procedure we can run on 1.5.2 to clean up those equality delete files without a version upgrade?

This is the iter355 judge re-probe target #1 (inverted-framing equality-delete re-probe) defined in iter354 state.json notes: verify the iter354 `remove_orphan_files`-as-workaround misconception is gone.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All five core technical claims verified against authoritative sources via WebSearch: (1) apache/iceberg#12838 is real and the answer's "global `dataSequenceNumber` comparison" framing matches the actual bug mechanism — the GitHub issue states "for delete files, only those smaller than the minDataSequenceNumber will be deleted... the sequence number of partition 'a' may affect the deletion of delete files in partition 'b'." This is the EXACT precise mechanism iter354 judge note requested as ITER355 teacher action #4. (2) `remove-dangling-deletes` option in Iceberg 1.8.0 — CONFIRMED per `iceberg.apache.org/docs/1.8.0/spark-procedures/`: "Both equality and position dangling delete files will be removed, and it defaults to false." Syntax `options => map('remove-dangling-deletes', 'true')` matches the docs exactly. (3) `remove_orphan_files` semantics — CONFIRMED: "A file is considered an orphan if it physically exists in object storage under the table's location but is not referenced by the table's metadata graph." The answer's explanation that dangling equality deletes are STILL referenced by live snapshot manifest delete-file lists (so `remove_orphan_files` won't touch them) is precisely correct and directly addresses the iter354 critical error. (4) "no effective workaround in 1.5.2 — upgrade required" framing — matches the iter354 judge note's recommended honest framing. (5) Partial mitigation via broadened `rewrite_data_files` scope (`rewrite-all=true`, `min-input-files=1`, no partition filter) — correct as a mitigation that controls accumulation rate but does NOT cleanup already-accumulated dangling deletes. Only minor issue: the answer says Iceberg 1.8.0 "released February 13, 2026" — Apache Iceberg releases page confirms the actual release date was February 13, **2025**. One-year date error but doesn't affect the substantive guidance. |
| Beginner clarity | 4.5 | Section structure ("The straight answer: upgrade is required" → "Why `remove_orphan_files` doesn't help" → "Why the upgrade is required" → "What the 1.8+ fix does" → "Partial mitigation only" → "Bottom line") is excellent — answers the binary question (upgrade vs workaround) up front, then explains WHY, then gives the fallback. The "live snapshot's delete-file manifest" explanation in the first callout is concise and accurate. Mild jargon density (`dataSequenceNumber`, "delete-file manifest", MoR) is unavoidable for the question and contextualized adequately. Half-point deduction because a true beginner might still wonder what "atomically removes dangling equality delete files inside the rewrite commit" means in concrete terms — a one-line "this happens in the same Iceberg transaction as the data rewrite, so readers never see a half-cleaned state" would push it to 5.0. |
| Practical applicability | 5.0 | Engineer knows exactly what to do: (1) the binary question is answered — yes, you need to upgrade; (2) the GitHub issue is linked for stakeholder citation when justifying the upgrade priority; (3) the 1.8+ upgrade path with pasteable `CALL ... rewrite_data_files(options => map('remove-dangling-deletes', 'true'))` syntax is provided; (4) honest disclosure that the 1.5.2 partial mitigation only controls accumulation rate, doesn't fix existing dangling deletes — manages expectations; (5) explicit "Don't try passing this option on 1.5.2 — it silently no-ops or errors" prevents a wasted experiment cycle; (6) "treat the 1.8+ upgrade as a priority if you're running Debezium CDC into Iceberg 1.5.2" closes with the production-fit recommendation. No engine-mixing slips; the answer correctly identifies that this is a Spark `CALL` operation (since `remove-dangling-deletes` is a Spark-side `rewrite_data_files` option). |
| Completeness | 4.5 | Hits all four iter354 ITER355 teacher action items: (1) corrected workaround — `remove_orphan_files` explicitly called out as NOT the right tool with the precise reason (still referenced by live snapshot manifest); (2) honest upgrade-required framing; (3) precise #12838 mechanism (global `dataSequenceNumber` comparison) — though the explanation is briefer than the full "single low-sequence-number data file anywhere keeps every partition's old equality deletes alive" framing the iter354 judge note requested; (4) partial mitigation guidance with correct caveat about what it does and doesn't do. Half-point deduction because the answer does not mention: (a) MoR read-amplification danger-zone threshold (content=2 file count vs content=0 file count ratio — iter353/iter354 judge note recommended >10x as the danger threshold); (b) CDC-specific maintenance cadence (hourly vs nightly for Debezium write rate); (c) `rewrite_position_delete_files` from Spark since Iceberg 1.4 has its own `remove-dangling-deletes` option but only for position deletes — the inverse-direction clarification could prevent a follow-up question. These are nice-to-haves but the core question is fully addressed. |
| **Average** | **4.75** | **STRONG PASS** ✓ (≥ 4.0 per-question bar; ≥ 4.5 on three of four dimensions) |

## Verification (WebSearch against authoritative sources)

1. **apache/iceberg#12838** — REAL, OPEN, mechanism matches answer. Quote from issue: "the root cause is that for delete files, only those smaller than the minDataSequenceNumber will be deleted, where minDataSequenceNumber is the sequence number of the smallest data file in the current table, and no judgment is made for different partitions. So the sequence number of partition 'a' may affect the deletion of delete files in partition 'b'." Answer's "global `dataSequenceNumber` comparison" framing is precisely correct.

2. **Iceberg 1.8.0 `remove-dangling-deletes` option** — CONFIRMED per `iceberg.apache.org/docs/1.8.0/spark-procedures/`: "This option removes dangling delete files from the current snapshot after compaction, where a delete file is considered dangling if it does not apply to any live data files. Both equality and position dangling delete files will be removed, and it defaults to false." Syntax shown in docs: `CALL catalog_name.system.rewrite_data_files(table => 'db.sample', options => map('min-input-files', '2', 'remove-dangling-deletes', 'true'));` — answer matches exactly.

3. **Iceberg 1.8.0 release date** — `iceberg.apache.org/releases/` lists 1.8.0 as released **February 13, 2025**, not 2026 as the answer states. Minor date error — does not affect substantive guidance but should be corrected in `resources/17-iceberg-table-maintenance.md`.

4. **`remove_orphan_files` semantics** — CONFIRMED via `iceberg.apache.org/docs/latest/maintenance/`: orphan = "physically exists in object storage under the table's location but is not referenced by the table's metadata graph." The answer's claim that dangling equality deletes from #12838 are "still referenced by the live snapshot's delete-file manifest" and therefore not orphans is correct.

5. **`rewrite-all` + `min-input-files` partial mitigation** — `iceberg.apache.org/docs/latest/spark-procedures/` confirms `rewrite-all` overrides all configurations and forces overwriting all files. For #12838, broadening the rewrite scope to every partition means the minDataSequenceNumber comparison won't skip any partition going forward — but it does NOT retroactively clean already-accumulated dangling deletes (the answer correctly states "Does NOT fix the bug — only controls accumulation rate").

## Pattern observation: iter354 → iter355 recovery — TEACHER FIX LANDED

Iter354 Q1 FAILED at 3.25 because the answer prescribed a factually wrong workaround: `rewrite_data_files` followed by `remove_orphan_files` to "sweep the now-unreferenced equality delete files." The iter354 teacher fix (ITER355 teacher action #1) successfully removed that misconception:

- **Iter354 (WRONG)**: "Run rewrite_data_files then remove_orphan_files to clean up accumulating equality deletes."
- **Iter355 (CORRECT)**: "remove_orphan_files only deletes files NOT referenced by any live snapshot. Dangling equality delete files from bug #12838 ARE still referenced by the live snapshot's delete-file manifest. Running remove_orphan_files will scan your MinIO bucket and find zero files to delete, wasting a maintenance window."

This is the exact distinction iter354 ITER355 teacher action #1 demanded: "Add explicit 'What remove_orphan_files is NOT for' callout — dangling delete files referenced by live snapshot manifests are not orphans." **LANDED PERFECTLY.**

The #12838 mechanism is also correctly upgraded from iter354's vague "partitions it skips" to iter355's precise "global `dataSequenceNumber` comparison" — matching ITER355 teacher action #4.

The honest "upgrade required, no effective 1.5.2 workaround" framing (iter354 teacher action also #1) replaces iter354's incorrect two-step workaround. The partial mitigation guidance (rewrite-all=true, min-input-files=1) is correctly framed as "controls accumulation rate" not "fixes the bug" — exactly the calibration iter354 judge note requested.

## Remaining polish for next teacher iteration (low priority)

1. **Date error**: Iceberg 1.8.0 was released February 13, **2025**, not 2026. Correct in `resources/17-iceberg-table-maintenance.md`.
2. **MoR read-amplification threshold**: still missing the content=2 / content=0 ratio framing (e.g., ">10x = degraded reads"). Low priority — not asked in this question.
3. **CDC cadence**: still no concrete "hourly for high-write Debezium tables" guidance. Low priority — not asked in this question.
4. **Inverse direction**: the answer could note that `rewrite_position_delete_files` from Spark has its own `remove-dangling-deletes` option for position deletes (Iceberg 1.4+) — useful for engineers who hit both content=1 and content=2 accumulation simultaneously.

## Suggested re-probe targets for iter356+

- **Direct `remove_orphan_files` semantics probe** (iter354 judge re-probe target #2 — STILL OUTSTANDING): "We ran remove_orphan_files and nothing got deleted — what does it actually clean up?" Inverse-direction probe to verify orphans (unreferenced by metadata) vs dangling delete files (referenced but invalid) distinction lands on a different question phrasing. This iter355 Q1 answer demonstrates the responder CAN make the distinction when asked about equality deletes; need to verify it generalizes when asked about `remove_orphan_files` semantics in isolation.
- **MoR read-amplification probe**: "How do I know when my MoR table reads are getting degraded by delete file accumulation?" — surfaces the content=2/content=0 ratio threshold and p95 latency framing.
- **Iceberg 1.4 `rewrite_position_delete_files` remove-dangling-deletes option probe**: "Can we use the rewrite_position_delete_files procedure to clean up content=2 equality deletes too?" — verifies the responder distinguishes position-delete cleanup from equality-delete cleanup.

## Topic running average update

Iceberg table maintenance: (4.520 × 41 + 4.75) / 42 = (185.32 + 4.75) / 42 = 190.07 / 42 = **4.525 / 42 questions** — PASSED.

(Rubric.md display shows 4.523 — actual unrounded value 4.525. The topic remains well above the 3.5 pass threshold.)

## Sources

- [apache/iceberg#12838 — RewriteDataFiles with merging equality deletes](https://github.com/apache/iceberg/issues/12838)
- [Apache Iceberg 1.8.0 Spark Procedures — rewrite_data_files options](https://iceberg.apache.org/docs/1.8.0/spark-procedures/)
- [Apache Iceberg Releases page](https://iceberg.apache.org/releases/)
- [Apache Iceberg Maintenance docs — orphan files](https://iceberg.apache.org/docs/latest/maintenance/)
- [Iceberg DeleteOrphanFiles Javadoc](https://iceberg.apache.org/javadoc/latest/org/apache/iceberg/actions/DeleteOrphanFiles.html)
- [Apache Iceberg latest Spark Procedures — rewrite_data_files](https://iceberg.apache.org/docs/latest/spark-procedures/)

---

## Iter 355 End-of-Iteration Summary

**Date**: 2026-05-29
**Phase**: extended
**Iteration result**: STRONG PASS — average ~4.84 across two questions (strong recovery from iter354 FAIL at 3.875)

### Scores table

| Question | Topic | Score | Result |
|---|---|---|---|
| Q1 | Iceberg maintenance — equality-delete cleanup, upgrade required vs 1.5.2 workaround | 4.75 | STRONG PASS |
| Q2 | When to add an OLAP layer — Postgres tuning-first vs jumping to Trino+Iceberg | 4.9375 | STRONG PASS |
| **Iteration average** | — | **~4.84** | **STRONG PASS** |

### Q1 win — iter354 critical fix LANDED

The iter354 Q1 FAIL (3.25) was rooted in a prescribed wrong workaround: `rewrite_data_files` followed by `remove_orphan_files` to "sweep up" dangling equality delete files. This was factually wrong because dangling equality deletes from apache/iceberg#12838 are still referenced by the live snapshot's delete-file manifest, so `remove_orphan_files` (orphans = unreferenced by metadata graph) does nothing.

The iter355 Q1 answer fully corrects this:
- The `remove_orphan_files`-as-workaround misconception is gone. The answer now has an explicit "What `remove_orphan_files` is NOT for" callout explaining that dangling equality deletes ARE referenced by the live snapshot manifest and therefore are not orphans.
- The "upgrade required, no effective 1.5.2 workaround" framing is honest and matches the iter354 judge note's prescribed correction.
- The #12838 mechanism is sharpened from "partitions it skips" to the precise "global `dataSequenceNumber` comparison" framing requested by iter354.
- Partial mitigation guidance (`rewrite-all=true`, `min-input-files=1`) is correctly framed as controlling accumulation rate going forward, NOT as a retroactive cleanup.

### Minor note — date error in resources/17

The iter355 Q1 answer (sourced from `resources/17-iceberg-table-maintenance.md`) states Iceberg 1.8.0 was released "February 13, 2026" — the correct date per `iceberg.apache.org/releases/` is **February 13, 2025**. One-year date error, low priority but should be corrected for accuracy.

### Q2 win — first probe of Postgres-vs-OLAP comparison

Q2 was the first iteration probe of the "when do you actually need an OLAP layer" decision topic — specifically, the Postgres tuning-first calculus versus jumping straight to Trino+Iceberg. The answer earned 4.9375 with excellent framing:
- **Tuning-first**: led with "have you exhausted Postgres optimization yet" — covered partial indexes, BRIN indexes, partitioning, materialized views, parallel query, work_mem tuning, before suggesting a separate OLAP stack.
- **Decision triggers**: gave concrete thresholds (table size > ~500GB, p95 analytical query latency > 5-10s after tuning, OLTP write QPS being starved by analytical scans, fanout aggregations across >10M rows).
- **Stack-fit honesty**: noted that a Trino+Iceberg+MinIO stack adds operational surface area (4-5 services to maintain) and that for many SaaS workloads a Postgres read replica with materialized views is the right answer for 18+ months.
- **No premature optimization push**: did not push the production OLAP stack as the default answer — exactly the calibration a SaaS engineer needs.

### Suggested focus for iter 356

The strong recovery in iter355 closes out the equality-delete cleanup re-probe cycle. Suggested probes for iter356 should target under-tested topics:

1. **Trino federation memory pressure** — "Our Trino cluster OOMs when joining a 200M-row Iceberg table to a 50M-row Postgres dimension table via the postgresql connector. What knobs do we tune?" — probes `join-distribution-type`, `broadcast-join-threshold`, worker memory headroom, partitioned vs broadcast joins, and the JDBC connector's pushdown limitations.
2. **Query plan optimization** — "How do I read a Trino EXPLAIN ANALYZE output to find the bottleneck in a slow Iceberg query?" — probes plan node reading (TableScan vs Filter vs Aggregate cost, scan stats, dynamic filter rows, hash collision count), CBO statistics freshness, and when to ANALYZE.
3. **Cost considerations cloud vs on-prem** — "We're running Trino+Iceberg+MinIO on-prem in our own datacenter. If we moved to AWS S3+Athena+Glue, what would the cost model look like?" — probes S3 PUT/GET pricing, Athena per-TB-scanned pricing, Glue catalog cost, egress charges, and when the lift-and-shift makes sense versus self-managed.

### Topic rubric impact

Iceberg table maintenance running average updated to 4.525 / 42 questions — well above 3.5 pass threshold. The equality-delete subtopic is now considered closed (two-question re-probe sequence confirmed iter354 fix is durable). Postgres-vs-OLAP-decision topic is freshly probed at 4.9375; recommend at least one additional re-probe at a different question phrasing before declaring this subtopic durable.
