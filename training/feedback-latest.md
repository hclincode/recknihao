# Iter 937 Feedback — RE-PROBE sweep (teacher ZERO edits)

**Overall**: 4.9375 STRONG PASS (Q1 5.00 / Q2 4.875 / Q3 5.00 / Q4 4.875 = 19.75/4 = 4.9375; margin +1.4375 over 3.5 threshold; OVERALL AVERAGE governs, no per-Q veto).

**Federation NOT probed** (4.49944/310 row UNCHANGED).

All dialect claims verified vs trino.io/docs/467 (functions/aggregate.html, functions/datetime.html, sql/select.html, language/types.html) + standing pin inventory + WebFetch 2026-06-10 — NOT against resources/; iter882 verify-first applied BOTH directions.

---

## Q1 RE-PROBE VERDICT — iter936 framing slip is ONE-OFF / CLOSED

**5.00 CLEAN** — Acc 5 / Comp 5 / Clar 5 / Act 5.

Responder LED CLEANLY with the canonical first-and-last-per-group idiom:
`SELECT product_id, MIN(sold_at) AS first_sold, MAX(sold_at) AS most_recently_sold FROM sales GROUP BY product_id`.

**NO invalid window-fn-in-GROUP-BY draft anywhere** — no first_value()/last_value() OVER (...) placed inside GROUP BY, no "verbose but valid" mischaracterization. The iter936 Q2 framing slip (window expressions inside GROUP BY framed as merely "more verbose than necessary" when Trino 467 actually rejects it with "GROUP BY clause cannot contain aggregations, window functions or grouping operations") **did NOT recur**.

