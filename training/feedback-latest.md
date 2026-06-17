# Judge Feedback — iter1038

Verified BOTH directions against RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/...) + WebSearch (official docs + community), NOT against resources/. Prod stack (Trino 467 + Iceberg + MinIO + Hive Metastore) — all 4 questions fit; no federation/auth angle. Federation r22 §13.x hard-locked, NOT probed.

Scoring per dimension (Accuracy / Completeness / Clarity / Actionability), each 1–5.

---

## Q1 — array length filter: rows where tags has ≥3 elements

**Answer:** `WHERE cardinality(tags) >= 3`; cardinality(array) returns element count as bigint, no UNNEST needed.

**Verification:** array.md (467 RAW) — `cardinality(x) -> bigint`, "Returns the cardinality (size) of the array x." CONFIRMED. Applying it directly in WHERE with `>= 3` is exactly right; no UNNEST/COUNT detour needed; bigint compares cleanly with an integer literal.

**Scores:** Accuracy 5 / Completeness 4.75 / Clarity 4.75 / Actionability 4.75 → **4.8125**
Clean. Correct function, correct return type, correct usage, the "no UNNEST needed" note is the useful efficiency reassurance a beginner wants.

---

## Q2 (THE KEY ITEM) — running total of revenue per day

**Answer (LEAD):**
```sql
SELECT order_date,
       SUM(revenue) AS daily_revenue,
       SUM(revenue) OVER (ORDER BY order_date
                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_revenue
FROM orders
GROUP BY order_date
ORDER BY order_date;
```
plus a `PARTITION BY tenant_id` variant of the same single-SUM window expression.

**Verification — DISPOSITIVE FINDING: the LEAD query is INVALID as written and would NOT run in Trino 467.**

Standard SQL semantics, to which Trino conforms: when a query has `GROUP BY order_date`, the SELECT/window stage is evaluated AFTER grouping. Every column reference in that stage must be either (a) a grouping column or (b) wrapped in an aggregate. The running-total expression `SUM(revenue) OVER (...)` has a bare inner argument `revenue` that is NEITHER a grouping column NOR inside a GROUP BY aggregate. Trino raises:

> `'revenue' must be an aggregate expression or appear in GROUP BY clause`

This is the same class of error documented in the Trino/Athena community (AWS re:Post "Must be an aggregate expression or appear in GROUP BY clause") and is corroborated by the Trino docs search results: the recommended pattern for a running total over grouped data is to "first aggregate with GROUP BY, then apply the window function OVER (ORDER BY) in an outer query" (or nest the aggregates). The single-SUM-over-GROUP-BY form is NOT accepted.

