# Judge Feedback — iter608 (EXTENDED PHASE)

**OVERALL: 4.375 PASS** (margin +0.875 above 3.5 floor; −0.5625 swing from iter607's 4.97). FEDERATION NOT PROBED — 4.49944/310 row UNCHANGED.

**HEADLINE:** Q1 date-spine gap-fill, Q2 greatest()-across-columns, and Q3 LEAD days-until-next are all docs-verbatim **zero-defect 5.00** first-probe. Q4 is the single genuine defect and it is a **WRONG-FUNCTION-CHOICE**: the user explicitly asked for THREE subtotal types — (a) all products within each region, (b) **all regions for each product category**, and (c) grand total — but the responder used `GROUP BY ROLLUP(region, category)`, which is hierarchical/prefix-only and **structurally omits subtotal (b)**, the (category)-only grouping the user named. The query parses and runs but does NOT answer the question. CUBE was required.

---

## Per-question scores

### Q1 — Gap-fill daily signups, every calendar day in a 90-day range, zero for missing days — 5/5/5/5 = 5.00 STRONG PASS
```sql
WITH calendar AS (
  SELECT date_add('day', n, current_date - INTERVAL '90' DAY) AS day
  FROM UNNEST(sequence(0,89)) AS t(n)
), signups AS (
  SELECT date_trunc('day', event_time) AS day, COUNT(*) cnt
  FROM user_events
  WHERE event_name='signup' AND event_time >= current_date - INTERVAL '90' DAY
  GROUP BY 1
)
SELECT c.day, COALESCE(s.cnt,0) AS signups
FROM calendar c LEFT JOIN signups s ON s.day=c.day
ORDER BY c.day
```
Verified trino.io/docs/current/functions/array.html: `sequence(start, stop)` "Generate a sequence of integers from `start` to `stop`" — **inclusive of both bounds**, so `sequence(0,89)` = **90 values** (one per calendar day). Verified functions/datetime.html: `date_add(unit, value, timestamp)` "Adds an interval `value` of type `unit` to `timestamp`"; `date_trunc(unit, x)` "Returns `x` truncated to `unit`". `UNNEST(...) AS t(n)` expands the array to rows; `LEFT JOIN` + `COALESCE(s.cnt,0)` is the textbook gap-fill that surfaces zero for missing days. **No `::` cast, no `generate_series` (which does not exist in Trino).** Correct, idiomatic, copy-paste runnable. Zero defects.

### Q2 — Single highest of three rating columns per row (max ACROSS columns) — 5/5/5/5 = 5.00 STRONG PASS
`greatest(quality_rating, value_rating, service_rating) AS highest_rating`. Verified functions/comparison.html: `greatest(value1, value2, ..., valueN)` "Returns the largest of the provided values"; docs-verbatim NULL note: *"Like most other functions in Trino, they return null if any argument is null. Note that in some other databases, such as PostgreSQL, they only return null if all arguments are null."* The responder's NULL-propagation caveat is **exactly correct** (and correctly flags the PostgreSQL divergence in spirit), and the COALESCE-each-arg workaround (`greatest(COALESCE(quality_rating, 0), ...)`) is the right idiom when NULLs should be ignored. Critically did NOT confuse row-wise `greatest(a,b,c)` (across columns) with aggregate `MAX()` (down rows). Zero defects.

### Q3 — Days until that customer's NEXT order (look-ahead per customer) — 5/5/5/5 = 5.00 STRONG PASS
```sql
LEAD(order_date) OVER (PARTITION BY customer_id ORDER BY order_date) AS next_order_date,
date_diff('day', order_date, LEAD(order_date) OVER (PARTITION BY customer_id ORDER BY order_date)) AS days_until_next_order
... ORDER BY customer_id, order_date
```
Verified functions/datetime.html: `date_diff(unit, timestamp1, timestamp2)` "Returns `timestamp2 - timestamp1` expressed in terms of `unit`" — so `date_diff('day', order_date, next_order_date)` = next − current = **days UNTIL next** (correct sign/direction). `LEAD(col) OVER (PARTITION BY customer_id ORDER BY order_date)` looks one row forward per customer; no frame clause needed. NULL for the last order per customer (no following row) is correctly noted. Zero defects.

### Q4 — Revenue by region AND category WITH three subtotal types in one result — 2/2/4/2 = 2.50 FAIL (per-Q below 3.5) — WRONG-FUNCTION-CHOICE (ROLLUP used; CUBE required)
```sql
SELECT region, category, SUM(revenue) AS total_revenue,
  CASE GROUPING(region,category)
    WHEN 0 THEN 'Detail' WHEN 1 THEN 'Region Total' WHEN 3 THEN 'Grand Total' END AS row_type
FROM sales GROUP BY ROLLUP(region, category)
ORDER BY GROUPING(region,category), region NULLS LAST, category NULLS LAST
```
**The user EXPLICITLY named three subtotal types:** (a) "all products within each region" = the `(region)`-only grouping; (b) **"all regions for each product category" = the `(category)`-only grouping**; (c) grand total. Verified trino.io/docs/current/sql/select.html:
- `ROLLUP(a,b)` generates only the **hierarchical/prefix** sets `(a,b)`, `(a)`, `()` — "The `ROLLUP` operator generates all possible subtotals for a given set of columns" but hierarchically (trailing-drop only).
- `CUBE(a,b)` generates the **power set** `(a,b)`, `(a)`, `(b)`, `()` — "The `CUBE` operator generates all possible grouping sets (i.e. a power set)." This is the ONLY construct that includes the `(b)`-only / `(category)`-only grouping.

**CONFIRMED: ROLLUP(region, category) structurally OMITS the (category)-only subtotal (b) the user explicitly requested.** The query is syntactically valid and runs, but it returns the wrong result set — it answers an adjacent question. The CASE has `WHEN 0/1/3` with **no `WHEN 2`** — value 2 (binary `10` = region rolled up, category present = the per-category subtotal) is the exact row ROLLUP never emits, which is itself the fingerprint of the omission. The GROUPING() bitmask labeling that IS present is correct for ROLLUP: verified the leftmost arg is the MSB, so `GROUPING(region,category)=1` = binary `01` = category rolled up = a per-region subtotal, so the "Region Total" label on WHEN 1 is correctly placed **for ROLLUP** — but the whole ROLLUP choice is wrong for this question. Acc 2 (runs, but does not satisfy the named requirement), Comp 2 (subtotal (b) absent entirely), Clar 4 (well-formatted/explained, the GROUPING table reasoning is sound), Act 2 (engineer copy-pastes and silently loses the per-category subtotal rows they asked for).

**Correct answer:** `GROUP BY CUBE(region, category)` with the CASE extended to `WHEN 2 THEN 'Category Total'` (and `WHEN 0/1/3` as-is). Equivalent explicit form: `GROUP BY GROUPING SETS ((region, category), (region), (category), ())`. Either replaces the user's 3-query UNION with a single one-pass scan.

---

## Q4 VERDICT + DIAGNOSIS (PRIMARY)

**CONFIRMED:** ROLLUP structurally omits the (category)-only "all regions for each product category" subtotal the user explicitly asked for; **CUBE was the correct choice** (or explicit GROUPING SETS).

**Diagnosis: ROUTED-BUT-MIS-APPLIED (stopped-early), not landing-point miss.** The CUBE content the responder needed is **already present and findable** in r28:
- r28:504 (§(e)): *"`CUBE(a, b)` is shorthand for `GROUP BY GROUPING SETS ((a, b), (a), (b), ())` — it emits all 2^N combinations, including the `(b)`-only grouping that ROLLUP skips."*
- r28:509: CUBE value table — value 2 = "a rolled up, b present (the 'category total' you can't get from ROLLUP)."
- r28:514: *"If a migrated query labels rows for both 'region total' AND 'category total' (independent margins), the source must be using `CUBE` ... not `ROLLUP`. ... translating a CUBE-shaped query to ROLLUP silently drops the b-only subtotal rows."*

The responder routed correctly to the r28 ROLLUP/GROUPING-SETS LEADING CANONICAL block (line 413) but **read top-down and stopped at the ROLLUP-centric worked example (§(c), lines 463-491) without reaching the ROLLUP-vs-CUBE decision section (§(e), lines 502-514)**. The block leads with ROLLUP and the GROUPING() bitmask mechanics; the CUBE/decision content is buried four subsections down. The keyword anchors at line 413/415 list "ROLLUP, CUBE, GROUPING SETS" but there is **no decision-first signpost keyed on the question's own phrasing** ("all X for each Y AND all Y for each X") that would steer a question demanding BOTH independent margins to CUBE before the responder commits to the ROLLUP example.

### iter609 PRIMARY directive — add a ROLLUP-vs-CUBE DECISION SIGNPOST at the r28 block head
At the top of the r28 LEADING CANONICAL block (immediately after the keyword-anchor line 415, BEFORE the bitmask rule §(a)), ADD a short decision-first signpost (reconcile-in-place; do NOT rewrite §(a)-(f) bodies, do NOT touch the ROLLUP value tables or the WHEN-2-grand-total inoculation):

> **DECIDE ROLLUP vs CUBE FIRST (before writing any GROUPING() CASE):**
> - Question asks for **hierarchical/prefix subtotals only** — "subtotal per region, then per region+category, then grand total", "drill-down rollup", a single drill path → **ROLLUP(region, category)** (emits `(r,c)`, `(r)`, `()`; N+1 rows).
> - Question asks for **every independent margin** — "all products within each region **AND** all regions for each category", "subtotals for BOTH dimensions independently", "region totals and category totals", "all X for each Y and all Y for each X" → **CUBE(region, category)** (emits `(r,c)`, `(r)`, `(c)`, `()`; 2^N rows). **ROLLUP CANNOT produce the (category)-only subtotal — it drops trailing columns only.**
> - Want exactly some sets but not all → explicit **GROUPING SETS ((region,category),(region),(category),())**.

Add keyword anchors matching the question verbatim: *"all regions for each product category", "all products within each region", "subtotals for both dimensions", "region totals AND category totals", "independent margins", "all X for each Y and all Y for each X", "replace my UNION of 3 queries"*. Then point: "if you need the (category)-only row, see §(e) CUBE." This converts the routed-but-stopped-early failure into a decision the responder makes before it picks the ROLLUP worked example. The CUBE worked example/value table already exist (§(e)); the gap is purely a decision-first signpost at the block head, not new CUBE content.

---

## Other slips / fabrications

**NONE.** Q1/Q2/Q3 are docs-verbatim correct. Zero `::`-casts, zero `generate_series`, zero QUALIFY, zero EXTRACT(EPOCH), zero invalid clause placement, zero off-by-one (sequence(0,89)=90 inclusive confirmed), zero fabricated functions or absences, zero wrong-version pins. Q2's NULL-propagation note and PostgreSQL divergence are factually accurate. Q3's date_diff direction is correct. The only defect is the Q4 wrong-function-choice diagnosed above.

## TOPIC AVG UPDATES
- **Analytical query patterns on Iceberg+Trino / r07** (Q1 date-spine gap-fill clean +0.5; Q3 LEAD days-until-next clean +0.5) — net UP.
- **SQL query best practices for OLAP / r23+r27** (Q2 greatest()-across-columns clean +0.5) — UP.
- **Complex-SQL-perf-on-Trino-with-dbt / r28** (Q4 ROLLUP-instead-of-CUBE wrong-function-choice; content present but routed-but-stopped-early) — mild DOWN; iter609 decision-signpost fix.
- Federation NOT probed — **4.49944/310 row UNCHANGED**.

## DO NOT (iter609)
- Do NOT touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter608).
- Do NOT rewrite the r28 §(a)-(f) bodies, ROLLUP value tables, or the WHEN-2-grand-total inoculation (all durable/correct) — ADD the decision signpost adjacent only (reconcile-in-place at the block head).
- Do NOT re-edit the verified-clean r07 date-spine / LEAD / r23 greatest() canonicals (all routed first-probe clean).
- Do NOT add `::`-casts (iter571 PIN), `generate_series` (not in Trino), QUALIFY, or EXTRACT(EPOCH) (iter562 ban).
- Do NOT touch iter534-607 locks. Do NOT bump training/state.json (already 608).

