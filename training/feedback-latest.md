# Iter 353 Q1 — Judge Feedback

**Date**: 2026-05-29
**Phase**: extended
**Topic**: Iceberg table maintenance — Debezium CDC equality delete files (fresh angle, iter352 suggestion #1)
**Average**: 3.875 / 5.00 — **MARGINAL FAIL** (below 4.0 per-question pass bar)
**Topic running avg**: 4.554 / 39 questions (still PASSED in aggregate)

---

## Score breakdown

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.0 | Core claims correct: Debezium → equality deletes (because it only knows PK, not row position); `rewrite_position_delete_files` is position-only; Trino 467 doesn't support it; $files content codes (0=data, 1=position, 2=equality) right. BUT overstates "equality deletes handled correctly by rewrite_data_files during normal compaction" — misses well-documented Iceberg 1.5.2 dangling-equality-delete bug (apache/iceberg#12838, #8933) where equality delete files persist after rewrite_data_files across partition boundaries. The fix (`remove-dangling-deletes` option) only landed in Iceberg 1.8+. Production stack runs 1.5.2 per prod_info.md. Also: "Debezium CDC streams Postgres deletes into your Iceberg table via MERGE INTO statements" framing is slightly off — the Iceberg Debezium consumer writes equality delete files via the Iceberg writer API directly, not SQL MERGE INTO. |
| Beginner clarity | 4.5 | Strong structure: corrects the user's framing first, defines both delete types with concrete examples (file_path/row_position vs column-value tuples), diagnostic SQL annotated with content codes, plain-language bottom line. Could use a CDC-specific example (e.g., "after 1M Postgres UPDATEs you'll have N equality delete files") but well-organized for a non-OLAP engineer. |
| Practical applicability | 3.5 | Names Trino 467 + Spark explicitly (fits production stack). Provides a runnable diagnostic query. BUT does NOT name Iceberg 1.5.2 limitation (production version per prod_info.md), does not give a concrete cadence/threshold for Debezium pipelines, does not flag `remove-dangling-deletes` as an upgrade rationale. An engineer copy-pasting this guidance into a high-write Debezium pipeline will be surprised when equality delete files don't go away. |
| Completeness | 3.5 | Answers both direct sub-questions implicitly. Missing: explicit "no `rewrite_equality_delete_files` procedure exists today" statement (the user literally asked this — "is there a completely different maintenance operation I need to be running for those?"). Missing: Iceberg 1.5.2 dangling-equality-delete bug callout. Missing: CDC-specific maintenance cadence guidance (Debezium write rate vs maintenance frequency). Missing: MoR read-amplification problem on equality-delete-heavy CDC tables — the production failure mode the engineer is most at risk of. |

**Average**: (4.0 + 4.5 + 3.5 + 3.5) / 4 = **3.875** → **MARGINAL FAIL**

---

## WebSearch verification trail

1. **Debezium → equality deletes**: Confirmed via debezium.io/blog/2021/10/20/using-debezium-create-data-lake-with-apache-iceberg/ — the Iceberg Debezium consumer "uses the Iceberg equality delete feature and creates delete files using the key of the Debezium change data events (derived from the primary key of the source table)." Responder's core claim is correct.

2. **`rewrite_data_files` and equality deletes — partial story**: apache/iceberg#12838 (May 2025, still open as of 2026-05) documents that `rewrite_data_files` leaves orphaned equality delete files when dataSequenceNumber comparisons cross partition boundaries. apache/iceberg#8933 ("equality delete files can be removed immediately after rewrite?") was closed as not-planned. The `remove-dangling-deletes` option in Iceberg 1.8+ addresses this — Iceberg 1.5.2 (production stack) does NOT have it. Responder's "handled correctly during normal compaction" claim overstates the production reality.

3. **No standalone `rewrite_equality_delete_files` procedure exists**: Confirmed via Iceberg Spark procedures docs and apache/iceberg#12914 (planned `ConvertEqualityDeleteFiles` action, not yet shipped). Responder addresses this implicitly but should state it explicitly.

4. **Trino 467 doesn't support `rewrite_position_delete_files`**: Confirmed via trinodb/trino#27371 roadmap. Responder correct.

5. **$files content codes**: Confirmed via Iceberg spec — 0=data, 1=position delete, 2=equality delete. Responder correct.

---

## What the iter354 teacher should add

The iter353 question exposed three distinct gaps from the iter352 position-delete fix. The position-delete topic is now durable across iter345/iter352. But equality-delete cleanup is a separate sub-topic that needs its own resource section.

**Recommended new section** in `resources/17-iceberg-table-maintenance.md` (or `resources/15-postgres-iceberg-cdc.md` if cross-referenced from CDC):

### Section title: "Equality delete files from CDC pipelines (Debezium)"

Required content:

1. **What writes equality deletes vs position deletes**:
   - Debezium Iceberg consumer → equality deletes (PK-based, content=2)
   - Trino MERGE/UPDATE/DELETE with `write.delete.mode = 'merge-on-read'` → position deletes (content=1)
   - Spark MERGE INTO can write either depending on config

2. **Iceberg 1.5.2 dangling-equality-delete bug (CRITICAL FOR PRODUCTION)**:
   - apache/iceberg#12838: `rewrite_data_files` does NOT always remove equality delete files across partitions
   - Fix: `remove-dangling-deletes` option in Iceberg 1.8+
   - Production runs Iceberg 1.5.2 — DOES NOT have this option
   - Workaround: snapshot expiry will eventually release the underlying files; or manually run `delete_orphan_files` after rewrite_data_files passes; or upgrade to 1.8+

3. **No standalone `rewrite_equality_delete_files` procedure exists today**:
   - Planned per apache/iceberg#12914 but not shipped
   - Closest substitute: `rewrite_data_files` applies equality deletes during data file rewrite (subject to the 1.5.2 dangling bug above)

4. **CDC-specific maintenance cadence**:
   - Debezium pipelines generate equality deletes at source UPDATE/DELETE rate
   - For high-write tables (>100 UPDATEs/sec on source Postgres): hourly compaction recommended, not nightly
   - For low-write tables (<10 UPDATEs/sec): nightly is fine
   - Concrete trigger threshold: if `content=2` file count exceeds 10× `content=0` data file count for a partition, read amplification is severe — run rewrite_data_files immediately

5. **MoR read-amplification on equality-delete-heavy tables**:
   - Every Trino query scans BOTH data files AND equality delete files
   - With 1000+ equality delete files accumulated, query latency goes from seconds to minutes
   - The diagnostic query in the responder's answer is correct; add a concrete "danger zone" threshold

6. **Correct framing of Debezium write path**:
   - The Iceberg Debezium consumer writes equality delete files via the Iceberg writer API directly
   - NOT via SQL MERGE INTO (the responder's current framing is incorrect)
   - kafka-connect-iceberg sink has config options (databricks/iceberg-kafka-connect#319) for position-delete mode, but Debezium Server's Iceberg consumer is equality-delete-mode by default

---

## Recommendations for iter354+

- **iter354**: Teacher writes the equality-delete section above. Judge re-probes with a related question — e.g., "We've been running rewrite_data_files nightly on our Debezium-ingested Iceberg tables but our $files content=2 count keeps growing. Is the procedure broken, or are we missing a step?" — to verify the Iceberg 1.5.2 dangling-equality-delete callout lands.
- **Avoid re-probing position-delete cleanup again** (durable since iter352 with the canonical 5-step ordering).
- **Other under-probed topics to rotate to** (per iter352 notes): on-prem MinIO storage sizing/growth (Cost considerations, 4 questions); Trino federation memory pressure (Query performance regression, 2 questions).

---

## Pattern note

This is the second per-question FAIL on Iceberg maintenance in the last 4 iterations (iter351 Q2 FAIL on position-delete ordering → iter352 PERFECT on re-probe → iter353 Q1 FAIL on equality-delete angle). The pattern is **NOT a regression** of the position-delete fix; it's exposure of a related but distinct sub-topic that the iter352 resource fix did not cover. The iter354 teacher action should be additive (new section), not corrective (no changes to existing position-delete content).

---

# Iter 353 Q2 — Judge Feedback

**Date**: 2026-05-29
**Phase**: extended
**Topic**: Cost considerations / Storage sizing — Iceberg lakehouse on MinIO: 1 TB raw data vs 4 TB MinIO footprint, attributing 3 TB overhead to snapshots vs compaction vs delete files (fresh angle, iter352 suggestion #2)
**Average**: 4.125 / 5.00 — **MARGINAL PASS** (above 4.0 per-question pass bar)
**Topic running avg (Cost considerations)**: 4.450 / 5 questions (still PASSED)

---

## Question summary

"4 TB on MinIO vs 1 TB raw data — 3 TB overhead. Is it old snapshots, compaction temp doubling, or delete files? How do I figure out the main culprit so I know what to fix first?"

## Score breakdown

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.0 | Core claims verified: old snapshots as primary cause (~90%) confirmed by [Starburst](https://www.starburst.io/blog/iceberg-snapshots-affect-storage-not-performance/) + [IOMETE](https://iomete.com/resources/blog/iceberg-maintenance-runbook). Compaction temporarily doubles storage confirmed by [Dremio](https://www.dremio.com/blog/maintaining-iceberg-tables-compaction-expiring-snapshots-and-more/) + [Conduktor](https://www.conduktor.io/glossary/maintaining-iceberg-tables-compaction-and-cleanup) ("Compaction temporarily doubles storage usage, with old and new files existing until snapshots expire"). `$snapshots` and `$files` metadata table queries valid in Trino 467 (stable through 481). `$files.content` mapping (0=data, 1=position delete, 2=equality delete) correct per Iceberg spec. **Major deduction (-1.0)**: the fix-step block uses Spark CALL syntax (`CALL iceberg.system.rewrite_data_files(...)`, `CALL iceberg.system.expire_snapshots(...)`, `CALL iceberg.system.remove_orphan_files(...)`) for procedures that ARE available natively in Trino 467 via `ALTER TABLE table EXECUTE optimize(...)`, `ALTER TABLE table EXECUTE expire_snapshots(retention_threshold => '...')`, `ALTER TABLE table EXECUTE remove_orphan_files(retention_threshold => '...')`. Per [Trino 481 Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html), the Spark CALL syntax does NOT execute in Trino. Only `rewrite_manifests` is genuinely Spark-only on Trino 467 (per trinodb/trino#27371). The diagnostic queries are correctly written in Trino syntax, but the fix block switches to Spark without flagging the engine change. This is a partial regression of the iter351 Q2 engine-mixing defect — the iter352 Q1 fix on `resources/17-iceberg-table-maintenance.md` taught engine-labeling for position-delete maintenance but did NOT generalize to the cost/storage flow. |
| Beginner clarity | 4.5 | Strong scaffold: 6-step framework (CoW/MoR check → diagnostic queries → percentage breakdown → delete file check → fix → verify). The 2.5–3 TB / 0.1–0.2 TB / 1 TB attribution builds a concrete mental model for "where does the 3 TB live". The closing formula `daily_rewritten_volume × retention_days` cleanly explains the snapshot-retention cost knob. **Minor deduction (-0.5)**: engine confusion in the fix block (Spark CALL vs Trino EXECUTE) is the opposite of clarity for a beginner — an engineer pasting `CALL iceberg.system.rewrite_data_files(...)` into Trino will get `Procedure not registered` and not know why. The iter352 Q1 pattern (engine label per step + side-by-side Trino-vs-Spark syntax matrix) would have closed this. |
| Practical applicability | 3.5 | Diagnostic queries are immediately runnable in Trino 467 — that part is excellent. 50–75% storage reduction expectation gives the engineer a target. Nightly compaction + weekly full maintenance cadence is reasonable. **Major deduction (-1.5)**: the fix-step code block cannot be pasted into Trino 467 as written. An engineer who copies the Spark CALL syntax into Trino will get a procedure-not-registered error. They MUST either translate to `ALTER TABLE ... EXECUTE` or run from Spark — the answer never tells them this. Given the question is fundamentally "how do I fix this", a fix block that doesn't execute on the production query engine is a real applicability hit. The MinIO sizing context is acknowledged; the engine fit is not. Also: `dry_run => true` is Spark-only syntax — Trino's ALTER TABLE EXECUTE `remove_orphan_files` does NOT support dry_run, so engineers can't preview-before-delete on Trino. |
| Completeness | 4.5 | All three sub-questions answered directly: (1) yes, old snapshots are primary (~90%); (2) yes, compaction temporarily doubles storage and only shrinks after expire_snapshots; (3) delete files <10% typically unless heavy CDC, separate $files content=1/2 check. Plus diagnostic queries, fix sequence, verification, scheduling. **Minor deduction (-0.5)**: doesn't mention MinIO erasure-coding multiplier as an orthogonal cause of the 4x footprint. A bare-metal MinIO pool with EC 4+2 introduces 1.5x logical-to-physical overhead BEFORE any Iceberg-side overhead. This could explain a meaningful chunk of the "3 TB gap" and is worth at least a sentence to rule out at the storage layer before attacking Iceberg. The 4x ratio is suspiciously close to typical EC multiplier × snapshot bloat. Also missing: `iceberg.expire_snapshots.min-retention` Trino catalog default (7d floor) — common first-time-user trip-wire. |

**Average**: (4.0 + 4.5 + 3.5 + 4.5) / 4 = **4.125** → **MARGINAL PASS**

---

## WebSearch verification trail

1. **Old snapshots as primary storage growth cause**: CONFIRMED. Starburst and IOMETE both establish that snapshot accumulation is the principal driver of unexpected storage growth in long-running Iceberg tables. The 90% framing is a reasonable rule of thumb for append-mostly raw-event ingest where rows are rarely updated; snapshot-pinned data file retention dominates.

2. **Compaction temporary doubling**: CONFIRMED. Dremio's "Maintaining Iceberg Tables" and Conduktor's "Maintaining Iceberg Tables: Compaction and Cleanup" both state: "Compaction temporarily doubles storage usage, with old and new files existing until snapshots expire." Responder's framing matches docs.

3. **Trino 467 `$snapshots` / `$files` metadata tables**: CONFIRMED. The Trino Iceberg connector exposes `<table>$snapshots`, `<table>$files`, `<table>$manifests`, `<table>$partitions`, `<table>$history`. The `file_size_in_bytes` and `content` columns are stable in 467 and current 481. SQL `SUM(file_size_in_bytes) / 1024 / 1024 / 1024` is a valid pattern.

4. **Trino 467 `CALL iceberg.system.*` procedures**: NOT VALID. The Trino Iceberg connector exposes `expire_snapshots`, `remove_orphan_files`, and `optimize` (Trino's name for what Iceberg's Spark API calls `rewrite_data_files`) via `ALTER TABLE <name> EXECUTE <procedure>(...)`, NOT via `CALL iceberg.system.<procedure>(...)`. The Spark CALL syntax in the answer's fix-step block requires a Spark job to execute. The engineer cannot paste those statements into Trino. Source: [Trino 481 Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html) "Procedures" and "ALTER TABLE EXECUTE" sections; also [Trino PR #10810](https://github.com/trinodb/trino/pull/10810) "Expire Snapshot and Remove Orphan files for Iceberg".

5. **`rewrite_manifests` Spark-only on Trino 467**: CONFIRMED. Trino does not yet expose `rewrite_manifests` (tracked in roadmap issue trinodb/trino#27371). For this single step, dropping to Spark is correct.

6. **MinIO erasure-coding multiplier**: a 4x footprint on a bare-metal MinIO pool with EC 4+2 + snapshot retention is a plausible real-world breakdown. The answer attributes 100% of the gap to Iceberg overhead, which may overstate Iceberg-side responsibility for the 3 TB.

---

## What the iter354 teacher should add

The iter353 Q2 question exposed two distinct gaps from the iter352 position-delete fix:

### Gap 1: Engine-label generalization

The iter352 Q1 fix taught engine-labeling on `resources/17-iceberg-table-maintenance.md`. The responder reproduces this perfectly for position-delete maintenance. But the lesson did NOT generalize to the cost/storage diagnostic flow on Q2. The cost/storage resource (likely `resources/15-storage-sizing.md` or wherever this content lives) needs the SAME Trino-vs-Spark side-by-side maintenance syntax cheat sheet that `resources/17` has.

**Recommended addition** — side-by-side table near any maintenance-step listing in cost/storage resources:

| Step | Trino 467 syntax | Spark CALL syntax | Use which |
|---|---|---|---|
| Compaction | `ALTER TABLE t EXECUTE optimize(file_size_threshold => '256MB')` | `CALL iceberg.system.rewrite_data_files(table => 't', options => map('target-file-size-bytes', '268435456'))` | Trino EXECUTE preferred (Trino is the query engine) |
| Expire snapshots | `ALTER TABLE t EXECUTE expire_snapshots(retention_threshold => '30d')` | `CALL iceberg.system.expire_snapshots(table => 't', older_than => current_timestamp - interval '30' day)` | Trino EXECUTE preferred |
| Remove orphan files | `ALTER TABLE t EXECUTE remove_orphan_files(retention_threshold => '3d')` | `CALL iceberg.system.remove_orphan_files(table => 't', older_than => ..., dry_run => true)` | Trino EXECUTE for prod; Spark CALL for dry_run preview |
| Rewrite manifests | NOT SUPPORTED in Trino 467 (trinodb/trino#27371) | `CALL iceberg.system.rewrite_manifests(table => 't')` | Spark only |

### Gap 2: MinIO erasure-coding callout

Add to the storage sizing / capacity planning section: a concrete multiplier table for EC 4+2 (1.5x), EC 8+4 (1.5x), EC 4+4 (2x). Tell the engineer to subtract this BEFORE attributing the remainder to Iceberg overhead. This is on-prem-MinIO-specific knowledge that pure cloud-storage docs miss and that the production stack (per prod_info.md) explicitly uses.

### Gap 3 (minor): `iceberg.expire_snapshots.min-retention` catalog floor

Trino's catalog property `iceberg.expire_snapshots.min-retention` defaults to 7d. Attempts to expire with `retention_threshold < 7d` will fail with "Retention specified (...) is shorter than the minimum retention configured in the system (7.00d)". One paragraph on this saves engineers a debugging cycle.

### Gap 4 (minor): `dry_run` syntax mismatch

Spark CALL `remove_orphan_files` supports `dry_run => true`; Trino EXECUTE does not. Engineers wanting to preview before deleting on Trino need to know this — and may need to drop to Spark for that one step.

---

## Recommendations for iter354+

- **iter354**: Teacher adds the Trino-vs-Spark maintenance syntax cheat sheet to the cost/storage resource (gap 1 above) + MinIO EC multiplier section (gap 2) + min-retention floor (gap 3) + dry_run note (gap 4). Judge re-probes from a Trino-first angle, e.g., "I only have Trino access, not Spark — how do I run compaction and snapshot cleanup on my Iceberg tables on MinIO?"
- **Avoid re-probing position-delete cleanup** (durable since iter352).
- **Other under-probed topics to rotate to** (per iter352 notes): Trino federation memory pressure (Query performance regression, only 2 questions).

---

## Sources consulted

- [Starburst — Iceberg Snapshots Affect Storage, Not Performance](https://www.starburst.io/blog/iceberg-snapshots-affect-storage-not-performance/)
- [IOMETE — The Iceberg Maintenance Runbook: Snapshots, Orphan Files, and Metadata Bloat](https://iomete.com/resources/blog/iceberg-maintenance-runbook)
- [Dremio — Maintaining Iceberg Tables: Compaction, Expiring Snapshots, and More](https://www.dremio.com/blog/maintaining-iceberg-tables-compaction-expiring-snapshots-and-more/)
- [Conduktor — Maintaining Iceberg Tables: Compaction and Cleanup](https://www.conduktor.io/glossary/maintaining-iceberg-tables-compaction-and-cleanup)
- [Apache Iceberg Maintenance Docs](https://iceberg.apache.org/docs/latest/maintenance/)
- [Apache Iceberg Spark Procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Trino 481 Iceberg Connector — Procedures and ALTER TABLE EXECUTE](https://trino.io/docs/current/connector/iceberg.html)
- [Trino PR #10810 — Expire Snapshot and Remove Orphan files for Iceberg](https://github.com/trinodb/trino/pull/10810)
- [Trino Issue #27371 — Iceberg Roadmap (rewrite_manifests Spark-only)](https://github.com/trinodb/trino/issues/27371)
- [Trino Issue #24086 — Delete files are not removed after running Iceberg maintenance ops](https://github.com/trinodb/trino/issues/24086)

---

## Iter 353 summary

| Question | Topic | Score | Result |
|---|---|---|---|
| Q1 | Iceberg maintenance — Debezium CDC equality delete files | 3.875 | MARGINAL FAIL |
| Q2 | Cost / storage — 1 TB raw vs 4 TB MinIO diagnosis | 4.125 | MARGINAL PASS |
| **Iter 353 average** | | **4.000** | **MARGINAL PASS (overall)** |

Each question reveals a distinct sub-topic gap:
- Q1 → equality-delete cleanup gap in Iceberg 1.5.2 (suggests new section in `resources/17-iceberg-table-maintenance.md`)
- Q2 → Trino-vs-Spark syntax generalization gap in cost/storage diagnostics (suggests engine-label treatment in `resources/15-storage-sizing.md` or wherever cost content lives)

Neither is a critical correctness failure, but both are actionable for iter354 teacher work. The aggregate topic averages remain above pass thresholds (Iceberg maintenance 4.554/39, Cost considerations 4.450/5).

---

## Iter 353 End-of-Iteration Summary

**Date**: 2026-05-29
**Phase**: extended
**Result**: MARGINAL PASS (barely above threshold)

### Scores table

| Question | Topic | Avg | TechAcc | BegClr | PracApp | Comp | Result |
|---|---|---|---|---|---|---|---|
| Q1 | Iceberg maintenance — Debezium CDC equality delete files | 3.875 | 4.0 | 4.5 | 3.5 | 3.5 | MARGINAL FAIL |
| Q2 | Cost / storage — 1 TB raw vs 4 TB MinIO diagnosis | 4.125 | 4.0 | 4.5 | 3.5 | 4.5 | MARGINAL PASS |
| **Iteration average** | | **4.000** | **4.0** | **4.5** | **3.5** | **4.0** | **MARGINAL PASS** |

### Q1 root cause

Equality-delete sub-topic is not covered in `resources/17-iceberg-table-maintenance.md`. The responder correctly reproduced the position-delete cleanup story (durable since iter345/iter352) but had nothing to draw from on the equality-delete angle — specifically: no callout of the Iceberg 1.5.2 dangling-equality-delete bug (apache/iceberg#12838) that affects production, no explicit statement that no standalone `rewrite_equality_delete_files` procedure exists today, no CDC-specific maintenance cadence guidance for Debezium pipelines, no MoR read-amplification framing. **This is an additive gap, not a regression** of the iter352 position-delete fix. Position-delete cleanup remains durable; equality-delete cleanup is a related but distinct sub-topic that needs its own resource section.

### Q2 root cause

Spark CALL syntax used in the fix-step block despite Trino 467 ALTER TABLE EXECUTE being available. The diagnostic queries are correctly written in Trino syntax, but the fix block silently switches engines: `CALL iceberg.system.rewrite_data_files(...)`, `CALL iceberg.system.expire_snapshots(...)`, `CALL iceberg.system.remove_orphan_files(...)` are all Spark-only and will return "Procedure not registered" if pasted into Trino. Trino 467 supports all three natively via `ALTER TABLE t EXECUTE optimize/expire_snapshots/remove_orphan_files(...)` (only `rewrite_manifests` is genuinely Spark-only on Trino 467, per trinodb/trino#27371). The iter352 Q1 engine-labeling fix on `resources/17` did NOT generalize to the cost/storage flow — partial regression of the iter351 engine-mixing defect on a new resource surface.

### Suggested teacher actions for iter 354

**(a) Add equality-delete section to `resources/17-iceberg-table-maintenance.md`** covering: Debezium→equality-deletes vs Trino MERGE→position-deletes write-path distinction; Iceberg 1.5.2 dangling-equality-delete bug (apache/iceberg#12838) + production workaround (`remove-dangling-deletes` only in 1.8+, fall back to snapshot expiry / `delete_orphan_files`); explicit "no standalone `rewrite_equality_delete_files` procedure exists today" (apache/iceberg#12914 planned, not shipped); CDC-specific maintenance cadence (hourly for >100 UPDATEs/sec, nightly for <10 UPDATEs/sec, immediate rewrite when content=2 file count exceeds 10× content=0 data file count); MoR read-amplification danger zone; correct framing of Debezium write path (Iceberg writer API directly, NOT SQL MERGE INTO).

**(b) Fix Trino-vs-Spark syntax in cost/storage resources** by adding the same engine-labeling treatment that `resources/17` got in iter352. Specifically: a side-by-side Trino-EXECUTE-vs-Spark-CALL syntax cheat sheet for compaction / expire_snapshots / remove_orphan_files / rewrite_manifests, with explicit "use which" recommendation; plus the `iceberg.expire_snapshots.min-retention` 7d catalog floor callout; plus the `dry_run` syntax mismatch note (Spark CALL supports it, Trino EXECUTE does not). Also add a MinIO erasure-coding multiplier table (EC 4+2 = 1.5x, EC 8+4 = 1.5x, EC 4+4 = 2x) so engineers subtract storage-layer overhead BEFORE attributing the remainder to Iceberg.

**Re-probe targets for iter354 judge**: (1) Trino-first equality-delete question, e.g., "We've been running rewrite_data_files nightly on our Debezium-ingested Iceberg tables but our $files content=2 count keeps growing. Is the procedure broken, or are we missing a step?" — to verify the Iceberg 1.5.2 dangling-equality-delete callout lands. (2) Trino-only maintenance question, e.g., "I only have Trino access, not Spark — how do I run compaction and snapshot cleanup on my Iceberg tables on MinIO?" — to verify the engine-labeling treatment generalizes beyond `resources/17`.

**Avoid re-probing**: position-delete cleanup (durable since iter352), EXPLAIN/EXPLAIN ANALYZE interpretation (durable since iter352 Q2).
