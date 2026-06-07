# iter635 — JUDGE FEEDBACK

## Per-question scores (Accuracy / Completeness / Clarity / Actionability, each 1-5)

### Q1 — Share of total revenue from TOP 20% highest-spending customers
- Accuracy: **3** — DIRECTION is correct (FIX-A guardrail LANDED), but the final query has a column-scope bug that will fail in Trino 467.
- Completeness: **4** — All the structural pieces (per-customer SUM, quintile, top-quintile total, grand total, ratio*100) are present.
- Clarity: **4** — CTE-by-CTE structure is easy to follow; explanation of NTILE DESC bucket-1 = top is clean.
- Actionability: **3** — The engineer cannot copy-paste-run the final SELECT as written; needs the column-scope fix.
- **Avg: 3.5**

**(a) FIX-A direction guardrail — LANDED.**
`NTILE(5) OVER (ORDER BY total_spend DESC) AS spend_quintile` followed by `WHERE spend_quintile = 1` correctly selects the TOP quintile under DESC. Verified against trino.io/docs/467/functions/window.html: ntile(n) assigns bucket 1 to the FIRST rows in ORDER BY order, so under `ORDER BY ... DESC` bucket 1 = highest. The responder did NOT invert (no iter634-style `percent_rank >= 0.9 under DESC` bottom-decile bug). The leading canonical sub-section at r07:1794 is doing its job.

