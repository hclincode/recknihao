# Iter 664 — Judge Feedback

**Overall: 4.5625 PASS** (margin +1.0625 above 3.5 floor)

Per-Q averages: Q1 4.75 / Q2 5.00 / **Q3 3.50 (flagged weak — Trino-dialect defects on day-of-week semantics)** / Q4 5.00.

---

## Per-question scores

### Q1 — Two-level macro-median (median per customer, then overall median of those medians) — 4.75 PASS

Responder answer:
```sql
SELECT approx_percentile(customer_median, 0.5) AS typical_order_value
FROM (
  SELECT customer_id, approx_percentile(amount, 0.5) AS customer_median
  FROM orders GROUP BY customer_id
) per_customer_stats;
```

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Verified trino.io/docs/467/functions/aggregate.html — `approx_percentile(x, p)` is the canonical Trino median idiom; no `MEDIAN`/`PERCENTILE_CONT` exists in Trino 467. Inner per-customer aggregate sits in a subquery so it is NOT a nested aggregate — the outer `approx_percentile` operates on a scalar column projected from the subquery. Two-level subquery shape valid Trino. |
| Completeness | 4 | Question asked for BOTH "overall median AND avg of the per-customer medians" — responder only delivered the median (`approx_percentile`) layer, omitted `AVG(customer_median)`. Minor scope miss. |
| Clarity | 5 | Clean two-level construction; `per_customer_stats` alias is self-documenting; inline notes explain no-nested-aggregate rule and no-PERCENTILE_CONT/MEDIAN inoculation. |
| Actionability | 5 | Drop-in valid Trino 467 SQL; engineer can paste into a Trino client and run unchanged. |

### Q2 — Multi-key dim-JOIN + filter + SUM (orders × product_region on product_id+region_id, WHERE list_price > 100) — 5.00 STRONG PASS

```sql
SELECT SUM(o.amount) AS total_revenue
FROM orders o
JOIN product_region pr ON o.product_id = pr.product_id AND o.region_id = pr.region_id
WHERE pr.list_price > 100;
```

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | ANSI-SQL ON clause accepts conjunctions; multi-key JOIN with `ON a.k1=b.k1 AND a.k2=b.k2` is standard composite-key JOIN form. WHERE on dim column after INNER JOIN is semantically equivalent to ON-clause filter for the SUM result. Verified via trino.io/docs/467/sql/select.html JOIN semantics. |
| Completeness | 5 | All three asks met: JOIN both keys, filter list_price > 100, SUM(amount). |
| Clarity | 5 | Short, table aliases, ON-AND structure obvious. |
| Actionability | 5 | Drop-in valid Trino 467. |

### Q3 — Busiest weekday per user (avoid MAX(COUNT(*)) nested aggregate) — 3.50 PASS (FLAGGED WEAK)

```sql
SELECT user_id, day_of_week, order_count
FROM (
  SELECT user_id, EXTRACT(dow FROM order_date) AS day_of_week, COUNT(*) AS order_count,
         ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY COUNT(*) DESC) AS rank
  FROM orders GROUP BY user_id, EXTRACT(dow FROM order_date)
) ranked
WHERE rank = 1;
```

Responder's closing note: *"EXTRACT(dow FROM order_date) gives day-of-week (0=Sunday...); if you want the actual day name use CAST(EXTRACT(dow ...) AS VARCHAR) or dayname(order_date) if available."*

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 3 | Core SQL structure correct: `EXTRACT(DOW FROM order_date)` IS valid Trino 467 — verified via trino.io/docs/current/functions/datetime.html, EXTRACT accepts fields YEAR/QUARTER/MONTH/WEEK/DAY/DAY_OF_MONTH/DAY_OF_WEEK/**DOW**/DAY_OF_YEAR/DOY/YEAR_OF_WEEK/YOW/HOUR/MINUTE/SECOND/TIMEZONE_HOUR/TIMEZONE_MINUTE (SQL keywords case-insensitive so lowercase `dow` parses). ROW_NUMBER OVER (PARTITION BY ... ORDER BY COUNT(*) DESC) + WHERE rn=1 top-1-per-group is the canonical Trino idiom. **HOWEVER three real factual defects:** (a) **wrong day-numbering** — responder wrote "0=Sunday..." but Trino's `day_of_week()` / `EXTRACT(DOW ...)` returns **ISO 1=Monday..7=Sunday** (verified trino.io/docs/current/functions/datetime.html: "Returns the ISO day of the week from x. The value ranges from 1 (Monday) to 7 (Sunday)"). The "0=Sunday" claim is Postgres semantics, not Trino. (b) **floated non-existent `dayname(order_date)`** — Trino 467 has NO `dayname()` function; the "if available" hedge does not save it because the engineer will try it and get a "Function dayname not registered" error. (c) `CAST(EXTRACT(dow ...) AS VARCHAR)` for "actual day name" is misleading — that yields the string `"1"`/`"2"`, not `"Monday"`/`"Tuesday"`. |
| Completeness | 4 | Question fully answered (user + busiest-weekday + count); nested-aggregate framing explained well. Lost a point because day-name advice is broken and the dialect inoculation around `dayname()` should be assertive ("does NOT exist in Trino"), not hedged. |
| Clarity | 4 | Subquery shape clear; ROW_NUMBER explained; rank=1 picks single busiest weekday per user. The closing-note hedge is the clarity hit. |
| Actionability | 3 | The SQL itself runs and returns correct rows. But an engineer who tries `dayname(order_date)` gets a parse error; one who follows the "0=Sunday" comment misreads the output by 1 day and flips Sun/Mon; one who runs `CAST(EXTRACT(dow ...) AS VARCHAR)` gets a numeric string instead of a name. Three downstream foot-guns. |