## Docs verified today (trino.io/docs/current ≡ 467 semantics)
- sql/select.html — ROLLUP "all possible subtotals" (hierarchical/prefix); CUBE "all possible grouping sets (i.e. a power set)" incl. (b)-only; GROUPING() bitmask, leftmost arg = MSB, bit 0 = present / bit 1 = rolled up (Q4).
- functions/array.html — `sequence(start, stop)` inclusive both bounds → sequence(0,89)=90 values (Q1).
- functions/datetime.html — `date_add(unit,value,ts)`, `date_trunc(unit,x)` (Q1); `date_diff(unit, t1, t2)` = t2 − t1 (Q3).
- functions/comparison.html — `greatest(...)` "Returns the largest"; "return null if any argument is null ... PostgreSQL ... only return null if all arguments are null" (Q2).

**OVERALL: 4.375 PASS — Q1 date-spine gap-fill + Q2 greatest()-across-columns + Q3 LEAD days-until-next all docs-verbatim zero-defect 5.00; Q4 used ROLLUP where the user explicitly named BOTH the per-region AND the per-category independent subtotals — ROLLUP structurally omits the (category)-only grouping, CUBE was required (WRONG-FUNCTION-CHOICE). Diagnosis: routed-but-stopped-early (CUBE content present r28:504/509/514 but responder stopped at the ROLLUP worked example); iter609 = add a ROLLUP-vs-CUBE decision signpost at the r28 block head keyed on "all X for each Y AND all Y for each X" → CUBE. No fabrications; federation row stays 4.49944/310.**
