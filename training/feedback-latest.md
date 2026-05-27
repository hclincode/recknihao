# Judge Feedback — Iter 344

Date: 2026-05-27
Phase: extended
Topics: Iceberg table maintenance / weekly maintenance ordering WHY (Q1) + Multi-tenant analytics / resource group selector first-match-wins (Q2)

---

## Q1 — Iceberg Maintenance Ordering Rationale (STRONG PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Both expire-before-orphan reasons correctly explained (exposing previously-protected files + in-flight write race window). One overstatement: "Why compaction must come BEFORE expire_snapshots" framed as a safety concern (files may not be protected, broken pointers). This is incorrect — Iceberg's atomic commit semantics guarantee expire_snapshots cannot delete files referenced by any live snapshot. The real reason to compact before expire is operational efficiency: you get max cleanup in one maintenance window vs. needing an extra cycle. No data-loss risk in reversing the order. |
| Beginner clarity | 5.0 | "Leases on files" analogy for snapshot protection is excellent. "Quick mnemonic" section gives one-sentence rationales for each ordering decision. Swap-by-swap table directly answers the engineer's specific "what breaks?" question. Runbook-close is practical. |
| Practical applicability | 5.0 | Engineer can explain all three ordering decisions to their team lead with concrete rationales. No action needed (their current setup is right) and they understand why. |
| Completeness | 4.5 | Covers: all four steps in order, WHY for each major step pair, what breaks when flipped, practical recommendation. Minor gap: rewrite_manifests ordering rationale not explained (it's last because you rebuild the index after the data layer is clean). |
| **Average** | **4.75** | **STRONG PASS** |

### What Worked
- Both reasons for expire-before-orphan correctly surfaced (the pre-iter resources/17 fix held).
- "Leases on files" analogy is one of the clearest in the training run.
- Swap-by-swap table directly addresses the engineer's "what actually breaks?" question.
- In-flight write race window correctly explained and linked to the 7-day retention floor.
- Resources/17 expanded WHY section from pre-iter fix confirmed holding.

### What Missed
1. **Compact-before-expire overstated as a safety issue** — Iceberg's atomic commit semantics protect all live-snapshot files. The actual concern is operational efficiency: compact first to get the old-small-file snapshots eligible for the same-window expire run. Reversing the order has no data-loss risk, only a one-week efficiency penalty.
2. **rewrite_manifests ordering rationale not explained** — it goes last because you rebuild the metadata index after the data layer has been cleaned by orphan removal.

### Technical Accuracy Verification (verified by judge via WebSearch)
- expire_snapshots drops old snapshots and physically deletes unreferenced data files — CONFIRMED per iceberg.apache.org/docs/latest/maintenance/
- remove_orphan_files scans for files not in any snapshot — CONFIRMED; expired snapshots expose more orphans
- In-flight write race condition (files uploaded before commit look like orphans) — CONFIRMED per Iceberg maintenance docs
- Iceberg atomic commit semantics protect files referenced by live snapshots from expire_snapshots — CONFIRMED; compact-before-expire is efficiency, not safety

### Resource Fix Applied
resources/17-iceberg-table-maintenance.md: Corrected compact-before-expire framing from "safety/data-loss" to "operational efficiency — same final state, just one extra week of storage cost." Added explicit statement that Iceberg atomic commit semantics guarantee expire_snapshots cannot delete files referenced by any live snapshot.

### Rubric Update
- Iceberg table maintenance: prior avg 4.575/33 → (4.575 × 33 + 4.75) / 34 = 155.725 / 34 = **4.580 across 34 questions**. Status: **PASSED** (recovering upward; ordering WHY correctly explained with both expire-before-orphan reasons).

---

## Q2 — Resource Group Selector First-Match-Wins (STRONG PASS — PERFECT)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All five claims verified against trino.io: first-match-wins top-to-bottom (confirmed), user/source are Java regex (confirmed), group in selectors is literal string not regex (confirmed), multiple fields AND-combined (confirmed), system.runtime.queries user/resource_group_id columns exist (confirmed since release 0.206). |
| Beginner clarity | 5.0 | if-elif-else analogy perfectly maps the concept to familiar programming constructs. Wrong-order vs right-order side-by-side snippet is immediately scannable. "Occasionally fails" symptom correctly traced to AND-combined conditions (source field) as the prime suspect. |
| Practical applicability | 5.0 | Three-step debugging recipe (check JSON order, query system.runtime.queries, match regex to actual JWT value) gives the engineer a complete runbook for their specific symptom. JWT principal callout fits the production on-prem auth stack. |
| Completeness | 5.0 | Covers: first-match-wins rule, catch-all ordering trap, AND-combination, user/source as regex, group as literal, system.runtime.queries debugging, five operational rules. The pre-iter resources/05 selector hierarchy section confirmed holding with a perfect score. |
| **Average** | **5.00** | **STRONG PASS — PERFECT SCORE** |

### What Worked (everything)
- if-elif-else analogy makes the first-match-wins rule immediately intuitive.
- Correctly identifies the catch-all-above-specific-rule as the most common cause of the engineer's symptom.
- AND-combined conditions correctly surfaced as the intermittent failure cause (source field varying by submission path).
- user/source as Java regex vs group as literal correctly stated — direct application of the iter343 selector syntax fix.
- system.runtime.queries debugging recipe is copy-pasteable and directly actionable.
- Resources/05 pre-iter selector hierarchy section confirmed holding.

### What Missed (none — perfect score)
Minor non-deductions: no mention of `selectorPriority` field (an alternative to position-based ordering); no mention of `userGroup` field for group-membership-based routing.

### Technical Accuracy Verification (verified by judge via WebSearch)
- First-match-wins top-to-bottom in JSON array — CONFIRMED per trino.io/docs/current/admin/resource-groups.html
- user and source are Java regex — CONFIRMED
- group in selectors is literal string — CONFIRMED (distinct from session-property-manager match-rules where group IS regex)
- Multiple conditions AND-combined — CONFIRMED
- system.runtime.queries resource_group_id (array(varchar)) — CONFIRMED since Trino release 0.206

### Resource Fix Applied
None needed. Resources/05 pre-iter selector hierarchy section confirmed holding with perfect score.

### Rubric Update
- Multi-tenant analytics: prior avg 4.454/137 → (4.454 × 137 + 5.00) / 138 = 615.198 / 138 = **4.458 across 138 questions**. Status: **PASSED** (recovering upward; 3rd consecutive strong score on selector-related subtopics).

---

## Iter 344 Summary

**Iter 344 average: (4.75 + 5.00) / 2 = 4.875 — STRONG PASS** ✓

### Notable
- Q1 4.75 STRONG PASS: Both expire-before-orphan reasons correctly surfaced (pre-iter resources/17 fix held). One technical overstatement corrected post-iteration: compact-before-expire is an efficiency decision, not a safety decision (Iceberg atomic commits prevent expire from deleting live-snapshot files).
- Q2 5.00 PERFECT: First-match-wins selector hierarchy perfectly explained — 2nd consecutive perfect score on a multi-tenant subtopic. Pre-iter resources/05 selector section confirmed holding.

### Resource fixes applied this iteration
- **resources/17-iceberg-table-maintenance.md**: Corrected compact-before-expire rationale from safety to efficiency; added Iceberg atomic commit guarantee statement.
- **resources/05-multi-tenant-analytics.md** (teacher pre-iter fix): Selector first-match-wins hierarchy section — confirmed holding with perfect score.

### Suggested focus for Iter 345
- **Iceberg table maintenance** (4.580/34): Probe the compact-before-expire atomic commit detail specifically — can the responder now correctly explain it as efficiency (not safety)? Also probe rewrite_manifests ordering rationale.
- **Postgres-to-Iceberg** (4.501/125): Consider probing CDC with Debezium — schema changes in source table + Iceberg schema evolution.
- **Multi-tenant analytics** (4.458/138): Consider probing the `selectorPriority` field as an alternative to position-based ordering — not yet tested.
