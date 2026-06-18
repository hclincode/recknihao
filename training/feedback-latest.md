# Judge Feedback — iter1041

Verified BOTH directions against RAW git-tag 467 source (datetime.md, array.md, map.md) + WebSearch (trino.io SQL-standard special-form note), NOT resources/. Production stack (Trino 467 + Iceberg + Hive Metastore on-prem k8s/MinIO) consistent with all advice. No federation probe.

## Per-question scores

### Q1 — cumulative signups week-over-week from RAW one-row-per-signup table — **4.8125**
Acc 5.0 / Comp 4.75 / Clar 4.75 / App 4.75

**THE KEY ITEM — FIX-A CONFIRMED, invalid form did NOT recur.** The answer pre-aggregates correctly:
```
WITH weekly_signups AS (
  SELECT DATE_TRUNC('week', created_at) AS signup_week, COUNT(*) AS new_signups
  FROM signups GROUP BY DATE_TRUNC('week', created_at))
SELECT signup_week, new_signups,
  SUM(new_signups) OVER (ORDER BY signup_week ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_signups
FROM weekly_signups ORDER BY signup_week;
```
- The CTE collapses the raw one-row-per-signup table to ONE ROW PER WEEK (`DATE_TRUNC('week', created_at)` + `COUNT(*)` + `GROUP BY DATE_TRUNC('week', created_at)` — GROUP BY repeats the expr, NOT the alias, so no #16533 alias-in-GROUP-BY error).
- The OUTER query applies `SUM(new_signups) OVER (...)` on the **already-aggregated** CTE result. `new_signups` is a real materialized column of `weekly_signups`, NOT a raw per-row column inside a GROUP BY. There is therefore **NO bare-SUM-OVER-beside-GROUP-BY error** — the exact invalid shape that scored 3.5 in iter1038 (Q2) and 3.5 in iter1040 (Q1) is **ABSENT**. This is the correct pre-aggregate-CTE-then-window pattern.
- `DATE_TRUNC('week', ...)` truncates to ISO Monday-start (Trino ISO day-of-week 1=Mon..7=Sun convention; datetime.md). `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` is the correct inclusive running-total frame (each week = its own new signups + all earlier weeks).
- `ORDER BY signup_week` at the outer level gives a clean chronological cumulative series.
Minor: complete and directly runnable on the engineer's raw table. **2-in-2 relapse did NOT recur** — the iter1040 FIX-A reached the responder.

### Q2 — sum an array of prices into an order total per row, no joins — **4.8125**
Acc 5.0 / Comp 4.75 / Clar 4.75 / App 4.75
`reduce(line_items, 0, (sum, price) -> sum + price, sum -> sum)` — VERIFIED canonical. RAW array.md 467: signature `reduce(array(T), initialState S, inputFunction(S,T,S), outputFunction(S,R)) -> R` — the answer's 4-arg form with identity output lambda `sum -> sum` matches EXACTLY. **array_sum does NOT exist in 467** (absent from array.md function index), so reduce is the canonical answer, not a workaround. One row in / one row out, no joins, no UNNEST — exactly as asked. Sound.

### Q3 — count DISTINCT keys across all rows of a MAP(varchar,varchar) — **4.8125**
Acc 5.0 / Comp 4.75 / Clar 4.75 / App 4.75
`SELECT COUNT(DISTINCT key) FROM events CROSS JOIN UNNEST(map_keys(properties)) AS t(key)` — VERIFIED. RAW map.md 467: `map_keys(x(K,V)) -> array(K)` returns all keys as an array. CROSS JOIN UNNEST(array) AS t(key) flattens keys to rows, COUNT(DISTINCT key) gives the distinct-key count across all rows. Valid and idiomatic. The `SELECT DISTINCT key ... ORDER BY key` listing variant is a sound complementary offer (shows WHICH keys), not a broken secondary. Sound.

### Q4 — current_timestamp vs now(): different or not? which to use? — **4.78125**
Acc 4.875 / Comp 4.75 / Clar 4.75 / App 4.75
Sub-claims verified against RAW datetime.md 467 + WebSearch:
- **(a) current_timestamp and now() both return timestamp(3) with time zone, equal at query start — TRUE.** datetime.md: current_timestamp "Returns the current timestamp with time zone as of the start of the query, with 3 digits of subsecond precision"; now() "This is an alias for current_timestamp."
- **(b) current_timestamp usable WITHOUT parentheses as a SQL-standard special form — TRUE.** datetime.md note: "The following SQL-standard functions do not use parenthesis: current_date, current_time, current_timestamp, localtime, localtimestamp."
- **(c) current_timestamp() with EMPTY parentheses is a PARSE ERROR — TRUE.** current_timestamp is a SQL-standard special syntactic form, not a regular function; empty parens are not accepted (corroborated by the documented "do not add parentheses" guidance and the special-form grammar — an empty-paren call is invalid).
- **(d) current_timestamp(p) precision overload exists, returns timestamp(p) with time zone — TRUE.** datetime.md has a separate `current_timestamp(p)` entry returning "current timestamp with time zone as of the start of the query, with p digits of subsecond precision."
- **(e) now() is the alias and is written WITH parens — TRUE.** now() is documented as "an alias for current_timestamp" and, being a regular function, is invoked as `now()`. The answer's framing "now() is the parenthesized alias" is accurate.
Tiny clarity nuance only: the contrast (special-form `current_timestamp` no-paren / overload `current_timestamp(p)` / function `now()`) is correctly drawn. Functionally identical, either is fine. Sound.

## Tics scan
`::` absent all 4. No QUALIFY, no false semi-join, no fabricated function, no regex-backslash, no INTERVAL quarter/week, no OFFSET-before-LIMIT, no over-warning folklore, no broken-secondary padding. The Q3 second offering is complementary not broken. The iter1038/iter1040 bare-SUM-OVER-in-GROUP-BY shape did NOT recur on Q1.

## Overall
(4.8125 + 4.8125 + 4.8125 + 4.78125) / 4 = **4.8046875 PASS** (margin +1.3047 over 3.5).

## Recommendation — DEFAULT NO-OP; Q1 watch DOWNGRADE to monitor (FIX-A confirmed)
**Q1 FIX-A confirmation:** The iter1040 hoisted running-total guard at r07 ~L2576 (the prominent inline "MANY rows per grouping key? do NOT write SUM(x) OVER beside GROUP BY — INVALID" callout, with the pre-aggregate-CTE form and nested SUM(SUM) form + forward-links) **reached the responder.** Q1 used the CTE pre-aggregate form (`DATE_TRUNC('week') + COUNT(*) GROUP BY` in the CTE, then `SUM(new_signups) OVER` on the aggregated result) and the dangerous bare-SUM-OVER-in-GROUP-BY shape did **NOT** recur — first clean running-total LEAD on the raw-table-many-rows surface since the iter1038/1040 relapses. **Recommend downgrading watch (q) to passive monitor: FIX-A confirmed.** No resource edit, no new FIX-A, no commit. Re-probe the running-total surface once more next sweep from a different grain (e.g. monthly revenue from a raw orders table) to confirm durability before fully retiring the watch. MUST NOT bump state.json (already 1041; orchestrator commits).
