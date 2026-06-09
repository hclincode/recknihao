# Judge Feedback — iter830 (DEFAULT NO-OP durability sweep; zero resource edits)

**Phase:** extended. **Verdict: PASS — overall avg 4.84.**
All four dialect claims verified against trino.io/docs/467 (PIN 467). No accuracy defects.

## Per-question scores

| Q | Topic | Acc | Compl | Clar | Action | Avg |
|---|---|---|---|---|---|---|
| Q1 | multi-column ORDER BY, mixed directions | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | format date as full month name 'June 2025' | 5 | 3.5 | 5 | 4 | 4.375 |
| Q3 | filter groups by aggregate count (HAVING) | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | concat 3 columns with comma separator | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = 4.84 → PASS** (overall average governs; no per-Q veto).

## Verification notes (trino.io/docs/467)

- **Q1** `ORDER BY account_cost DESC, ticket_created_at DESC` — CONFIRMED. Per-column ASC/DESC, evaluated left-to-right. Maps exactly to "most expensive accounts at top, newest tickets first within each account." Resource cross-ref (`ORDER BY order_count DESC, dow ASC`) reinforces the mixed-direction pattern. Clean.
- **Q2** `format_datetime(CAST(signup_date AS timestamp), 'MMMM yyyy')` — CONFIRMED. format_datetime uses JodaTime patterns; MMMM=full month name, MMM=abbreviated, MM=numeric month, lowercase mm=MINUTE (the gotcha — responder flagged it correctly). format_datetime requires a timestamp, so casting the DATE is right. date_format(ts,'%M %Y') is the valid MySQL-style alt (%M=full month name, %Y=4-digit year) — responder did not mention the alt but the chosen path is fully correct.
  - **COMPLETENESS DING (Q2 completeness 3.5):** The ask is "group signups BY MONTH," but the query does `GROUP BY signup_date` (the raw DATE) → one row per distinct DAY, not one row per month. The formatting EXPRESSION is correct (hence no accuracy defect), but the grouping granularity does not match the stated "by month" intent. Correct grouping would be `GROUP BY date_trunc('month', signup_date)` (then format that), or `GROUP BY 1` on the format_datetime label / `GROUP BY format_datetime(...)`. Also ORDER BY signup_date would order rows that aren't at month granularity. This is a routing/teaching gap, not a Trino-dialect error.
- **Q3** `HAVING COUNT(*) > 10` — CONFIRMED. WHERE filters rows pre-group; HAVING filters post-aggregation; HAVING references aggregates or GROUP BY columns (correct — the "cannot HAVING a raw ungrouped column" note is accurate). Runnable example valid 467: GROUP BY rep_id is a real input column; ORDER BY total_deals uses an alias, which Trino ORDER BY permits. Clean.
- **Q4** `concat_ws(', ', city, state, country)` — CONFIRMED. concat_ws skips NULL args (no doubled separator); NULL separator → NULL result. concat_ws does NOT skip empty strings — the `NULLIF(col,'')` caveat to also drop empties is accurate and valuable. The array+join contrast is correct (that path is for aggregating ROWS). Clean.

## Defect / gap flag

- **Q2 group-by-day-vs-by-month granularity** is the only blemish this sweep. It is a real (small) completeness gap that recurs whenever a "group by month, display as name" question lands on the format_datetime card without a co-located GROUP-BY-the-truncated/label canonical. The card teaches the FORMAT but not the GROUPING granularity.

## iter831 directive — FIX-A (light findability, Q2 month-grouping)

iter831 = **FIX-A** (a small completeness gap surfaced; not a NO-OP).

Targeted, in-place, no churn of the verified format_datetime canonical:
- At the format_datetime / date_format month-name card (resources/07 and/or resources/23 — wherever "month as full name" / "June 2025" keywords route), add a small GROUPING-GRANULARITY blockquote: when the ask is "group/aggregate BY month," group on `date_trunc('month', signup_date)` (or `GROUP BY 1` on the format label / `GROUP BY format_datetime(...)`), NOT on the raw DATE column (raw DATE → one row per distinct day). Provide a runnable canonical, e.g.:
  ```
  SELECT format_datetime(CAST(month AS timestamp), 'MMMM yyyy') AS month_label, COUNT(*) AS signups
  FROM (SELECT date_trunc('month', signup_date) AS month FROM signups) t
  GROUP BY month ORDER BY month;
  ```
  or the one-level form `GROUP BY date_trunc('month', signup_date)`.
- Inline-defang `GROUP BY signup_date` (raw DATE) on its own un-copyable line as "groups by DAY not MONTH" so the weak responder stops copying it for by-month asks.
- Keyword anchors: group by month, signups per month, monthly counts, group by month name, one row per month not per day, date_trunc month.
- Keep all pipe-bearing content in FENCED blocks (pipe-escape trap). PIN Trino 467. Verify date_trunc('month', date) returns a DATE (so the CAST-to-timestamp for format_datetime still applies).
- Preserve: full iter534–827 lock inventory; NO federation edits (r22 §13.x ZERO edits; federation row stays 4.49944/310).

## Locks reaffirmed (no edits this iter)

- bool_or/bool_and/every() all-NULL/empty → NULL (iter825/827 fix) intact.
- GROUP-BY-alias asymmetry card (§8) intact; GROUP BY accepts input col/expr/ordinal, NOT alias; ORDER BY accepts alias+ordinal.
- repeat()→array(E) + array_join canonical (iter823) intact.
- round-to-NEAREST-N-min canonical (iter814/815/818) intact.
- No state.json bump. No resource edits this iter (sweep clean except the Q2 granularity note → FIX-A next).
