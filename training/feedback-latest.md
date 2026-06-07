# Judge Feedback — iter636

**Date**: 2026-06-07
**Iteration**: 636
**Phase**: extended

---

## Per-question scores (1–5 each dimension)

| Q | Dimension | Score | Notes |
|---|---|---|---|
| **Q1** (enterprise revenue as % of total) | Accuracy | 5 | Single-pass `SUM(CASE WHEN ...) * 100.0 / SUM(amount)` and `SUM(amount) FILTER (WHERE plan_type='enterprise') * 100.0 / SUM(amount)` are BOTH valid Trino 467 (verified against trino.io/docs/467/functions/aggregate.html — FILTER clause confirmed; 100.0 float division + two aggregates in one SELECT confirmed). No CTE/cross-join, no base-column scope bug. **FIX-A guardrail LANDED.** |
| Q1 | Completeness | 5 | Both the conditional-SUM and FILTER variants given; ROUND wrapper included. |
| Q1 | Clarity | 4.5 | Concise, no jargon. Could optionally name divide-by-zero guard, but not required for the question. |
| Q1 | Actionability | 5 | Engineer can copy-paste directly. |
| **Q1 avg** | | **4.875** | |
| **Q2** (rolling 7-day distinct active users) | Accuracy | 1.5 | **HEADLINE SNIPPET INVALID.** `COUNT(DISTINCT user_id) OVER (ORDER BY occurred_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)` — verified via trinodb/trino#7885, #5523, #25434: DISTINCT inside window function parameters is NOT supported in Trino; produces "DISTINCT in window function parameters not yet supported" at planning (the partial impl in newer issues returns 0 incorrectly — confirmed buggy). The first snippet also mixes a window over `user_id` with `GROUP BY occurred_date` while selecting the window output — incoherent semantically (user_id is neither grouped nor aggregated). The unused `daily_active` CTE is dead code. The SECOND snippet's HLL approach (`approx_set(user_id)` per day → store as varbinary → self-join 7-day window → `cardinality(merge(CAST(s2.user_sketch AS HyperLogLog)))`) IS valid Trino 467 (verified against trino.io HyperLogLog functions docs — `approx_set` returns HyperLogLog, `merge(hyperloglog)` aggregates HLLs, `cardinality(merge(...))` returns the union estimate; the canonical "weekly_unique_users" docs example is precisely this pattern). The self-join `s2.event_date BETWEEN s1.event_date - INTERVAL '6' DAY AND s1.event_date` then GROUP BY s1.event_date merging the joined sketches is correct for a rolling-7-day approximate distinct. But the answer LEADS with the invalid snippet and only offers HLL as an alternative — a Haiku responder consumer may copy the broken headline. |
| Q2 | Completeness | 3 | The HLL alternative IS the right pattern, but the answer should reverse priority: HLL FIRST as canonical, with an explicit call-out that `COUNT(DISTINCT) OVER` is unsupported. An exact-count alternative (self-join each day to its 7-day window then `COUNT(DISTINCT user_id) GROUP BY anchor_day`) was not given. |
| Q2 | Clarity | 3 | Two snippets given but no signposting of which to use. Beginner reader cannot tell that snippet 1 will error at planning. |
| Q2 | Actionability | 2.5 | Engineer who copies snippet 1 gets a Trino planning error. Engineer who copies snippet 2 succeeds but needs to understand it's approximate. |
| **Q2 avg** | | **2.5** | |
| **Q3** (total subscribed days per customer) | Accuracy | 4 | `SUM(date_diff('day', start_date, end_date)) GROUP BY customer_id` is valid Trino 467 (`date_diff` returns bigint, verified — trino.io/docs/467/functions/datetime.html; SUM over rows is valid). The +1 inclusive-boundary variant is reasonable. **Caveat NOT raised**: this sums per-row spans without deduplicating overlapping subscription periods — if a customer has two overlapping subscription rows the days are double-counted. The literal question reading allows this answer, but a robust answer should flag the overlap caveat (or provide an interval-merge pattern for the "unique subscribed days" reading). |
| Q3 | Completeness | 3.5 | Core answer correct; overlap caveat absent. Boundary +1 variant is a nice touch. |
| Q3 | Clarity | 4 | Clean and direct. |
| Q3 | Actionability | 4 | Engineer can run it; would benefit from the overlap caveat call-out. |
| **Q3 avg** | | **3.875** | |
| **Q4** (count of orders tied for each customer's personal-max amount) | Accuracy | 1.5 | **MULTIPLE INVALID SNIPPETS — REGRESSION against r27:§4.2 window-in-WHERE guard.** (1) Snippet 2 uses `WHERE amount = MAX(amount) OVER (PARTITION BY customer_id)` — window functions are NOT allowed in WHERE in Trino (WHERE evaluated before window-function phase per SELECT processing order; verified via trino.io SELECT docs + trinodb/trino#6447). Snippet 2 ALSO nests `MAX(amount) OVER (...)` inside `SUM(CASE ... THEN 1 ELSE 0 END) OVER (PARTITION BY customer_id)` — nested window functions are not allowed in Trino. (2) Snippet 4 uses `COUNT(*) FILTER (WHERE amount = MAX(amount) OVER (PARTITION BY customer_id))` — window function inside a regular aggregate's FILTER is the same pre-window-phase violation; INVALID. (3) Snippet 1 has a logic bug: `WHERE o.amount = cm.max_amount` already pre-filters AND `GROUP BY o.customer_id, o.order_id, o.amount` makes each group a single row, so `COUNT(*) FILTER (...)` returns 1 per surviving order, NOT the per-customer tied count. The CORRECT pattern (compute `MAX(amount) OVER (PARTITION BY customer_id) AS cust_max` in an INNER SUBQUERY/CTE, then OUTER `WHERE amount = cust_max` or `COUNT(*) FILTER (WHERE amount = cust_max) GROUP BY customer_id`) is NOT given. Snippet 3's `CASE WHEN amount = MAX(amount) OVER (...) THEN 1 ELSE 0 END` is valid as a SELECT-list flag but does not answer the count question on its own. |
| Q4 | Completeness | 2 | Four snippets, only one (snippet 3 as a per-row tag) is valid Trino; none correctly answer the count question. |
| Q4 | Clarity | 2 | Multiple snippets confuse the reader without correctness signposting. |
| Q4 | Actionability | 1.5 | Snippets 2 and 4 fail at planning; snippet 1 silently returns wrong numbers. Engineer following this answer is stuck. |
| **Q4 avg** | | **1.75** | |

---

## Overall

- **Q1 avg**: 4.875
- **Q2 avg**: 2.5
- **Q3 avg**: 3.875
- **Q4 avg**: 1.75
- **Overall average**: (4.875 + 2.5 + 3.875 + 1.75) / 4 = **3.25**

### Verdict: **FAIL** (overall 3.25 < 3.5)

---

## Specific findings

### (a) Q1 FIX-A confirmation — LANDED

The iter636 share-of-subset final-assembly guardrail at r07:1097 LANDED cleanly. The Q1 answer uses the single-pass conditional-SUM form `SUM(CASE WHEN plan_type='enterprise' THEN amount ELSE 0 END) * 100.0 / SUM(amount)` AND the equivalent FILTER form `SUM(amount) FILTER (WHERE plan_type='enterprise') * 100.0 / SUM(amount)` over a single FROM (orders). No CTE cross-join, no out-of-scope base-column reference, no iter635-style column-scope bug. Both forms are valid Trino 467 per trino.io/docs/467/functions/aggregate.html. The iter635 share-of-subset final-assembly column-scope bug is fully inoculated for this question shape.

### (b) Q4 window-in-WHERE / nested-window REGRESSION — FINDABILITY MISS

This is a **regression against the locked r27:§4.2 alias/window-in-WHERE guard**. The guard exists in resources but the responder did NOT reach it for the "orders tied for each customer's personal-max amount" / "rows equal to per-customer max" phrasing. Snippets 2 and 4 both put a window function in WHERE (or in the FILTER of an aggregate, which is evaluated at the same pre-window stage), and Snippet 2 also nests window functions. These are exactly the patterns the r27:§4.2 guard is supposed to inoculate against.

**Diagnosis**: FINDABILITY MISS — the keyword anchors for the "tied-at-personal-max / orders matching per-customer max / rows equal to the partition max" phrasing are not strong enough at the r27:§4.2 site. The responder did topic-correct retrieval (max-per-group, ties) but missed the dialect-validity anchor.

**Recommended iter637 FIX-A** — add a canonical sub-card adjacent to r27:§4.2 (RECONCILE-in-place, do NOT rewrite the existing guard) keyed to these phrasings as READ-THIS-FIRST anchors:

- "orders/rows tied for each customer's max"
- "orders matching their group max"
- "rows equal to the partition max / per-group max"
- "count of rows tying the per-customer maximum"
- "how many orders at each customer's top spend"
- "ties at the per-group maximum value"
- "rows equal to MAX OVER PARTITION BY"

Canonical pattern to anchor:

```sql
-- CORRECT: wrap window in subquery/CTE, filter at outer level on the projected alias
WITH ranked AS (
  SELECT o.customer_id, o.order_id, o.amount,
         MAX(o.amount) OVER (PARTITION BY o.customer_id) AS cust_max
  FROM orders o
)
SELECT customer_id,
       COUNT(*) FILTER (WHERE amount = cust_max) AS tied_at_max
FROM ranked
GROUP BY customer_id;
```

Equivalent outer-WHERE form:

```sql
WITH ranked AS (
  SELECT o.customer_id, o.order_id, o.amount,
         MAX(o.amount) OVER (PARTITION BY o.customer_id) AS cust_max
  FROM orders o
)
SELECT customer_id, COUNT(*) AS tied_at_max
FROM ranked
WHERE amount = cust_max
GROUP BY customer_id;
```

DO-NOT-WRITE rows (verbatim against the bad iter636 A4 snippets):

- `WHERE amount = MAX(amount) OVER (PARTITION BY customer_id)` — window in WHERE; WHERE evaluated before window phase; FAILS at planning.
- `COUNT(*) FILTER (WHERE amount = MAX(amount) OVER (...))` — window inside regular-aggregate FILTER; same pre-window violation; FAILS.
- `SUM(CASE WHEN amount = MAX(amount) OVER (...) THEN 1 ELSE 0 END) OVER (...)` — nested window functions; not allowed in Trino; FAILS.
- Snippet-1-style pre-filter then GROUP BY order_id giving 1-per-row count — logic bug; grouping at the row grain destroys the per-customer tie count.

### (c) Q2 COUNT(DISTINCT) OVER invalidity

`COUNT(DISTINCT user_id) OVER (ORDER BY occurred_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)` is INVALID Trino (verified — trinodb/trino#7885, #5523 long-standing; #25434 confirms even partial impl returns 0 incorrectly). Rolling-distinct-count needs:

- **Approximate**: HLL-merge over self-join 7-day windows — the SECOND snippet in A2 IS this pattern and is valid. The teacher should promote this to PRIMARY in the answer ordering.
- **Exact**: self-join each anchor day to its 6-day-back-to-current window then `COUNT(DISTINCT user_id) GROUP BY anchor_day` — true (non-window) aggregate over the joined 7-day span.

Recommended teacher addition (supporting sub-card, not the iter637 FIX-A): a "rolling-distinct-count" canonical at r07 anchored on phrasings "rolling 7-day distinct users", "last N days unique users per day", "moving window distinct count" — leading with HLL-merge as PRIMARY and inoculating `COUNT(DISTINCT) OVER` as DO-NOT-WRITE with the docs-issue citations.

### Lowest per-question average

**Q4 avg = 1.75** is the lowest and is the iter637 FIX-A target (window-in-WHERE / nested-window canonical with "orders tied at personal-max" phrasings).

### Q3 minor caveat (not blocking)

The overlap-double-counting caveat for SUM(date_diff(...)) over multiple subscription rows is a nice-to-have but does not block this Q on its own; the literal question allows the per-row span sum.

---

## iter637 FIX-A directive

**Target**: r27:§4.2 (window-in-WHERE / nested-window guard) — add a sub-card adjacent to the existing guard (RECONCILE-in-place — do NOT rewrite r27:§4.2) anchored on the "orders tied for each customer's personal max" / "rows equal to per-group max" / "ties at the partition maximum" phrasings, with:

1. READ-THIS-FIRST keyword anchors covering the 7+ phrasings listed in section (b).
2. ONE-FACT summary: "compute MAX(...) OVER (PARTITION BY ...) in an INNER subquery/CTE, then filter on the projected alias at the OUTER level — NEVER place a window function in WHERE / FILTER / nested-OVER."
3. CORRECT canonical (CTE form + outer-WHERE form).
4. DO-NOT-WRITE table with the 4 verbatim bad forms from iter636 A4.
5. Cross-references from r07/r23 conditional-aggregation cards to this sub-card.

Pin: Trino 467 dialect (no QUALIFY, no nested-window, no window-in-WHERE, no window-in-FILTER-of-regular-aggregate, no DISTINCT-in-window, FILTER clause valid on plain aggregates only).
