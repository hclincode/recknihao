# Judge Feedback — Iter 412 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.625 STRONG PASS** (Q1 4.875 + Q2 4.5 + Q3 4.625 + Q4 4.5) — well above the 3.5 PASS threshold; **+0.406 step-up from iter411 4.219**; highest score since iter404 4.6875. **ITER411 Q2 DIALECT-ACCURACY FAIL IS FULLY AND DURABLY RESOLVED.** All four answers STRONG PASS; no failure mode surfaced this iteration.

**Headline:**
1. **WIN — Q1 iter411 QUALIFY/dialect-accuracy FAILURE FULLY RESOLVED (4.875, up from 3.25 FAIL).** Teacher's iter412 PRIMARY FIX landed exactly as planned: the explicit "Trino 467 does NOT support QUALIFY" callout in resources/13-postgres-to-iceberg-ingestion.md with literal WRONG/RIGHT examples + the new "Trino 467 SQL-dialect anti-patterns" section in resources/23-sql-best-practices-olap.md (with the universal ROW_NUMBER subquery + outer WHERE rn<=N pattern). The responder now produces the canonical Trino-compatible dedup-before-MERGE pattern verbatim.
2. **WIN — Q2 HMS->Nessie carry-forward (4.5).** Teacher's LOW backlog fix in resources/21-hive-metastore-iceberg.md (metadata-only nature, iceberg-catalog-migrator CLI, 4-phase dual-write-window playbook, register --overwrite for stale-pointer handling, no-callback-to-catalog-during-execution semantic) landed and is verifiably accurate against projectnessie.org docs + Dremio's catalog migration blog.
3. **WIN — Q3 RANGE vs ROWS carry-forward (4.625).** Teacher's resources/07-analytical-query-patterns.md expansion landed — calendar-vs-position frame semantics + SaaS gap-day gotcha + supported ORDER BY types.
4. **WIN — Q4 aggregate pushdown (4.5).** Cleanly separates aggregate pushdown from predicate pushdown, gives the EXPLAIN Aggregation-node diagnostic, lists supported simple aggs, and explains the "all WHERE predicates must push for aggregate to push" requirement correctly.

**Pattern note:** eleventh consecutive PASS in the extended phase (iter402-412), and the third clean recovery from a failure mode in three tries:
- **iter408 content gap** (Trino MVs not in resources) → fixed iter409 (4.5625 STRONG PASS).
- **iter410 findability gap** (write.isolation-level buried in resource 17) → fixed iter411 (4.875 STRONG PASS).
- **iter411 dialect-accuracy gap** (QUALIFY recommended on Trino) → fixed iter412 (4.875 STRONG PASS).

The teacher's recovery pattern remains tight and is the most reliable signal in the loop.

---

## Q1 — Trino 467 QUALIFY dialect re-probe + dbt incremental idempotency (RESOLVED)

**Scores: 5.0 / 5.0 / 5.0 / 4.5 — avg 4.875 STRONG PASS**

### Dialect-accuracy failure resolution confirmed
- **Trino 467 does NOT support QUALIFY** — VERIFIED. trino.io/docs/current/sql/select.html lists no QUALIFY in the SELECT grammar through Trino 481; the Starburst forum 2024 feature-request thread "Available window functions and Qualify statement" confirms QUALIFY remains a feature request. The responder now explicitly states this and provides the canonical workaround.
- **Canonical Trino dedup-before-MERGE pattern** — `SELECT * FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY updated_at DESC) rn FROM source) WHERE rn = 1` — VERIFIED as the standard Trino-compatible rewrite; CTE-equivalent form also given.
- **dbt incremental idempotency framing** — embedding the dedup in the source SELECT + `is_incremental` WHERE `updated_at > (SELECT MAX(updated_at) FROM {{ this }})` is the canonical microbatch idempotency pattern — VERIFIED against docs.getdbt.com/docs/build/incremental-models.
- **unique_key only governs MERGE ON, not source dedup** — VERIFIED. dbt-labs community guidance explicitly recommends "always include deduplication in your SELECT rather than relying solely on unique_key."
- **MERGE_TARGET_ROW_MULTIPLE_MATCHES** error name + semantics — VERIFIED against trino.io/docs/current/sql/merge.html and supporting-merge.html. The mechanism is exactly as described: AssignUniqueId on target + MarkDistinct adding is_distinct column + check raises the exception if any row has is_distinct = false.
- **Retry-causes-duplicates root cause** — MERGE re-running over an overlapping window with non-idempotent source SELECT — sound.

### Verdict
**STRONG PASS. The iter411 dialect-accuracy FAIL is fully and durably resolved.** Engineer gets a copy-paste-ready Trino-compatible recipe + the dbt-side idempotency framing.

---

## Q2 — HMS->Nessie no-downtime migration

**Scores: 4.5 / 4.5 / 4.5 / 4.5 — avg 4.5 STRONG PASS**

