# Judge Feedback — iter1013

**OVERALL: 4.625 (74.0/16) — PASS** (threshold 3.5; margin +1.125; OVERALL AVERAGE governs, no per-Q veto)

Verified BOTH directions vs trino.io/docs/467 (functions/datetime.html, math.html, aggregate.html, sql/select.html) + RAW git-tag 467 source (MathFunctions roundLong = RoundingMode.HALF_UP) + Joda-Time DateTimeFormat (E text-field rule) + WebSearch (GROUP-BY/ORDER-BY "must be an aggregate expression or appear in GROUP BY clause"). NOT resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark + dbt) — all 4 fit; no federation/auth angle.

---

## Q1 — first session's channel (MIN gave alphabetical) — 4.75 CLEAN
`FIRST_VALUE(channel) OVER (PARTITION BY user_id ORDER BY session_time ASC)` + `SELECT DISTINCT`, alt `min_by(channel, session_time) GROUP BY user_id`. Critique correct.
- VERIFIED `min_by(x, y)` = "the value of x associated with the minimum value of y" (aggregate.html) → returns the channel at the earliest session_time. CORRECT.
- VERIFIED `MIN(channel)` returns the alphabetically smallest channel string, NOT the value at the earliest timestamp — responder's critique is exactly right.
- FIRST_VALUE with default frame (RANGE UNBOUNDED PRECEDING → CURRENT ROW) returns the first row's value within the ordered partition → earliest-session channel; correct. FIRST_VALUE is safe under the default frame (LAST_VALUE is the documented trap, not in play here). DISTINCT to collapse is correct.
- **Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75**

## Q2 — round int cents to 2dp dollars — 4.6875 CLEAN
`ROUND(total_cents/100.0, 2)`; ROUND(x,n) HALF_UP (away from zero); examples ROUND(49.555,2)=49.56, ROUND(49.545,2)=49.55; cast money to DECIMAL(18,2).
- VERIFIED round(x, d) exists (math.html). VERIFIED HALF_UP / round-half-away-from-zero via git-tag MathFunctions source (RoundingMode.HALF_UP).
- Examples consistent: `49.555`/`49.545` are exact DECIMAL literals in Trino (not float), so HALF_UP gives 49.56 and 49.55 respectively — both correct as stated.
- `/100.0` makes the operand DECIMAL (not integer division) → correct dollar value; DECIMAL(18,2) recommendation for money is sound (avoids float drift). Good practical guidance.
- **Acc 5 / Comp 4.5 / Clar 4.75 / App 4.5**

## Q3 — IDs in BOTH lists without a JOIN — 4.71875 CLEAN
`SELECT customer_id FROM customer_ids INTERSECT SELECT customer_id FROM paying_customers`; defaults DISTINCT, INTERSECT ALL keeps dups, NULL-safe, implemented as semi-join; alt INNER JOIN + DISTINCT.
- VERIFIED INTERSECT and INTERSECT ALL both exist in 467 (select.html: "INTERSECT returns only the rows that are in the result sets of both"; "If neither is specified, the behavior defaults to DISTINCT").
- NULL-safe claim correct: set ops compare by distinctness (NULL not distinct from NULL → matched) — no NOT-IN 3VL trap.
- Semi-join implementation note matches r23 L1714 lock. INNER JOIN + DISTINCT alt is a valid equivalent.
- **Acc 5 / Comp 4.75 / Clar 4.625 / App 4.5**

## Q4 — weekday NAME label from timestamp — 4.34375 (BROKEN-SECONDARY DEFECT in appended aggregation example)

**PRIMARY answer CORRECT:**
- VERIFIED no `dayname()` in Trino 467 (datetime.html lists none).
- VERIFIED `format_datetime(ts, 'EEEE')` → full weekday name ('Monday'); Joda-Time DateTimeFormat: text field 'E', "4 or more pattern letters → full form", 3 → abbreviated → `'EEE'`='Mon'. Correct.
- VERIFIED `day_of_week(x)` returns ISO 1 (Monday) .. 7 (Sunday). Correct as a sortable number.
- DATE→TIMESTAMP implicit coercion / CAST is fine.

