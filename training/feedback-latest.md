# Judge Feedback — iter762 (EXTENDED PHASE)

**Overall: 4.625 PASS** (margin +1.125 above 3.5 floor). Per-Q avgs: Q1 3.50 / Q2 5.00 / Q3 5.00 / Q4 5.00. Overall average governs (no per-Q veto).

All dialect claims verified against trino.io/docs/467 via WebFetch (select.html, functions/aggregate.html, functions/window.html). Production stack confirmed: Trino 467 + Iceberg connector, on-prem (prod_info.md). Note: prod_info.md target-serving section is unfilled; evaluated against the documented Trino 467 production query stack, which is the relevant constraint for these SQL questions.

---

## Q1 — ROLLUP RE-PROBE: revenue by (year, month) + per-year subtotal + grand total — 3.50

| Axis | Score | Reason |
|---|---|---|
| Accuracy | 3 | ROLLUP selection CORRECT (NOT CUBE) — hierarchical (year,month),(year),() with no per-month-only row, exactly the ask. GROUPING bitmask 0/1/3 CORRECT (no WHEN-2 row; ROLLUP never emits GROUPING=2). ORDER BY GROUPING(...), year NULLS LAST, month NULLS LAST CORRECT. **BUT one genuine, load-bearing dialect defect: `GROUP BY ROLLUP(EXTRACT(YEAR FROM billing_month), EXTRACT(MONTH FROM billing_month))` is INVALID in Trino 467.** |
| Completeness | 4 | Covers selection rationale, GROUPING labeling, ordering — but omits the CTE/subquery pre-computation step the EXTRACT form actually requires to run. |
| Clarity | 4 | Clear CASE-on-GROUPING labels (Monthly Detail / Year Subtotal / Grand Total), well explained. |
| Actionability | 3 | Engineer copies the query and it FAILS analysis on first run with an error on the ROLLUP arguments. Selection logic is right but the executable block is grain-correct yet won't execute. |

**VERIFIED DEFECT (trino.io/docs/467/sql/select.html, exact quote):** "Complex grouping operations do not support grouping on expressions composed of input columns. Only column names are allowed." This applies to ROLLUP, CUBE, and GROUPING SETS. The responder placed `EXTRACT(YEAR FROM billing_month)` and `EXTRACT(MONTH FROM billing_month)` directly inside `ROLLUP(...)`. Trino 467 rejects this at analysis time — the EXTRACT expressions are not column names.

**CORRECT FORM (the fix):** pre-compute the EXTRACT expressions as named columns in a subquery/CTE, then ROLLUP over those column names:
```
WITH m AS (
  SELECT EXTRACT(YEAR FROM billing_month) AS yr,
         EXTRACT(MONTH FROM billing_month) AS mo,
         revenue
  FROM ...)
SELECT yr, mo, SUM(revenue) AS total
FROM m
GROUP BY ROLLUP(yr, mo)
ORDER BY GROUPING(yr, mo), yr NULLS LAST, mo NULLS LAST
```

**ROLLUP-vs-CUBE selection is the bulletproof target — and it held: the responder picked ROLLUP (not CUBE) for the 2nd consecutive clean datapoint (iter761 + iter762). The selection-router from iter761 is doing its job.** The defect this iteration is a DIFFERENT, NEWLY-SURFACED gap: grouping on EXTRACT expressions inside ROLLUP. The r28 canonical ROLLUP example (`GROUP BY ROLLUP(region, product)`) uses bare column names, so it is docs-correct; the responder over-generalized by inlining EXTRACT into the ROLLUP arg list. The card never showed (or warned against) the expression-inside-ROLLUP form.

## Q2 — deviation from customer's average order amount, keep every row — 5.00

| Axis | Score | Reason |
|---|---|---|
| Accuracy | 5 | `order_amount - AVG(order_amount) OVER (PARTITION BY customer_id)` valid Trino 467 — aggregate-as-window form VERIFIED (functions/window.html: "All Aggregate functions can be used as window functions by adding the OVER clause"). Correct group-mean-centered value. |
| Completeness | 5 | Includes both the deviation column and the customer_avg column; explains the windowed avg repeats per partition row. |
| Clarity | 5 | "every detail row preserved, one pass vs JOIN-to-GROUP-BY reading the table twice" — exactly the right mental model. |
| Actionability | 5 | Copy-paste runs; engineer knows precisely what to do. |

FRESH-CLEAN. Deviation-from-group-mean (x - avg(x) OVER (PARTITION BY g)) confirmed docs-correct.

## Q3 — per-user fraction of events that were errors (conditional rate) — 5.00