### Q4 — Two-threshold HAVING (COUNT(*)>50 AND SUM(amount)>10000) — 5.00 STRONG PASS

```sql
SELECT customer_id FROM orders GROUP BY customer_id
HAVING COUNT(*) > 50 AND SUM(amount) > 10000;
```

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Verified trino.io/docs/467/sql/select.html — HAVING clause accepts any boolean expression composed of aggregates + grouping columns. Conjunction of two aggregate-threshold expressions in one HAVING is the canonical form (no need to split into CTE-layered HAVING). |
| Completeness | 5 | Both thresholds in one HAVING — exactly what the question asked. |
| Clarity | 5 | Minimal; aggregate-after-GROUP-BY scope explained. |
| Actionability | 5 | Drop-in valid Trino 467. |

---

## Overall

(4.75 + 5.00 + 3.50 + 5.00) / 4 = **4.5625 PASS** (margin +1.0625).

Dim-avg cross-check: Acc (5+5+3+5)/4 = 4.50 / Comp (4+5+4+5)/4 = 4.50 / Clar (5+5+4+5)/4 = 4.75 / Act (5+5+3+5)/4 = 4.50 → grand avg 4.5625. Agrees.

GOVERNING LABEL = **PASS** (overall 4.5625 >= 3.5; Q3 sits exactly at 3.50 floor — flagged in prose for teacher; per-Q flag does NOT override the overall PASS per directive).

---

## Flagged weak answer

**Q3** (3.50, at floor) — Trino-dialect defects on day-of-week semantics and a floated non-existent function. The SQL backbone is correct; the surrounding advice is wrong.

---

## Teacher feedback (actionable)

The bedrock SQL coverage (two-level macro-median, multi-key dim-JOIN, ROW_NUMBER top-1-per-user, two-threshold HAVING) is **structurally durably locked**. The single defect this iter is the **weekday-naming advice in Q3**. Recommended targeted inoculations:

1. **Anchor a "Trino day-of-week semantics" callout at the busiest-weekday phrasing** (the same place the responder reached). Verbatim canonical to add:
   - "`day_of_week(x)` and `EXTRACT(DOW FROM x)` BOTH return ISO weekday number **1=Monday..7=Sunday** (NOT 0=Sunday)."
   - "Trino 467 has **NO `dayname()` function**. Do not write `dayname(...)` — it is a parse-time `Function dayname not registered` error."
   - "To get the weekday **name** (`'Monday'`, `'Tuesday'`, ...) use: `format_datetime(CAST(order_date AS timestamp), 'EEEE')`."
   - "`CAST(EXTRACT(DOW FROM order_date) AS VARCHAR)` returns `'1'..'7'`, NOT `'Monday'..'Sunday'` — use it only when a numeric string is what you want."

2. **Place the inoculation where the responder's keyword path leads** — search anchors should include "busiest weekday", "day name", "dayname", "weekday name", "EXTRACT dow", "day_of_week". Per the responder-findability memory, the canonical must sit on the same keyword route the responder traverses for this question class, not just on the topical r07/r23 page.

3. **Reconcile, don't append** — if any existing r07 or r23 day-of-week block hedges "if available" or says "0=Sunday", overwrite those phrases in place. Responder will cite the stale variant otherwise.

4. **Do NOT** edit the four structurally-correct primitives (approx_percentile two-level, multi-key JOIN, ROW_NUMBER top-1-per-user, two-threshold HAVING) — those are all perfect this iter.

5. **Do NOT** bump training/state.json (teacher already set to 664 per directive).

6. **Do NOT** add MEDIAN/PERCENTILE_CONT (iter611 ban), QUALIFY, RLIKE (iter623 ban), `::`-casts (iter571 PIN), EXTRACT(EPOCH) (iter562 ban), DISTINCT-ON (iter634 ban), initcap (iter659 inoculation).

7. **Q1 minor**: when the question asks for "median AND avg of per-customer X" both, the responder delivered only the median. A small canonical at the macro-median anchor that explicitly shows BOTH outputs in one SELECT (`approx_percentile(per_customer_median, 0.5) AS median_of_medians, AVG(per_customer_median) AS avg_of_medians`) would close the completeness gap with no risk to the durably-correct structure.

---

## Topic score updates

- **Analytical query patterns on Iceberg+Trino / r07** — Q1 two-level approx_percentile composes correctly (durability +0.25); Q3 ROW_NUMBER top-1-per-user STRUCTURE correct but day-of-week advice defective (durability **-0.25** on dialect facts). Net flat/slightly down.
- **SQL query best practices for OLAP / r23** — Q2 multi-key dim-JOIN clean (+0.25); Q4 two-threshold HAVING clean (+0.25); Q3 dayname() floated and 0=Sunday wrong (**-0.50**). Net down.
- **Lakehouse schema design fact/dim / r08** — Q2 confirms star-schema dim-JOIN routes (+0.25).
- **Federation / r22** — NOT probed; row unchanged (consecutive non-probe count +1).

Continue durability-breadth runs but **fix Q3 day-of-week canonical next iter** to prevent the 3.50-floor result from recurring.
