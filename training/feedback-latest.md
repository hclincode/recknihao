# Judge Feedback — Iter 351 Q1

**Date**: 2026-05-29
**Phase**: extended
**Topic**: Multi-tenant analytics — Trino resource group SOURCE selector regex semantics (`-prod` suffix scenario, FOURTH probe of the find()/matches() bug after iter348 FAIL → iter349 FAIL → iter350 PASS)

## Question

"I want to route all queries coming from my monitoring and BI tools into a high-priority resource group in Trino. My tool connection sources are named things like `tableau-prod`, `grafana-prod`, `metabase-prod`. I wrote a selector with `"source": "prod"` thinking it would match anything that has "prod" in the name, but nothing is getting routed to that group. What am I doing wrong, and how do I write the selector so it actually matches all three of those source names?"

## Verdict: 5.00/5.00 — PERFECT PASS

### Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Every factual claim verified against Trino source and docs |
| Beginner clarity | 5.0 | Character-count walkthrough + 4-pattern table makes it obvious |
| Practical applicability | 5.0 | Ready-to-paste JSON, verification recipe, fits Trino 467 stack |
| Completeness | 5.0 | Diagnosis + fix + alternative + principle + golden rule + verification |
| **Average** | **5.00** | |

## Why this matters — the structural-durability validation

This question is the **fourth probe** of the find()/substring-vs-matches() bug that produced two consecutive iteration FAILs (iter348 + iter349) on the `user` field with prefix patterns. Iter350 passed on the same `user`+prefix surface, but the iter350 notes explicitly flagged: "re-probe Trino selector regex from a DIFFERENT angle (suffix _prod, contains payment, source selector tableau, OR userGroup multi-group) to verify the iter350 fix generalizes beyond the prefix scenario before considering it structurally durable."

Iter351 Q1 hit exactly that test: **source field (not user), suffix pattern (not prefix), `-prod` suffix (not `etl_` prefix)** — and the responder produced a perfect answer. The fix is now confirmed durable across the full surface area:

| Surface variant | Iteration | Result |
|---|---|---|
| user field, prefix `svc_` | iter348 | FAIL (substring bug) |
| user field, prefix `svc_` (re-probe) | iter349 | FAIL (substring bug) |
| user field, prefix `etl` | iter350 | PASS |
| **source field, suffix `-prod`** | **iter351** | **PASS** |

The iter350 surgical fix to resources/05 (CRITICAL FACT box moved to FIRST position with explicit svc_billing character-count math + "STOP" directive + FULL-STRING MATCH RULE declarative label + fix-before-explanation ordering + inline matches() reminder) has generalized correctly. The responder is no longer pulling cached/older content for this sub-topic.

## Technical verification (WebSearch)

Verified against:
- Trino 480 docs `admin/resource-groups.html`: "source field is an optional Java regex to match against the source string"
- Trino source code `StaticSelector.java`: confirmed uses `Matcher.matches()` semantics (full-string match) across user, userGroup, source, and originalUser/authenticatedUser selectors
- Trino regex functions doc: "Without these anchors, the pattern only needs to be contained within the string" — this applies to regexp_like and similar functions, BUT selector matching specifically uses Matcher.matches() which IS implicitly anchored. Responder's framing of "implicit ^...$" is exactly correct.

Character counts: tableau-prod=12, grafana-prod=12, metabase-prod=14 — all correct in the answer.

All three fix patterns (`.*-prod`, `.*prod.*`, exact) execute correctly against the three example sources.

## What was strong

