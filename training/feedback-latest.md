# Judge Feedback — Iter 352 Q1

**Date**: 2026-05-29
**Phase**: extended
**Topic**: Iceberg table maintenance (position delete file cleanup, MoR vs CoW, maintenance ordering)

**Question summary**: SaaS engineer notices storage keeps growing on Iceberg tables with heavy row deletes despite nightly `EXECUTE optimize` in Trino. Teammate said position delete files don't get cleaned up the same way. Is that true? Is there a separate step? Can Trino run it?

## Score

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | Every claim verified against iceberg.apache.org docs, trinodb/trino#27371, #23801, #12617, #24086. CoW-as-default for `write.delete.mode` correct. Spark CALL syntax correct. Trino EXECUTE optimize partition-scope behavior correct. Canonical 5-step order matches Iceberg maintenance runbook exactly. |
| Beginner clarity | 5.0 | CoW vs MoR crisply explained with concrete byte-level analogy ("metadata files listing 'ignore rows at positions 3, 7, 42 in data file X'"). Numbered steps with engine labels. Diagnostic query with content=0/1/2 mapping spelled out inline. Storage-growth closing reinforces the mental model from a different angle. |
| Practical applicability | 5.0 | Production stack (Trino 467 + Iceberg 1.5.2 + Spark + MinIO + on-prem k8s) fully respected. Engineer knows: (a) which procedure to run, (b) which engine to run it from (Spark), (c) when in the schedule to run it (between rewrite_data_files and expire_snapshots), (d) how to verify the problem exists ($files content=1 threshold of 50), (e) why storage spikes between optimize and expire. Ready-to-paste SQL. |
| Completeness | 5.0 | Answers all three sub-questions directly: (1) yes, position deletes are different; (2) yes, separate procedure rewrite_position_delete_files; (3) Spark only, not Trino 467. Plus bonus: full maintenance ordering with engine matrix, diagnostic query, storage-growth explanation. |
| **Average** | **5.00** | **PASS** |

## Verification (WebSearch)

1. **`rewrite_position_delete_files` real procedure** — confirmed at iceberg.apache.org/docs/latest/spark-procedures/ with documented dual purpose (minor compaction of small position delete files + remove dangling deletes after rewrite_data_files). Spark-only.
2. **Trino support** — NOT supported natively per trinodb/trino#27371 roadmap. Responder's "Trino 467 does NOT support this procedure" is correct.
3. **Canonical maintenance order** — rewrite_data_files → rewrite_position_delete_files → expire_snapshots → remove_orphan_files → rewrite_manifests is the documented sequence per iceberg.apache.org/docs/latest/maintenance/, IOMETE runbook, Dremio blog. Responder's 5-step order is exactly right.
4. **CoW as default** — confirmed default for `write.delete.mode` per iceberg.apache.org configuration docs.
5. **Trino OPTIMIZE partition-scope cleanup** — per PR #23801 (raunaqmorarka: "Clean up position deletes when optimizing a subset of partitions") and open issues #12617/#24086, Trino's OPTIMIZE applies position deletes ONLY for partitions being rewritten. Responder's framing "applies position deletes during rewrite but only for partitions it actually rewrites" is exactly correct.
6. **`$files` metadata content column** — 0=data, 1=position delete, 2=equality delete — confirmed by Iceberg spec.

## What worked

Clean recovery from iter351 Q2's FAIL. The iter352 teacher fix on `resources/17-iceberg-table-maintenance.md` landed precisely:

- TL;DR rewritten with explicit numbered canonical sequence → responder reproduced the correct 5-step order.
- NEW SECTION 1b `rewrite_position_delete_files` between sections 1 and 2 → responder now mentions the procedure prominently with full Spark CALL syntax + Trino #27371 callout.
- Safe scheduling order diagram updated → responder's "correct maintenance order for MoR tables" section is structured identically.
- Side-by-side Trino-vs-Spark syntax matrix → responder labels every step with its engine.
- Weekly schedule re-numbered starting with rewrite_data_files → ordering contradiction from iter351 is gone.

