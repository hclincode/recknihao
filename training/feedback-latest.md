# Judge Feedback — iter772 (DEFAULT NO-OP / durability-breadth sweep)

**Designation in:** durability-breadth sweep, teacher made ZERO resource edits.
**Verification:** Every dialect claim cross-checked against trino.io/docs/467 (datetime, window, conditional, aggregate, sql/select) via WebFetch on 2026-06-09. Not relying on resources/ as ground truth.

---

## Q1 — LTV: fractional months active (signup → cancel/today), 45 days ≠ 31 days

Answer: `date_diff('day', signup_date, COALESCE(cancelled_date, current_date)) / 30.44 AS months_with_customer`. Explains whole-day count, /30.44 avg days/month, 45 days → ~1.48 months, COALESCE for still-active. Cites r23 days-between canonical.

**Verification:** `date_diff('day', date, date)` confirmed → BIGINT day count (docs example `date_diff('day', DATE '2020-03-01', DATE '2020-03-02')` = 1). `current_date` confirmed SQL-standard (no parens). COALESCE valid. `/30.44` = 365.25/12 = 30.4375 — the standard average-days-per-month convention for fractional months. 45/30.44 = 1.478 ✓. The decimal divisor forces double division (date_diff returns BIGINT, so `/ 30.44` yields a double — no integer truncation). Directly satisfies "fractional, not calendar-month count."

- Accuracy: 5 — sound, docs-verified, correct fractional convention.
- Completeness: 5 — COALESCE for active, worked 45-day example, divisor rationale.
- Clarity: 5 — explains every piece for a non-OLAP engineer.
- Actionability: 5 — drop-in query.
- **Q1 avg = 5.00**

**WATCH-ITEM RESULT:** The iter771 crude `/31.0`-as-"more precise" imprecision did **NOT recur**. The responder used `/30.44` (the correct average-days-per-month value). **FRACTIONAL-MONTHS WATCH-ITEM = RESOLVED / CLOSED.** No FIX-A needed on this axis.

---

## Q2 — Each category's revenue as % of grand total, single query no subquery

Answer: `ROUND(100.0 * revenue / SUM(revenue) OVER (), 2) AS percent_of_total`. Explains empty-window SUM = grand total every row, single pass no subquery, 100.0* forces float, ROUND(...,2). Cites r23 window patterns.

**Verification:** sql/select.html confirms with no PARTITION BY and no ORDER BY "all rows are considered peers," so `SUM(x) OVER ()` spans the entire result set = grand total on every row. `100.0 *` forces double division (avoids integer truncation). `ROUND(x, 2)` valid. Correctly satisfies "single query no subquery" — the window function avoids a self-join/subquery for the denominator.

- Accuracy: 5 — empty-window grand-total semantics docs-confirmed.
- Completeness: 5 — single-pass, float-coercion, rounding all addressed.
- Clarity: 5 — empty `OVER ()` explained in plain terms.
- Actionability: 5 — drop-in.
- **Q2 avg = 5.00**

---

## Q3 — Most recent event row per order_id (one row each, latest status)

Answer: `SELECT * FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY timestamp DESC) AS rn FROM order_events) WHERE rn = 1`. Notes ties → tiebreaker (timestamp DESC, event_id DESC); Trino does NOT support QUALIFY; subquery form canonical; max_by alternative. Cites r23 §3.1G no-DISTINCT-ON.

**Verification:** row_number() confirmed window ranking fn; rn=1 in outer subquery = canonical keep-latest idiom. QUALIFY confirmed NOT present anywhere in sql/select.html → subquery/CTE form correctly required. max_by(status, timestamp) GROUP BY order_id confirmed valid for the single-column "latest status." Tie note (add event_id DESC) is the right deterministic-ordering caveat. Correctly distinguishes this from DISTINCT ON (Postgres-only, absent in Trino).

- Accuracy: 5 — idiom correct, QUALIFY-absence confirmed, max_by valid.
- Completeness: 5 — full-row vs single-column (max_by) both covered + tiebreaker nuance.
- Clarity: 5 — clear why subquery (no QUALIFY).
- Actionability: 5 — drop-in.
- **Q3 avg = 5.00**

---

## Q4 — Label customers Gold/Silver/Bronze by total spend range

Answer: `CASE WHEN total_spend >= 1000 THEN 'Gold' WHEN total_spend >= 500 THEN 'Silver' ELSE 'Bronze' END AS tier`. Explains first-match top-to-bottom; notes if(condition, value) single-branch shorthand exists but CASE clearer for multiple tiers. Cites r23 §3.1E.

**Verification:** conditional.html confirms searched CASE "evaluates each boolean condition from left to right until one is true and returns the matching result" — so `>= 500` after the `>= 1000` branch correctly maps 500–1000 to Silver (boundary handled via ordering). `if(condition, true_value)` confirmed returns NULL when false and no else — the responder's note that CASE is clearer for multiple tiers and that if() is a single-branch shorthand is accurate.

- Accuracy: 5 — first-match ordering + if() NULL-when-false both docs-confirmed.
- Completeness: 5 — boundary logic + if() alternative noted.
- Clarity: 5 — top-to-bottom first-match explained plainly.
- Actionability: 5 — drop-in.
- **Q4 avg = 5.00**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = 5.00 — PASS** (threshold 3.5).

### Production-environment fit
All four are pure Trino 467 SQL (Iceberg connector, Hive Metastore on-prem). No stack-incompatible recommendations; no auth/authz scope issues. Fits prod_info.md.

### Watch-item status
- **Fractional-months WATCH-ITEM: RESOLVED / CLOSED.** Q1 used `/30.44` (sound avg-days-per-month); the iter771 `/31.0`-as-"more precise" imprecision did NOT recur.

### Teacher feedback
No action required. The zero-edit NO-OP was the correct call — all four canonicals held and produced docs-accurate, drop-in answers. No new defect, gap, or findability-miss surfaced. The fractional-months card is now demonstrated stable across re-probes.

### iter773 designation
**DEFAULT NO-OP / durability-breadth sweep.** No open defect. Continue probing fresh adjacent angles; the previously-open fractional-months watch-item is closed and need not be the primary probe (one confirmatory re-probe at most). Keep verifying every dialect claim against trino.io/docs/467.
