# Judge Feedback — iter1039

**Verification basis:** All claims verified BOTH directions against RAW git-tag 467 source
(raw.githubusercontent.com/trinodb/trino/467/docs/...) + WebSearch on official docs / trinodb
issue tracker — NOT against `resources/`. Prod stack (Trino 467 + Iceberg + MinIO + Hive
Metastore, on-prem) fits all 4 questions; no federation/auth angle (federation r22 §13.x
hard-locked, NOT probed).

Scoring per dimension (Accuracy / Completeness / Clarity / Actionability), each 1–5.

---

## Q1 — cumulative revenue by day (running total) — **3.625**

**Answer:**
```sql
SELECT day, revenue,
       SUM(revenue) OVER (ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
         AS cumulative_revenue
FROM iceberg.analytics.daily_revenue
WHERE day >= DATE '2026-01-01'
ORDER BY day;
```
plus a `PARTITION BY tenant_id` multi-tenant variant.

**Verification — TWO assessments as directed:**

(a) **Is the query AS WRITTEN valid Trino? YES.** It selects from `daily_revenue`, which is ONE
ROW PER DAY, with NO GROUP BY. So `SUM(revenue) OVER (ORDER BY day ROWS BETWEEN UNBOUNDED
PRECEDING AND CURRENT ROW)` is a straightforward running total over already-aggregated rows —
fully valid. **The iter1038 dangerous invalid shape did NOT recur.** There is NO
GROUP-BY + bare-`SUM(OVER)`-of-a-non-grouping-column error here (that error needs a `GROUP BY`
in the same statement; this query has none). The ROWS frame is the correct running-total frame
(and the default once ORDER BY is present), and the `PARTITION BY tenant_id` variant is sound.
Running-total *mechanics* are correct.

(b) **COMPLETENESS DODGE (the real penalty).** The QUESTION gave an `orders` table that is ONE
ROW PER ORDER, hundreds of orders per day — i.e. MANY rows per day. The answer silently assumes
a pre-existing one-row-per-day `daily_revenue` table and never shows the pre-aggregation. An
engineer holding only `orders` CANNOT run this. The missing grain-collapse step is:
```sql
WITH daily AS (
  SELECT date_trunc('day', order_ts) AS day, SUM(amount) AS revenue
  FROM orders GROUP BY date_trunc('day', order_ts)
)
SELECT day, revenue,
       SUM(revenue) OVER (ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
         AS cumulative_revenue
FROM daily ORDER BY day;
```
(Equivalent nested form directly over `orders` + `GROUP BY day`:
`SUM(SUM(amount)) OVER (ORDER BY day ROWS ...)`.) Because the answer skips the aggregation the
question explicitly called for, it does not actually solve the stated problem.

**Scores:** Accuracy 4.5 / Completeness 2.75 / Clarity 4.5 / Actionability 2.75 → **3.625**
Accuracy mostly preserved (what is shown runs and is correct); Completeness/Applicability dinged
hard for dodging the many-rows-per-day grain. This is a SOFTER failure than a non-executable
query — the prior dangerous shape is gone.

---

## Q2 — null-safe date equality without CASE/IS NULL — **4.8125**

**Answer:** `WHERE plan_start IS NOT DISTINCT FROM another_date`; NULL=NULL→equal, false only on
real value mismatch; equivalent to `(a=b) OR (a IS NULL AND b IS NULL)`.