### What landed
- **Metadata-only, no data move** — VERIFIED. Iceberg's metadata.json + manifest list + manifest files all sit in MinIO; the catalog only holds the pointer to the current metadata.json. Switching catalogs swaps pointers, not data.
- **iceberg-catalog-migrator CLI** — VERIFIED against github.com/projectnessie/iceberg-catalog-migrator (the canonical projectnessie tool) and Dremio's "Introducing the Apache Iceberg Catalog Migration Tool" blog. The `register` subcommand is the correct verb.
- **4-phase dual-write-window playbook** (setup/register, readers cutover, writers cutover, decommission HMS) — sound canonical pattern; the brief window where HMS still has writes but Nessie pointer is stale is correctly identified as the risk surface.
- **register --overwrite for stale-pointer handling** — CORRECT semantic; the migrator supports re-registration to refresh stale pointers during the cutover window.
- **In-flight queries unaffected because scan is self-contained after planning** — CORRECT load-bearing claim. Once Trino's coordinator resolves metadata.json -> manifest list -> data file URIs and produces splits, executor splits read directly from MinIO without further catalog roundtrips. A catalog switch mid-execution does not interrupt.
- **No catalog callback during execution** — CORRECT.

### Minor opportunities (not gating)
- Could mention the brief write-freeze alternative to dual-write window for users who prefer simpler reasoning over zero downtime.
- Could mention Hive-views-don't-migrate gotcha (Nessie doesn't carry Hive view definitions; views must be recreated).

### Verdict
**STRONG PASS.** Teacher's LOW backlog fix in resources/21 landed cleanly. Engineer gets a clear phased playbook with the right tool name.

---

## Q3 — RANGE vs ROWS window frame on gap-day SaaS data

**Scores: 5.0 / 4.5 / 4.5 / 4.5 — avg 4.625 STRONG PASS**

### What landed
- **ROWS BETWEEN 6 PRECEDING AND CURRENT ROW = physical row count, breaks on gap days** — CORRECT. With sparse data (weekends, holidays, idle tenants) the 6-row window pulls in older calendar days than intended.
- **RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW = calendar-aware value-based range** — VERIFIED against trino.io/blog/2021/03/10/introducing-new-window-features.html ("Range frames with INTERVAL bounds") + trino.io/docs/current/functions/window.html. Trino supports this syntax; the offset interval applies to the ORDER BY column.
- **Missing days don't shift the window** — CORRECT semantic; RANGE filters by value, not by row position.
- **RANGE requires numeric / DATE / TIMESTAMP / TIMESTAMPTZ ORDER BY** — CORRECT. Trino docs explicitly require the offset to be compatible with the sorting column type.
- **SaaS weekend/holiday/idle-tenant gap-day framing** — practical and on-brand.

### Minor opportunities (not gating)
- Could mention the empty-frame NULL-aggregate edge case (if no rows fall in the calendar window, aggregates return NULL).
- Could mention the per-row-densification alternative (LEFT JOIN with calendar dimension) for cases where the engineer needs both window semantics and zero-fill.

### Verdict
**STRONG PASS.** Teacher's expansion of resources/07-analytical-query-patterns.md landed.

---

## Q4 — Aggregate pushdown to Postgres separate from predicate pushdown

**Scores: 4.5 / 4.5 / 4.5 / 4.5 — avg 4.5 STRONG PASS**

### What landed
- **Aggregate pushdown is SEPARATE from predicate pushdown** — VERIFIED against trino.io/docs/current/optimizer/pushdown.html (distinct sections for each).
- **"All WHERE predicates must also push for aggregate to push"** — CORRECT in spirit. If Trino can't push a filter, it must apply that filter locally; the aggregate must then run on Trino too because it operates on post-filter rows. The pushdown doc states this dependency.
- **Simple aggs COUNT/SUM/AVG/MIN/MAX** — CORRECT for the PostgreSQL connector (verified against trino.io/docs/current/connector/postgresql.html).
- **Default aggregate-pushdown-enabled** — CORRECT for PG connector; can be disabled via `aggregation_pushdown_enabled` session property.
- **EXPLAIN diagnostic — Aggregation node above TableScan = NOT pushed; Aggregation absent = pushed** — VERIFIED ("If an aggregate function is successfully pushed down to the connector, the explain plan does not show that Aggregate operator").
- **EXPLAIN ANALYZE Input row count as smoking gun** — canonical 50M-row-pulled diagnostic. The fix paths (tighten WHERE to use pushdown-compatible predicates, materialized view on PG) are sound.

### Minor opportunities (not gating)
- Could mention `jdbc-types-mapped-to-varchar` connector property as a foot-gun (unrecognized PG types get mapped to VARCHAR and break pushdown).
- Could mention `pushdown.computations.enabled` session property.
- For the Trino federation topic this datum nudges the average to **4.4925 (267 datapoints)** — still 0.0075 below the raised 4.5 threshold. The topic **REMAINS NEEDS WORK** in the rubric. Crossing the threshold will require a sustained sequence of ≥4.55 scores; the marginal lift per single datum at this volume is now <0.001.

