# Iter 298 Q1 — Score

**Question**: We've been running Iceberg on top of Trino for about two months and our S3 costs keep climbing. Everything I find talks about running maintenance through Spark — we don't have Spark. Do we actually need to spin up a Spark cluster just to run cleanup jobs, or is there a way to do this directly from Trino?

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter298-q1.md`

---

## Score table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All claims verified. `ALTER TABLE ... EXECUTE optimize/expire_snapshots/remove_orphan_files` syntax with `file_size_threshold` and `retention_threshold` named parameters is correct for Trino 467. The 7-day minimum retention floor (`iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention`, default 7d) is documented in the Trino docs — the error message format quoted in trino docs confirms this. `optimize_manifests` was indeed added in Trino 470 (released 5 Feb 2025) and is NOT in 467 — correct gating. The `dry_run` claim is accurate: Trino's `remove_orphan_files` table procedure does not expose a `dry_run` parameter (only `retention_threshold`), while Spark's `CALL ... system.remove_orphan_files(dry_run => true)` does. The ordering rationale (compact → expire → orphan) is correct — orphan removal honors snapshot references, so expiring snapshots first is what actually frees space. Minor nit: orphan removal uses ALL referenced files from metadata (active + referenced snapshots), so the "after expire" framing is a useful simplification rather than a strict ordering requirement, but the practical guidance is sound. |
| Beginner clarity | 5 | Opens with a direct "You do NOT need Spark" answer. Each command is annotated with cadence, ordering, and the floor rationale. The "Why costs keep climbing" section walks through the snapshot-keeps-old-files mental model without assuming Iceberg internals. The "After step 1 alone, storage looks worse" sentence is exactly the counterintuitive insight a beginner needs. No unexplained jargon. |
| Practical applicability | 5 | Engineer can act immediately on Trino 467 + Iceberg 1.5.2 + MinIO. Provides full SQL templates with realistic catalog/schema/table names, a concrete nightly+weekly schedule, K8s CronJob hint (`trino --execute "..."`), and explicitly addresses the dry-run gap with a one-time Spark workaround that the engineer can skip if comfortable. No advice contradicts the on-prem MinIO + K8s stack. |
| Completeness | 5 | Covers the three core operations, ordering, cadence, the 7-day floor, the `optimize_manifests` gap (and when it would matter), the `dry_run` limitation, and the only legitimate Spark-required case (sub-7-day GDPR purge). Addresses the underlying "why costs climbing" question, not just the literal "can I avoid Spark" question. Ends with a clear summary. |

---

## Verification notes

Searched and confirmed against trino.io and apache iceberg docs:

1. **ALTER TABLE EXECUTE syntax** — Confirmed `ALTER TABLE x EXECUTE optimize(file_size_threshold => '...')`, `expire_snapshots(retention_threshold => '...')`, `remove_orphan_files(retention_threshold => '...')` are all valid in Trino's Iceberg connector. Procedures available since Trino 378+ (well before 467).
2. **7-day minimum retention** — Confirmed default `iceberg.expire-snapshots.min-retention = 7d` and `iceberg.remove-orphan-files.min-retention = 7d`. Error message format ("Retention specified (X.XXd) is shorter than the minimum retention configured in the system (7.00d)") matches what the answer describes.
3. **optimize_manifests in Trino 470** — Confirmed via Trino 470 release notes (5 Feb 2025) that `optimize_manifests` procedure was added in this release. NOT available in 467. Answer's gating is accurate.
4. **dry_run parameter** — Confirmed Trino's `remove_orphan_files` table procedure only exposes `retention_threshold`; `dry_run` is part of the Iceberg Spark procedure spec (`CALL catalog.system.remove_orphan_files(table => ..., dry_run => true)`). Answer's claim is accurate.

---

## Topic mapping

- **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup** (primary) — directly addresses all three operations, ordering, cadence, and the Trino-vs-Spark question.
- **Cost considerations for analytical workloads at SaaS scale** (secondary) — addresses storage cost growth root cause.

---

## Verdict

**Average: (5 + 5 + 5 + 5) / 4 = 5.00 — PASS**

This is a model answer. It corrects the iter297 Q1 regression (where the responder had incorrectly said maintenance was Spark-only) by leading with Trino-native commands, accurately gating the one Trino 470 feature, and providing the one legitimate Spark workaround (dry-run preview) without overstating Spark's necessity. All technical claims verified against trino.io. Fully fits the production stack (Trino 467, Iceberg 1.5.2, MinIO, K8s).
