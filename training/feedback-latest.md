# Iter690 Judge Feedback — 2026-06-08 (EXTENDED PHASE)

## Overall verdict

**OVERALL: 4.9375 STRONG PASS** (margin +1.4375 above 3.5 floor; -0.0625 swing DOWN from iter689's perfect 5.000 attributable solely to the `GROUP BY o.*` illustrative-SQL slip on Q2 — substance bulletproof on all four)

Per-dimension cross-check: Acc(5+4.5+5+5)/4 = 4.875 / Comp(5+5+5+5)/4 = 5.00 / Clar(5+4.5+5+5)/4 = 4.875 / Act(5+5+5+5)/4 = 5.00 → mean (4.875+5.00+4.875+5.00)/4 = **4.9375**, agrees with per-Q mean.

ALL FOUR DIALECT FACTS VERIFIED against trino.io/docs/467 (analyze.html, connector/iceberg.html, sql/merge.html) via WebFetch — every Trino-syntax claim in the responder's answers is docs-accurate.

---

## Per-question scores

### Q1 — Iceberg compaction / small files (merge tens of thousands of tiny files into ~256MB files)

**Score: Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00**

- Canonical Trino 467 form: `ALTER TABLE iceberg.analytics.orders EXECUTE optimize(file_size_threshold => '256MB')` — VERIFIED exact match against trino.io/docs/467/connector/iceberg.html. The DataSize literal `'256MB'` (unit-suffixed, NOT bare bytes integer) is the correct format; default is `'100MB'` if omitted.
- Correctly notes EXECUTE optimize rewrites files smaller than threshold into larger files.
- Correctly notes native Trino procedure (no Spark required).
- Correctly notes old files remain until `expire_snapshots` + `remove_orphan_files` follow-up — essential operational caveat.
- Production-fit: on-prem Trino 467 with Iceberg connector + MinIO + Hive Metastore exactly matches prod_info.md.

### Q2 — CBO / ANALYZE stats (collect stats so planner makes smarter join decisions + see chosen plan)

**Score: Acc 4.5 / Comp 5 / Clar 4.5 / Act 5 = 4.75**

- **THE KEY VERDICT: ANALYZE-no-TABLE-keyword is CORRECT for Trino 467.** Verified against trino.io/docs/467/sql/analyze.html: official syntax is `ANALYZE table_name [WITH (property_name = expression [, ...])]` — NO `TABLE` keyword. The responder correctly used `ANALYZE iceberg.analytics.orders WITH (columns = ARRAY['customer_id', 'created_at'])` and explicitly flagged `ANALYZE TABLE` as Spark/Hive form that fails on Trino. This is the bedrock substance and it is bulletproof.
- `SHOW STATS FOR iceberg.analytics.orders` valid.
- `EXPLAIN (TYPE DISTRIBUTED)` valid; correctly identifies Join[BROADCAST]/Join[PARTITIONED] distribution + Estimates rows + `?` indicating missing stats.
- Puffin file reference correct for Iceberg NDV stats persistence.
- **Minor illustrative slip: `GROUP BY o.*`** — star in GROUP BY is NOT valid Trino dialect (must enumerate columns). However, this appears in a throwaway plan-illustration EXPLAIN snippet, not the substance the user asked about (the substance is ANALYZE-collects-stats + SHOW STATS + EXPLAIN-to-inspect). Material enough to dock 0.5 each on Acc/Clar (a SaaS engineer copy-pasting the literal EXPLAIN line would get a parse error), but NOT enough to drag the answer below pass — the ANALYZE-no-TABLE + SHOW STATS + EXPLAIN core fully addresses the question.

### Q3 — OPA / JWT multi-tenant central enforcement (forgotten WHERE can't leak across tenants)

**Score: Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00**

- Mechanism A (prod): OPA evaluates every query, reads tenant_id from JWT claim, injects row filter (or denies query) at planning time — central enforcement so forgotten WHERE can't leak. Matches prod_info.md exactly (OPA + JWT is the production stack).
- Mechanism B (fallback): `CREATE VIEW iceberg.tenant_acme.orders SECURITY DEFINER AS SELECT * FROM orders WHERE tenant_id='acme'` + GRANT SELECT on view only + REVOKE base-table SELECT. SECURITY DEFINER goes BEFORE AS in the grammar (not in WITH(...) — that's CREATE TABLE syntax) — CORRECT.
- Correctly defers specific OPA rules + user-tenant mappings to the external governance document (matches prod_info.md handling instructions for permission-related questions).
- Not a federation question; correctly framed as access-control + view-based isolation.

### Q4 — MERGE upsert (nightly staging batch, update existing + insert new, match on customer_id)

**Score: Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00**

- Canonical Trino 467 form: `MERGE INTO iceberg.analytics.customers AS t USING (SELECT ... FROM staging) s ON t.customer_id = s.customer_id WHEN MATCHED THEN UPDATE SET name = s.name, ... WHEN NOT MATCHED THEN INSERT (cols) VALUES (s.cols)` — VERIFIED against trino.io/docs/467/sql/merge.html: docs show explicit column lists (`UPDATE SET purchases = s.purchases + t.purchases` + `INSERT (customer, purchases, address) VALUES(...)`).
- Spark `spark.sql` MERGE with `INSERT *` correctly labeled as Spark-only (not Trino); Trino 467 docs do NOT mention `UPDATE SET *` or `INSERT *` star-shorthand.
- ON-clause mandatory join key — CORRECT.
- WHEN MATCHED updates / WHEN NOT MATCHED inserts atomic — CORRECT.
- Dedup source via ROW_NUMBER if duplicate customer_ids — CORRECT and ESSENTIAL: trino.io/docs/467/sql/merge.html explicitly states "The query fails if a single target table row matches more than one source row." Cardinality-violation guard is the right answer.
- Correctly notes `UPDATE SET *` only works if columns are identical (and even then is Spark-only on Trino 467).

---

## Flagged weak answers

**Q2 — `GROUP BY o.*` illustrative-SQL slip (minor, non-substance).** The star-in-GROUP-BY snippet is not valid Trino dialect — but it appears in an EXPLAIN plan-shape example, not in the substantive ANALYZE/SHOW STATS/EXPLAIN guidance the user actually needs to copy-paste. Docked 0.5 on Acc + 0.5 on Clar (total -0.25 on Q2 score → 4.75 vs perfect 5.00). Substance of the answer — ANALYZE-no-TABLE-keyword, Puffin stats, SHOW STATS verification, EXPLAIN (TYPE DISTRIBUTED) for plan inspection — is fully correct and bulletproofed by iter689's leading canonical statement at r24:5/206-215/228-230.

NO other weakness flags. Q1, Q3, Q4 are docs-perfect.

---

## Teacher feedback (concise, actionable)

**iter691 recommendation: DEFAULT NO-OP / durability-breadth continuation.**

The only borderline-material item this iteration is the Q2 `GROUP BY o.*` snippet. This is a minor illustrative-example slip, NOT a leading-canonical-recommendation drift — the substance (`ANALYZE iceberg.x.y` no-TABLE + SHOW STATS + EXPLAIN (TYPE DISTRIBUTED)) is bulletproof and exactly matches r24:5/206-215/228-230 leading canonical statements. Verified docs-correct against trino.io/docs/467/sql/analyze.html.

**Optional polish (LOW priority — do NOT touch if it risks destabilizing r24):** If the teacher wants to inoculate the responder against star-in-GROUP-BY illustrative slips, consider adding to the DO-NOT-WRITE matrix anywhere a `GROUP BY o.*` or `GROUP BY t.*` snippet might appear in plan-illustration EXPLAIN examples. Suggested matrix row: "DO NOT write `GROUP BY o.*` / `GROUP BY t.*` — Trino requires explicit columns in GROUP BY; star-in-GROUP-BY is parse error." This is OPTIONAL — the substance answer was correct, and adding inoculation against minor illustrative-snippet drift carries minor risk of destabilizing other r24 content. **My recommendation: leave it. Score margin is +1.4375 above floor, and the slip didn't affect the user's actionability.**

**DO NOT:**
- Bump training/state.json (teacher already set to 690).
- Rewrite r17 EXECUTE optimize canonical statements (Q1 docs-perfect; iter666/667/669 DataSize + WHERE-partition-predicate locks HELD).
- Rewrite r24 ANALYZE canonical statements (Q2 substance docs-perfect; the `GROUP BY o.*` slip is downstream of the ANALYZE substance, not in the canonical statement itself).
- Rewrite r05 OPA/JWT/SECURITY DEFINER canonical statements (Q3 docs-perfect + prod_info.md-perfect).
- Rewrite r13/r27/r22 MERGE INTO Trino-explicit-column canonical statements (Q4 docs-perfect; iter689 lock HELD).
- Touch r22 federation guardrails (46-iter ZERO probe streak; 4.49944 vs 4.5 thin-margin still — federation re-probe optional high-risk).
- Add any forbidden dialect patterns (QUALIFY, RLIKE, PERCENTILE_CONT/MEDIAN, ANALYZE TABLE, MERGE star-shorthand, MERGE WHEN NOT MATCHED BY SOURCE, optimize bare bytes, CREATE TABLE PRIMARY KEY, GROUP BY t.*).

**Rotation for iter691 adversarial pick (DEFAULT NO-OP continued):** All four areas tested this iter (compaction/CBO/OPA-JWT/MERGE) are bulletproofed. If iter691 proceeds with a probe rather than full no-op, rotate to undersurveyed adjacent: storage tiering (5th datapoint for durability lock), exposures (4th datapoint), MoR vs CoW trade-offs, time-travel via VERSION AS OF, partition evolution, sessionization, dbt incremental edge cases, MATCH_RECOGNIZE funnel re-probe, Iceberg snapshot/expire_snapshots/orphan-file cleanup workflow end-to-end. Federation NOT recommended for re-probe (46-iter ZERO streak protects the 4.49944 thin-margin).

**iter690 trajectory continuity:** iter687(4.0625) → iter688(4.500 PASS, FIX-A directive issued) → iter689(5.000 STRONG PASS, FIX-A re-probe CLOSED) → iter690(4.9375 STRONG PASS, all four orthogonal shapes clean). Sustained 4.0+ across 33 of last 34 iterations. iter689 FIX-A landing on running-cumulative-percent fully durable (not re-probed this iter; was probed orthogonally last iter and CLOSED).

---

## Per-question score table

| Q | Topic | Acc | Comp | Clar | Act | Per-Q avg |
|---|---|---|---|---|---|---|
| Q1 | Iceberg compaction (EXECUTE optimize 256MB) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | CBO/ANALYZE (no-TABLE-keyword + SHOW STATS + EXPLAIN) | 4.5 | 5 | 4.5 | 5 | 4.75 |
| Q3 | OPA/JWT multi-tenant (Mechanism A row-filter + Mechanism B SECURITY DEFINER view) | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | MERGE upsert (explicit-column WHEN MATCHED/NOT MATCHED) | 5 | 5 | 5 | 5 | 5.00 |
| **Overall** | | **4.875** | **5.00** | **4.875** | **5.00** | **4.9375 STRONG PASS** |

**GOVERNING LABEL: STRONG PASS (4.9375 ≥ 3.5 by margin +1.4375)**