### Verdict
**STRONG PASS.** The structural separation is right; the EXPLAIN diagnostic is the canonical verification.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.875 | STRONG PASS — iter411 DIALECT-ACCURACY FAILURE RESOLVED via "no QUALIFY" callout + canonical ROW_NUMBER pattern |
| Q2 | 4.5 | STRONG PASS — HMS->Nessie phased playbook + iceberg-catalog-migrator + self-contained scan semantic |
| Q3 | 4.625 | STRONG PASS — RANGE INTERVAL vs ROWS calendar-vs-position semantics + Trino syntax verified |
| Q4 | 4.5 | STRONG PASS — aggregate pushdown vs predicate pushdown separation + EXPLAIN diagnostic |

**Average 4.625 STRONG PASS** — eleventh consecutive PASS in the iter402-412 window; +0.406 step-up from iter411 4.219; highest score since iter404 4.6875.

**Trajectory iter394-412:** `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/4.625P/4.0625P/4.125P/4.5625P/4.0P/4.219P/**4.625P**`.

**Topic status table:**
- Postgres-to-Iceberg ingestion: 4.4891/144 -> 4.4917/145 — PASSED (above threshold).
- Iceberg table maintenance: 4.4067/76 -> 4.4102/77 — PASSED.
- Analytical query patterns Iceberg+Trino: 4.4031/10 -> 4.4233/11 — PASSED.
- Trino federation / cross-source: 4.4925/266 -> **4.4925/267 — NEEDS WORK (still 0.0075 below raised 4.5 threshold)**.

---

## Teacher actions next (iter 413)

1. **HIGH — Trino federation topic threshold push.** This topic remains NEEDS WORK at 4.4925/267, only 0.0075 below the raised 4.5 threshold. The marginal lift per single datum is now tiny (<0.001), so reaching the threshold requires either (a) a sustained sequence of high-quality answers (≥4.55) over multiple iterations, or (b) reducing the test-point denominator by re-scoping the topic. **Recommend (a) — polish the federation resources to produce consistently ≥4.6 answers.** Specifically:
   - Add a literal EXPLAIN ANALYZE output snippet to resources/16-trino-federation.md or similar, showing the exact "Input rows: 50,000,000" vs "Input rows: 5" smoking-gun pattern for aggregate pushdown.
   - Add a worked example of `aggregation_pushdown_enabled` session property + how to confirm via EXPLAIN.
   - Add the `jdbc-types-mapped-to-varchar` foot-gun callout.
   - Add the equality-perf-regression caveat for `enable-string-pushdown-with-collate` (may disable PG indexes on equality).

2. **LOW — Q1 polish.** Add a `dbt --vars '{batch_date: "2026-06-01"}'` parameterized-backfill example to the dbt incremental section in resources/13.

3. **LOW — Q2 polish.** Add the brief write-freeze alternative + Hive-views-don't-migrate gotcha to resources/21.

4. **LOW — Q3 polish.** Add empty-frame NULL-aggregate edge case + per-row-densification alternative (LEFT JOIN calendar dim) to resources/07.

5. **LOW carry-forward backlog**: MERGE rollback, OPA-override timeout, schema registry compat, JWT+OPA concurrency, Iceberg tagging 3rd-angle, fs.cache JMX 3rd-angle, equality delete 1.5.2 bug context, Iceberg v3 deletion vectors timeline, snapshot vs serializable phantom-row 3rd-angle (still pending re-probe from iter412 teacher's resource 26 § 8.1/8.2 fix).

---

## Judge probe targets next (iter 413)

1. **CRITICAL — Trino dialect-accuracy 2nd-angle (durability of iter412 fix).** Different question that probes SQL-dialect awareness. E.g., "how do I write a TOP-N-per-group query in Trino?" — confirms responder doesn't reach for QUALIFY, TOP, DISTINCT ON, or LIMIT N BY. Or "Trino equivalent of MySQL's `GROUP_CONCAT`?" — confirms responder uses `array_join(array_agg(...))` or `listagg`.

2. **Trino federation topic threshold-push probe.** Same kind of question that scored 4.5 in Q4 above but in a slightly different shape — e.g., "my federated PG join still pulls 100M rows from PG even after I added a WHERE — what's going on?" — probes the predicate-pushdown-as-prerequisite-for-aggregate-pushdown dependency at a different entry point.

3. **HMS->Nessie 2nd-angle.** "We started migrating to Nessie but a write hit HMS after the cutover — how do I reconcile?" — probes the stale-pointer reconciliation + register --overwrite recipe.

4. **Snapshot vs serializable phantom-row 3rd-angle.** Still pending durability re-probe from teacher's iter412 resource 26 § 8.1/8.2 fix — "when should I use snapshot isolation in Iceberg, and what's the phantom-row risk?"

5. **RANGE vs ROWS 2nd-angle.** "I need a 7-day rolling average for tenants with sparse activity — which window frame and why?" — natural follow-on probing the calendar-vs-position distinction in a different shape.

6. **Iceberg v3 deletion vectors timeline** carry-forward (long-standing backlog item).
