# iter797 Judge Feedback — DEFAULT NO-OP / durability-breadth sweep

**Teacher edits this iter:** ZERO (no resource changes). Expected-strong durability sweep.
**Verification:** every dialect claim checked against trino.io/docs/467 (regexp / aggregate / select / window .html) via WebFetch, 2026-06-09. resources/ NOT treated as ground truth.
**Production fit:** Trino 467 + Iceberg, on-prem. All four answers are pure SQL within stack constraints. No auth/authz scope.

---

## Per-question scores (Accuracy / Completeness / Clarity / Actionability)

### Q1 — EXTRACT NUMBER RE-PROBE (4-digit year from filename → integer) — 2nd regexp_extract datapoint
Answer: `CAST(regexp_extract(filename, '[0-9]{4}') AS INTEGER) AS year_number`; explained first-match + `{4}` = exactly 4 digits + CAST. Cited r23 §3.2 (lines 2800–2834). LED with regexp_extract.
- **Accuracy 5** — VERIFIED vs regexp.html: `regexp_extract(string, pattern) → varchar` "Returns the first substring matched". `'report_2026_final.pdf'` → first 4-digit run `'2026'` → `CAST AS INTEGER` = 2026. Correct.
- **Completeness 5** — pattern, first-match semantics, and CAST all explained. Acceptably flagged that `[0-9]{4}` grabs the FIRST 4-digit run (fine for these filenames).
- **Clarity 5** — clean, leads with the canonical, no muddled framing.
- **Actionability 5** — drop-in.
- **Q1 avg = 5.00**

### Q2 — FILTER ON COMPUTED VALUE / alias-in-WHERE WATCH
Answer: "You CANNOT reference a SELECT alias in WHERE — universal SQL rule." Gave subquery form (repeat `discount_amount/order_total > 0.5` in outer WHERE) AND CTE form (`WITH discounts AS (... discount_ratio) SELECT * ... WHERE discount_ratio > 0.5`). Cited r23.
- **Accuracy 5** — VERIFIED vs select.html: WHERE evaluated before SELECT → output aliases unresolvable in WHERE (valid in GROUP BY/HAVING/ORDER BY only). Rule correctly stated; both workarounds correct.
- **Completeness 5** — covers the rule + two canonical wrappings (subquery & CTE); subquery form also implicitly shows the "repeat the bare expression" option.
- **Clarity 5** — explains WHY (evaluation order), not just WHAT.
- **Actionability 5** — engineer has two ready patterns.
- **Q2 avg = 5.00**

### Q3 — LATEST-PER-GROUP COMPANION (price at latest changed_at, not MAX(price))
Answer: `ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY changed_at DESC)=1` (whole row) OR `max_by(price, changed_at) AS current_price` + `MAX(changed_at) GROUP BY product_id` (cheaper for specific columns). Cited r23 + r07.
- **Accuracy 5** — VERIFIED vs aggregate.html: `max_by(x, y)` "Returns the value of x associated with the maximum value of y" → `max_by(price, changed_at)` = price at latest changed_at. ROW_NUMBER DESC =1 = latest whole row. Both correct.
- **Completeness 5** — gives both the whole-row and the cheap-column approach with the right tradeoff guidance.
- **Clarity 5** — distinguishes "latest row" from MAX(price) misconception explicitly.
- **Actionability 5** — two drop-in patterns with a clear choice rule.
- **Q3 avg = 5.00**

### Q4 — CUMULATIVE RUNNING % (Pareto down revenue-desc ranking)
Answer: `SUM(pct_of_total) OVER (ORDER BY revenue DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_pct`; inner `pct_of_total = SUM(amount)*100.0/SUM(SUM(amount)) OVER ()`. Cited r07.
- **Accuracy 5** — VERIFIED vs window.html: aggregates usable as window fns via OVER; `SUM(SUM(amount)) OVER ()` = window-over-grouped-aggregate = grand total over the grouped result (standard valid Trino); explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` = standard running-total frame. `*100.0` forces double. Correct Pareto.
- **Completeness 5** — both the per-row %-of-total and the cumulative running % shown.
- **Clarity 5** — explicit frame removes ambiguity about default framing.
- **Actionability 5** — complete two-layer query, drop-in.
- **Q4 avg = 5.00**

---

## Overall

| Q | Acc | Compl | Clar | Action | avg |
|---|----|------|------|--------|-----|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = 5.00 → PASS** (threshold 3.5).

---

## Standing-item verdicts (teacher directives)

**(a) regexp_extract — BULLETPROOFED.** Q1 is the 2nd consecutive clean post-fix datapoint (after iter796). Responder LED with `CAST(regexp_extract(s, '<pattern>') AS INTEGER)`, no false "no digit-extraction function" claim, no broken regexp_replace fallback. The iter795 defect is fully closed and durable across two phrasings. Watch-item RETIRED.

**(b) alias-in-WHERE watch — CLOSED, slip did NOT recur.** iter796 carried a minor example-only slip (`WHERE order_num > 100` referencing a SELECT alias). In iter797 Q2 — directly probing filter-on-computed-value — the responder did the OPPOSITE of slipping: it correctly TAUGHT the rule ("cannot reference a SELECT alias in WHERE; WHERE runs before SELECT") and supplied correct subquery + CTE workarounds. Confirmed one-off; NO iter798 FIX-A. Watch-item CLOSED.

**(c) Other standing pins all clean:** max_by-latest-per-group (Q3), running-cumulative `SUM() OVER (... ROWS UNBOUNDED PRECEDING)` + pct-of-total `SUM(SUM()) OVER ()` (Q4) — all verified, no regression.

---

## iter798 designation: DEFAULT NO-OP / durability-breadth (expected)

No open defect, no new slip. Two watch-items closed this iteration (regexp_extract bulletproofed, alias-in-WHERE confirmed one-off). Recommend a NO-OP sweep of fresh adjacent topics. Suggested probes: `array_agg(DISTINCT ...)` / `from_unixtime` epoch→timestamp / `multimap_agg` vs `map_agg` / NTILE bucketing / `arbitrary()`/`any_value`. Optionally re-probe Q4 Pareto with different phrasing to bank a 2nd cumulative-% datapoint.

**PRESERVE (churn risk — all verified clean):** r23 §3.2 regexp_extract canonical, r23 alias-in-WHERE/subquery-CTE content, r23/r07 max_by + ROW_NUMBER latest-per-group, r07 running-total/pct-of-total window cards. No edits warranted.
