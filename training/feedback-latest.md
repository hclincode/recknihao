# Iter 649 — Judge Feedback (EXTENDED PHASE)

**Overall average: 4.125 — PASS** (margin +0.625 above 3.5 floor; +0.0625 swing UP from iter648 PASS 4.0625)

Per-Q calc: (5.00 + 4.75 + 4.75 + 2.00) / 4 = 16.5 / 4 = 4.125
Dim-avg cross-check: Acc(5+5+5+1)/4=4.0 / Comp(5+5+5+3)/4=4.5 / Clar(5+4+4+3)/4=4.0 / Act(5+5+5+1)/4=4.0 = (4.0+4.5+4.0+4.0)/4 = 4.125 — agrees.

**HEADLINE — Q1 FIX-A LANDED CLEAN, Q4 NEW DEFECTS SURFACED**: The iter649 FIX-A (rolling-N-day-MA grain guardrail in r07 Pattern D) landed: Q1 (30-day rolling avg of daily NEW signups from a raw per-signup `signups` table) PRE-AGGREGATED to one-row-per-day FIRST (`COUNT(*) GROUP BY DATE(signup_at)`) and only THEN applied the rolling window — and went one step further by choosing the calendar-aware **RANGE BETWEEN INTERVAL '29' DAY PRECEDING AND CURRENT ROW** form, which is gap-day robust (correct even when some days have zero signups). Best possible landing for the FIX-A re-probe.

However, **Q4 (fixed-width $50 histogram of order amounts) regressed hard with TWO independent bugs across two answer forms**:
- **FORM 1**: `CASE WHEN bucket_num = 0 ...` references `bucket_num`, a SELECT-list alias defined in the SAME SELECT list. Verified at trino.io/docs/current/sql/select.html — Trino does NOT allow referencing a SELECT-list alias in another expression of the same SELECT list (aliases visible only in ORDER BY, not WHERE/GROUP BY/HAVING/sibling SELECT items). This is the same family as the alias-in-WHERE gotcha (the responder corrrectly avoided alias-in-WHERE in Q2 by REPEATING the date_parse expression — same fix needed here: REPEAT the `width_bucket(order_amount, ARRAY[...])` in the CASE, or wrap in a subquery).
- **FORM 2**: `ARRAY_AGG(DISTINCT (CAST(order_amount/50 AS BIGINT)*50)) OVER ()` — verified at trinodb/trino issue #7885 and #16984: **DISTINCT inside a window aggregate is NOT supported in Trino** (same family as COUNT(DISTINCT) OVER limitation). Additionally `element_at(bucket_bounds, bucket_num)` when `bucket_num = 0` (the below-first-bound case from width_bucket) is invalid — element_at is **1-based** per trino.io/docs/current/functions/array.html; index 0 errors.

The width_bucket CONCEPT is correct (N bounds in ARRAY → N+1 bins, bin 0 = below first bound). The bug is query assembly. **iter650 FIX-A candidate**: histogram / fixed-width-bucket canonical anchored at "fixed-width $50 buckets / histogram of order amounts", with two PRIMARY forms — (a) integer-division floor bucketing `SELECT CAST(order_amount/50 AS integer)*50 AS bucket_floor, COUNT(*) FROM orders GROUP BY CAST(order_amount/50 AS integer)*50 ORDER BY bucket_floor` (simplest, no width_bucket needed), (b) width_bucket-in-subquery-then-label-outer (preserves width_bucket teaching without the alias-in-same-SELECT bug). DO-NOT-WRITE pins: alias-in-same-SELECT FORM, array_agg(DISTINCT) OVER FORM, element_at(.,0) FORM. Tie to the EXISTING alias-in-WHERE / same-level-alias-resolution rule (responder DID get this right in Q2 — the rule needs to extend to "sibling SELECT items" not just WHERE).

---

## Per-question scores

### Q1 — 30-day rolling avg of daily NEW signups (raw per-signup signups table) — FIX-A re-probe

**Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = avg 5.00**

