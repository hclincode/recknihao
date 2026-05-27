# Score: Iteration 16, Question 1

**Date**: 2026-05-24
**Phase**: Final
**Question**: We set up our main events table a few months ago without any partitioning. Can we just add a partition to the existing table, or do we have to rebuild it from scratch? And if we do add one, will the old data automatically benefit from it, or only new rows going forward?
**Rubric topics covered**: Iceberg partition design for SaaS; Iceberg table maintenance (compaction)

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.50 | Core concept correct: ALTER TABLE changes the spec for future writes only; historical files stay unpartitioned; rewrite_data_files is needed to retroactively apply the new spec to old data. Snapshot isolation during rewrite explained correctly. Storage spike warning (temporary doubling) is accurate. The CALL syntax shown is Spark SQL syntax — the answer does not explicitly label it as Spark, which could confuse an engineer who tries to run it in Trino. (Trino equivalent is ALTER TABLE ... EXECUTE optimize.) Minor deduction for this label gap. |
| Beginner clarity | 5.0 | Exceptional. The table comparing "files written before ALTER" vs "files written after ALTER" is the clearest single visualization of partition evolution across all iterations. "The key gotcha" section directly addresses the #1 mistake engineers make. Concrete timeline with estimated durations (30–60 min per 500 GB) is highly actionable. |
| Practical applicability | 4.75 | Correctly points to the production stack (Trino + Iceberg + MinIO). The rewrite_data_files call and expire_snapshots sequence is the right maintenance order. The storage spike warning is essential and correctly given. |
| Completeness | 4.75 | Covers partition evolution mechanism, ALTER TABLE syntax, rewrite procedure, snapshot isolation, storage spike, cleanup with expire_snapshots, and a concrete multi-step timeline. Missing: explicit labeling of CALL as Spark-only (Trino users need ALTER TABLE ... EXECUTE optimize). |
| **Average** | **4.75** | Strongest Q1 topic answer in final phase. |

---

## What the answer got right

1. "Cannot just add a partition" — files stay unpartitioned after ALTER TABLE — correctly stated.
2. ALTER TABLE + rewrite_data_files two-step sequence is the correct fix.
3. Snapshot isolation: queries running during rewrite keep reading old files — correct.
4. Old files become "unreferenced" after rewrite and need expire_snapshots — correct.
5. Storage spike warning: temporary doubling is accurate and important.
6. "Key gotcha" section is the exact misconception engineers fall into — correctly flagged.

## What the answer missed

1. **Engine label gap.** `CALL iceberg.system.rewrite_data_files(...)` is Spark SQL syntax. An engineer running Trino would need `ALTER TABLE ... EXECUTE optimize(file_size_bytes => 268435456)`. The resource (resources/17-iceberg-table-maintenance.md) has a Spark vs Trino reference table; the answer should have noted which engine runs each command.

---

## Resource assessment

`resources/10-lakehouse-partitioning.md` has the "Partitioning existing tables — important caveat" section that the answer correctly referenced. `resources/17-iceberg-table-maintenance.md` has the Spark vs Trino reference table. Both resources are correct — the engine-labeling gap is a responder behavior issue, not a resource gap.

---

## Topic score updates

**Iceberg partition design for SaaS**
- Prior: avg 4.125 across 2 questions (iter7-q4: ~3.75, iter8-q3: ~4.50 estimated)
- This answer: 4.75 (3rd angle — partition evolution / retroactive rewriting)
- New running avg: (8.25 + 4.75) / 3 = **4.333** across 3 questions
- Status: PASSED (improved from 4.125)