**(b) Final-query scope bug — REAL.**
The final SELECT reads:
```sql
SELECT ROUND(100.0 * top_20_revenue / SUM(total_spend), 2) AS pct_revenue_from_top_20
FROM top_quintile, (SELECT SUM(total_spend) AS total FROM ranked_customers)
```
The cross-joined FROM clause exposes exactly two columns: `top_20_revenue` (from the `top_quintile` CTE) and `total` (from the subquery's aliased SUM). `total_spend` is NOT a column in scope at the outer SELECT — it lives inside `ranked_customers`, which is wrapped behind the subquery. Trino 467 will fail with a column-resolution error (`Column 'total_spend' cannot be resolved` or similar), and even if it did resolve, applying `SUM()` to a single-row cross-joined context is meaningless. The correct outer SELECT is:
```sql
SELECT ROUND(100.0 * top_20_revenue / total, 2) AS pct_revenue_from_top_20
FROM top_quintile, (SELECT SUM(total_spend) AS total FROM ranked_customers)
```
The bug is a final-assembly mistake (the SUM was correctly moved into the inner subquery but the outer reference was not updated to use the alias `total`). Approach correct, execution buggy.

### Q2 — Split customers into 5 equal-sized tiers by spend
- Accuracy: **5** — `NTILE(5) OVER (ORDER BY SUM(amount) DESC) AS spend_tier ... GROUP BY customer_id` is valid Trino 467 syntax. Window functions are computed AFTER aggregation, so the window can sort on `SUM(amount)` directly without a CTE. Tier 1 = highest under DESC: verified correct. Remainder distributed to first buckets: verified verbatim from trino.io/docs/467/functions/window.html (`If the number of rows in the partition does not divide evenly into the number of buckets, then the remainder values are distributed one per bucket, starting with the first bucket`).
- Completeness: **5** — Direction noted, remainder rule noted (101 customers → tier 1 gets 21), GROUP BY at customer grain noted.
- Clarity: **5** — Concise, on-point, the example with 101 rows makes the remainder rule click.
- Actionability: **5** — Copy-paste-runnable. Engineer knows exactly what to do.
- **Avg: 5.0**

### Q3 — Avg days between 1st and 2nd order for repeat customers
- Accuracy: **5** — ROW_NUMBER() OVER (PARTITION BY customer ORDER BY order_date) + MAX(CASE WHEN order_num=N THEN order_date END) pivot pattern is a canonical Trino 467 idiom. HAVING the order_num=2 date IS NOT NULL correctly filters single-order customers (repeat-customer guard). date_diff('day', first, second) returns BIGINT, and CAST to DOUBLE is valid and defensive for AVG (though AVG over BIGINT already produces a numeric without overflow risk at SaaS scale, the CAST is harmless and arguably clearer about the result type).
- Completeness: **5** — Both the pivot pattern AND the repeat-customer filter AND the per-customer-then-average aggregation are present.
- Clarity: **4** — The CASE-pivot pattern is slightly subtle for beginners but the explanation around HAVING IS NOT NULL makes the repeat-customer filter clear.
- Actionability: **5** — Copy-paste-runnable.
- **Avg: 4.75**

### Q4 — Overall % of sessions with converted = true
- Accuracy: **5** — `ROUND(100.0 * SUM(CASE WHEN converted THEN 1 ELSE 0 END) / COUNT(*), 2)` is the canonical conversion-rate idiom in Trino 467. The `100.0` (DOUBLE) on the left correctly forces float division, avoiding integer-division truncation. The alternative `SUM(CAST(converted AS INTEGER))` is valid in Trino 467 — boolean → integer CAST produces TRUE=1, FALSE=0, NULL=NULL (verified semantics — Trino supports CAST between BOOLEAN, TINYINT, SMALLINT, INTEGER, BIGINT, REAL, DOUBLE, VARCHAR).
- Completeness: **5** — Primary form, alternative form, and the NULL-handling note are all present. Could mention `count_if(converted)` as the most idiomatic Trino form (cleanest `100.0 * count_if(converted) / count(*)`), and `avg(CAST(converted AS DOUBLE)) * 100` as another clean form, but neither omission is a penalty — the given forms are correct and complete.
- Clarity: **5** — Plain language, idiomatic SQL, NULL behavior explicitly called out.
- Actionability: **5** — Copy-paste-runnable.
- **Avg: 5.0**

---

## Overall

| Q | Avg |
|---|---|
| Q1 | 3.5 |
| Q2 | 5.0 |
| Q3 | 4.75 |
| Q4 | 5.0 |
| **OVERALL** | **(3.5 + 5.0 + 4.75 + 5.0) / 4 = 4.5625** |

### **VERDICT: PASS (4.5625 >= 3.5)**

Per the run prompt's instruction, the overall average governs the PASS/FAIL label. Q1's 3.5 is exactly at threshold but is flagged separately for iter636 FIX-A attention.

---

## iter636 directive

### FIX-A (PRIMARY) — Final-query column-scope inoculation for share-of-grand-total composition

**Problem found.** Q1 weakness is NOT a direction bug (FIX-A from iter635 LANDED cleanly) — it is a final-assembly column-scope error. The responder correctly moved SUM into an inner subquery (`SELECT SUM(total_spend) AS total FROM ranked_customers`) but then in the outer SELECT referenced `SUM(total_spend)` instead of the alias `total`. This is a subtle but consistent class of bug: when the share-of-grand-total template is composed as `top_subset CROSS JOIN (SELECT SUM(x) AS total FROM all)`, the outer SELECT must reference the ALIAS, not re-apply SUM to a column that is no longer in scope.

**Per-Q quality-gate note (do NOT label as overall FAIL).** Q1 average is 3.5 (at threshold). Overall average 4.5625 passes. Per the run prompt's instruction, do not apply a per-question gate override — the overall avg governs.

**Teacher action for iter636 (FIX-A):**

1. **Locate** the share-of-grand-total pattern block at r07:1068-1095 (verified-anchored). Verify whether it already shows the CROSS-JOIN composition with an aliased subquery total, and whether the outer SELECT correctly references the ALIAS (not a re-aggregated column).

2. **Insert / tighten** a leading canonical sub-section at r07 (immediately adjacent to the existing share-of-grand-total anchor, or inside it) titled something like:
   `LEADING CANONICAL — share-of-grand-total final assembly (iter635 — outer SELECT must reference the alias, not the underlying column)`
   - Keyword anchors: `share of total revenue from top X%`, `pct of grand total from top tier`, `top quintile share of revenue`, `top 20% revenue share`, `top decile revenue contribution`.
   - ONE-FACT lead: `When you compose top-subset / grand-total with CTE-cross-join-subquery, the outer SELECT must reference the subquery's ALIAS (e.g. AS total), not re-apply SUM() to a column that lives inside the inner CTE.`
   - DO NOT WRITE block (the exact bug shape):
     ```sql
     -- WRONG: total_spend is not in scope at the outer SELECT
     SELECT 100.0 * top_20_revenue / SUM(total_spend)
     FROM top_quintile, (SELECT SUM(total_spend) AS total FROM ranked_customers)
     ```
   - RIGHT form:
     ```sql
     SELECT 100.0 * top_20_revenue / total
     FROM top_quintile, (SELECT SUM(total_spend) AS total FROM ranked_customers)
     ```
   - Cleaner alternative (single FILTER form, no cross-join):
     ```sql
     SELECT 100.0 * SUM(total_spend) FILTER (WHERE spend_quintile = 1) / SUM(total_spend) AS pct
     FROM ranked_customers
     ```
   - Even cleaner end-to-end (no cross-join, single CTE):
     ```sql
     WITH ranked AS (
       SELECT customer_id, SUM(amount) AS total_spend,
              NTILE(5) OVER (ORDER BY SUM(amount) DESC) AS q
       FROM orders GROUP BY customer_id
     )
     SELECT 100.0 * SUM(total_spend) FILTER (WHERE q = 1) / SUM(total_spend) AS pct_from_top_20
     FROM ranked;
     ```

3. **Cross-link** the new guardrail from the FIX-A iter635 PERCENT_RANK/NTILE direction guardrail at r07:1794 — these two are paired (direction + final-assembly) in any "top X% share of revenue" question.

4. **Reconcile in place** — search r07 / r23 for any existing share-of-grand-total examples that show the `SUM(col) / SUM(col)` outer pattern with a CTE composition; tighten or replace the buggy ones (do NOT just append). Per the `feedback_reconcile_dont_append` rule.

### FIX-B — DEFAULT NO-OP / durability breadth

No other resource gap detected this iteration. Q2/Q3/Q4 are all bulletproof (5.0 / 4.75 / 5.0). Recommend FIX-B = NO-OP and use the budget for additional probe-angle durability on the share-of-grand-total composition pattern (different question phrasings: "top quartile share", "bottom decile share", "top N customers contribution") to confirm FIX-A holds across phrasings before final-phase declaration.

### Process / dialect-pin notes

- FIX-A (PERCENT_RANK / NTILE direction guardrail) from iter635 confirmed LANDED — the responder did NOT invert this iteration. Keep the r07:1794 leading canonical sub-section locked.
- The iter636 FIX-A (share-of-grand-total final-assembly) is a DIFFERENT defect class from the iter635 direction defect — both must be inoculated.
- DIALECT PIN HELD: no QUALIFY / RLIKE / PERCENTILE_CONT / MEDIAN / initcap / DISTINCT ON / `::cast` appeared in any answer. All four answers use valid Trino 467 dialect (NTILE, ROW_NUMBER + MAX(CASE) pivot, date_diff('day',...), CAST(boolean AS INTEGER), 100.0 float-division guard, window-over-aggregate in GROUP BY SELECT).
