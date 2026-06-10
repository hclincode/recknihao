# Judge Feedback — iter929 (NO-OP durability sweep)

**Overall: 4.375 PASS** (Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 2.50 = 17.50/4). OVERALL AVERAGE governs — no per-Q veto. Trino 467 PINNED. All dialect claims verified vs trino.io/docs/467 (select.html, window.html, array.html) + Trino GitHub (#16533 alias scoping, NESTED_WINDOW analyzer behavior) via WebFetch + multi-source WebSearch 2026-06-10. DO NOT bump training/state.json (already 929; passed=true preserved).

---

## Per-question scores

### Q1 — avg delivery distance per zone — 5.00 CLEAN
`SELECT zone, AVG(distance_km) FROM deliveries GROUP BY zone` + columnar/file-skipping note.
- AVG + GROUP BY valid (verified aggregate.html: avg() ignores NULLs in count; select.html GROUP BY divides input into groups). One row per distinct zone, correct shape.
- Partition-pruning / columnar file-skipping commentary reasonable and correctly framed for Iceberg+Trino.
- Acc 5 / Comp 5 / Clar 5 / Act 5.

### Q2 — count pending refunds — 5.00 CLEAN
`SELECT COUNT(*) FROM refund_requests WHERE status = 'pending'`.
- Filter-then-count valid; `= 'pending'` naturally excludes NULL status. Correct.
- Acc 5 / Comp 5 / Clar 5 / Act 5.

### Q3 — count products with 'clearance' tag in array — 5.00 CLEAN
`SELECT COUNT(*) FROM products WHERE contains(tags, 'clearance')` + contrast with UNNEST(CROSS JOIN)+COUNT(DISTINCT).
- VERIFIED: `contains(x, element) → boolean` "Returns true if the array x contains the element" (array.html). Correct, idiomatic array-membership test in Trino 467. Each product evaluated once → COUNT(*) tallies products, NOT tag occurrences.
- UNNEST + CROSS JOIN alternative correctly noted as ROW-EXPLODING (one row per tag), requiring COUNT(DISTINCT product_id) to avoid double-counting multi-tag products. Accurate contrast; `contains` is the right lead.
- Acc 5 / Comp 5 / Clar 5 / Act 5.

### Q4 — avg attempts before success per order — 2.50 (approach right, implementation INVALID/won't run)
`WITH attempts_ranked AS (SELECT order_id, attempt_at, succeeded, ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY attempt_at ASC) AS attempt_num, MAX(CASE WHEN succeeded THEN attempt_num ELSE NULL END) OVER (PARTITION BY order_id) AS final_success_attempt FROM payment_attempts), ... SELECT AVG(final_success_attempt) ...`

**VERIFIED Q4 VERDICT — CONFIRMED STRUCTURAL DEFECT (verified BOTH directions per iter882 protocol). The inner SELECT is INVALID and would NOT run.** Two independent, mutually-reinforcing grounds:

1. **Alias-not-resolvable-in-same-SELECT.** `MAX(CASE WHEN succeeded THEN attempt_num ELSE NULL END) OVER (...)` references `attempt_num`, the ROW_NUMBER() output ALIAS defined in the SAME SELECT list. Trino 467 output-column aliases are visible ONLY in the outer ORDER BY (after projection) — NOT in sibling SELECT-list expressions, NOT in GROUP BY/WHERE/HAVING (verified select.html: aliases usable in ORDER BY only; confirmed by Trino GitHub #16533 "Using alias in group by is not supported" — same pre-projection scoping rule). → `Column 'attempt_num' cannot be resolved`.

2. **Nested-window (even if `attempt_num` were inlined).** Replacing `attempt_num` with the inline `ROW_NUMBER() OVER (...)` puts a window function inside another window aggregate's argument → Trino analyzer (`ExpressionAnalyzer.java`) throws `NESTED_WINDOW`: *"Cannot nest window functions or row pattern measures inside window specification."* (Same rule resources already document at r07 L3209/L3221.)

Either way the query errors at analysis time. The CONCEPT (rank attempts per order by time, find the attempt number of the first success, average those across orders) is CORRECT. The single-level implementation is broken. **Correct shape:** compute `attempt_num` (+ `succeeded`) in CTE-1; in a SEPARATE outer layer aggregate `MIN(attempt_num) WHERE succeeded` (or `MAX(CASE WHEN succeeded THEN attempt_num END)`) per order; then `AVG(...)` across orders. You cannot reference the window alias OR nest the windows in one SELECT.

- Acc 2 (query will not execute) / Comp 3 (approach + CTE skeleton present, success-isolation logic sound) / Clar 3 / Act 2 (engineer who pastes this hits an analysis error). = 2.50.

---

## (a) DEFECT — confirmed
ONE defect: Q4 inner SELECT references a window-fn output alias (`attempt_num`) inside a sibling window aggregate in the same SELECT (alias-not-resolvable), and would also be a NESTED_WINDOW error if inlined. Confirmed it would NOT run. Approach conceptually correct; needs two CTE layers.

## (b) SCOPE — RESPONDER synthesis slip → RE-PROBE-DON'T-CHURN (NO FIX-A)
Both root causes are ALREADY TAUGHT, findably and prominently, in resources:
- **Alias-not-visible-to-sibling-SELECT**: r07 L4448, L4506–L4514 ("output column aliases are visible ONLY [in ORDER BY]"; explicit DO-NOT-WRITE example of referencing a SELECT alias in a sibling SELECT expression), L2806.
- **NESTED_WINDOW illegal**: r07 §B-Streak L3155/L3209/L3221 — quotes the exact analyzer error and prescribes the 3-layer materialize-then-consume fix.

The responder had BOTH rules available and failed to apply them when synthesizing a novel multi-step query — it collapsed two CTE layers into one. This is a SYNTHESIS slip on rules already covered, NOT a findable content gap. **No iter930 FIX-A.** Churning r07 (already dense with these cards) risks New-Card-over-attracts / defang regressions for zero benefit. RE-PROBE next sweep with an explicit "rank-then-aggregate-first-success per group / average" question to confirm the responder can compose the two-CTE-layer pattern. Only escalate to a dedicated FIX-A router card ("first-success / first-matching-rank per group = TWO CTE layers; never alias-in-sibling, never nested window") if the slip recurs across 2+ sweeps.

## (c) prod-env
Unaffected — pure analytical SQL. On-prem Trino 467 + Iceberg + MinIO + Hive Metastore + JWT/OPA all untouched. No federation probed (federation 4.49944/310, thinnest passing row, UNCHANGED).

## (d) iter930 = DEFAULT NO-OP / durability-breadth
Optional fresh adjacents: (1) RE-PROBE the Q4 slip — "average rank of first qualifying event per group" forcing the two-CTE-layer split (does responder avoid alias-in-sibling + nested-window?); (2) `contains(array, element)` vs `any_match`/`element_at` array predicates; (3) AVG GROUP BY with COALESCE(x,0) treat-absent-as-zero interpretation; (4) CONSIDER probing FEDERATION (thinnest passing row, long un-retested). PRESERVE full iter534–928 pin inventory; NO federation edits.

DO NOT touch state.json.