| Axis | Score | Reason |
|---|---|---|
| Accuracy | 5 | `CAST(COUNT(*) FILTER (WHERE status='error') AS DECIMAL(10,4)) / NULLIF(COUNT(*),0)` valid Trino 467. FILTER VERIFIED (functions/aggregate.html: "The FILTER keyword can be used to remove rows from aggregation processing"). CAST-to-DECIMAL dodges integer-division-truncates-to-0; NULLIF guards divide-by-zero. |
| Completeness | 5 | Explains FILTER subset count, the integer-division trap, the zero-guard. |
| Clarity | 5 | Each clause justified plainly. |
| Actionability | 5 | Runs as-is. |

FRESH-CLEAN. NOTE: the directive anticipated `avg(CASE WHEN cond THEN 1.0 ELSE 0 END)`, but the responder chose the `COUNT(*) FILTER` variant — EQUALLY VALID, arguably cleaner, native Trino. NOT penalized for the choice (both docs-correct). The CAST-to-DECIMAL + NULLIF decimal-rate is correct.

## Q4 — per-endpoint p95 response time (robust to outliers) — 5.00

| Axis | Score | Reason |
|---|---|---|
| Accuracy | 5 | `approx_percentile(response_time_ms, 0.95)` per GROUP BY endpoint valid Trino 467; t-digest-based. The approx_percentile (t-digest, percentiles) vs approx_distinct (HLL, distinct counts) distinction is accurate and genuinely useful. |
| Completeness | 5 | Adds p50/p99; explains 0.95 is a fraction (95th pct), not 95ms; notes the sketch avoids a full sort. |
| Clarity | 5 | The "0.95 = 95th percentile, not 95 milliseconds" disambiguation is exactly the beginner trap to head off. |
| Actionability | 5 | Runs as-is. The PERCENT_RANK exact-alternative aside is a valid (slower) approach — not over-scrutinized. |

FRESH-CLEAN. p95 approx_percentile / t-digest confirmed; HLL-vs-t-digest distinction accurate.

---

## Verdict and iter763 directive

**ROLLUP-vs-CUBE selection: BULLETPROOFED — YES.** 2nd consecutive clean datapoint (iter761 + iter762). The responder correctly chose ROLLUP over CUBE for a hierarchical-subtotal ask, emitting no per-month-only rows, with the correct GROUPING 0/1/3 bitmask. The iter761 selection-router is working. This construct-choice sub-skill is closed.

**Q2 deviation / Q3 conditional-rate / Q4 p95: ALL FRESH-CLEAN, maximum signal.** No gaps.

**NEW GAP (iter763 = FIX-A):** ROLLUP (and CUBE / GROUPING SETS) over **computed expressions** is invalid in Trino 467 — "Only column names are allowed." The responder inlined `EXTRACT(YEAR FROM ...)` / `EXTRACT(MONTH FROM ...)` directly into `ROLLUP(...)`, producing a query that fails analysis. This is a DIFFERENT defect from the iter760 ROLLUP-vs-CUBE selection gap (now closed) — it is a structural-form gap, not a construct-choice gap.

**iter763 FIX-A (narrow, additive, reconcile-in-place at the r28 GROUPING SETS/ROLLUP/CUBE card):**
- Add a tight READ-ME-FIRST clarifier at the r28 card: "ROLLUP/CUBE/GROUPING SETS take COLUMN NAMES ONLY — Trino 467 rejects `ROLLUP(EXTRACT(YEAR FROM col), ...)` or any expression inside the grouping operation. Pre-compute the expression as a named column in a CTE/subquery, then ROLLUP over the alias."
- Include the WRONG inline-defang (`GROUP BY ROLLUP(EXTRACT(YEAR FROM billing_month), ...)` — un-copyable per iter693 pattern) and the CORRECT CTE-then-`ROLLUP(yr, mo)` canonical with the exact docs quote ("Complex grouping operations do not support grouping on expressions composed of input columns. Only column names are allowed.").
- This is the year/month-from-date ROLLUP shape specifically — a very common SaaS revenue-rollup phrasing. Place keyword anchors near it (revenue by year/month with subtotals, monthly rollup with year subtotal, date-bucketed grand total).
- Keep it ADDITIVE — do NOT churn the existing iter761 selection-router or the CUBE/GROUPING-SETS/bitmask content (all docs-correct and bulletproofed).

HOLD all iter534-761 locks (~308). resources/22 federation untouched (do not probe — 4.49944 vs 4.5 thin). Do NOT touch state.json.

**OVERALL: 4.625 PASS — ROLLUP-vs-CUBE selection BULLETPROOFED (2nd consecutive clean, iter761+762); Q2 deviation / Q3 conditional-rate / Q4 p95 all fresh-clean with maximum signal; ONE newly-surfaced FIX-A gap on Q1 — ROLLUP over EXTRACT expressions is invalid in Trino 467 (only column names allowed), the query fails analysis as written; fix = pre-compute in a CTE then ROLLUP over column names.**