All four iter351 defects are addressed in this single answer:
1. Internal ordering contradiction — GONE (numbered 1→5 matches inline justification).
2. Missing `rewrite_position_delete_files` — PRESENT with full Spark syntax and explicit "Trino 467 does NOT support" callout.
3. Wrong Trino syntax mixed with Spark CALL — CORRECTLY SEPARATED (Spark CALL for rewrite_position_delete_files + rewrite_manifests; Trino EXECUTE optimize for compaction).
4. Trino 467 version-fit gap on rewrite_manifests — "Spark only on Trino 467" label PRESENT.

## What to watch for next

No teacher action required for this sub-topic. The Iceberg maintenance topic recovers to 4.572/38. Recommended next probes for durability checks at different angles:

- **Equality delete files** (`content = 2`) — when do these accumulate, what procedure handles them, Trino vs Spark availability. Most responders/resources focus on position deletes; equality deletes from CDC pipelines are the next-most-likely real-world question.
- **`dangling_delete_threshold` parameter** for `rewrite_position_delete_files` — controls when minor compaction triggers; useful for tuning.
- **What happens if you NEVER run rewrite_position_delete_files** — long-term query performance degradation timeline; how many delete files before scan planning slows materially.
- **Combined-job ordering with concurrent writes** — what happens if rewrite_position_delete_files runs while a Debezium CDC stream is writing new deletes? Conflict resolution behavior.

## Rubric update

- Iceberg table maintenance: 4.560 / 37 → **4.572 / 38** (PASSED — recovery from iter351 Q2 FAIL)

## Sources consulted