Note: the `daily_revenue` column (a bare `SUM(revenue)` as a normal GROUP BY aggregate) is fine. The defect is ONLY in the running-total expression. The frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` is the CORRECT running-total frame (and is the implicit default frame once an ORDER BY is present), so that part is sound. The `PARTITION BY tenant_id` variant inherits the same single-SUM defect.

**Correct Trino 467 forms (either works):**

1. Nested aggregate (the idiomatic one-statement fix):
```sql
SELECT order_date,
       SUM(revenue) AS daily_revenue,
       SUM(SUM(revenue)) OVER (ORDER BY order_date
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_revenue
FROM orders
GROUP BY order_date
ORDER BY order_date;
```
The inner `SUM(revenue)` is the per-day GROUP BY aggregate; the outer `SUM(...) OVER` is the running total over those daily sums.

2. Daily CTE then window:
```sql
WITH daily AS (
  SELECT order_date, SUM(revenue) AS daily_revenue
  FROM orders GROUP BY order_date
)
SELECT order_date, daily_revenue,
       SUM(daily_revenue) OVER (ORDER BY order_date
                                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_revenue
FROM daily ORDER BY order_date;
```

The responder also correctly answered the engineer's actual sub-question ("is it possible in SQL or must it be app-side") — YES, it is pure SQL, no app-side needed — but delivered a LEAD query that errors. The conceptual answer is right; the runnable artifact is wrong.

**Scores:** Accuracy 2.5 / Completeness 4.0 / Clarity 4.5 / Actionability 3.0 → **3.5**
Accuracy heavily dinged: the primary deliverable does not execute. Completeness/clarity partially salvaged because the correct frame, the PARTITION-BY tenant variant intent, and the "it's possible in SQL" framing are all present and well-explained — an engineer who knows the nested-SUM trick could repair it, but the responder did not provide it.

---

## Q3 — return whichever currency amount is non-null per row, without a big CASE

**Answer:** `COALESCE(amount_usd, amount_eur, amount_gbp) AS amount` — first non-null, no CASE.

**Verification:** conditional.md (467) — COALESCE "Returns the first non-null value in the argument list." All three columns are in the numeric family; Trino coerces to a common numeric super-type (no type error, possible precision widening only). Exactly the "one populated per row" pattern, and exactly the no-CASE answer requested. CONFIRMED.

**Scores:** Accuracy 5 / Completeness 4.75 / Clarity 4.75 / Actionability 4.75 → **4.8125**
Clean. Direct, idiomatic, addresses the explicit "without a big CASE" ask.

---

## Q4 — label each event with the day-of-week NAME ("Monday")

**Answer:** `format_datetime(CAST(occurred_at AS timestamp), 'EEEE') AS day_name` → full weekday name; notes `dayname()` does NOT exist in 467; CAST optional (DATE→TIMESTAMP coercion).

**Verification:** datetime.md (467 RAW) — `format_datetime(timestamp, format) -> varchar`, "use a format string compatible with JodaTime's DateTimeFormat pattern format." In JodaTime DateTimeFormat, `E` = day-of-week and 4+ pattern letters (`EEEE`) render the FULL text form ("Monday"); `EEE` = abbreviated ("Mon"). CONFIRMED correct. `dayname()` is genuinely ABSENT in 467 — correct callout. `day_of_week(x) -> bigint` returns the NUMBER (1=Mon..7=Sun) the user did NOT want — correctly avoided. `occurred_at` is already a timestamp, so the CAST is REDUNDANT-but-harmless (responder correctly flags it as optional).

**Scores:** Accuracy 5 / Completeness 4.75 / Clarity 4.75 / Actionability 4.75 → **4.8125**
Clean. Correct function, correct pattern letters, correctly rules out the two wrong-tool alternatives.

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q2 | 2.5 | 4.0 | 4.5 | 3.0 | 3.5 |
| Q3 | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q4 | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |

**Overall average = (4.8125 + 3.5 + 4.8125 + 4.8125) / 4 = 4.484375 → PASS** (overall average governs; no per-Q veto. Margin +0.984375 over the 3.5 threshold; Q2 sits exactly at 3.5 individually but does not veto.)

`::` cast ABSENT all 4. No QUALIFY / false-semi-join / fabricated-function / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / over-warning. The only defect is the Q2 single-SUM-OVER-in-GROUP-BY.

---

## Q2 defect classification + recommendation

The Q2 defect is the well-known "window aggregate over a GROUP BY column that isn't grouped/aggregated" error. Two possibilities:

- **RESPONDER SLIP** if the running-total resource teaches the correct nested-`SUM(SUM(x)) OVER` form (or the daily-CTE-then-window form) findably, and the responder collapsed it to a single SUM under GROUP-BY pressure.
- **RESOURCE GAP/DEFECT** if the running-total card actually shows a bare `SUM(x) OVER (...)` sitting in the same statement as a `GROUP BY`, i.e. the resource itself blesses the non-runnable form.

This is the FIRST occurrence of this specific construction in the recent re-probe history (running totals previously appeared as windowed shares / RANGE-interval windows, not as cumulative-sum-over-daily-GROUP-BY), so it is NOT yet 2-in-2 and does NOT warrant an automatic FIX-A.

**RECOMMENDATION = grep-classify, then decide (no blind churn).** Orchestrator should grep resources for the running-total / cumulative-sum / `OVER (ORDER BY ... ROWS` cards and check whether ANY canonical shows a single `SUM(x) OVER (...)` in a statement that ALSO has `GROUP BY` on a different key:
- If a resource shows the buggy single-SUM-with-GROUP-BY form → RESOURCE DEFECT → reconcile-in-place (replace with `SUM(SUM(x)) OVER` nested form AND a daily-CTE alternative; add a one-line note: "a running total OVER the per-period total needs the nested aggregate or a pre-aggregated CTE — a bare SUM(x) OVER in a GROUP BY query errors with 'must be an aggregate expression or appear in GROUP BY'").
- If resources already teach the nested/CTE form correctly → RESPONDER SLIP → per-instance monitor only, NO resource edit; re-probe the cumulative-sum-over-daily-GROUP-BY angle next sweep to see if it recurs (escalate to LIGHT findability nudge only if 2-in-2).

Do NOT touch state.json (already at iter1038; orchestrator commits). Do NOT edit resources/ (judge scope) — the grep-classify + any fix is the teacher/orchestrator's action.
