# Iteration 1221 — Judge Feedback

**Verdict: 4.56 STRONG PASS. Two watches CLOSE; NO FIX-A.**

- **Q1 (iter1220 r10 transform-refinement-vs-column-addition WATCH) CLOSES** — responder correctly rejected teammate's "Trino can't prune old files AT ALL / full scan" overstatement and stated old-spec files prune at the OLD COARSER granularity via predicate projection through the old transform. Minor framing slips (see below) but the load-bearing diagnosis flipped from iter1220's "scans all 400M" to the correct "prunes at coarse old granularity."
- **Q3 (iter1218 r28+r27 accepted_values-doesnt-catch-NULL FIX-A WATCH) CLOSES** — responder went from iter1218's "NULL and 'none' will BOTH be caught" (2.75 FAIL) to iter1221's pin-perfect "NULL NOT IN (...) = UNKNOWN in 3-valued logic, NULLs silently excluded, pair with not_null" (5.0). Clean 1st-re-probe close.
- Q2 market-basket self-join + PARTITIONED join: 4.25 (load-bearing right; basket-skew caveat missing — not load-bearing for the engineer's immediate fix).
- Q4 Oracle NVL2 → CASE/IF: 5.0 pin-perfect.

---

## Q1 — Iceberg partition spec evolution (day→hour) cross-spec pruning [WATCH RE-PROBE]

**Score: 4.0** | Tech 4.0 | Clar 4.5 | App 3.5 | Compl 4.0
**Routing**: Iceberg partition design for SaaS (line 64)
**Watch status: iter1220 r10 transform-refinement-vs-column-addition CLOSES on 1st re-probe**

Load-bearing answer correct: teammate is WRONG, old (day-spec) files still prune at the OLD coarser day granularity via predicate transform projection — NOT full scan. Verified via [Dremio engineering](https://www.dremio.com/blog/apache-iceberg-partition-evolution-change-your-partitioning-strategy-without-rewriting-data/) (mixed-spec semantics: "Dremio prunes new files at day granularity (very precise) and old files at month granularity (coarser)") + [Streamkap operational guide](https://streamkap.com/resources-and-guides/iceberg-partition-evolution-operational-guide) ("Iceberg query planner reads all manifests, groups by spec ID, applies correct partition pruning logic for each group") + [Apache Iceberg Evolution docs](https://iceberg.apache.org/docs/latest/evolution/). The iter1220 FIX-A (r10 §98-117 PIN point 5 disambiguating transform-refinement vs column-addition) reached cleanly.

**Two MINOR framing slips (Acc -1, App -1, Compl -1)** — flagged in directive as non-load-bearing:

1. **"matching MONTH (or whatever the old spec was)" — old spec here was DAY**: the responder's lead example says "prune to the matching MONTH," then hedges with "or whatever the old spec was." For this specific question (day→hour), the correct phrasing is "prune to the matching DAY." Recall-ceiling phrasing slip, not a resource defect — r10 §98-117 PIN point 5 (iter1220 FIX-A) lists both `month()→day()` and `day()→hour()` as transform-refinement examples; responder generalized the first one.

2. **"day-level pruning on old files (what you want) is what's missing" framing muddled for THIS use case**: the engineer's query is a QUARTERLY report `WHERE event_ts >= DATE '2026-01-01' AND < DATE '2026-04-01'` — a 90-day window. Day-level pruning on old files IS already available (old spec was day) and IS sufficient (the report scans 90 days; hour-level pruning wouldn't reduce that — there's still 90 days × 24 hours = 2160 hourly partitions inside the 90-day window). The "hundreds of GB" is the actual physical volume of a quarter of events at this ingest rate, NOT a pruning failure. The responder's "fix" — Spark `rewrite_data_files(rewrite-all=true)` to restamp old files under hour-spec — won't reduce the quarterly-report scan because the bottleneck isn't transform granularity, it's the 90-day window itself. The rewrite would help a 6-hour DASHBOARD on old data; it doesn't help a quarterly report. Practical Applicability shaved because the prescription is mismatched to the stated use case.

Why this scores 4.0 not lower: load-bearing point (teammate WRONG, prunes at coarse old granularity) is correct, the iter1220 FIX-A reached, and `rewrite_data_files(rewrite-all=true)` IS the right rewrite path for general "old data pruning at NEW spec granularity" needs (just not for THIS quarterly report). No imported-prior, no fabrication. NO FIX-A — both slips are recall-ceiling, the resource correctly teaches the disambiguation as of iter1220.

**NEW SOFT WATCH** `iter1221 Q1 quarterly-window-vs-transform-granularity diagnosis` — re-probe in 5-9 iters under "quarterly/annual report scans a lot, did partition evolution break pruning" framing; if recurs, light additive line in r10 noting "for date-range queries spanning many old-spec partitions, the volume IS the window — rewriting to finer granularity won't reduce scan; that's only a win for short-window queries inside old data."

---

## Q2 — Market basket self-join OOM, partitioned-join lever

**Score: 4.25** | Tech 4.5 | Clar 4.5 | App 4.5 | Compl 3.5
**Routing**: Improving complex SQL performance on Trino with dbt (line 419)

Load-bearing answer correct:

1. **Self-join shape `a.product_id < b.product_id` is canonical co-occurrence pair construction** — drops self-pairs (`a.product_id = b.product_id` filtered) AND drops mirror duplicates (only one orientation per pair). Standard market-basket / association-rule pair-mining shape per [GeeksforGeeks Market Basket SQL](https://www.geeksforgeeks.org/market-basket-analysis-with-sql/) + Lumi-AI walkthrough.

2. **`SET SESSION join_distribution_type='PARTITIONED'` is a valid Trino 467 session property** — verified at [trino.io/docs/467/admin/properties-general.html](https://trino.io/docs/467/admin/properties-general.html) verbatim "valid values are AUTOMATIC (default), PARTITIONED, BROADCAST" + "PARTITIONED employs hash distributed joins where both tables are redistributed using a hash of the join key" — matches pinned iter1203 canonical (broadcast vs partitioned distribution). `SET SESSION join_max_broadcast_table_size='1MB'` is also valid (default `100MB` per [PR #2527](https://github.com/trinodb/trino/pull/2527)) — lowering to `1MB` effectively forces partitioned for any non-trivial build side. Either lever alone forces partitioned; both is belt-and-suspenders.

3. **Diagnosis correct that broadcast on a 100M-row self-join is the OOM cause** — broadcast replicates the build side to every worker; if Trino's CBO picks broadcast for `order_items` (because ANALYZE is stale or absent, no NDV stats), every worker tries to hold 100M rows → OOM. Partitioned hash-distribution shuffles both sides on `order_id` (the join key), so each worker holds only its slice → bounded memory.

4. **`ANALYZE order_items` as the durable fix** — populating Iceberg Puffin NDV stats so CBO picks partitioned automatically without session overrides. Matches pinned iter1203 canonical.

**COMPLETENESS SHAVE (-1)**: The deeper market-basket OOM driver — **basket-cardinality skew** — is not surfaced. An order with N items produces N(N-1)/2 pairs at join time; a basket with 1000 items produces ~500K pairs from a single `order_id`. Partitioned join solves the per-worker memory distribution; it does NOT solve the **join cardinality blow-up** itself. For 100M rows skewed toward a few mega-baskets, the partitioned join still produces a massive intermediate cardinality before the GROUP BY collapses it. The other lever (which the responder did not mention) is:
- **Cap basket cardinality** — pre-filter `WHERE order_id NOT IN (SELECT order_id FROM order_items GROUP BY order_id HAVING COUNT(*) > 50)` or top-N-items-per-basket
- **Pre-aggregate to distinct (order_id, product_id) pairs FIRST** if duplicates exist within an order
- **Two-phase**: filter pairs to "frequent items only" via a first-pass `HAVING SUM(...) >= min_support` before the self-join

Non-load-bearing for the engineer's stated immediate fix (partitioned join WILL likely resolve the OOM for typical retail baskets where p99 basket size is small). But on truly skewed data (B2B wholesale, supplier orders), partitioned alone may not be enough. Watch label `iter1221 Q2 market-basket basket-skew completeness` — re-probe if a high-basket-cardinality framing surfaces. NO FIX-A — single re-probe data point, not source-anchored.

No imported-prior. No broken-secondary. No fabrication. Cites r24/r27/r28 family pinned canonicals.

---

## Q3 — dbt accepted_values + NULL trap [WATCH RE-PROBE]

**Score: 5.0** | Tech 5.0 | Clar 5.0 | App 5.0 | Compl 5.0
**Routing**: dbt model contracts (line 455)
**Watch status: iter1218 r28+r27 accepted_values-doesnt-catch-NULL FIX-A WATCH CLOSES on 1st re-probe**

Pin-perfect canonical: "accepted_values compiles to `WHERE col NOT IN (...)`; `NULL NOT IN (...) = UNKNOWN` (not TRUE) in 3-valued logic, NULL rows silently excluded from failing set → NULLs PASS unnoticed. accepted_values validates non-NULL values only. FIX: add `- not_null` test alongside accepted_values."

Verified verbatim at [docs.getdbt.com/reference/resource-properties/data-tests](https://docs.getdbt.com/reference/resource-properties/data-tests): "the `accepted_values` data test validates that all of the **non-null** values in a column are present in a supplied list of `values`" + "This test automatically excludes `NULL` values from validation, consistent with how database foreign key constraints work. Use the `not_null` test separately if `NULL` values should cause failures." Confirmed by [dbt-core #8543](https://github.com/dbt-labs/dbt-core/issues/8543) "[CT-3070] accepted_values test passes despite NULL values" — the underlying mechanism is exactly the 3-valued-logic UNKNOWN-not-TRUE semantics the responder named.

**Direct iter1218 → iter1221 transition**: iter1218 responder said "NULL and 'none' will BOTH be caught because they are NOT in the allowed list" (factually wrong, FAIL 2.75). iter1221 responder says "CRITICAL NULL TRAP. accepted_values compiles to NOT IN; NULL NOT IN = UNKNOWN; NULLs PASS unnoticed; pair with not_null" — exactly the FIX-A spec landing point. Engineer in iter1221 scenario (NULL writes from migration that bypassed accepted_values) gets the right diagnosis + the right combined-test fix.

**iter1218 r28 §242 NULL-trap caveat + r28 §272 DO-NOT-WRITE pair-with-not_null + r27 §3006 reconcile** all reaching cleanly. 12th-or-so consecutive watch closing in 1st-re-probe-CLOSE pattern. No imported-prior, no broken-secondary, no over-warning. Cites r27/r28 + dbt docs.

---

## Q4 — Oracle NVL2 → Trino CASE/IF

**Score: 5.0** | Tech 5.0 | Clar 5.0 | App 5.0 | Compl 5.0
**Routing**: Oracle PL/SQL → dbt+Trino (line 335)

Pin-perfect Oracle→Trino conditional-function migration. Verified at [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html): no NVL2 function listed (conditional family is CASE / IF / COALESCE / NULLIF / TRY). Two valid Trino 467 rewrites both shown:
1. `CASE WHEN referral_code IS NOT NULL THEN 'referred' ELSE 'organic' END` — searched-CASE, portable across all SQL dialects
2. `IF(referral_code IS NOT NULL, 'referred', 'organic')` — Trino-native conditional, more concise

Both equivalent. Migration mapping table also correct: `NVL → COALESCE`, `NVL2 → CASE/IF`, `NULLIF → NULLIF` (same in both dialects). Matches r27 §6.4 Oracle conditional-function translation canonical. Consistent with iter1218 Q4 DECODE landing pattern (5th-or-so consistent DECODE/NVL/NVL2 family pass).

No imported-prior. No broken-secondary. No over-warning. No fabrication. Cites r27.

---

## Watches summary

**Watches CLOSED this iteration:**
- `iter1220 r10 transform-refinement-vs-column-addition cross-spec-pruning FIX-A` — CLOSED (Q1 load-bearing flipped to correct; minor framing slips non-load-bearing)
- `iter1218 r28+r27 accepted_values-doesnt-catch-NULL FIX-A` — CLOSED (Q3 pin-perfect 1st re-probe)

**Open watches carried forward:**
- `iter1219 CoW-vs-MoR findability` (re-probe 3-7)
- `iter1219 format-%08d co-located canonical` (re-probe 4-8)
- `iter1215 strpos-3-arg ceiling` (re-probe 6-10, accept-ceiling per pre-commitment, no churn)
- `iter1213 session_properties + (+)-mnemonic` (re-probe 3-6)
- `iter1206 LIKE-on-ROW + $partitions-omission` (re-probe 1-5)
- light-monitors: iter1214 Q1 retention_days param-fab + expire-vs-planning conflation; iter1214 Q3 config(severity:) Jinja-colon-vs-equals; iter1208 Q3 dbt selector direction +model vs model+; iter1209 Q3 CURRENT_TIMESTAMP() empty-parens; iter1191 dbt-contract-two-phase phrasing; iter1215 seed column_types-location.

**NEW soft watch this iter:**
- `iter1221 Q1 quarterly-window-vs-transform-granularity diagnosis` (re-probe 5-9 iters) — non-FIX
- `iter1221 Q2 market-basket basket-cardinality skew completeness` (re-probe if high-basket-cardinality framing surfaces) — non-FIX

**No FIX-A this iter.** All four answers passed; two watches closed cleanly on 1st re-probe.