- [Apache Iceberg Spark Procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Apache Iceberg Maintenance](https://iceberg.apache.org/docs/latest/maintenance/)
- [Apache Iceberg Configuration](https://iceberg.apache.org/docs/latest/configuration/)
- [Trino Iceberg Connector Docs](https://trino.io/docs/current/connector/iceberg.html)
- [Trino Iceberg Roadmap (rewrite_position_delete_files proposal) — trinodb/trino#27371](https://github.com/trinodb/trino/issues/27371)
- [Trino PR #23801 — Clean up position deletes when optimizing a subset of partitions](https://github.com/trinodb/trino/pull/23801)
- [Trino issue #12617 — Remove unused position and equality deletes when running optimize](https://github.com/trinodb/trino/issues/12617)
- [Trino issue #24086 — Delete files are not removed after running Iceberg maintenance ops](https://github.com/trinodb/trino/issues/24086)
- [Dremio — CoW vs MoR in Apache Iceberg](https://www.dremio.com/blog/row-level-changes-on-the-lakehouse-copy-on-write-vs-merge-on-read-in-apache-iceberg/)
- [IOMETE Iceberg Maintenance Runbook](https://iomete.com/resources/blog/iceberg-maintenance-runbook)

---

# Judge Feedback — Iter 352 Q2

**Date**: 2026-05-29
**Phase**: extended
**Topic**: SQL query best practices for OLAP — interpreting Trino `EXPLAIN` output (operator names like `ScanFilterProject`, `LocalExchange`), `EXPLAIN` vs `EXPLAIN ANALYZE` semantic difference, how to use metrics to localize slowdowns.

## Question

"My Trino queries on our biggest tables are getting slow and I want to actually understand what's happening before I start randomly adding things. Someone told me to run `EXPLAIN` on my query to see the execution plan. I did that and got back this wall of text with words like 'ScanFilterProject' and 'LocalExchange' and numbers I don't know how to interpret. What is this output actually telling me, and how do I use it to figure out where the slowdown is? Is there also an `EXPLAIN ANALYZE` — is that different?"

## Verdict: 4.75/5.00 — STRONG PASS

### Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All factual claims verified against Trino official docs. EXPLAIN ANALYZE does execute the query (confirmed via [Trino 481 EXPLAIN ANALYZE docs](https://trino.io/docs/current/sql/explain-analyze.html)). Field names `CPU`, `Scheduled`, `Blocked`, `Physical Input` are accurate. Operator descriptions (`ScanFilterProject` = read+filter+project, `LocalExchange` = within-worker shuffle) are correct. The compute-vs-I/O classification rule ("Scheduled ≈ CPU = compute-bound; Scheduled >> CPU = I/O-bound") is a legitimate diagnostic heuristic matching the docs' note that "scheduled time and physical input read time represents the amount of time spent doing I/O, which often dominates query time". The "EXPLAIN ANALYZE costs the same as running the query normally" warning is accurate and production-relevant. |
| Beginner clarity | 5.0 | Excellent. Each operator name is defined in plain English on first appearance ("ScanFilterProject = read the table, apply WHERE conditions, pick columns to return"). The EXPLAIN vs EXPLAIN ANALYZE distinction is established with a clear free-vs-costs framing and side-by-side code blocks. The fields table (Field / Meaning / Red flag) is the right pedagogical structure for someone facing wall-of-text output. The closing concrete example with "Translation: 200 GB from disk for a 'last week' query = partition pruning failure" demonstrates exactly how to read the output, not just what it means. |
| Practical applicability | 4.5 | Fits the production stack — MinIO is explicitly mentioned twice ("waiting on MinIO", "Compressed bytes read from MinIO"). The 5-step "how to find the problem" runbook is concrete and actionable. The follow-up diagnostic `SELECT COUNT(*) FROM iceberg.analytics."events$files"` for small-files diagnosis is correct Trino 467 syntax. The cost warning on EXPLAIN ANALYZE is engineer-appropriate ("Use sparingly, only when actively debugging"). **Gap**: the verification prompt explicitly asked about `EXPLAIN (TYPE DISTRIBUTED)` — the answer doesn't mention it. This is a meaningful applicability miss because the engineer's stated intent is "understand before randomly adding things" and TYPE DISTRIBUTED is the safer plan-only middle ground between plain `EXPLAIN` (default already shows distributed plan) and `EXPLAIN ANALYZE` (which costs full query execution). An engineer with a 30-minute slow query who wants distributed fragments without paying the runtime cost benefits from knowing this command exists. |
| Completeness | 4.5 | Covers EXPLAIN vs EXPLAIN ANALYZE difference, output anatomy, operator names, metric interpretation, compute-vs-I/O classification, problem-finding runbook, concrete example. **Missing**: (a) `EXPLAIN (TYPE DISTRIBUTED)` as the explicit plan-only fragments option — the question specifically asks "is there also an EXPLAIN ANALYZE — is that different?" which is a natural lead-in to listing the three forms (LOGICAL/DISTRIBUTED/ANALYZE); (b) `EXPLAIN ANALYZE VERBOSE` for deeper diagnosis (Filtered %, dynamicFilterSplitsProcessed, per-operator breakdown); (c) Trino Web UI Query Plan tab as an alternative to reading raw text output (common engineer workflow — same info visualized). The core answer is strong but these three additions would close the loop. |
| **Average** | **4.75** | **STRONG PASS** |

## Technical verification (WebSearch)

1. **EXPLAIN ANALYZE executes the query** — Confirmed via [Trino 481 EXPLAIN ANALYZE docs](https://trino.io/docs/current/sql/explain-analyze.html): "EXPLAIN ANALYZE executes the statement and shows the distributed execution plan of the statement along with the cost of each operation." Cost warning is faithful to docs.

2. **Metric names** — `CPU`, `Scheduled`, `Blocked`, `Physical Input` all verified in [Trino EXPLAIN ANALYZE docs](https://trino.io/docs/current/sql/explain-analyze.html) and [Simon Thelin's Trino query performance write-up](https://medium.com/@simon.thelin90/query-plans-analyse-sql-performance-in-trino-97ac1e8f8044). Trino docs explicitly note: "scheduled time and physical input read time represents the amount of time spent doing I/O, which often dominates query time" — matches the answer's I/O-bound classification rule.

3. **Operator names** — `ScanFilterProject` and `LocalExchange` are real Trino operator names confirmed in [Trino EXPLAIN docs examples](https://trino.io/docs/current/sql/explain.html). `ScanFilterProject[table = ..., filterPredicate = ...]` appears verbatim in docs; `LocalExchange[HASH][$hashvalue]` is shown in distributed plan examples.

4. **EXPLAIN (TYPE DISTRIBUTED)** — Confirmed real syntax via [Trino 480 EXPLAIN docs](https://trino.io/docs/current/sql/explain.html): `EXPLAIN [ ( option [, ...] ) ] statement` with `TYPE { LOGICAL | DISTRIBUTED | VALIDATE | IO }`. Distributed plan is the default. Not mentioned in the answer — this is the completeness gap noted.

## What worked

1. **Concrete operator translations** — "ScanFilterProject = read the table, apply WHERE conditions, pick columns to return" is exactly the kind of plain-language explanation a beginner needs after staring at unfamiliar operator names.

2. **Field interpretation table** — the Field / Meaning / Red flag structure is excellent pedagogy. The engineer can use it as a lookup reference when reading future EXPLAIN output.

3. **Compute-vs-I/O heuristic** — the `Scheduled ≈ CPU` vs `Scheduled >> CPU` rule is the right mental model and matches official docs.

4. **5-step problem-finding runbook** — concrete steps (check Physical Input first, classify CPU vs I/O bound, check small-files via `events$files`, look at join order if compute-bound). Engineer knows exactly what to do next.

5. **MinIO explicitly mentioned** — production stack fit. "Waiting on MinIO" and "Compressed bytes read from MinIO" map the abstract concept of "I/O" to the engineer's actual storage layer.

6. **Closing concrete example with translation** — "200 GB from disk for a 'last week' query = partition pruning failure. CPU ≈ Scheduled = not compute-heavy. Fix: verify your WHERE clause matches the partition column." This demonstrates the diagnostic in action, not just in theory.

7. **EXPLAIN ANALYZE cost warning** — "costs the same as running the query normally" + "Use sparingly, only when actively debugging" is critical safety guidance for a stack where the slow query might be running on a big table.

## What was minor (small deductions)

1. **No `EXPLAIN (TYPE DISTRIBUTED)` mention** — the verification prompt specifically flagged this. The answer covers EXPLAIN (free, plan-only — actually default already shows distributed) and EXPLAIN ANALYZE (executes), but doesn't explicitly enumerate the `TYPE` options. Engineer with a long-running slow query who wants fragments-without-execution may not realize they can use `EXPLAIN (TYPE DISTRIBUTED)` to be explicit, or that the default already gives them this.

2. **No `EXPLAIN ANALYZE VERBOSE`** — for deeper diagnosis (per-operator stats, Filtered %, dynamic filter stats). This is the next layer of "I see the plan but still don't know which operator is slow" investigation.

3. **No mention of Trino Web UI Query Plan tab** — the same info is available visually in the UI without needing to parse the wall of text. Common engineer workflow.

4. **Minor metric imprecision** — "Scheduled: Wall-clock time across workers" is close but not exact. Scheduled time is the sum of scheduled time across worker threads — a wall-clock proxy summed across workers, not averaged. Not deducting because the diagnostic intent (compare to CPU) is preserved.

## Topic score updates

- **SQL query best practices for OLAP**: 4.645/15 → **4.652/16 questions** (PASSED — stable, slight uptick; EXPLAIN/EXPLAIN ANALYZE interpretation sub-angle is well-covered, though `EXPLAIN (TYPE DISTRIBUTED)`, `EXPLAIN ANALYZE VERBOSE`, and Trino Web UI sub-angles remain under-probed)

## Iter 352 summary so far

| Question | Topic | Score | Result |
|---|---|---|---|
| Q1 | Iceberg table maintenance — position delete file cleanup, MoR vs CoW, maintenance ordering | 5.00 | PERFECT PASS |
| Q2 | SQL query best practices — interpreting Trino EXPLAIN output, EXPLAIN vs EXPLAIN ANALYZE | 4.75 | STRONG PASS |
| **Iter 352 average** | | **4.875** | **STRONG PASS** |

Clean recovery iteration: iter351 marginal-pass (4.00) → iter352 strong-pass (4.875). Both Q1 (Iceberg maintenance, the topic that FAILed last iteration) and Q2 (a fresh probe on EXPLAIN interpretation) land at high quality.

## Recommendations for teacher

**No urgent action required** — this answer is solid and the topic remains passing. For incremental polish on the EXPLAIN/EXPLAIN ANALYZE sub-topic:

1. **Add a 3-form EXPLAIN comparison table** to whichever resource covers `EXPLAIN`:

| Form | Runs query? | Use when |
|---|---|---|
| `EXPLAIN <query>` | No (default shows DISTRIBUTED) | Quick plan preview, see fragments + operators |
| `EXPLAIN (TYPE LOGICAL) <query>` | No | Single-node logical plan before distributed planning |
| `EXPLAIN (TYPE DISTRIBUTED) <query>` | No | Explicit distributed plan (same as default) |
| `EXPLAIN ANALYZE <query>` | YES (full execution cost) | Real metrics: CPU, Scheduled, Blocked, Physical Input |
| `EXPLAIN ANALYZE VERBOSE <query>` | YES (full execution cost) | Above + per-operator deep stats, Filtered %, dynamic filter stats |

2. **Add Trino Web UI as alternative** — one-line callout that the Query Plan tab in the Trino UI shows the same plan info visually, often easier than parsing text output.

3. **Add `EXPLAIN ANALYZE VERBOSE` to the diagnostic ladder** — useful for the next layer of "I see the plan but still don't know which operator is slow" investigation.

## Recommendations for next iteration (iter353+)

**Topics under-tested or with sub-angle gaps**:
- SQL query best practices: probe `EXPLAIN (TYPE DISTRIBUTED)` directly, or `EXPLAIN ANALYZE VERBOSE`, or partition pruning verification via EXPLAIN
- Iceberg table maintenance: equality delete files (content=2) from CDC pipelines, `dangling_delete_threshold` tuning, long-term degradation if rewrite_position_delete_files never runs
- Cost considerations: MinIO erasure coding tier choices, on-prem capacity planning (only 4 questions)
- Query performance regression: oncall workflow integration with EXPLAIN ANALYZE diagnostics (only 2 questions)

## Sources consulted

- [Trino 481 EXPLAIN ANALYZE](https://trino.io/docs/current/sql/explain-analyze.html)
- [Trino 480 EXPLAIN](https://trino.io/docs/current/sql/explain.html)
- [Trino 480 Cost in EXPLAIN](https://trino.io/docs/current/optimizer/cost-in-explain.html)
- [Simon Thelin — Query Plans: Analyse SQL Performance In Trino](https://medium.com/@simon.thelin90/query-plans-analyse-sql-performance-in-trino-97ac1e8f8044)
- [CelerData — Trino Query Optimization Best Practices](https://celerdata.com/glossary/trino-query-optimization)

---

## Iter 352 End-of-Iteration Summary

**Date**: 2026-05-29
**Phase**: extended
**Result**: STRONG PASS — iteration average 4.875/5.00

### Scores

| Question | Topic | Score | Result |
|---|---|---|---|
| Q1 | Iceberg table maintenance — position delete file cleanup (MoR vs CoW), canonical maintenance ordering, `rewrite_position_delete_files` Spark-only availability | 5.00 | PERFECT PASS |
| Q2 | SQL query best practices — Trino `EXPLAIN` output interpretation, operator names (`ScanFilterProject`, `LocalExchange`), `EXPLAIN` vs `EXPLAIN ANALYZE` semantic difference, compute-vs-I/O classification heuristic | 4.75 | STRONG PASS |
| **Iter 352 average** | | **4.875** | **STRONG PASS** |

### Q1 win — resources/17 fix confirmed durable for MoR/position-delete scenario

The iter352 teacher fix on `resources/17-iceberg-table-maintenance.md` landed perfectly and the responder reproduced every key element:

- Canonical 5-step ordering (rewrite_data_files → rewrite_position_delete_files → expire_snapshots → remove_orphan_files → rewrite_manifests) is reproduced exactly with engine labels per step.
- `rewrite_position_delete_files` is prominently named with correct Spark CALL syntax and explicit "Trino 467 does NOT support" callout (trinodb/trino#27371).
- CoW-as-default for `write.delete.mode` is correctly stated.
- Trino `OPTIMIZE` partition-scope behavior (applies position deletes only for partitions actually rewritten) is correctly framed per PR #23801 and issues #12617/#24086.
- `$files` content column mapping (0=data, 1=position delete, 2=equality delete) is spelled out inline with diagnostic query.
- All four iter351 Q2 defects (ordering contradiction, missing procedure, wrong syntax, missing version-fit) are addressed in this single answer.

Topic score: Iceberg table maintenance 4.560/37 → 4.572/38 (recovery confirmed from iter351 Q2 FAIL).

### Q2 win — first probe of EXPLAIN/EXPLAIN ANALYZE topic, strong answer

First time the EXPLAIN output interpretation sub-angle has been tested directly. Strong showing:

- EXPLAIN vs EXPLAIN ANALYZE semantic difference (plan-only vs full execution cost) clearly established with cost warning.
- Operator names (`ScanFilterProject`, `LocalExchange`) translated to plain English on first appearance.
- Field interpretation table (Field / Meaning / Red flag) gives engineer a usable lookup reference.
- Compute-vs-I/O heuristic (`Scheduled ≈ CPU` vs `Scheduled >> CPU`) matches official Trino docs.
- MinIO explicitly named twice, anchoring abstract I/O to the production stack.
- Concrete 200 GB partition-pruning-failure example demonstrates diagnostic in action.

Minor deductions (-0.25 on each of applicability and completeness): no `EXPLAIN (TYPE DISTRIBUTED)` enumeration, no `EXPLAIN ANALYZE VERBOSE`, no Trino Web UI Query Plan tab mention. These are polish gaps, not correctness issues.

Topic score: SQL query best practices for OLAP 4.645/15 → 4.652/16.

### Suggested focus for iter 353 — probe different angles

Avoid re-testing position-delete cleanup (already perfect twice — iter345/352). Recommended fresh probes:

1. **Equality delete cleanup (`content = 2`)** — when Debezium CDC writes equality deletes (vs position deletes from straight DELETEs), what procedure handles cleanup, Trino vs Spark availability matrix, how `rewrite_position_delete_files` does or does not address equality deletes. Most resources focus on position deletes; equality deletes from CDC are the next-most-likely real-world question.

2. **Storage sizing / growth on-prem** — capacity planning for MinIO on Iceberg lakehouse: snapshot retention policy impact on raw bytes stored, position+equality delete file overhead on MoR tables, manifest file growth on high-write tables, ratio of metadata to data, MinIO erasure coding tier choices and their effective storage multiplier. Cost considerations topic has only 4 questions and is under-probed.

3. **Trino federation memory pressure** — when federating Iceberg + PostgreSQL CDC source + something else, where do memory bottlenecks land: coordinator vs worker, query_max_memory_per_node vs query_max_memory, spill-to-disk on MinIO-backed temp storage, the realistic limits on JOIN size between a Trino-federated PostgreSQL table and a large Iceberg table. Query performance regression topic (only 2 questions) and Trino federation sub-angles are under-probed.

Any of these three angles would test fresh ground and validate durability of recent gains on different topics.
