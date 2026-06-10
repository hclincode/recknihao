# Judge Feedback — iter925 (NO-OP durability sweep)

**Overall: 4.50 PASS** (Q1 5.00 / Q2 3.50 / Q3 5.00 / Q4 5.00 = 18.00/4). OVERALL AVERAGE governs — no per-Q veto. Threshold 3.5 met.

Trino 467 PINNED. All dialect claims verified vs trino.io/docs/467 functions/aggregate.html + WebSearch/WebFetch 2026-06-10 (NOT against resources/). Multi-source.

---

## Q2 MULTI-ARG COUNT(DISTINCT a,b) VERDICT — EXPLICIT

**CONFIRMED SYNTAX DEFECT (Approach 2 only).** Verified BOTH directions per iter882 lesson.

- trino.io/docs/current(467) functions/aggregate.html documents `count()` with EXACTLY two signatures: `count(*) → bigint` and `count(x) → bigint`. A SINGLE argument. There is **no** multi-argument `count(DISTINCT a, b)` signature.
- Therefore the responder's Approach-2 expression `COUNT(DISTINCT user_id, date_trunc('week', login_at))` with TWO comma-separated args is a **signature/parse error** in Trino 467 (`Unexpected parameters … Expected: count(), count(t)`). It would NOT run.
- The documented way to count distinct COMBINATIONS in Trino is to **ROW-wrap**: `COUNT(DISTINCT (user_id, week_start))` (parenthesized tuple → ROW type counted as one composite value). Confirmed via WebSearch (trinodb/trino + querifylabs distinct-aggregation references).
- SEMANTICS (had the syntax been valid): Approach-2 ratio = total_logins / distinct(user, week) pairs = "avg logins per active user-week" = SAME metric as Approach 1. So it is semantically equivalent — the defect is purely the multi-arg signature, not the math.

**SCOPE-CHECK: RESPONDER SYNTHESIS SLIP, not a findable resource gap.**
- Approach 1 (the RECOMMENDED lead) — `WITH lppw AS (SELECT user_id, date_trunc('week', login_at) AS week_start, COUNT(*) AS logins_this_week FROM logins GROUP BY user_id, date_trunc('week', login_at)) SELECT AVG(logins_this_week) FROM lppw` — is **CORRECT** (count per user-week, then AVG). The responder led with the right answer.
- The broken multi-arg form appears only in a clearly-labeled "shortcut / mathematically equivalent" ALTERNATIVE. This is a synthesis slip in an optional alternative, not a wrong primary answer and not a missing resource. **RE-PROBE, DON'T CHURN.** Do NOT edit resources for this. A teacher edit risks New-Card-Over-Attracts-Adjacent / defang regressions for zero benefit since the lead is correct.

Q2 scored DOWN proportionally (not vetoed): correct recommended form delivered (full credit on the lead), broken "shortcut" alternative drags Accuracy/Actionability. Q2 = 3.50 (Acc 3 / Comp 4 / Clar 4 / Act 3).

---

## Per-question scores

| Q | Accuracy | Completeness | Clarity | Actionability | Avg | Verdict |
|---|---|---|---|---|---|---|
| Q1 count products stock < reorder_threshold | 5 | 5 | 5 | 5 | 5.00 | CLEAN |
| Q2 avg logins per user per week | 3 | 4 | 4 | 3 | 3.50 | DEFECT in Approach-2 shortcut; Approach-1 lead correct |
| Q3 count orders above store avg | 5 | 5 | 5 | 5 | 5.00 | CLEAN |
| Q4 count gift-wrap orders | 5 | 5 | 5 | 5 | 5.00 | CLEAN |

**Q1** `SELECT COUNT(*) FROM products WHERE stock_level < reorder_threshold` — column-vs-column comparison in WHERE is valid Trino; count(*) tallies surviving rows. CORRECT.

**Q3** `WITH store_avg AS (SELECT store_id, AVG(order_total) AS avg_order_total FROM orders GROUP BY store_id) SELECT COUNT(*) FROM orders o JOIN store_avg sa ON o.store_id=sa.store_id WHERE o.order_total > sa.avg_order_total` — above-store-average count via CTE-AVG + JOIN + filter. Valid and correct (per-store avg broadcast back via equi-join, strict `>` counts strictly-above orders). CORRECT.

**Q4** `count_if(gift_wrap)` / `COUNT(*) … WHERE gift_wrap = true` / `COUNT(*) FILTER (WHERE gift_wrap)` — all three valid in 467. Verified: `count_if(x)` documented ("Returns the number of TRUE input values; equivalent to count(CASE WHEN x THEN 1 END)"); FILTER documented as "supported for all aggregate functions." count_if(bool) is the idiomatic lead. CORRECT.

---

## Defect / scope summary

- **(a) ONE defect:** Q2 Approach-2 multi-arg `COUNT(DISTINCT a, b)` = confirmed Trino 467 syntax error (needs ROW-wrap `COUNT(DISTINCT (a,b))`). Confined to a labeled optional shortcut; Q2's recommended lead (CTE count-per-user-week + AVG) is correct.
- **(b) SCOPE:** RESPONDER synthesis slip in an optional alternative — NOT a findable resource gap. Re-probe next sweep with a multi-col distinct-count question; do NOT churn resources.
- **(c) Prod-env:** unaffected — all pure SQL on on-prem Trino 467 + Iceberg + MinIO + HMS + JWT/OPA.
- **(d) iter925 = DEFAULT NO-OP.** No teacher edits warranted. Optional fresh adjacents next sweep: explicit `COUNT(DISTINCT (a,b))` ROW-wrap distinct-combination count (directly re-probes this slip), AVG-over-CTE rate metrics, count_if vs FILTER vs CASE share. CONSIDER probing FEDERATION (thinnest passing row 4.49944/310, long un-retested). PRESERVE full iter534–924 pin inventory; NO federation edits (federation 4.49944/310, UNCHANGED — not probed).

DO NOT bump training/state.json (already 925; passed=true preserved).

## Sources
- [Aggregate functions — Trino docs (current / 467)](https://trino.io/docs/current/functions/aggregate.html)
- [SELECT — Trino docs](https://trino.io/docs/current/sql/select.html)
- [Distinct aggregation optimization in Trino — Querify Labs](https://www.querifylabs.com/blog/distinct-aggregation-optimization-in-apache-calcite-and-trino)
