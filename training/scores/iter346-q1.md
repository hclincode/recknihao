# Iter 346 Q1 — Iceberg Table Maintenance: rewrite_manifests in Trino vs Spark

## Score Table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Every claim verified: rewrite_manifests is NOT in Trino 467; Trino 470 (Feb 5, 2025) added it as `optimize_manifests` (different name correctly noted); Spark `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')` syntax is correct per Iceberg docs; all four maintenance procedures' Trino availability matrix accurate. |
| Beginner clarity | 5.0 | Opens with direct answer ("You are not missing anything"), uses a clean engine/availability matrix, defines what manifest rewrite does in plain operational language ("planning drops from 10+ seconds to under 1 second"), and zero unexplained jargon. |
| Practical applicability | 5.0 | Engineer knows exactly what to run (`CALL iceberg.system.rewrite_manifests(table => 'analytics.events')` from Spark), where to run it (`spark-sql` CLI or `spark-submit`), and how it fits the weekly maintenance workflow. Future upgrade path (Trino 470+ → `optimize_manifests`) called out so the engineer can plan migration. |
| Completeness | 5.0 | Covers: (1) Yes/no answer to the core question, (2) why it fails (capability gap, not syntax), (3) exact Spark fix, (4) why manifest rewrite matters operationally, (5) where it fits in the weekly maintenance order, (6) future Trino 470+ syntax, (7) recommendation to run whole job from Spark for orchestration cleanliness. |

**Average: 5.00 — STRONG PASS (PERFECT)**

---

## What Worked

- **Direct, unambiguous lead.** First sentence resolves the engineer's anxiety ("not missing anything — genuinely not available"). No hedging.
- **Engine matrix gets all three rows right.** Spark = available; Trino 470+ = available as `optimize_manifests` (correct procedure name change); Trino 467 = not available. The name change between `rewrite_manifests` (Spark/Iceberg) and `optimize_manifests` (Trino 470+) is a subtle but important detail that the responder nailed.
- **Spark CALL syntax exactly correct.** `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')` matches Iceberg 1.5.2 spark-procedures docs verbatim.
- **Operational context, not just syntax.** The "why you want this anyway" paragraph (planning drops from 10+s to <1s after manifests consolidate) gives the engineer a reason to keep this in the weekly job rather than skip it because Trino can't do it.
- **Workflow integration.** Embeds rewrite_manifests in the broader 4-step weekly maintenance (compaction → expire → orphan → manifests) in the correct order with engine annotations.
- **Forward-looking upgrade path.** Mentions Trino 470+ `optimize_manifests` so the engineer knows what changes when the cluster upgrades, without making it sound like an urgent action item.
- **Honest about workarounds.** "No workarounds or alternative approaches" — does not invent a clever Trino-side hack. Spark is the answer, period.

## What Missed

Nothing material. Possible minor enhancements (none worth a deduction):
- Could have mentioned the `$manifests` metadata table diagnostic (`SELECT COUNT(*) FROM iceberg.analytics."events$manifests"`) so the engineer can verify before/after the rewrite. But the question was "is it available in Trino?", not "how do I measure manifest bloat?", so this is genuinely outside scope.
- Could have mentioned the optional `sort_by` Spark argument (e.g., `CALL iceberg.system.rewrite_manifests(table => '...', sort_by => array('partition_col'))`) for tables where partition-pruning latency is critical. Again outside the scope of the question as asked.

## Technical Accuracy Verification

Verified via WebSearch against official Trino release notes and Iceberg documentation:

1. **Trino 470 release date and feature**: Confirmed — Trino 470 was released **5 Feb 2025** and added `optimize_manifests` as the table procedure for manifest consolidation (per https://trino.io/docs/current/release/release-470.html). The procedure name in Trino is `optimize_manifests`, NOT `rewrite_manifests` — the responder correctly identified this naming distinction.
2. **Trino 467 lacks rewrite_manifests / optimize_manifests**: Confirmed — Trino 467 predates the Feb 2025 release of `optimize_manifests`. The longstanding feature request issue (trinodb/trino#14821) and the PR (#25378) that introduced `optimize_manifests` both confirm the gap on 467. Neither `CALL iceberg.system.rewrite_manifests(...)` nor `ALTER TABLE ... EXECUTE optimize_manifests` works on Trino 467.
3. **Spark CALL syntax**: Confirmed — `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')` matches the canonical Iceberg Spark procedures docs (https://iceberg.apache.org/docs/latest/spark-procedures/). Named-argument `=>` form is the recommended syntax.
4. **Procedure name distinction (rewrite_manifests vs optimize_manifests)**: Confirmed — Spark/Iceberg uses `rewrite_manifests`; Trino 470+ exposes equivalent functionality as `optimize_manifests`. The responder is one of the few answers in this loop's history that called this naming subtlety out without confusion.

All four key technical claims in the answer are accurate. No corrections needed.

## Resource Fix Applied

None needed. `resources/17-iceberg-table-maintenance.md` already contains all the information the responder used:
- The engine-availability matrix for `rewrite_manifests` (Spark / Trino 470+ / Trino 467) is present in the section "4. `rewrite_manifests` — run weekly" (lines 538–562).
- The procedure-name distinction (`optimize_manifests` in Trino 470+ vs `rewrite_manifests` in Spark) is explicit in the cheat sheet (line 156) and the per-procedure section.
- The 4-step weekly ordering with engine annotations is correct in the answer and the resource.

The iter345 note suggested "consider adding engine-availability note to resources/17" — this is already done from prior iterations (the structure was in place). The responder used it correctly. No further edits warranted.

## Rubric Update

**Topic**: Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup

**Previous**: 4.592 / 35 questions
**This Q**: 5.00
**New average**: (4.592 × 35 + 5.00) / 36 = 165.72 / 36 = **4.6033 / 36 questions**

Topic remains **PASSED** — strong recovery confirmed. Two consecutive perfect scores on rewrite_manifests questions (iter345 Q2 covered the ordering rationale; iter346 Q1 covers the engine-availability gap). The Trino 467 limitation is now clearly explained in resources/17 and the responder is able to surface it without prompting.
