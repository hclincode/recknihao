# iter823 Judge Feedback — FIX-A re-probe (repeat-a-character) + 3 fresh probes

**Overall: 4.44 / 5 — PASS** (overall average governs; no per-Q veto)

All dialect claims verified against trino.io/docs/467 (PINNED 467; array.html, string.html, datetime.html, sql/select.html, GH#16533).

## Per-Q scores

| Q | Topic | Acc | Compl | Clar | Action | Avg |
|---|---|---|---|---|---|---|
| Q1 | repeat a char N times into a string (40-dash divider) | 5 | 5 | 5 | 5 | **5.00** |
| Q2 | per-day running/cumulative total (window over aggregate) | 5 | 5 | 5 | 5 | **5.00** |
| Q3 | extract email domain after `@` + group by domain | 2 | 3 | 4 | 2 | **2.75** |
| Q4 | add 90 days to a timestamp/date | 5 | 5 | 5 | 5 | **5.00** |

**Overall avg = (5.00 + 5.00 + 2.75 + 5.00) / 4 = 4.44 → PASS**

## Q1 — repeat-char fix LANDED. CLOSE the topic.

The iter822 Q3 2.00 defect (responder floundered, falsely claimed "Trino has no repeat()", showed broken `concat(repeat(...),repeat(...))`) is FIXED. The responder NOW:
- LEADS with `array_join(repeat('-', 40), '')` -> 40 dashes (the canonical at r23:606-631).
- Correctly states **repeat() returns an ARRAY, not a string** — the load-bearing rule.
- Gives the dynamic-width form `array_join(repeat('-', header_length), '')`.
- Explains WHY skipping array_join fails (prints as an array).

Verified per docs: `repeat(element, count) -> array(E)` ("Repeat element for count times"); `array_join(x, delimiter) -> varchar` ("Concatenates the elements of the given array using the delimiter"). `array_join(repeat('-',40),'')` = 40 dashes. CLEAN. **repeat-char-to-string is CLOSED.** The r23:606-631 sub-canonical and its keyword anchors (divider line / ASCII bar / progress bar / star rating / row of dashes / repeat()) routed the responder correctly.

## Q2 — clean. Window-over-aggregate confirmed valid.

`SUM(COUNT(*)) OVER (ORDER BY event_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` with `GROUP BY event_date` is valid Trino 467: window functions are logically evaluated AFTER GROUP BY/aggregation, so `SUM(COUNT(*))` (window over an aggregate) compiles and returns one row per group with a running total. ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW gives the cumulative frame. Correct "window functions return every input row unlike GROUP BY" note. Cited r07:2412-2437 (which shows the SUM(amount) OVER variant; the SUM(COUNT(*)) OVER nesting the responder produced is an equally-valid extension). No defect.

## Q4 — clean. Both forms verified.

`date_add('day', 90, session_start)` and `session_start + INTERVAL '90' DAY` both verified. `date_add(unit, value, timestamp)` returns the SAME TYPE as input (TIMESTAMP->TIMESTAMP, DATE->DATE) — confirmed at datetime.html. Correct, important note: **INTERVAL requires a string LITERAL; use date_add for a column/variable offset** (matches r07:2350-2391 leading canonical). Mar 1 + 90 days = May 30 traced correct (Mar31=+30, Apr30=+60, May30=+90). No defect.

## Q3 — DEFECT (findable-but-WRONG-construct). New gap for iter824.

`split_part(email, '@', 2)` is CORRECT and well-explained (1-indexed, field 2 = after the first `@`; verified at string.html: "Field indexes start with 1", out-of-range -> NULL). The `split_part`-vs-`substr(strpos)` framing (r23:411-427) is good.

BUT the runnable example SQL is BROKEN in Trino 467:

```sql
SELECT customer_id, email, split_part(email, '@', 2) AS domain
FROM signups GROUP BY domain ORDER BY COUNT(*) DESC
```

Two fatal problems:
1. **`GROUP BY domain` references a SELECT output ALIAS — Trino does NOT support this.** Confirmed: GH#16533 "Using alias in group by is not supported by Trino" (still the behavior in 467; ANSI-standard scoping — aliases are not visible to GROUP BY). The responder's routing asserted "GROUP BY by output alias/ordinal is allowed" — **the ORDINAL is allowed (`GROUP BY 3`), the ALIAS is NOT.** Must be `GROUP BY split_part(email, '@', 2)` or `GROUP BY 3`.
2. **`customer_id, email` are selected alongside a domain GROUP BY** with neither aggregation nor membership in GROUP BY — internally inconsistent; would error even if alias-grouping worked. A "group signups by domain" query should be `SELECT split_part(email,'@',2) AS domain, COUNT(*) AS signups FROM signups GROUP BY 1 ORDER BY signups DESC`.

Net: an engineer who copies this gets a query-analysis error. The function answer is right; the surrounding GROUP BY scaffold is wrong. Accuracy 2 / Actionability 2.

## iter824 directive — FIX-A (a defect surfaced; NOT a no-op)

Target the **GROUP BY-output-alias misconception** + the **email-domain grouping example**:

1. At r23:411-427 (the split_part card), add a corrected, runnable grouping example:
   `SELECT split_part(email, '@', 2) AS domain, COUNT(*) AS signups FROM signups GROUP BY 1 ORDER BY signups DESC` — group by the **ordinal** (`GROUP BY 1`) or the **repeated expression**, NOT the alias; and select ONLY the grouped expression + aggregates.
2. Add an inline DO-NOT-WRITE defang (own line, un-copyable): `-- GROUP BY domain (a SELECT alias) -- Trino does NOT allow GROUP BY on an output ALIAS (GH#16533); use GROUP BY 1 or repeat the expression -- DO NOT COPY`.
3. Add a short rule card (findable from keywords: *GROUP BY alias, group by output column, group by the aliased expression, group by 1, can I use an alias in GROUP BY Trino*): **Trino GROUP BY accepts input columns, expressions, or an ORDINAL (`GROUP BY 1`) — but NOT a SELECT alias.** Place it where the responder routes for "group by the domain / group by a derived column". Likely near the existing GROUP BY / aggregation guidance in r07 or r23; cross-link from the split_part card.
4. Do NOT churn the verified split_part SQL or the verified r07 window/date_add canonicals.

NO federation edits (r22 13.x untouched; federation 4.49944/310 holds).

iter824 = **FIX-A** (GROUP BY-alias construct defect).