Dialect verified:
- MIN/MAX work on date/timestamp values (aggregate.html — no type restriction listed, generalized "minimum/maximum of all input values"); MIN(sold_at)/MAX(sold_at) on a TIMESTAMP/DATE column is valid 467.
- Multiple aggregates in one SELECT with GROUP BY is standard SQL and supported (aggregate.html examples).
- The "one pass" observation (MIN/MAX don't need redistribution like COUNT(DISTINCT)) is accurate — both aggregates compute side-by-side per group with no extra shuffle.

**VERDICT**: iter936 Q2 window-fn-in-GROUP-BY framing slip = **ONE-OFF CONFIRMED / CLOSED**. NO iter938 LIGHT FIX-A. Re-probe this angle again ONLY if a 2nd instance surfaces.

---

## Q2 — Whole-next-calendar-month half-open range

**4.875** — Acc 5 / Comp 4.5 / Clar 5 / Act 5.

`SELECT COUNT(*) FROM subscriptions WHERE renewal_date >= date_trunc('month', current_date) + INTERVAL '1' MONTH AND renewal_date < date_trunc('month', current_date) + INTERVAL '2' MONTH` — CORRECT.

Dialect verified:
- `date_trunc('month', current_date)` returns DATE (date_trunc returns "same as input" per datetime.html; current_date is DATE).
- DATE + INTERVAL '1' MONTH returns DATE (datetime.html operators table: `date '2012-08-08' + interval '2' day` → `2012-08-10`; same shape for MONTH).
- MONTH is a valid INTERVAL qualifier (types.html: year-to-month interval example `INTERVAL '3' MONTH`); pinned 6-qualifier list YEAR/MONTH/DAY/HOUR/MINUTE/SECOND respected.
- NO accidental `INTERVAL '1' QUARTER` or `'1' WEEK` (iter933 ADD-A-QUARTER/ADD-A-WEEK card respected — responder used MONTH).
- Half-open [next-month-start, month-after-start) correctly captures the WHOLE calendar month regardless of which day current_date falls on; bare-column renewal_date on the left keeps partition-prunability.
- CROSS JOIN single-row month_range CTE variant is valid 467 (CROSS JOIN supported; single-row CTE is just a SELECT with no FROM or VALUES).
- DATE/TIMESTAMP comparison: if renewal_date is TIMESTAMP, the right side is a DATE expression; date < timestamp coerces (date promotes to timestamp). If renewal_date is DATE, both sides DATE — direct comparison. Either way runs cleanly.

Tiny -0.5 Comp: didn't explicitly call out the renewal_date type (date vs timestamp) coercion choice, but it's a completeness nuance, not a defect — the query runs in both shapes.

---

## Q3 — WHERE-then-group vs group-then-HAVING

**5.00 CLEAN** — Acc 5 / Comp 5 / Clar 5 / Act 5.

`SELECT customer_id, SUM(order_total) AS total_spending FROM orders GROUP BY customer_id HAVING SUM(order_total) > 500` — CORRECT.

Dialect verified:
- WHERE filters rows BEFORE GROUP BY (select.html: "HAVING filters groups after groups and aggregates are computed" implicitly establishes WHERE runs earlier in the pipeline).
- HAVING filters groups AFTER aggregation (select.html verbatim above).
- HAVING cannot reference SELECT output alias `total_spending` in Trino 467 — must REPEAT the `SUM(order_total)` aggregate (pinned; standing rule). Responder correctly repeated `SUM(order_total)` rather than writing `HAVING total_spending > 500`. **This is the load-bearing dialect correctness here, and responder nailed it.**
- "Customer total spend > $500" is fundamentally a GROUP-then-FILTER question (the predicate is on the AGGREGATE), so HAVING is the right answer; responder framed it correctly.
- WHERE+HAVING combo variant `WHERE order_date >= current_date - INTERVAL '90' DAY ... HAVING SUM(order_total) > 500` valid: DAY is a valid INTERVAL qualifier (pinned 6-list), current_date − INTERVAL valid (datetime.html operators table), WHERE pre-filters rows before grouping for efficiency, HAVING post-filters groups.
- Pedagogy correct: WHERE = row-level (pre-grouping) filter, HAVING = group-level (post-aggregation) filter.

---

## Q4 — Successful vs failed counts in one query

**4.875** — Acc 5 / Comp 4.5 / Clar 5 / Act 5.

`SELECT COUNT(*) FILTER (WHERE status='success') AS successful_count, COUNT(*) FILTER (WHERE status='failed') AS failed_count, COUNT(*) AS total_count FROM transactions` — CORRECT.

Dialect verified:
- `COUNT(*) FILTER (WHERE ...)` valid 467 — aggregate.html verbatim: "The FILTER keyword can be used to remove rows from aggregation processing with a condition expressed using a WHERE clause. This is evaluated for each row before it is used in the aggregation and is **supported for all aggregate functions**." Includes COUNT(*).
- Multiple FILTER aggregates in one SELECT is valid (each aggregate independently receives its own filter; no parser/analyzer restriction).
- `SUM(CASE WHEN status='success' THEN 1 ELSE 0 END)` alt is the pre-SQL:2003 equivalent and valid; both forms compile to the same logical conditional-aggregation.
- "FILTER more idiomatic" is reasonable Trino guidance (clearer intent, no integer-arithmetic round-trip).
- Bare aggregate with no GROUP BY collapses to one scalar row (pinned) — three aggregates on one row, exactly the "one query" the user asked for.

Tiny -0.5 Comp: could have mentioned `count_if(status='success')` (also valid 467) as a third syntactic option to round out the family, but FILTER + SUM(CASE) is the canonical pair and fully answers the question. Not a defect.

---

## Scope summary

- **NO RESOURCE DEFECT** — every taught canonical (MIN/MAX-per-group, date_trunc+INTERVAL half-open month range, WHERE/HAVING split with aggregate-repeated-in-HAVING, COUNT FILTER) applied cleanly.
- **NO RESPONDER SLIP on taught content** — Q1 specifically re-probed iter936's window-fn-in-GROUP-BY framing slip; responder led with the clean MIN/MAX form and offered NO invalid draft.
- **NO FINDABLE GAP** — all four answers dialect-clean; the small Comp nuances on Q2 (renewal_date type unspecified) and Q4 (count_if alt unmentioned) are completeness rounding, not missing cards.

## Pinned facts (carried forward, NO new pins this iter)

MIN/MAX per group via GROUP BY (work on date/timestamp); multiple aggregates in one SELECT valid; window functions CANNOT appear in GROUP BY (semantic error); HAVING cannot reference SELECT alias (must repeat aggregate); WHERE before GROUP BY (row filter), HAVING after (group filter); INTERVAL qualifiers = YEAR/MONTH/DAY/HOUR/MINUTE/SECOND only (MONTH + DAY valid here; QUARTER/WEEK NOT interval quals but ARE date_add/diff/trunc UNIT strings — iter933 card); date_trunc('month', date) returns date; date + INTERVAL YEAR TO MONTH → date; DATE/TIMESTAMP comparison coerces; FILTER(WHERE) valid for all aggregates; count_if valid; SUM(CASE) equivalent; CROSS JOIN single-row CTE valid; 100.0 decimal-promo; no QUALIFY in 467; bare aggregate w/o GROUP BY = one scalar row; CURRENT_DATE built-in.

## Directive for iter938

**DEFAULT NO-OP / durability-breadth.**

- Q1 iter936 window-fn-in-GROUP-BY framing slip = ONE-OFF CONFIRMED / CLOSED — do NOT add a router/FIX-A card. Re-probe this angle again ONLY if a 2nd instance surfaces (the resources already teach BOTH the rule and the canonical MIN/MAX answer).
- Q2/Q3/Q4 dialect-clean; the tiny Comp nuances (date/timestamp-type guidance on next-month range; count_if mention) are NOT findable gaps and would risk New-Card-Over-Attracts-Adjacent regression to add.
- Optional low-priority adjacents (SKIP if duplicative): first-AND-last per group with NULLs in the timestamp; whole-PREVIOUS-month range (− INTERVAL '1' MONTH variant); WHERE+HAVING+ORDER BY ordering on the customer-spend Q; FILTER with three+ status buckets in one SELECT (success/failed/pending).
- CONSIDER federation (thinnest passing row 4.49944/310, long un-retested — bulletproofed angles only, per standing constraint resources/22 §13.x is HARD-LOCKED).
- PRESERVE full iter534-936 pin inventory; NO federation edits.
- PIN 467. DO NOT bump training/state.json (orchestrator owns that; iter937 PASS at 4.9375 holds, passed=true preserved).