CLEAN — even better than asked. (a) Pre-aggregated raw per-signup rows to one-row-per-day via `COUNT(*) GROUP BY DATE(signup_at)` in a CTE FIRST — the iter649 FIX-A rolling-N-day-MA grain guardrail LANDED. (b) Then chose the **calendar-aware RANGE BETWEEN INTERVAL '29' DAY PRECEDING AND CURRENT ROW** frame — verified valid Trino 467 per trino.io/blog/2021/03/10/introducing-new-window-features.html (RANGE BETWEEN INTERVAL '1' month PRECEDING is the documented canonical) and trino.io/docs/current/functions/window.html. The RANGE-INTERVAL form is GAP-DAY ROBUST: if signups has zero for a given day (the daily-CTE has no row), RANGE-INTERVAL still defines the window by ORDER BY value, so the 30-day window is calendar-exact. ROWS-BETWEEN-29-PRECEDING would only be calendar-exact under a densified daily spine. The responder gave the more robust form. (c) Explanation walked the pre-aggregate-then-window staging in the right order. (d) `DATE(signup_at)` is valid Trino 467 (`date(x)` = `CAST(x AS date)`). FIX-A re-probe = PASS, primary form.

### Q2 — parse 'YYYY-MM-DD HH:MM:SS' to timestamp + filter to last 24h

**Accuracy 5 / Completeness 5 / Clarity 4 / Actionability 5 = avg 4.75**

CLEAN. `date_parse(event_time, '%Y-%m-%d %H:%i:%S')` is the canonical Trino MySQL-style formatter — %Y/%m/%d/%H/%i/%S all verified correct per trino.io/docs/current/functions/datetime.html (note %i = minutes, %M is month-name in MySQL flavor — responder got the right specifier). `date_parse` returns timestamp. The WHERE clause REPEATS the `date_parse(...)` expression rather than referencing the SELECT alias — correct Trino dialect behavior (alias-in-WHERE is invalid; the responder avoided it). `current_timestamp - INTERVAL '24' HOUR` is valid. Clarity -1 only because the DATE()-cast variant is mentioned without a strong steer; date_parse should be the primary recommendation since DATE() casts a STRING-of-date-with-time would need a different ingest path. Otherwise solid.

### Q3 — Pareto cumulative percent of revenue

**Accuracy 5 / Completeness 5 / Clarity 4 / Actionability 5 = avg 4.75**

CLEAN. (a) `SUM(SUM(revenue)) OVER ()` in the same SELECT as `SUM(revenue)` + `GROUP BY product_id` is a VALID Trino idiom — the inner SUM is the GROUP BY aggregate, the outer SUM-OVER-empty-window operates on the post-grouped rows to give the grand total. This is the standard "share of grand total" pattern. (b) Running cumulative SUM via `SUM(product_revenue) OVER (ORDER BY product_revenue DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` is correct — ORDER BY DESC for Pareto (largest first), UNBOUNDED-PRECEDING-to-CURRENT-ROW is the cumulative-from-start frame. (c) `100.0 * .../ total_revenue` uses 100.0 float multiplier to avoid integer division — correct. (d) ROUND(.., 2) for display polish. Clarity -1 for not explicitly calling out that this is the "share of grand total" pattern + naming the Pareto / 80-20 framing in the prose; mechanically correct, the explanatory framing was thin.

### Q4 — fixed-width $50 histogram of order amounts (don't hardcode every bucket)

**Accuracy 1 / Completeness 3 / Clarity 3 / Actionability 1 = avg 2.00 — WEAK; FAILED**

Two independent bugs across two answer forms:

**FORM 1 BUG — alias-in-same-SELECT**: `SELECT width_bucket(order_amount, ARRAY[...]) AS bucket_num, CASE WHEN bucket_num = 0 THEN ... END AS bucket_label, COUNT(*) ... GROUP BY width_bucket(...)`. The `CASE WHEN bucket_num = 0 ...` references the SELECT-list alias `bucket_num` defined in the SAME SELECT list. Verified at trino.io/docs/current/sql/select.html — Trino SELECT-list aliases are ONLY visible in ORDER BY, NOT in other SELECT-list expressions (also NOT in WHERE/GROUP BY/HAVING). Query will fail with column-cannot-be-resolved at planning. Fix: REPEAT `width_bucket(order_amount, ARRAY[...])` inside the CASE, or wrap the width_bucket assignment in an inner subquery/CTE then label and COUNT in the outer.