**SECONDARY (appended aggregation example) — DEFECT, broken-secondary pattern:**
```
SELECT format_datetime(CAST(created_at AS timestamp),'EEEE') AS day_of_week, COUNT(*)
FROM events
GROUP BY format_datetime(CAST(created_at AS timestamp),'EEEE')
ORDER BY day_of_week(created_at)          -- INVALID
```
`ORDER BY day_of_week(created_at)` references the RAW, ungrouped `created_at` column — it is neither a grouping expression (only `format_datetime(...,'EEEE')` is grouped) nor wrapped in an aggregate. Trino 467 REJECTS this in a grouped query with an error of the form **"'created_at' must be an aggregate expression or appear in GROUP BY clause"** (confirmed via Trino GROUP-BY/ORDER-BY semantics; same error family as trinodb/trino #16984). This is a genuine analysis error, not a stylistic nit.

CORRECT FIXES (any one):
- `ORDER BY min(day_of_week(created_at))` — wrap in an aggregate; or
- `GROUP BY format_datetime(CAST(created_at AS timestamp),'EEEE'), day_of_week(created_at) ORDER BY day_of_week(created_at)` — also group the sort key (cleaner: pre-compute `day_of_week` in a CTE alongside the name, group by both); or
- compute `day_of_week(created_at)` as a selected column in a subquery/CTE and ORDER BY that.

Textbook broken-secondary pattern: responder nails the LEAD (weekday-name label) and appends a "for completeness" aggregation example with an invalid sort. The primary deliverable the user asked for ('Monday' label) is fully correct.
- **Acc 4.0 / Comp 4.25 / Clar 4.5 / App 4.625**

---

## Sub-score grid
| Q | Acc | Comp | Clar | App |
|---|---|---|---|---|
| Q1 | 5 | 4.75 | 4.75 | 4.75 |
| Q2 | 5 | 4.5 | 4.75 | 4.5 |
| Q3 | 5 | 4.75 | 4.625 | 4.5 |
| Q4 | 4.0 | 4.25 | 4.5 | 4.625 |

Sum = 74.0 / 16 = **4.625 → PASS**

`::` cast shorthand ABSENT all 4 (ban holds). No QUALIFY / false-semi-join / MAX-varchar / GREATEST-LEAST-NULL / fabricated-fn (min_by, ROUND, INTERSECT/ALL, format_datetime, day_of_week ALL real & verified) / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT. ONE active TIC: Q4 broken-secondary ORDER-BY-ungrouped-column.

## RECOMMENDATION — DEFAULT NO-OP
Margin +1.125; 3/4 clean; Q4 PRIMARY (the actual ask) correct. The Q4 ORDER-BY-ungrouped defect is in an APPENDED "for completeness" aggregation example — a textbook **broken-secondary one-off**, NOT a findable resource gap (the question is "weekday NAME label," which the primary answers correctly). Matches the established broken-secondary family (iter936/943/948/950/954) where the lead passes and Haiku pads with a flawed alternative. No single resource fix addresses responder padding. NO resource edit; NO FIX-A.

Re-probe next sweep:
- (a) another first/earliest-event-attribute Q — confirm FIRST_VALUE default-frame + min_by; watch LAST_VALUE default-frame trap (the actual landmine, not exercised here).
- (b) another money/round Q — ROUND HALF_UP + DECIMAL(p,s) for money.
- (c) another set-membership/intersection Q — INTERSECT default-DISTINCT + INTERSECT ALL + semi-join.
- (d) another weekday/temporal-label Q — format_datetime EEEE full / EEE short + day_of_week ISO; **watch whether the GROUP-BY + ORDER-BY-by-ungrouped-derived-key secondary recurs.** If `ORDER BY <fn>(ungrouped_col)` in a grouped query appears a SECOND consecutive time (2-in-2), grep resources for grouped-ORDER-BY guidance and consider a LIGHT findability nudge (pin "ORDER BY in a GROUP BY query must reference a grouping expression or an aggregate; wrap derived sort keys in min()/group them too"). Until then, monitor only — do not churn.

Federation r22 §13.x hard-locked, NOT probed (stays 4.49944/310). MUST NOT bump state.json (already 1013; orchestrator commits).