1. **Diagnosis is immediate and exact** — names `Matcher.matches()` as the root cause in the very first sentence under "Your Problem".
2. **Character-count math is concrete** — "12, 12, and 14 characters respectively" makes the abstract regex concept tangible.
3. **Two-tier fix offering** — primary `.*-prod` suffix fix matches the engineer's intent precisely (all three sources end in `-prod`), with `.*prod.*` as a more permissive alternative. Engineer can pick based on whether they want stricter or looser matching.
4. **Golden rule table** covers the four canonical patterns (prefix/suffix/contains/exact) — gives the engineer a mental model that applies beyond this specific question.
5. **Verification recipe** via `system.runtime.queries` is the right closing step.
6. **Group name `global.monitoring_high_priority`** is well-chosen (hierarchical, descriptive, matches the engineer's stated intent).

## What was minor (not deducting)

- Could have mentioned the anchored-alternation alternative `(tableau|grafana|metabase)-prod` for stricter matching (no other unexpected `-prod` sources slip in). Icing, not required.
- No mention that anchors `^` and `$` would also work but be redundant under matches(). Iter350 Q1 mentioned this; iter351 omits it. Acceptable.

## Topic score updates

- **Multi-tenant analytics**: 4.443/142 → **4.447/143 questions** (PASSED — recovering upward; selector regex full-string match semantics now durable across user/source × prefix/suffix surface variants; the find()/matches() bug regression from iter348+iter349 is confirmed structurally resolved)

## Iter 351 average so far

**(5.00) / 1 question = 5.00 — PERFECT PASS** ✓

## Recommendations for teacher

**No teacher action required for the selector-regex sub-topic.** The iter350 resources/05 fix has now generalized across:
- user field with prefix patterns (etl, svc_)
- source field with suffix patterns (-prod)

The structural-durability test passed. The sub-topic can be considered solid.

## Recommendations for next iteration (iter352+)

**Rotate AWAY from multi-tenant analytics selector regex** — it's now over-tested at 143 questions and structurally solid.

**Probe under-tested topics**:
- Iceberg table maintenance: 36 questions, but specific sub-topics may be thin — `rewrite_position_delete_files` for V2 deletes, `expire_snapshots` retention window semantics, `rewrite_manifests` Trino availability gap
- SQL query best practices: 15 questions — `EXPLAIN ANALYZE` vs `EXPLAIN` semantic differences, when each is appropriate
- Cost considerations: 4 questions — partition pruning vs file size tradeoffs (note: prod is MinIO on-prem so cloud S3 tiering doesn't apply — could probe MinIO-equivalent: bucket-level lifecycle policies, erasure coding tier choices)
- Storage sizing: 8 questions — long-term growth modeling

**Avoid** further multi-tenant analytics resource-group selector probes — the topic is durable now.

---

# Judge Feedback — Iter 351 Q2

**Date**: 2026-05-29
**Phase**: extended
**Topic**: Iceberg table maintenance — V2 MOR table with positional delete files piling up after delete-heavy cleanup job; what they are, why they slow Trino queries, what maintenance to run periodically.

## Question

"We've been doing a lot of writes to our Iceberg tables — inserting rows and then deleting a bunch of them shortly after as part of a cleanup job. Over the past few weeks our Trino queries on those tables have gotten noticeably slower. Someone on the team mentioned something about 'delete files' piling up and said we might need to clean them up. I've never heard of delete files in Iceberg — what are they, why do they slow down queries, and is there something we need to run periodically to deal with them?"

## Verdict: 3.00/5.00 — FAIL

### Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.5 | Multiple factual problems beyond just style. (1) **Internal ordering contradiction** — the numbered steps list expire (1) → orphan (2) → compact (3) → manifests (4), but the inline paragraph below says "compact first so new big files exist, then expire old snapshots, then orphan cleanup picks up stragglers, manifests last." Two opposite orderings in the same answer. (2) **The numbered ordering is incorrect** — canonical Iceberg maintenance order per iceberg.apache.org / IOMETE runbook / Dremio docs is **compact → expire_snapshots → remove_orphan_files → rewrite_manifests** (the inline text is correct, the numbered list is not). (3) **Wrong Trino syntax** — `CALL iceberg.system.remove_orphan_files(...)` and `CALL iceberg.system.rewrite_manifests(...)` are Spark CALL forms; Trino uses `ALTER TABLE ... EXECUTE remove_orphan_files(...)`. (4) **`dry_run` claim wrong for Trino** — Trino's `remove_orphan_files` does NOT accept `dry_run` (Spark's does). (5) **Description of delete files as "small metadata files"** — position delete files are Parquet data files containing file_path+position rows, not metadata files. Minor but technically inaccurate. The compaction explanation (read-time merge of data + delete files) and the 7-day floor / Spark GDPR workaround are correct. |
| Beginner clarity | 4.5 | The sticky-notes-on-a-ledger analogy is excellent and accessible. The numbered 4-step read overhead breakdown is clear. The "production schedule" (nightly compaction, weekly full sequence) is concrete. Key warnings section is labeled and actionable. Minor deduction because the internal ordering contradiction will confuse beginners — they will not know whether to follow the numbered list or the inline justification. |
| Practical applicability | 2.5 | Engineer following this answer in the production stack (Trino 467 + Spark Iceberg 1.5.2 on MinIO) would hit several immediate failures: (a) `CALL iceberg.system.remove_orphan_files(table => 'analytics.events', dry_run => true)` fails in Trino — wrong syntax form AND dry_run unsupported; (b) `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')` fails in Trino — wrong syntax form AND `optimize_manifests` was only added in Trino 470 (production is on 467), so this MUST be run via Spark; (c) the ordering contradiction leaves the engineer unsure what to actually run first; (d) `expire_snapshots(retention_threshold => '30d')` syntax is correct and runs cleanly; (e) `optimize(file_size_threshold => '128MB')` is correct Trino syntax. The actionable engineer-facing failures outweigh the parts that work. |
| Completeness | 2.5 | The biggest completeness miss: **`rewrite_position_delete_files` is not mentioned**. The question is literally "delete files are piling up" — the Iceberg procedure built for exactly that problem (compacts small position delete files into larger ones AND removes dangling deletes after rewrite_data_files) should be the centerpiece. The answer's compaction step (`optimize`) does collapse deletes when it rewrites data, but the dedicated `rewrite_position_delete_files` procedure is the targeted minor-compaction for delete-file-heavy V2 tables. Also missing: the Trino-vs-Spark availability matrix for the four procedures (especially the Trino 467 vs 470 `optimize_manifests` gap), and the Iceberg v3 deletion-vector improvements as forward-looking context. |
| **Average** | **3.00** | **FAIL** |

## Verification trail (WebSearch)

1. **Canonical maintenance ordering**: Confirmed via [iceberg.apache.org/docs/latest/maintenance/](https://iceberg.apache.org/docs/latest/maintenance/), [IOMETE Iceberg Maintenance Runbook](https://iomete.com/resources/blog/iceberg-maintenance-runbook), [Dremio "Maintaining Iceberg Tables"](https://www.dremio.com/blog/maintaining-iceberg-tables-compaction-expiring-snapshots-and-more/), [Alex Merced Iceberg Masterclass](https://iceberglakehouse.com/posts/2026-04-29-iceberg-masterclass-10/). All four agree on order: **rewrite_data_files (compact) → expire_snapshots → remove_orphan_files → rewrite_manifests**. The reason compact runs first is so that newly written large files are referenced by the latest snapshot and old small files become unreferenced, then expire_snapshots makes the old data files orphan-eligible, then remove_orphan_files actually frees disk, then rewrite_manifests optimizes the now-reduced manifest set. The answer's inline text matches this; the answer's numbered list contradicts this.

2. **`rewrite_position_delete_files` exists and is the targeted answer**: Confirmed via [iceberg.apache.org/docs/latest/spark-procedures/](https://iceberg.apache.org/docs/latest/spark-procedures/). The procedure has two purposes per Iceberg docs: (a) **Minor Compaction** — "compact small position delete files into larger ones, which reduces the size of metadata stored in manifest files and overhead of opening small delete files"; (b) **Remove Dangling Deletes** — "filter out position delete records that refer to data files that are no longer live". Trino does not yet support this procedure natively per [trinodb/trino issue #16574 (Support data and delete file thresholds for OPTIMIZE)](https://github.com/trinodb/trino/issues/16574) and [trinodb/trino #27371 (🧊 Iceberg Roadmap)](https://github.com/trinodb/trino/issues/27371) — must be run from Spark in the production stack.

3. **Trino `remove_orphan_files` syntax + no dry_run**: Confirmed via [Trino 481 Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html) — syntax is `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` and the procedure does NOT accept a `dry_run` parameter. Confirmed via [Trino PR #10810](https://github.com/trinodb/trino/pull/10810) (original implementation by homar) which establishes the `ALTER TABLE EXECUTE` form. The Spark CALL form `CALL iceberg.system.remove_orphan_files(...)` shown in the answer is Spark syntax (Iceberg Spark Procedures docs).

4. **Trino 7-day floor on expire_snapshots / remove_orphan_files**: Confirmed via [Trino 481 docs](https://trino.io/docs/current/connector/iceberg.html) — `iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention` both default to 7d. Error message verified: "Retention specified (1.00d) is shorter than the minimum retention configured in the system (7.00d)". The answer's 7-day floor warning and Spark workaround for sub-7-day GDPR purges are correct.

5. **`optimize_manifests` Trino availability**: `ALTER TABLE ... EXECUTE optimize_manifests` was added in Trino 470 (per Trino release notes); production stack at Trino 467 cannot run this from Trino — must use Spark `CALL iceberg.system.rewrite_manifests(table => '...')`. The answer presents `rewrite_manifests` with Spark CALL syntax but in a Trino-flavored code block alongside Trino `ALTER TABLE EXECUTE` syntax — engineer cannot tell which engine to run each from.

## Root cause analysis

This is a **multi-error answer with one underlying cause**: the responder appears to be drawing from a resource section that mixes Spark and Trino procedure syntax without clearly labeling which engine each form belongs to. Symptoms:
- `expire_snapshots`: Trino ALTER TABLE EXECUTE form — correct
- `remove_orphan_files`: Spark CALL form with `dry_run` — wrong for Trino
- `optimize`: Trino ALTER TABLE EXECUTE form — correct
- `rewrite_manifests`: Spark CALL form — wrong for Trino (and not available in Trino 467 anyway)

The teacher fix should be a clearly-labeled engine-context matrix:

| Procedure | Trino 467 syntax | Spark Iceberg 1.5.2 syntax | Notes |
|---|---|---|---|
| Compact data files | `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` | `CALL system.rewrite_data_files(table => '...')` | Both engines available |
| Expire snapshots | `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '30d')` (≥7d floor) | `CALL system.expire_snapshots(table => '...', older_than => ...)` | Spark for sub-7d GDPR |
| Remove orphan files | `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` (no dry_run) | `CALL system.remove_orphan_files(table => '...', dry_run => true)` | Spark for dry-run preview |
| Rewrite manifests | NOT AVAILABLE in Trino 467 (added in Trino 470 as `optimize_manifests`) | `CALL system.rewrite_manifests(table => '...')` | Spark-only on production stack |
| Compact position deletes | NOT AVAILABLE in Trino (roadmap) | `CALL system.rewrite_position_delete_files(table => '...')` | Spark-only — directly addresses delete-files-piling-up |

The teacher should also fix the ordering contradiction in `resources/13-iceberg-table-maintenance.md` (or wherever the four-step sequence lives): the numbered ordering MUST be `compact → expire → orphan → manifests`, matching the inline justification.

## What worked

- Sticky-notes-on-a-ledger analogy is genuinely excellent for beginners.
- 4-step Trino read-overhead breakdown (read data file → load delete file → cross-reference → filter) is accurate and clear.
- 7-day floor caveat with Spark GDPR workaround is correct and production-relevant.
- "Don't skip weekly expire_snapshots after compaction" warning correctly explains why compaction alone doesn't free storage.
- `expire_snapshots(retention_threshold => '30d')` and `optimize(file_size_threshold => '128MB')` syntax is correct Trino.

## Recommended teacher action

1. **Fix the ordering contradiction in `resources/13-iceberg-table-maintenance.md`**: ensure the numbered list and the inline justification BOTH say compact → expire → orphan → manifests. The current resource appears to have them in different orders.

2. **Add `rewrite_position_delete_files` as a first-class procedure** in the maintenance section, explicitly labeled "Spark-only — Trino roadmap item not yet shipped". This is the most targeted procedure for the delete-files-piling-up problem the question describes; omitting it is the largest completeness gap.

3. **Add an engine-context matrix** (Trino 467 vs Spark Iceberg 1.5.2) for the five procedures showing syntax differences, dry_run availability differences, and version-availability gotchas (`optimize_manifests` needs Trino 470+, `rewrite_position_delete_files` Spark-only).

4. **Clean up the Spark/Trino syntax mixing** in the four-step example block — the resource appears to have Spark CALL syntax in code blocks meant to look like Trino runbooks. Engineer copying these into Trino 467 hits syntax errors immediately.

## Resource gaps identified

- `resources/13-iceberg-table-maintenance.md` (or the equivalent file): ordering contradiction in the canonical four-step sequence; needs single source of truth on order.
- Missing dedicated section on `rewrite_position_delete_files` for V2 MOR tables with delete file pileup — exactly the question's framing.
- Missing Trino 467 vs Trino 470 version gap callout for `optimize_manifests` — production stack relevant.
- Missing explicit Spark CALL vs Trino ALTER TABLE EXECUTE syntax matrix.

## Iter 351 final summary

| Question | Topic | Score | Result |
|---|---|---|---|
| Q1 | Multi-tenant analytics — Trino selector regex (source field, -prod suffix, 4th probe) | 5.00 | PERFECT PASS |
| Q2 | Iceberg maintenance — delete file pileup, what they are, what to run periodically | 3.00 | **FAIL** |
| **Iteration avg** | | **4.00** | **MIXED** |

Topic average updates:
- Multi-tenant analytics: 4.443/142 → **4.447/143 questions** (PASSED — selector regex fix generalized across user/source × prefix/suffix)
- Iceberg table maintenance: 4.603/36 → **4.560/37 questions** (still PASSED, but first significant FAIL after a long strong-PASS streak — exposes ordering contradiction, missing `rewrite_position_delete_files`, Spark/Trino syntax confusion, Trino 467 version-fit gap on `rewrite_manifests`)

This iteration is a strong reminder that "topic PASSED" status can mask sub-topic gaps. Iceberg maintenance has 36 prior questions averaging 4.603 — but the V2 delete-files-piling-up sub-angle was apparently not covered with the depth needed. Iter352 should probe this sub-topic again (or an adjacent one — `rewrite_position_delete_files` for V2 tables, `optimize_manifests` Trino version gap, dry_run engine asymmetry) AFTER the teacher addresses the four resource gaps above.

---

## Iter 351 End-of-Iteration Summary

**Date**: 2026-05-29
**Phase**: extended
**Iteration verdict**: 4.00 average — marginal PASS (Q1 PERFECT, Q2 FAIL)

### Scores table

| Question | Topic | Sub-angle | Score | Result |
|---|---|---|---|---|
| Q1 | Multi-tenant analytics | Trino resource group selector regex — source field, `-prod` suffix (4th probe of find()/matches() bug) | 5.00 | PERFECT PASS |
| Q2 | Iceberg table maintenance | V2 MOR delete-file pileup — what delete files are, why they slow Trino, what to run periodically | 3.00 | FAIL |
| **Iteration average** | | | **4.00** | **MIXED (marginal PASS)** |

### Q1 win — selector regex fix confirmed structurally durable

The iter350 surgical fix to `resources/05` lines 2253-2445 (CRITICAL FACT box moved to FIRST position with svc_billing character-count math + "STOP" directive, declarative FULL-STRING MATCH RULE labeling, fix-before-explanation ordering, inline matches() reminder) has now passed its **structural-durability test** across the full surface area:

| Surface variant | Iteration | Result |
|---|---|---|
| user field, prefix `svc_` | iter348 | FAIL |
| user field, prefix `svc_` (re-probe) | iter349 | FAIL |
| user field, prefix `etl` | iter350 | PASS |
| **source field, suffix `-prod`** (4th probe — different FIELD and different DIRECTION) | **iter351** | **PERFECT PASS** |

The fix generalizes across both the user/source field axis and the prefix/suffix direction axis. The find()/matches() substring bug is structurally resolved. No further selector-regex probes needed for the next several iterations — rotate away.

### Q2 root cause — three intertwined failures pointing to one resource defect

Q2 failed at 3.00/5.00 (technical 2.5, clarity 4.5, applicability 2.5, completeness 2.5). Root cause is a **multi-error answer with one underlying resource defect**: the responder drew from a section that mixes Spark `CALL` and Trino `ALTER TABLE EXECUTE` syntax without engine labels, AND contains an internal ordering contradiction.

1. **Ordering contradiction inside the same answer** — numbered list says `expire → orphan → compact → manifests` while the inline paragraph says `compact → expire → orphan → manifests` (the latter is the canonical Iceberg order per iceberg.apache.org, IOMETE runbook, Dremio docs). Engineer cannot tell which to follow.

2. **`rewrite_position_delete_files` missing entirely** — the question's literal framing is "delete files are piling up", and Iceberg's dedicated minor-compaction-for-delete-files procedure should be the centerpiece. It is not mentioned at all. This is the largest completeness gap.

3. **Spark/Trino syntax confusion** — `remove_orphan_files` shown in Spark `CALL` form with unsupported `dry_run` parameter (Trino uses `ALTER TABLE EXECUTE` and does not accept `dry_run`); `rewrite_manifests` shown in Spark CALL form but presented as runnable from Trino (it is NOT available in Trino 467 — added in Trino 470 as `optimize_manifests`; production stack must run this via Spark). Engineer copy-pasting these into Trino 467 hits immediate syntax errors.

### Suggested focus for iter 352

**Teacher MUST fix resources/17 (Iceberg table maintenance) before the next iter352 probe.** Required edits:

1. **Single source of truth on ordering** — both numbered list and inline justification must say `rewrite_data_files (compact) → expire_snapshots → remove_orphan_files → rewrite_manifests`. Remove the contradictory ordering.

2. **Add `rewrite_position_delete_files` as a first-class procedure** — explicitly labeled Spark-only (Trino roadmap not yet shipped), with both purposes documented (minor compaction of small delete files + removal of dangling deletes after rewrite_data_files).

3. **Engine-context matrix** — Trino 467 vs Spark Iceberg 1.5.2 syntax for all five procedures (compact, expire, orphan, manifests, position-delete-compaction), with dry_run availability differences and the Trino 467 → Trino 470 version gap on `optimize_manifests` explicitly called out.

4. **Clean up Spark/Trino syntax mixing in code examples** — every code block must be labeled with the engine it runs in. No Spark CALL syntax in Trino-flavored runbook blocks.

After teacher fixes land, iter352 should re-probe this sub-topic (delete-file pileup, OR `rewrite_position_delete_files` directly, OR `optimize_manifests` Trino version gap, OR dry_run engine asymmetry) to verify the resource fix took.

### Topic score state at iter 351 end

- Multi-tenant analytics: **4.447/143 questions** — PASSED, selector regex durable
- Iceberg table maintenance: **4.560/37 questions** — still PASSED, but first significant FAIL after long strong-PASS streak; sub-topic gap exposed
- All other topics: unchanged from iter 350 end

### Phase / state

- Phase remains `extended`
- `final_iterations_remaining` remains 0
- `passed` remains true (overall rubric still passing despite this iteration's marginal result)
- Iteration counter advances to 352
