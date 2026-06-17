# iter1014 Judge Feedback

**OVERALL: 4.75 (76.0/16) — PASS** (threshold 3.5; margin +1.25; OVERALL AVERAGE governs, no per-Q veto)

Verified BOTH directions vs trino.io/docs/467 (sql/select.html, functions/window.html, functions/math.html) + WebSearch — NOT resources/. Prod stack (Trino 467 + Iceberg, on-prem MinIO/HMS) fits all 4; no federation/auth angle this iter.

## Per-question scores

| Q | Acc | Comp | Clar | App | Avg |
|---|---|---|---|---|---|
| Q1 window COUNT OVER PARTITION (no collapse) | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q2 CASE-in-ORDER-BY custom sort | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q3 (KEY) INTERSECT both-sets | 5 | 4.75 | 4.625 | 4.75 | 4.78125 |
| Q4 abs() absolute-value filter | 4.75 | 4.5 | 4.75 | 4.5 | 4.625 |

16 sub-scores sum = 76.0 → 76.0/16 = **4.75**.

## Resolved verdicts (with citations)

1. **Q1 — CORRECT.** `COUNT(*) OVER (PARTITION BY user_id) AS user_total_events`: with NO ORDER BY in the window, all rows in the partition are peers, so the frame defaults to the ENTIRE partition (RANGE UNBOUNDED PRECEDING→UNBOUNDED FOLLOWING). Returns the full per-user event count on every row, KEEPS all rows (window fns are one-row-per-input, no collapse), single pass, no subquery+join. Valid Trino 467. (functions/window.html "all rows are peers" / sql/select.html)
2. **Q2 — CORRECT.** `ORDER BY CASE plan_type WHEN 'enterprise' THEN 1 WHEN 'pro' THEN 2 WHEN 'starter' THEN 3 ELSE 4 END`: ORDER BY accepts arbitrary expressions ("Each expression may be composed of output columns…"); CASE produces a numeric sort key, ELSE 4 puts all other/unknown plan types last. Valid Trino 467. (sql/select.html)
3. **Q3 (KEY) — CORRECT.** `SELECT user_id FROM users INTERSECT SELECT user_id FROM referrals`: INTERSECT returns only rows present in BOTH queries; "If neither [ALL/DISTINCT] is specified, the behavior defaults to DISTINCT" — so dedup is automatic, no JOIN/GROUP BY needed. Set-op distinctness (NULL not distinct from NULL) means it does NOT inherit the NOT-IN 3VL trap. Responder's note to use a semi-join/explicit join for multi-column or extra-filter matching is sound. Valid Trino 467. (sql/select.html)
4. **Q4 — CORRECT.** `WHERE abs(fee_amount) > 100`: `abs(x)` is a Trino 467 math built-in returning the magnitude, same type as input; `abs(-150)=150` so a -$150 refund passes. Simpler than a CASE/OR sign-split. Valid Trino 467. (functions/math.html)

## Defects / notes

- ZERO parse-error defects. ZERO `::`-cast shorthand (absent all 4). ZERO broken-secondary "for completeness" padding. ZERO TICs (no QUALIFY / false-semi-join / MAX-varchar / GREATEST-LEAST-NULL / fabricated-fn [COUNT/abs/INTERSECT all real & verified] / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / generate_subscripts).
- Minor Q4 nits (not defects): no mention of `abs()` returning NULL on NULL input, or that INTEGER `abs(MIN_VALUE)` overflows — niceties, not errors for the as-asked refund-magnitude filter.
- All 4 KEY/dialect checks resolved in the responder's favor against official 467 docs.

## Recommendation: DEFAULT NO-OP

Margin +1.25; all 4 correct & verified both directions; KEY Q3 INTERSECT default-DISTINCT resolved in responder's favor; no findable gap, no resource defect, no 2-in-2 recurrence. NO resource edit; NO FIX-A. State.json already at 1014 (orchestrator commits) — MUST NOT bump.

Re-probe next sweep: (a) window-agg-no-ORDER-BY full-partition vs running (watch FIRST_VALUE/LAST_VALUE default-frame trap); (b) CASE-in-ORDER-BY + NULLS LAST for ELSE/unmatched; (c) INTERSECT default-DISTINCT/ALL + semi-join alt durable; (d) abs()/sign math built-in (watch NULL-in→NULL, integer-overflow edge). Federation r22 §13.x hard-locked NOT probed (4.49944/310).
