# Judge Feedback — iter1010

**OVERALL: 4.40625 (70.5 / 16) — PASS** (threshold ≥ 3.5; margin +0.90625; OVERALL AVERAGE governs, NO per-Q veto)

Verified BOTH directions vs trino.io/docs/467 (functions/array.html, functions/datetime.html) + WebSearch — NOT resources/. Prod stack (Trino 467 + Iceberg, on-prem) fits all 4; no federation/auth angle this sweep.

---

## Dialect verifications (with citations)

1. **(KEY) `generate_subscripts` — NOT a Trino 467 function.** PostgreSQL-only. functions/array.html lists only `sequence(start, stop[, step])` and `repeat(element, count)` as series/array generators — no `generate_subscripts`. **The Q4 PRIMARY query is a function-not-found DEFECT.** Trino's idiomatic spine is `UNNEST(sequence(...))` — which the responder's SECOND query uses correctly.
2. **`INTERVAL '1' MONTH * <integer>` — VALID.** Trino supports multiplying an interval by a number. So the interval arithmetic in the primary query is fine; that query fails ONLY on `generate_subscripts`, not on the multiply.
3. **`date_trunc('day', timestamp)` return type — TIMESTAMP at midnight, NOT DATE.** datetime.html: return type is same-as-input; `date_trunc('day', TIMESTAMP '2022-10-20 05:10:00')` → `2022-10-20 00:00:00.000`. Responder's "returns a DATE value" is a **minor type imprecision** (grouping by it still produces correct daily buckets, so functionally harmless). To get an actual DATE: `CAST(occurred_at AS date)` or `date(occurred_at)`.
4. **Q3 CASE-in-ORDER-BY — VALID.** Unmatched statuses → NULL from CASE → sort LAST under Trino default NULLS LAST. Correct.
5. **Q2 MIN+MAX single GROUP BY — VALID, single scan.** Correct.

---

## Per-question scores

### Q1 — strip time / group by day (4.25)
`date_trunc('day', occurred_at)` + `GROUP BY date_trunc('day', occurred_at)` is correct and idiomatic; pruning-aside (don't wrap partition cols in functions, but fine for grouping) is accurate and useful. Sole ding: claims the result "returns a DATE value" — it actually returns a TIMESTAMP at midnight (same type as input). Functionally harmless for grouping but technically imprecise; should have offered `CAST(... AS date)` if a true DATE is wanted.
**Acc 4 / Comp 4.25 / Clar 4.5 / App 4.25**

### Q2 — MIN and MAX per product (4.875)
`SELECT product_id, MIN(order_value), MAX(order_value) ... GROUP BY product_id`. Fully correct, single-scan multi-aggregate note accurate. Clean.
**Acc 5 / Comp 4.75 / Clar 5 / App 4.75**

### Q3 — custom sort order (4.8125)
`ORDER BY CASE status WHEN 'active' THEN 1 WHEN 'trial' THEN 2 WHEN 'churned' THEN 3 END`. Valid; unmatched→NULL→sorts last (correct under default NULLS LAST). Clean. Could optionally note an explicit ELSE for deterministic placement of unknowns, but the NULLS-LAST behavior is correctly stated.
**Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75**

### Q4 — count completed per month, KEEP zero months (3.6875)
Core concept is RIGHT: `COUNT(*) FILTER (WHERE status='completed')` is correct Trino (verified) and is exactly the construct the user needs. The SECOND ("simpler") query is fully correct Trino: `UNNEST(sequence(DATE '2026-01-01', current_date, INTERVAL '1' MONTH)) AS d(month)` LEFT JOIN the FILTER aggregate, COALESCE(...,0). **But the PRIMARY query is a DEFECT:** it uses `generate_subscripts(ARRAY[0,1,2,3,4,5], 1)`, which is NOT a Trino function (PostgreSQL-only) → function-not-found at parse/analysis. A weak reader could copy the primary and hit an error.

**User's ACTUAL fix clarification (note for teacher):** The simplest correct answer is just `GROUP BY date_trunc('month', payment_date)` + `COUNT(*) FILTER (WHERE status='completed')` with NO outer WHERE on status — that keeps every month that has *any* payment (the original bug was almost certainly a `WHERE status='completed'` filtering out whole months). The calendar spine (`UNNEST(sequence(...))` + LEFT JOIN + COALESCE) is ONLY needed for months that have ZERO payments of any kind. The responder buried the simplest fix and led with a broken spine.
**Acc 3.25 / Comp 4 / Clar 3.75 / App 3.75**

---

## TICs / pattern notes
- `::` cast shorthand: ABSENT all 4 (lock holds).
- Q4 is the recurring **"broken secondary/alternative" pattern** — except here it's inverted: the broken form is the PRIMARY and the correct form is the secondary. The correct construct (FILTER + UNNEST(sequence) spine) IS present and correct, so the LEAD concept passes; the `generate_subscripts` primary is a per-instance PostgreSQL-prior import slip.
- `generate_subscripts` is a NEW fabrication slip (1st occurrence) — not previously seen; imported-PostgreSQL-prior family (cf. date−integer, ILIKE).

## RECOMMENDATION = DEFAULT NO-OP
- Overall 4.40625 PASS, margin +0.90625; 3 of 4 clean; Q4 core concept correct with a correct second query present.
- `generate_subscripts` is a **1st-occurrence responder slip**, NOT a findable resource gap or 2-in-2 recurrence. Resources already teach `UNNEST(sequence(...))` as the spine (the responder produced it correctly as the second query), so there is no missing canonical to add — the failure is the responder ALSO emitting a PostgreSQL primary, not a resource hole.
- **No resource edit; no FIX-A.** Monitor for a 2nd `generate_subscripts`/PG-series-generator occurrence — if it recurs in 2-in-2, consider a LIGHT findability nudge pinning `sequence()+UNNEST` as the ONLY Trino series generator (with `generate_subscripts`/`generate_series` defanged as PG-only). Until then, do not churn.

Re-probe next sweep: (a) another month/date-spine Q — confirm `UNNEST(sequence(...))` leads cleanly without a PG primary; (b) date_trunc return-type precision (DATE vs TIMESTAMP-at-midnight); (c) `COUNT(*) FILTER (WHERE ...)` vs `SUM(CASE...)`; (d) CASE-in-ORDER-BY + NULLS LAST. Federation r22 §13.x hard-locked NOT probed (4.49944/310). MUST NOT bump state.json (already 1010; orchestrator commits).
