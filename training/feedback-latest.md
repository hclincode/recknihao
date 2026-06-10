# Judge Feedback — iter911 (NO-OP durability sweep)

**Verdict: STRONG PASS — overall average 4.875 / 5. NO-OP. No FIX-A for iter912.**

Phase: extended. state.json NOT touched (already iter911, passed:true). Teacher made ZERO edits this iter — this is a 4-probe durability/adjacency sweep on window-function + date_trunc patterns.

All dialect claims verified against **trino.io/docs/467** (datetime.html, window.html, types.html) + WebSearch on DATE↔TIMESTAMP coercion, Trino 467 PINNED, 2026-06-10, multi-source. On-prem Trino 467 + Iceberg + MinIO + HMS + JWT/OPA stack: all four answers are pure ANSI-ish SQL with no stack conflict.

## EXPLICIT window-function correctness note (the headline check)

All FOUR window functions are used **CORRECTLY** — each is computed inside a subquery/CTE and then filtered or aggregated in an OUTER query. This is the canonical no-QUALIFY-in-467 pattern. There is **no muddle** (no window fn mixed into a GROUP-BY select list, no window fn in a bare WHERE, no attempt at QUALIFY):
- Q1: `MAX() OVER (PARTITION BY)` in subquery → outer `SUM(CASE...) GROUP BY`.
- Q3: `LAG() OVER (PARTITION BY ORDER BY)` in subquery → outer `WHERE price > prior_price`, `COUNT(DISTINCT)`.
- Q4: `MIN() OVER (PARTITION BY)` in subquery → outer `WHERE first_order_date = order_date AND date_trunc(...)`, `DISTINCT`.
- Q2 uses a plain `MIN()...GROUP BY` CTE (no window) joined to signups — also clean.

## Per-question scores

### Q1 — per-customer count of orders tying that customer's all-time max — 5.00
`SUM(CASE WHEN order_value = max_value THEN 1 ELSE 0 END) GROUP BY customer_id` over a subquery with `MAX(order_value) OVER (PARTITION BY customer_id) AS max_value`.
- VERIFIED window.html: all aggregate fns (incl. MAX) usable as window fns with `OVER (PARTITION BY)` and no ORDER BY → partition-wide max broadcast to every row. Valid.
- Logic correct: outer GROUP BY customer_id counts every order whose value equals the per-customer max. **Ties → all tied orders counted** (intended for a "count of orders tying the max"). CLEAN.

### Q2 — customers whose first order is in the same calendar week as signup — 4.75
`first_orders` CTE `MIN(order_date)`; JOIN signups; `WHERE date_trunc('week', s.created_at) = date_trunc('week', f.first_order_date)`; `COUNT(DISTINCT)`.
- VERIFIED datetime.html: `date_trunc('week', ...)` → **Monday-start** (ISO week, doc example `2001-08-22` → `2001-08-20` Monday). Same-week check correct.
- **TIMESTAMP-vs-DATE nuance verified, NOT a defect.** `s.created_at` is TIMESTAMP → `date_trunc('week', timestamp)` returns TIMESTAMP (`Monday 00:00:00`); `f.first_order_date` is DATE (from `MIN(order_date)`) → `date_trunc('week', date)` returns DATE (`Monday`). The equality is TIMESTAMP = DATE. Trino 467 **implicitly coerces DATE → TIMESTAMP at midnight (00:00:00)** for the comparison (verified vs Trino DATE/TIMESTAMP comparison semantics: `DATE '...' < TIMESTAMP '...'` is valid, date→timestamp@midnight). So both sides resolve to `Monday 00:00:00` and equality yields the intended same-week result. **Valid, no type error, correct.** Weighed proportionally — coercion works → fully correct, no penalty.
- Tiny clarity ding only: answer could have noted the DATE/TIMESTAMP coercion explicitly so a beginner isn't surprised by the mixed-type equality. Not a correctness issue.

### Q3 — how many products had a price increase at least once — 5.00
Subquery `LAG(price) OVER (PARTITION BY product_id ORDER BY changed_at) AS prior_price`; outer `WHERE price > prior_price`; `COUNT(DISTINCT product_id)`.
- VERIFIED window.html: LAG valid; first row of partition → NULL (no preceding row).
- `price > prior_price` detects any increase; first row `price > NULL` → NULL → excluded by WHERE (correct, the first observation has no prior to compare). `COUNT(DISTINCT product_id)` = products with ≥1 increase. CLEAN.

### Q4 — customers whose first-ever order is in the current month — 4.75
Subquery `MIN(order_date) OVER (PARTITION BY customer_id) AS first_order_date`; outer `WHERE first_order_date = order_date AND date_trunc('month', order_date) = date_trunc('month', CURRENT_DATE)`; `DISTINCT customer_id`.
- VERIFIED window.html MIN OVER valid (partition-wide min, no ORDER BY); datetime.html `date_trunc('month', ...)` → first of month. `CURRENT_DATE` is DATE → `date_trunc('month', date)` DATE; `order_date` DATE → DATE = DATE, no mixed-type issue here.
- `first_order_date = order_date` isolates the first order row; month-equality keeps only current-month first orders. CLEAN.
- Tiny ding: if a customer placed two orders on the exact same earliest date, `DISTINCT customer_id` still dedupes correctly, so harmless. No penalty of substance.

## Overall

| Q | Score |
|---|---|
| Q1 | 5.00 |
| Q2 | 4.75 |
| Q3 | 5.00 |
| Q4 | 4.75 |
| **Avg** | **4.875** |

**PASS (overall average governs, 4.875 ≥ 3.5).**

## Defect / FIX-A assessment

- **NO fabrication** — every function (MAX/MIN/LAG OVER, date_trunc, the DATE→TIMESTAMP coercion) verified present + correct-signature + correct-semantics in Trino 467.
- **NO wrong-signature, NO crossed-family, NO findability slip, NO muddle** — all four window fns used in the correct subquery+outer-filter/aggregate form.
- **Q2 TIMESTAMP-vs-DATE date_trunc equality investigated specifically (per directive) and CLEARED** — implicit date→timestamp@midnight coercion makes both Mondays compare at `00:00:00`; intended same-week result holds. Not a hard defect, not even a soft one — only a clarity nicety to mention the coercion.
- **NO prod-env conflict** — pure SQL; on-prem Trino 467 + Iceberg + MinIO + HMS + JWT/OPA unaffected.

**iter912 = DEFAULT NO-OP / durability-breadth sweep.** No resource edit warranted. Optional fresh adjacents for next sweep (do NOT mandate): `LEAD` (mirror of Q3 LAG), `NTH_VALUE`/`FIRST_VALUE` first-order variants, mixed DATE/TIMESTAMP date_trunc with an explicit CAST to show the coercion, count-of-ties using `RANK()=1` instead of `MAX() OVER`.

**PRESERVE** the full iter534–910 pin inventory; NO federation edits (federation 4.49944/310, do not churn). DO NOT bump training/state.json (already 911).
