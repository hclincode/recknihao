# Judge Feedback — iter905 (re-probe sweep)

**Overall: 5.00 / 5.00 — STRONG PASS** (per-Q 5.00/5.00/5.00/5.00 = 20.00/4). Overall average governs; no per-Q veto. Margin +1.50 over the 3.5 threshold.

**Verdict: iter906 DEFAULT NO-OP.** All four answers dialect-clean vs Trino 467. Teacher: ZERO edits. Do NOT touch state.json (already passed).

---

## Per-question scores (Accuracy / Completeness / Clarity / Actionability)

### Q1 — top 2 invoices per account; `where rank <= 2` errored — 5.0 (5/5/5/5)
**WINDOW-FN-IN-WHERE SLIP ONE-OFF CONFIRMED — DID NOT RECUR. The iter904 slip is CLOSED. NO findability-anchor FIX-A needed.**

The responder this time CORRECTLY explained the root cause: window functions cannot appear in a WHERE clause because WHERE is evaluated *before* window functions run. VERIFIED vs trino.io/docs/467 window.html: window functions "run after the HAVING clause but before the ORDER BY clause" — i.e. after WHERE/GROUP BY/HAVING — so a RANK() reference in WHERE is illegal.

The fix given is the canonical Trino 467 pattern and is correct:
```sql
SELECT * FROM (
  SELECT account_id, invoice_id, amount,
         RANK() OVER (PARTITION BY account_id ORDER BY amount DESC) AS amount_rank
  FROM invoices
) WHERE amount_rank <= 2;
```
plus the equivalent CTE variant. CONFIRMED: Trino 467 has **NO QUALIFY clause** (verified select.html + WebSearch — QUALIFY is absent), so subquery/CTE nesting is the *required* approach, not merely one option. The responder did not hallucinate QUALIFY. RANK() ranking fns must NOT carry a frame — none was added. Clean 5.0.

### Q2 — pull year out of a date "as a string" for grouping — 5.0 (5/5/5/5)
VERIFIED vs datetime.html: `year(order_date)` → **bigint** and `EXTRACT(YEAR FROM order_date)` → **bigint**. The responder CORRECTLY said both return an INTEGER (e.g. `2024`, not `'2024'`) and did NOT falsely claim `year()` returns a string. GROUP BY either is valid. For an actual `'2024'` string the responder gave `CAST(year(order_date) AS VARCHAR)` — correct. The implicit correction of the engineer's "as a string" premise (year is integer; cast only if a string is genuinely needed) is exactly right and helpful. Clean 5.0.

### Q3 — running lowest price per product up to & including current date — 5.0 (5/5/5/5)
VERIFIED vs window.html: all aggregate functions (incl. MIN) usable as window functions via OVER, and aggregate window fns DO accept a frame (unlike ranking fns).
```sql
MIN(price) OVER (
  PARTITION BY product_id
  ORDER BY sale_date
  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
) AS lowest_price_to_date
```
Frame is valid 467 syntax and the semantics are correct: with ORDER BY sale_date and the UNBOUNDED PRECEDING → CURRENT ROW frame, each row sees the minimum over all prior rows plus itself = a running/cumulative minimum "up to and including" the current date, per product. Clean 5.0.

### Q4 — single % of orders shipped late (actual_ship_date > promised_ship_date) — 5.0 (5/5/5/5)
Both forms VERIFIED valid in 467:
```sql
100.0 * SUM(CASE WHEN actual_ship_date > promised_ship_date THEN 1 ELSE 0 END) / COUNT(*)
100.0 * COUNT(*) FILTER (WHERE actual_ship_date > promised_ship_date) / COUNT(*)
```
The `100.0 *` decimal literal forces non-integer division (avoids the classic int-truncate-to-0 trap) — correct and important. `FILTER (WHERE ...)` aggregate syntax CONFIRMED supported in Trino (aggregate.html: `aggregate_function(expr) FILTER (WHERE condition)`). Offering both the portable CASE form and the cleaner FILTER form is complete and actionable. Clean 5.0.

---

## Coverage / topic notes
- This sweep probed **SQL query best practices for OLAP** (window-fn placement, year extraction, running aggregates, late-rate percentage) — all PASSED-row territory, no new topic opened.
- **Federation (4.49944 / 310)** remains the ONLY un-passed row and was NOT probed this sweep — row UNCHANGED. Probe only bulletproofed federation angles next.

## Defect / FIX-A scan
- NO dialect defect. NO findable-but-missing gap. Q1 slip did NOT recur (one-off confirmed).
- iter882 verify-first applied: every structurally-notable claim (QUALIFY absence, FILTER support, aggregate-window frame legality, year()→bigint) VERIFIED vs trino.io/docs/467 + WebSearch before judgment; none flagged.

## Directive to teacher — iter906
**DEFAULT NO-OP. ZERO edits.** Do NOT add any "wrong"/correction card for Q1–Q4. Do NOT churn the subquery/CTE-wrap-and-filter card, the year()-returns-integer card, the running-min window-frame card, or the percent-with-FILTER/CASE card. Do NOT add a QUALIFY-not-supported card unless it touches no existing pin (likely redundant — SKIP). Do NOT touch any iter534–904 pin. PIN Trino 467. NO federation edits. DO NOT bump training/state.json (already passed; overall 5.00 PASS holds).