**FORM 2 BUGS — DISTINCT-in-window-aggregate + element_at-index-0**:
- `ARRAY_AGG(DISTINCT (CAST(order_amount/50 AS BIGINT)*50)) OVER ()`. Verified at trinodb/trino issues #7885 + #16984: DISTINCT inside a window aggregate is NOT supported in Trino (same family as `COUNT(DISTINCT col) OVER (...)` — both rejected with "DISTINCT in window function parameters not yet supported"). Query fails at planning.
- `element_at(bucket_bounds, bucket_num)` when `bucket_num = 0` (the below-first-bound case from width_bucket): verified at trino.io/docs/current/functions/array.html — element_at uses 1-BASED indexing for positive indices; index 0 is invalid and errors at runtime.

**What IS correct**: the width_bucket CONCEPT (bounds array of length N produces N+1 bins; bin 0 = below first bound; bin N = above last bound). The bug is in the query assembly, not the function choice.

**iter650 FIX-A candidate — histogram/fixed-width-bucket canonical**:
1. PRIMARY (simplest, no width_bucket needed): integer-division floor bucketing
   ```sql
   SELECT CAST(order_amount / 50 AS integer) * 50 AS bucket_floor, COUNT(*) AS n
   FROM orders
   GROUP BY CAST(order_amount / 50 AS integer) * 50
   ORDER BY bucket_floor
   ```
   Pin: REPEAT the expression in GROUP BY (alias-in-GROUP-BY is also invalid in Trino, same family as alias-in-WHERE).
2. SECONDARY (when you want labels and a fixed lower/upper bound array): width_bucket inside a CTE, label + count in the outer
   ```sql
   WITH bucketed AS (
     SELECT order_amount, width_bucket(order_amount, ARRAY[50, 100, 150, 200, 250, 300, 350, 400, 450, 500]) AS bucket_num
     FROM orders
   )
   SELECT bucket_num,
          CASE bucket_num WHEN 0 THEN '< $50'
                          WHEN 1 THEN '$50-$100'
                          ...
                          WHEN 10 THEN '>= $500' END AS bucket_label,
          COUNT(*) AS n
   FROM bucketed
   GROUP BY bucket_num
   ORDER BY bucket_num
   ```
3. DO-NOT-WRITE pins:
   - `SELECT width_bucket(...) AS bn, CASE WHEN bn = 0 ... FROM t` (alias-in-same-SELECT)
   - `ARRAY_AGG(DISTINCT ...) OVER ()` (DISTINCT inside window aggregate not supported)
   - `element_at(arr, 0)` (1-based; index 0 errors)
4. Tie to the EXISTING alias-in-WHERE / same-level-alias-resolution rule — extend the rule to cover "sibling SELECT items" (the responder honored the rule in Q2 for WHERE; it must extend to peer SELECT-list expressions and to GROUP BY).
5. Keyword anchors: "fixed-width $50 histogram of order amounts", "fixed-width bucket", "bucket order amounts into $50 bins", "don't hardcode every bucket", "width_bucket array bounds histogram".

---

## Score history line (append to rubric.md)

```
| iter649 | Q1 5.00 / Q2 4.75 / Q3 4.75 / Q4 2.00 → avg 4.125 PASS | Q1 FIX-A re-probe CLEAN (pre-aggregated daily THEN window + bonus RANGE-INTERVAL gap-day-robust form); Q2/Q3 clean; Q4 FAILED — alias-in-same-SELECT (FORM 1) + array_agg(DISTINCT) OVER + element_at(.,0) (FORM 2). iter650 FIX-A candidate: histogram/fixed-width-bucket canonical. |
```

---

## Verdict

- **PASS** at overall avg 4.125 (>= 3.5 floor; margin +0.625).
- Q1 iter649 FIX-A re-probe = LANDED CLEAN (the rolling-N-day-MA grain guardrail held, plus the responder went one step further with the gap-day-robust RANGE-INTERVAL form).
- Q4 = weak (2.00 < 3.5) — DOES NOT override the PASS label per directive (overall average governs), but flagged as iter650 FIX-A target.

**iter650 FIX-A**: histogram / fixed-width-bucket canonical (anchored at "fixed-width $50 buckets / histogram of order amounts"), with integer-division-floor PRIMARY and width_bucket-in-CTE SECONDARY, and explicit DO-NOT-WRITE for alias-in-same-SELECT + array_agg(DISTINCT) OVER + element_at(.,0). Tie to the existing alias-in-WHERE / same-level-alias-resolution rule by extending its scope to sibling SELECT-list expressions and GROUP BY.
