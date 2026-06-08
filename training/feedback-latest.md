# Judge Feedback — iter699

**Mode**: extended-phase end-of-iteration (4-question durability probe across 4 fresh areas).
**Verdict**: PASS (overall avg 4.6875 ≥ 3.5).
**Verification basis**: trino.io/docs/current admin/properties-general, optimizer/cost-based-optimizations, connector/iceberg, sql/select, functions/aggregate.

---

## Per-question scoring

### Q1 — HAVING vs WHERE for "accounts with more than 10 orders"

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | (a) `GROUP BY ... HAVING COUNT(*) > 10` is valid Trino 467 SELECT grammar (HAVING listed in `trino.io/docs/current/sql/select.html`). (b) "Aggregates illegal in WHERE" is correct — Trino raises a semantic error if an aggregate appears in WHERE; aggregates must appear in SELECT/HAVING/ORDER BY of the same query. (c) Execution-order FROM/JOIN → WHERE → GROUP BY → HAVING → SELECT matches the standard SQL logical evaluation order Trino follows. WRONG/RIGHT defang is correctly directional. |
| Completeness | 5 | WRONG form (so the responder doesn't get copy-imitated), RIGHT form, and the WHY (execution order) — all three are present. |
| Clarity | 5 | Tight: one paragraph of mechanism + two SQL blocks + one-line order. Zero unexplained jargon. |
| Actionability | 5 | Engineer can paste the RIGHT form and ship. The execution-order line tells them how to reason about future cases (e.g. "why can't I filter on AVG in WHERE"). |

**Q1 avg = 5.00**

### Q2 — Reading EXPLAIN on a slow dashboard query

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | (a) `EXPLAIN`, `EXPLAIN ANALYZE`, and `EXPLAIN (TYPE DISTRIBUTED)` are all valid Trino 467 forms (per `trino.io/docs/current/sql/explain.html` grammar). (b) REPLICATE-as-broadcast and REPARTITION-as-hash-shuffle terminology is the Trino plan-node vocabulary (matches Trino UI / `EXPLAIN ANALYZE` output). (c) Function-wrapped-predicate-defeats-partition-pruning is correct — wrapping a partition column in a function (e.g. `date(event_date) = DATE '...'`) prevents the planner from pushing the predicate to partition metadata, since the planner needs a literal-comparable form. (d) Scheduled-time vs CPU-time gap as I/O / downstream wait is the documented interpretation of EXPLAIN ANALYZE operator metrics. |
| Completeness | 5 | Four-step triage (cluster, pruning, skew, slowest-operator) covers the universe of "why slow"; metrics named (CPU/Scheduled/physicalInputDataSize) tell the reader WHICH numbers to look at. |
| Clarity | 4 | Dense — works for someone with some Trino UI familiarity. A pure beginner has to internalize REPLICATE/REPARTITION/Filter-above-TableScan vocabulary. Still readable because terms are inline-defined. |
| Actionability | 5 | Concrete checks ("Queued > 0 in UI", "Filter node ABOVE TableScan = pruning broke", "raw range vs date(col)=DATE'...'") — engineer knows exactly what to look for and what to change. |

**Q2 avg = 4.75**

### Q3 — Iceberg ADD/RENAME column on millions-row table without rewrite

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | (a) `ALTER TABLE ... ADD COLUMN`, `ALTER TABLE ... RENAME COLUMN`, `ALTER TABLE ... DROP COLUMN` are all valid Trino 467 Iceberg-connector DDL (per `trino.io/docs/current/connector/iceberg.html`). (b) Iceberg schema evolution is metadata-only — these operations mutate the schema in the metadata layer without rewriting Parquet files; old files NULL-fill the new column on read (this is the documented Iceberg-spec behavior for ADD). (c) "Added column always nullable" is correct — Iceberg does not allow NOT NULL on an added column because pre-existing rows have no value (the spec requires added columns to be optional). (d) DROP COLUMN is metadata-only and bytes are recoverable via time-travel until snapshot expiry. |
| Completeness | 5 | All three operations (ADD, RENAME, DROP) covered with the read-path semantics (NULL-fill), the nullability constraint, and the recoverability window. |
| Clarity | 4 | Tight and concrete. The table-reference `iceberg.products` is catalog.table — missing schema (production form would be `iceberg.<schema>.products`). Per the directive this is minor / illustrative, but a strict beginner could copy verbatim and hit a "schema not specified" error. Not penalized heavily. |
| Actionability | 5 | Engineer can paste the DDL and ship; understands the read-time NULL-fill and the time-travel rescue path; knows backfill needs Spark for non-NULL historical values. |

**Q3 avg = 4.75**

### Q4 — Broadcast join: huge events to ~200-row lookup

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | (a) `SET SESSION join_distribution_type = 'BROADCAST'` (and `'PARTITIONED'` / `'AUTOMATIC'`) is the documented Trino 467 session property and value set (verified against `trino.io/docs/current/admin/properties-general.html` and `optimizer/cost-based-optimizations.html`). (b) Default `join_max_broadcast_table_size = 100MB` is **correct** (verified against `trino.io/docs/current/optimizer/cost-based-optimizations.html` — "By default, the replicated table size is capped to 100MB"). (c) Semantics correct: BROADCAST replicates the build (smaller) side to every worker that holds the probe side, the probe side is not shuffled; PARTITIONED hash-distributes both sides on the join key. The AUTOMATIC-may-shuffle-when-stats-stale caveat is the correct gotcha. |
| Completeness | 5 | Session property, semantics, size threshold, fallback to PARTITIONED, and stats-stale caveat — every leg of the decision is covered. |
| Clarity | 5 | One-paragraph reasoning + one SQL block + one fallback statement. Numbers are concrete (200 rows, 100M events, 100MB cap). |
| Actionability | 5 | Engineer can run the SET SESSION immediately, knows what happens when memory pressures up, knows how to fall back. |

**Q4 avg = 5.00**

---

## Overall

**16 sub-scores → average = (5.00 + 4.75 + 4.75 + 5.00) / 4 = 4.6875**

**PASS** — clear strong-pass margin.

---

## Findable-but-missing gap audit for iter700

| Question | Genuine gap surfaced? | Notes |
|---|---|---|
| Q1 HAVING-vs-WHERE | NO | Routing is solid (resources/23 line 1809 cited); WRONG-RIGHT defang correctly directional; aggregates-illegal-in-WHERE and execution-order both docs-consistent. |
| Q2 EXPLAIN triage | NO | All three EXPLAIN forms valid Trino 467; REPLICATE/REPARTITION vocabulary docs-consistent; function-wrapped-pruning claim correct; Scheduled-vs-CPU interpretation correct. |
| Q3 Iceberg ADD/RENAME | NO (minor cosmetic only) | All three DDL forms valid; metadata-only claim correct; always-nullable claim correct; time-travel recovery correct. The `iceberg.products` (catalog.table without schema) reference is illustrative and within tolerance per the directive — not a dialect defect, not a findable gap. |
| Q4 broadcast join | NO | join_distribution_type values correct; 100MB default **verified correct against trino.io/docs/current/optimizer/cost-based-optimizations.html**; BROADCAST/PARTITIONED semantics correct; AUTOMATIC stats-stale caveat correct. |

**No findable-but-missing gap and no dialect defect surfaced across all 4 questions.** Every answer is a valid Trino 467 form. All four answers cite the correct resource line ranges and the responder's routing is hitting the landing points.

**iter700 stays DEFAULT NO-OP.** Resources are mature (166+ consecutive PASSES); the three FRESH fixes (iter698 MoM card, iter697 approx_percentile mirror inoculation, iter695 QUALIFY canonical) are intact and the responder is correctly drawing from all three regions when appropriate. No teacher action required for iter700.

---

## Teacher feedback

1. **Hold all locks.** No edits required. The four fresh areas probed (HAVING-vs-WHERE, EXPLAIN reading, Iceberg schema evolution, broadcast join) all returned strong-pass answers with no dialect defects.
2. **Optional cosmetic** (NOT required, NOT a gap): if resources/13 examples consistently use `iceberg.products` (catalog.table) instead of `iceberg.<schema>.products`, consider adding a one-line note that production DDL needs the schema segment. This is purely illustrative-form polish and should NOT trigger a fix-A iteration on its own.
3. **Maintain the ban-list discipline** — no QUALIFY, no PERCENTILE_CONT, no MEDIAN, no date-minus-date, no array_slice, no element_at-index-0, no CoW-default, no t-digest-with-accuracy-arg leaks observed in any of the 4 answers.
4. **Responder routing health**: the responder cited resources/23 line 1809 (Q1), resources/18 lines 28-130 (Q2), resources/13 lines 1660-1775 (Q3), resources/18 lines 154-163 (Q4) — four distinct resource regions, all correctly matched to the question's keywords. Findability stays healthy.
