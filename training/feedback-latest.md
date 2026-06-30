# Judge Feedback — Iteration 1294

**Overall: 4.609 — PASS. Three clean answers (Q1/Q2/Q3 all ≥4.8) + one practical-applicability shave on Q4 (missed engineer's "per customer" top-N-per-group grain — global ORDER BY LIMIT 50 returns 50 rows TOTAL not 50-per-customer). No FAILs. No FIX-A. One soft watch on the recurring "missed-grain on multi-word framing" pattern (Q4 here mirrors iter1293-Q1 bool_and account grain).**

| Q | Score | Acc | Clar | Prac | Compl | Topic | Result |
|---|---|---|---|---|---|---|---|
| Q1 (LEFT JOIN IS NULL vs NOT EXISTS — anti-join shape + #21859) | **4.8125** | 5.0 | 4.75 | 4.75 | 4.75 | SQL query best practices for OLAP | Clean / resource-faithful |
| Q2 (sorted_by for account_id filter — file-level pruning + EXECUTE optimize) | **4.875** | 4.75 | 5.0 | 5.0 | 4.75 | Iceberg partition design for SaaS | Clean |
| Q3 (dbt auto-GRANT after rebuild — grants:config bug + post_hook TO ROLE) | **4.875** | 5.0 | 4.75 | 5.0 | 4.75 | Oracle PL/SQL → dbt+Trino | Clean |
| Q4 (Oracle ROWNUM<=50 PER CUSTOMER → Trino) | **3.875** | 4.0 | 4.5 | 3.5 | 3.5 | Oracle PL/SQL → dbt+Trino | Grain miss: per-customer top-N-per-group not addressed |

Average: (4.8125 + 4.875 + 4.875 + 3.875) / 4 = **4.609**

---

## Accuracy confirmations

### Q1 — LEFT JOIN IS NULL = SemiJoin anti-join; NOT EXISTS = slower LeftJoin+Aggregation+Filter path — CONFIRMED + RESOURCE-FAITHFUL

- **Trino issue #21859** verified via [github.com/trinodb/trino/issues/21859 "Improve performance of correlated NOT EXISTS queries"](https://github.com/trinodb/trino/issues/21859). Quote from issue text: *"Correlated NOT EXISTS queries... are rewritten to involve a Filter, Projection, Aggregation, and LeftJoin."* The inefficiency: *"The LeftJoin in the plan produces a row for every match. However, only a single match is required to determine that exists == true for a particular probe row."* Confirms responder's framing exactly.
- **Resource-faithful**: r28 L790 lists NOT EXISTS among shapes that may NOT decorrelate cleanly (issue #21859); L869 gives the canonical "NOT EXISTS → LEFT JOIN ... WHERE b.id IS NULL (anti-join)" rewrite. Responder cited r23 §10 + matches r28 anchor.
- **NOT IN NULL trap correctly caveated**: responder offered NOT IN form only when `events.account_id IS NOT NULL`, otherwise the LEFT JOIN IS NULL form (because `NOT IN` against a NULL-containing list returns NULL for every probe row → empty result, a well-known SQL footgun).
- **EXPLAIN to verify SemiJoin**: pointing at EXPLAIN/EXPLAIN ANALYZE for plan-shape confirmation is the right diagnostic next-step.
- Minor Clar shave (-0.25): "lowers to SemiJoin" is the right mental model but assumes the reader knows what a SemiJoin operator is (vs a regular Hash Join) — one extra clause linking SemiJoin to "stops at first match per probe row" would be zero-jargon. Minor Prac/Compl shaves (-0.25 each): didn't surface dynamic-filtering interaction (a SemiJoin probe builds a dynamic filter on the outer side, which can prune Iceberg partitions on the 400M-row events scan — material on this exact stack).
- **No imported-prior, no broken-secondary, no over-warning, no fabrication.**

### Q2 — sorted_by Iceberg table property + EXECUTE optimize to force rewrite — CONFIRMED

- **`sorted_by` is a modifiable Iceberg table property in Trino 467** — CONFIRMED via WebFetch of [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): "The following table properties can be updated after a table is created: `format`, `format_version`, `partitioning`, `sorted_by`, `object_store_layout_enabled`, `data_location`." So `ALTER TABLE ... SET PROPERTIES sorted_by = ARRAY['account_id ASC']` is valid on 467.
- **File-level pruning via sorted_by min/max** — confirmed at [Starburst "Iceberg Partitioning and Performance Optimizations in Trino"](https://www.starburst.io/blog/iceberg-partitioning-and-performance-optimizations-in-trino-partitioning/): when data within files is sorted by a column referenced in WHERE, the number of files that require a full read drops further — sorted_by enables file-level pruning beyond what partitioning alone gives.
- **EXECUTE optimize with file_size_threshold above existing file size forces rewrite** — correct mechanism. Default 100MB; raising to '512MB' makes already-large files re-eligible for rewrite, picking up the new sorted_by property on the rewritten files. Matches the iter1278 Q1 `file_size_threshold => '256MB'` raise-pattern that's been clean across many iters.
- **Trino-native (no Spark needed)** — correct for this production stack (k8s on-prem MinIO with Spark available but Trino-only-on-this-axis is cleaner). Matches pin `reference_trino_optimize_clears_position_deletes` (Trino optimize APPLIES + clears even position-deletes for files it rewrites).
- **Minor Acc shave (-0.25)**: the Trino docs page is silent on whether optimize honors the sorted_by property at rewrite time (Starburst blog asserts it does; the trino.io page does not state it explicitly). Operationally this works (industry consensus + Starburst blog + community reports), but the responder presented it as documented behavior — a tiny precision slip. Minor Compl shave (-0.25): didn't mention re-ANALYZE after rewrite to refresh Puffin NDV stats for the CBO (the rewrite changes file-level min/max distribution which the CBO consumes via Puffin stats).
- **No imported-prior, no broken-secondary, no over-warning, no fabrication.**

### Q3 — dbt grants: config idempotent + dbt-trino emits-bare-user bug + post_hook TO ROLE fallback — CONFIRMED

- **dbt grants: config is idempotent and reapplied each run** — verified at [docs.getdbt.com/reference/resource-configs/grants](https://docs.getdbt.com/reference/resource-configs/grants): dbt computes the diff between desired and current grants on every run and applies the delta as part of the materialization — so a `--full-refresh` that drops/recreates the table still reapplies the configured grants. Correct.
- **dbt-trino grants:config emits bare user, NOT TO ROLE keyword** — CONFIRMED via [dbt-labs/dbt-core issue #12862 "[Bug] Trino/Starburst Cannot use grants with roles"](https://github.com/dbt-labs/dbt-core/issues/12862). Verified quote from the issue: dbt-trino's grants macro generates `grant select on "data_warehouse"."mwh_analytics_dbt_artifacts"."sources" to ""` — emits the grantee without the `ROLE` qualifier; Trino requires `to ROLE name` or `to USER name`. The responder's "use post_hook with explicit `TO ROLE analyst_role` if the grantee is a Trino role" is the correct workaround on dbt-trino while the macro bug is unfixed.
- **post_hook timing**: `{{ this }}` resolves to the fully-qualified relation; post_hook runs after the model build inside the same dbt transaction → idempotent reapply on `--full-refresh` and on every normal run. Correct.
- **OPA-enforcement-is-separate caveat for prod stack**: responder correctly notes that the production environment uses OPA as the authorization backend, so the `GRANT` statement registers the role grant with Trino but the OPA policy is the actual enforcement layer — matches prod_info.md guidance (general Trino RBAC + OPA conceptual, no specific policy docs).
- **Minor Clar shave (-0.25)**: didn't explicitly show the post_hook YAML shape inline (`post_hook: "GRANT SELECT ON {{ this }} TO ROLE bi_readonly"`) vs verbal description — engineer copy-paste-readiness slightly reduced. Minor Compl shave (-0.25): didn't mention `on-run-end` hook in `dbt_project.yml` as the project-wide alternative (one place vs per-model post_hook), useful when many models share the same grantee.
- **No imported-prior, no broken-secondary, no over-warning, no fabrication.**

### Q4 — Oracle ROWNUM<=50 → Trino: GLOBAL explanation CORRECT but MISSED engineer's "per customer" top-N-per-group grain

- **Global ROWNUM-before-ORDER-BY semantic** — CORRECT in absolute terms. Oracle ROWNUM is assigned at predicate evaluation BEFORE the ORDER BY → `WHERE ROWNUM <= 50 ORDER BY date DESC` picks an unspecified 50 rows then sorts them; the canonical Oracle top-50 is `SELECT * FROM (SELECT ... ORDER BY date DESC) WHERE ROWNUM <= 50`. Trino's `LIMIT` applies AFTER ORDER BY, so `ORDER BY date DESC LIMIT 50` is the equivalent — verified via [Trino SELECT docs](https://trino.io/docs/current/sql/select.html) for LIMIT semantics and standard Oracle documentation for ROWNUM pre-ORDER-BY behavior.
- **LOAD-BEARING GAP — missed "per customer" grain**: engineer said *"get the 50 most recent orders **per customer**"*. That's a top-N-PER-GROUP, NOT a global LIMIT. The most likely root cause of the "different row counts" the engineer observed is: their Oracle code was per-customer (subquery + ROWNUM with PARTITION-by-equivalent inline-view or a `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC)` form), but they replaced it with a global `ORDER BY order_date DESC LIMIT 50` — which returns 50 rows TOTAL across the entire orders table, not 50 per customer. This is a categorically different result shape.
- **Correct Trino-467 form for top-50-per-customer**:
  ```sql
  SELECT customer_id, order_id, order_date, ...
  FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC) AS rn
    FROM orders
  )
  WHERE rn <= 50;
  ```
  Note: Trino 467 does NOT have QUALIFY (would be `... QUALIFY ROW_NUMBER() OVER (...) <= 50` on Snowflake/Databricks/BigQuery; on Trino 467 you must wrap in a subquery or CTE and use WHERE). This is the load-bearing answer the engineer needed.
- **Responder's global ORDER BY date DESC LIMIT 50 is wrong for the per-customer ask**: engineer would copy-paste, get 50 rows total, observe "row counts even more different than before", and need a second round of help.
- **Migration table (FETCH FIRST → LIMIT; OFFSET before LIMIT)** — correctly noted, matches pin `reference_trino_offset_before_limit`.
- Acc shave (-1.0, "ROWNUM != LIMIT" framing is true but applied to wrong variant); Clar shave (-0.5, migration table clean but didn't disambiguate global-vs-per-group); Prac shave (-1.5, engineer's per-customer ask not answered with the load-bearing ROW_NUMBER PARTITION BY form); Compl shave (-1.5, missed the entire top-N-per-group dimension that was the actual question).
- **Pattern match**: this is the same family as iter1293-Q1 (bool_and answered "all users TRUE globally" while engineer asked "all users TRUE per ACCOUNT") — multi-clause questions where the qualifier word ("per X", "in a given Y") is dropped and the responder answers the simpler global variant. Per `feedback_responder_broken_secondary_alternative.md` and `feedback_synthesis_ceiling_stop_churning.md`, scoped one-off, no FIX-A — resources already cover ROW_NUMBER PARTITION BY top-N-per-group; this is recall-ceiling on dropping a qualifier clause, not a content gap.
- **No imported-prior, no broken-secondary, no over-warning, no fabrication of functions.** Just the missed grain.

---

## Explicit answers to teacher questions

1. **Q1 — confirm correct + resource-faithful?** YES. NOT EXISTS lowering to LeftJoin+Aggregation+Filter is exactly what Trino issue #21859 documents; LEFT JOIN IS NULL lowers to SemiJoin (anti-join). Responder's "prefer LEFT JOIN IS NULL over NOT EXISTS for performance" is technically correct on Trino 467 AND matches r28 L790/L869 resource anchors. 4.8125 score.
2. **Q4 — did it miss the per-customer top-N-per-group?** YES, confirmed. Engineer said "50 most recent orders PER CUSTOMER"; responder answered the global ROWNUM-vs-LIMIT semantic without ever introducing `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC)`. Global ORDER BY date DESC LIMIT 50 returns 50 rows total, not 50-per-customer — this is the MORE LIKELY cause of the "different row counts" the engineer observed (vs the ordering-timing global story). Practical-applicability and completeness both shaved -1.5.
3. **Q2/Q3 accuracy**: Q2 verified clean (sorted_by IS a modifiable property in 467; EXECUTE optimize with raised file_size_threshold is the right rewrite trigger; Trino-native = correct for this stack). Q3 verified clean (dbt-trino grants bug #12862 confirmed; post_hook TO ROLE is the correct workaround; OPA caveat correctly defers specific policy to external governance per prod_info.md).
4. **New watches / FIX-A**: NO FIX-A. The Q4 gap is the recurring "qualifier dropped from multi-word question" pattern (iter1293-Q1 mirror), which is recall-ceiling per `feedback_synthesis_ceiling_stop_churning.md` — adding a FIX-A would either over-attract adjacent global-LIMIT questions or duplicate ROW_NUMBER PARTITION BY coverage already in r07 §funnels/cohorts and r27 Oracle-migration. One SOFT WATCH addition (low priority): `iter1294-Q4 Oracle ROWNUM-per-group qualifier-drop` — re-probe within 4-8 iters under varied "Oracle ROWNUM/RANK/DENSE_RANK PARTITION-equivalent → Trino top-N-per-group" framings; if 2+ recurrences route to global LIMIT and skip ROW_NUMBER PARTITION BY, escalate to LIGHT FIX-A at r27 ROWNUM-migration section adding a question-shape anchor "ROWNUM per customer / per X" routing to the ROW_NUMBER PARTITION BY canonical.

---

## Topic score updates

| Topic | Before | After | Δ |
|---|---|---|---|
| SQL query best practices for OLAP (Q1) | 4.5887/308 | 4.5891/309 | +0.0004 |
| Iceberg partition design for SaaS (Q2) | 4.4052/70 | 4.4118/71 | +0.0066 |
| Oracle PL/SQL → dbt+Trino (Q3 + Q4) | 4.4999/266 | 4.4990/268 | −0.0009 |

All topics REMAIN PASSED. Margin on Oracle-PL/SQL topic remains +0.999 above 3.5 threshold; thinnest topic continues to be "Query performance basics" at 4.1701/44 (unchanged this iter).

---

## Streak / state

- **Continuous PASS loop**: iter1294 = 4.609 PASS (clean Q1/Q2/Q3 + Q4 grain miss only). Streak holds.
- **No FIX-A** this iter.
- **No new HARD watches.** One SOFT watch added (iter1294-Q4 Oracle ROWNUM-per-group qualifier-drop).
- **Carry watches**: iter1278-Q1 Scheduled-vs-CPU as I/O-wait (soft); iter1280-Q1 partition-evolution MUST-use-Spark paraphrase (soft); iter1290-Q3 small-files routing distribution-mode vs commit-frequency-compaction (soft); iter1289-Q4 LPAD/RPAD false-divergence (soft); plus `feedback_synthesis_ceiling_stop_churning` + `feedback_responder_broken_secondary_alternative` recall-ceiling acceptance for multi-clause grain-drop family (iter1293-Q1 + iter1294-Q4 now both in this family).

---

## Sources

- [Trino #21859 — Improve performance of correlated NOT EXISTS queries](https://github.com/trinodb/trino/issues/21859)
- [Trino 467 Iceberg connector docs — sorted_by + ALTER TABLE SET PROPERTIES](https://trino.io/docs/467/connector/iceberg.html)
- [Starburst — Iceberg Partitioning and Performance Optimizations in Trino](https://www.starburst.io/blog/iceberg-partitioning-and-performance-optimizations-in-trino-partitioning/)
- [dbt-labs/dbt-core #12862 — Trino/Starburst grants with roles bug](https://github.com/dbt-labs/dbt-core/issues/12862)
- [dbt docs — grants resource config](https://docs.getdbt.com/reference/resource-configs/grants)
- [Trino 467 SELECT docs — LIMIT, OFFSET, FETCH FIRST](https://trino.io/docs/467/sql/select.html)
- [Trino 467 aggregate functions — bool_and, listagg (context for Q3/Q4 prior iter pin)](https://trino.io/docs/467/functions/aggregate.html)
