# Judge Feedback — Iter 376 (EXTENDED PHASE)

**Iteration average: 4.5625 — STRONG PASS**

| Question | Topic | TA | BC | PA | Comp | Avg | Result |
|---|---|---|---|---|---|---|---|
| Q1 | Trino web UI slow query diagnosis | 4.75 | 4.0 | 4.75 | 4.5 | **4.50** | STRONG PASS |
| Q2 | Iceberg cross-table atomic transactions | 5.0 | 4.25 | 4.75 | 4.5 | **4.625** | STRONG PASS |

---

## Q1 — Trino web UI slow query diagnosis

**What worked:** All technical claims verified against Trino 480/481 docs:
- CPU vs Scheduled time framing accurate (Scheduled = CPU + per-thread blocked time)
- Physical Input Data Size as partition-pruning indicator confirmed per EXPLAIN ANALYZE docs
- BLOCKED query state and Blocked Time metric confirmed
- Spilled Data Size in web UI confirmed (Trino PR #161)
- Queued state as concurrency/resource-group saturation indicator correct
- EXPLAIN ANALYZE vs EXPLAIN (TYPE DISTRIBUTED) distinction correct (latter is plan-only, does not execute)

**Gaps:**
- BC -1.0: Trino UI vocabulary cascade (Queued, Scheduled time, Physical Input, Blocked:Input, Spilled Data, EXPLAIN ANALYZE, TYPE DISTRIBUTED) used without inline plain-English glosses at first mention. Same systemic gloss-gap as iter375.
- TA -0.25: "CPU≈Scheduled" framing is a useful heuristic but technically Scheduled = CPU + per-thread-blocked-time summed across threads, so on highly parallel CPU-bound queries you can see Scheduled > CPU just from parallelism. Minor framing imprecision.
- PA -0.25: Did not surface the specific web UI click-path (Stages tab, Live Plan view) — engineer told WHAT to look at but not WHERE to click.
- Comp -0.5: Missing the "EXPLAIN ANALYZE actually executes the query so do not run it casually on already-slow queries" warning; missing Live Plan inspection for in-flight queries; missing `system.runtime.queries` / `system.runtime.tasks` SQL-queryable alternative.

---

## Q2 — Iceberg cross-table atomic transactions

**What worked:** Core claim is correct and well-verified:
- Iceberg native API supports atomic transactions on a single table only (per apache/iceberg Java API docs)
- Open issue #10617 confirms multi-table transaction API is a feature request, not native
- HMS-backed Iceberg in Trino (production stack per prod_info.md) inherits per-table-only semantics; HMS struggles even with concurrent single-table writes per Trino issue #27942
- Workaround pattern (additive write first, verify, then destructive operation) is the standard data-engineering idempotent-write convention for warehouses lacking cross-table tx
- Explicit "no BEGIN...COMMIT spanning multiple tables" is accurate and important for an engineer with OLTP mental model

**Gaps:**
- BC -0.75: "Atomic", "idempotent", "destructive operation", "reconciliation" used without inline glosses. A SaaS engineer with OLTP background may know "atomic" but newcomers to lakehouse semantics need "atomic = all-or-nothing, either every row commits or none do" plain-English gloss at first mention.
- PA -0.25: Workaround pattern is described but no concrete Trino SQL example showing the two-statement sequence (INSERT INTO additive_table SELECT ... then DELETE FROM source WHERE ...) on the production Iceberg 1.5.2 + Trino 467 + HMS stack.
- Comp -0.5: Did not mention catalog-level alternatives (Nessie branch-merge, Databricks Unity Catalog multi-statement tx) even with the explicit "not part of your on-prem HMS production stack" caveat — engineer would benefit from knowing WHY their HMS setup has this limit and what does solve it. Did not surface the three operational failure shapes (write-then-crash partial commit / write-then-rollback / concurrent-writer-conflict). Did not mention dbt-test reconciliation as the concrete monitoring implementation hook (prod_info.md confirms dbt is supported).

---

## ITER377 TEACHER ACTIONS (PRIORITY-ORDERED)

1. **HIGH (clarity, systemic 16th-iter-flagged gloss-at-first-mention gap)** — Inline glossary in `resources/` for:
   - Trino UI terms: Queued, Scheduled time vs CPU time, Physical Input Data Size, Blocked Time, Spilled Data Size, EXPLAIN ANALYZE, TYPE DISTRIBUTED
   - Lakehouse transaction terms: atomic, idempotent, destructive operation, partial commit
   - One-line plain-English gloss per term, placed before the diagnostic / workaround recommendation, not after.

2. **HIGH (completeness)** — Add Trino web UI click-path section: which tab to open (Stages, Live Plan), how to find a specific query by ID, how to read the operator-level metrics table. Engineer is told WHAT to look at but not WHERE to click.

3. **MEDIUM (completeness)** — Add catalog-level alternatives section for Iceberg cross-table transactions: Nessie branch-merge, Unity Catalog multi-statement tx — with explicit on-prem HMS production caveat that neither is part of the production stack but knowing WHY HMS lacks it helps engineer reason about limitations.

4. **MEDIUM (completeness)** — Add EXPLAIN ANALYZE warning: it actually executes the query, so on an already-slow query do not run it casually; use EXPLAIN (TYPE DISTRIBUTED) for plan-only. Surface the "free vs paid" distinction explicitly.

5. **MEDIUM (practical)** — Add concrete Trino SQL two-statement workaround sequence (INSERT INTO additive_table SELECT ... → verify counts → DELETE FROM source_table WHERE ...) on Iceberg 1.5.2 + Trino 467 + HMS, plus dbt-test reconciliation example.

6. **LOW (carry-forward iter375)** — `memory.heap-headroom-per-node` constraint and 25%-vs-30% heap framing; federation glossary (CBO/BROADCAST/PARTITIONED) open since iter360; HyperLogLog gloss open since iter372; MinIO TCO decomposition open since iter374.

---

## ITER377 JUDGE PROBE TARGETS

1. **Trino UI live-plan reading**: "I see my query stuck in RUNNING for 8 minutes — where in the web UI do I look to see WHICH operator is slow right now, while it's still running?" — tests action #2 (Live Plan click path).
2. **EXPLAIN ANALYZE warning**: "EXPLAIN ANALYZE timed out on my slow query too. What do I run instead to see the plan?" — tests action #4 (EXPLAIN TYPE DISTRIBUTED as plan-only).
3. **Iceberg cross-table tx workaround SQL**: "Show me the actual SQL to safely move 1M rows from staging_events to events without leaving the table in a half-committed state." — tests action #5.
4. **Catalog-level alternative**: "Is there any catalog setup that would give me real cross-table atomic transactions on Iceberg?" — tests action #3 (Nessie / Unity awareness with on-prem HMS caveat).
5. Carry-forward iter375 federation glossary (CBO/BROADCAST/PARTITIONED) open since iter360.
6. Carry-forward iter375 Trino S3 filesystem config / MinIO TCO open since iter374.

---

## PATTERN OBSERVATIONS

- (a) Iter376 4.5625 STRONG PASS continues iter370-376 stabilizing 4.2-4.6 band; both answers technically accurate, no factual errors.
- (b) **Shared systemic pattern**: property/term-name density without inline gloss-at-first-mention is the dominant BC drag (Q1 BC=4.0, Q2 BC=4.25). Same pattern across iter375 (BC=4.0 on both Qs) and federation BC ceiling since iter360. This is the most durable improvement target across the loop.
- (c) Production-fit landed cleanly: Q2 implicitly assumes HMS production stack (no Nessie/Unity push); Q1 web UI is the on-prem deployment view.
- (d) "Query performance regression diagnosis" topic now at 4.771/4 questions — durability proof builds, no longer a 1-question PASS.
- (e) Both Q1 and Q2 missed an "alternatives you do NOT have but should know exist" callout — would lift completeness without bloating the answer (Q1: system.runtime SQL view; Q2: Nessie/Unity catalog-level cross-table tx).
- (f) Q1 framing of CPU vs Scheduled as compute-bound vs I/O-bound is technically defensible but oversimplifies — Scheduled > CPU can also reflect scheduling overhead on highly parallel queries, not just I/O wait.

---

## SOURCES VERIFIED (WebSearch)

- [Web UI — Trino 480 Documentation](https://trino.io/docs/current/admin/web-interface.html)
- [EXPLAIN ANALYZE — Trino 481 Documentation](https://trino.io/docs/current/sql/explain-analyze.html)
- [Faster Query Processing: CPU Time — Starburst](https://www.starburst.io/blog/faster-query-processing-cpu-time/)
- [Add spilled data to query stats, CLI, and Web UI — Trino PR #161](https://github.com/trinodb/trino/pull/161)
- [Java API — Apache Iceberg](https://iceberg.apache.org/docs/nightly/api/?h=transaction)
- [Add Multi-Table Transaction API · Issue #10617 · apache/iceberg](https://github.com/apache/iceberg/issues/10617)
- [Nessie — Apache Iceberg](https://iceberg.apache.org/docs/nightly/nessie/?h=transaction)
- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html)
- [Iceberg Connector using the Hive Metastore doesn't handle concurrent writes — Trino Issue #27942](https://github.com/trinodb/trino/issues/27942)
- [Multi-Format, Multi-Table, Multi-Statement Transactions on Unity Catalog — Databricks DAIS 2025](https://www.databricks.com/dataaisummit/session/multi-format-multi-table-multi-statement-transactions-unity-catalog)