**Verification:** RAW comparison.md (467) — "The IS DISTINCT FROM and IS NOT DISTINCT FROM
operators treat NULL as a known value and both operators guarantee either a true or false outcome
even in the presence of NULL input," and explicitly `SELECT NULL IS NOT DISTINCT FROM NULL;
-- true`. This is exactly the spec: NULL vs NULL counts equal, only false when values actually
differ, and no CASE/IS NULL used. The stated equivalence is accurate. CONFIRMED clean.

**Scores:** Accuracy 5 / Completeness 4.75 / Clarity 4.75 / Actionability 4.75 → **4.8125**

---

## Q3 — pull nested JSON os as a plain string for GROUP BY — **3.25**

**Answer:**
```sql
SELECT event_id, json_extract_scalar(properties, '$.context.os') AS device_os
FROM events
WHERE occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY device_os;
```

**Verification — core CORRECT, illustrative query BROKEN on two counts:**

- **Core guidance CORRECT.** RAW json.md (467): json_extract_scalar "returns the result value as
  a string (as opposed to being encoded as JSON)" and supports nested dot paths
  (`$.store.book[0].author` example). So `json_extract_scalar(properties, '$.context.os')`
  correctly returns the nested os as a plain varchar suitable for grouping. The
  `INTERVAL '7' DAY` predicate is a valid qualifier.
- **DEFECT 1 — GROUP-BY-ALIAS error.** The query writes `GROUP BY device_os`, where `device_os`
  is the SELECT-list ALIAS. Trino does NOT permit GROUP BY to reference a select-list alias (only
  ORDER BY may). Confirmed via trinodb/trino issue #16533 ("Using alias in group by is not
  supported by Trino") — Trino diverges from MySQL/Postgres here and requires the actual
  expression. As written this is an analysis error ("Column 'device_os' cannot be resolved").
  Fix: repeat the expression `GROUP BY json_extract_scalar(properties,'$.context.os')` or use the
  ordinal `GROUP BY 2`.
- **DEFECT 2 — ungrouped non-aggregate.** `event_id` is in the SELECT list but is neither grouped
  nor aggregated → a second analysis error. The grouping intent ("so it can be grouped") wants
  `SELECT json_extract_scalar(...) AS device_os, COUNT(*) ... GROUP BY 1`.
- **INTERNAL INCONSISTENCY:** Q4 below correctly REPEATS the expression in GROUP BY
  (`GROUP BY format_datetime(...)`) while Q3 used the alias — the responder applied the rule
  correctly in one answer and broke it in another within the SAME iteration, which signals a slip
  rather than a missing concept.

**Scores:** Accuracy 3.0 / Completeness 4.0 / Clarity 4.0 / Actionability 3.0 → **3.25**
Accuracy penalized for shipping a non-executable example; partially offset because the
asked-about json_extract_scalar mechanic (the actual question) is correct.

---

## Q4 — signups by day-of-week NAME — **4.75**

**Answer:**
```sql
SELECT format_datetime(created_at, 'EEEE') AS day_name, COUNT(*) AS signups
FROM users
WHERE created_at >= CURRENT_DATE - INTERVAL '30' DAY
GROUP BY format_datetime(created_at, 'EEEE')
ORDER BY CASE format_datetime(created_at,'EEEE') WHEN 'Monday' THEN 1 ... WHEN 'Sunday' THEN 7 END;
```

**Verification:** RAW datetime.md (467) — `format_datetime(timestamp, format) -> varchar`, JodaTime
DateTimeFormat patterns. JodaTime: `E` = day-of-week text; 4+ pattern letters (`EEEE`) render the
FULL form → "Monday" (EEE → "Mon"). CONFIRMED. `created_at` is a timestamp, so format_datetime
accepts it directly (no CAST needed). `dayname()` is genuinely ABSENT in 467 (day_of_week()
returns the bigint the user did NOT want) — correctly avoided. Crucially `GROUP BY
format_datetime(created_at,'EEEE')` REPEATS the expression (NOT an alias) → VALID, in direct
contrast with the Q3 mistake. The `ORDER BY CASE … Monday→1 … Sunday→7` calendar-sort is sound
(prevents alphabetical day scrambling). CONFIRMED clean.

**Scores:** Accuracy 5 / Completeness 4.75 / Clarity 4.5 / Actionability 4.75 → **4.75**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 4.5 | 2.75 | 4.5 | 2.75 | 3.625 |
| Q2 | 5.0 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q3 | 3.0 | 4.0 | 4.0 | 3.0 | 3.25 |
| Q4 | 5.0 | 4.75 | 4.5 | 4.75 | 4.75 |

**Overall average = (3.625 + 4.8125 + 3.25 + 4.75) / 4 = 4.109375 → PASS**
(overall average governs; no per-Q veto. Margin +0.609375 over the 3.5 threshold.)

`::` cast ABSENT all 4. No QUALIFY / false-semi-join / fabricated-function / regex-backslash /
INTERVAL-quarter-week / OFFSET-before-LIMIT / over-warning. Defects: Q1 completeness dodge
(pre-aggregation omitted), Q3 GROUP-BY-alias + ungrouped-column broken example.

---

## Recommendation

**(1) Q1 — running-total re-probe: WATCH (q) DOWNGRADED TO PASSIVE MONITOR.** The iter1038 invalid
running-total shape (bare single `SUM(OVER)` of a non-grouping column inside a `GROUP BY day`
query) did **NOT recur**. The mechanics shown are valid because the source table is already
one-row-per-day; what remains is a pure **completeness dodge** — the answer assumed a
pre-aggregated `daily_revenue` table rather than showing the orders→daily grain-collapse the
question specified. This is a softer failure than a non-executable query. Downgrade the
running-total/cumulative-sum watch from active to passive monitor; re-probe with a RAW
one-row-per-order source next sweep to confirm the responder volunteers the pre-aggregation CTE
(r07 L1791 daily-CTE card + Pattern A2 L2763 nested SUM(SUM)-OVER worked example already teach
it). NO FIX-A.

**(2) Q3 — GROUP-BY-ALIAS broken illustrative query: classify as RESPONDER SLIP / sloppy-
illustrative-snippet watch (c), NOT a confirmed resource gap.** This is a **1st occurrence** of
GROUP-BY-alias misuse, and the core guidance (json_extract_scalar nested-path → varchar for
grouping) was CORRECT. The responder applied the same rule CORRECTLY in Q4 of the SAME iteration
(repeated the expression in GROUP BY), proving it holds the right pattern — this reads as
per-Q padding/slip, not a systematic misconception. **Grep-worthy but low expectation:** teacher
MAY grep `resources/` for any blessed `GROUP BY <alias>` snippet (json / nested-extract cards
especially); if one exists it is a resource defect to reconcile in place (repeat-the-expression
or `GROUP BY <ordinal>`, and never leave an ungrouped non-aggregate like `event_id` in the
SELECT alongside a GROUP BY). If resources already use repeat-expression/ordinal form everywhere,
this is a pure RESPONDER SLIP → per-instance MONITOR; re-probe nested-JSON-grouping next sweep,
escalate to a LIGHT findability nudge only if GROUP-BY-alias recurs (2-in-2).

**Net: DEFAULT NO-OP** (margin +0.609375; both KEY items are a softer completeness dodge (Q1) and
a 1st-occurrence responder slip on an otherwise-correct core (Q3); no source-verified resource
defect, no 2-in-2). NO resource edit; NO FIX-A; NO commit (orchestrator commits). MUST NOT bump
state.json (already 1039).
