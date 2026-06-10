# Judge Feedback — iter893 (EXTENDED PHASE)

**Overall: 4.86 / 5.00 — STRONG PASS** (per-Q 5.00 / 4.9375 / 4.8125 / 4.6875 = 19.4375 / 4 = 4.859; margin +1.36 over the 3.5 threshold; the OVERALL AVERAGE governs — no per-question override).

**Federation NOT probed this iter** — the Trino-federation row (4.49944 / 310, FAIL) is UNCHANGED.

**iter893 was a NO-OP durability sweep** — 4 fresh adjacent SQL-pattern probes. Three answers dialect-clean; ONE minor accuracy nit (Q4 ISO-week-1 rationale). All cores correct and actionable.

---

## Per-question scores

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | % of customers with >1 product category (COUNT(DISTINCT)+FILTER) | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |
| Q2 | single product nearest to $49.99 (ORDER BY abs(diff) LIMIT 1) | 5.0 | 4.75 | 5.0 | 5.0 | **4.9375** |
| Q3 | count occurrences of 'timeout' in text (length-diff trick) | 5.0 | 4.5 | 4.75 | 5.0 | **4.8125** |
| Q4 | group signups by calendar week-of-year (week_of_year/EXTRACT WEEK) | 4.25 | 4.75 | 4.75 | 5.0 | **4.6875** |

---

## Verification (all vs trino.io/docs/467, WebFetch/WebSearch 2026-06-10)

**Q1 — 5.00 — CORRECT.** `WITH customer_categories AS (SELECT customer_id, COUNT(DISTINCT product_category) AS n_categories FROM purchases GROUP BY customer_id) SELECT 100.0*COUNT(*) FILTER (WHERE n_categories>1)/COUNT(*) AS pct FROM customer_categories`.
- VERIFIED functions/aggregate.html: the `FILTER (WHERE <condition>)` clause "can be used to remove rows from aggregation processing with a condition" and "is supported for all aggregate functions" — so `COUNT(*) FILTER (WHERE n_categories>1)` is valid. Multiple `COUNT(DISTINCT ...)` in one query is supported in 467 (the inner per-customer `COUNT(DISTINCT product_category)` is one such).
- The `100.0*` prefix is a DECIMAL literal, so `100.0*COUNT(*) FILTER(...)/COUNT(*)` evaluates as DECIMAL division (non-integer) — correctly avoids integer-truncated 0. Two-stage CTE (per-customer category count → outer ratio of >1-category customers) is the idiomatic shape. No defect.

**Q2 — 4.9375 — CORRECT.** `SELECT product_id, product_name, target_price FROM products ORDER BY ABS(target_price - 49.99) LIMIT 1`.
- VERIFIED functions/math.html: `abs(x)` "Returns the absolute value of x". ORDER BY an arbitrary expression (`abs(a-b)`) is standard Trino/SQL — valid. Nearest-to-target = sort by absolute distance ascending + LIMIT 1; correct and minimal.
- Completeness nit (−0.25 Comp): on an exact tie (two products equidistant from 49.99) `LIMIT 1` returns an **arbitrary** one with no deterministic tiebreaker. A one-line note ("add `, product_id` to ORDER BY for a deterministic pick on ties") would make it bulletproof. Minor only — not an accuracy defect.

**Q3 — 4.8125 — CORRECT (core); cleaner built-in not mentioned.** `(LENGTH(description) - LENGTH(REPLACE(description,'timeout',''))) / LENGTH('timeout') AS timeout_count`; worked example 100→86, (100−86)/7 = 2.
- VERIFIED functions/string.html: `length(string)` "Returns the length of string in **characters**" (codepoints, not bytes); `replace(string, search, replace)` "Replaces all instances of search with replace". The arithmetic is sound: each removed non-overlapping `'timeout'` (7 chars) shrinks the string by exactly 7, so `(orig − stripped)/7` = occurrence count. Because `length()` counts CHARACTERS uniformly on both sides, the divide-by-`length('timeout')` is correct even if the text contains multibyte chars — the per-occurrence delta is in the SAME character unit as the divisor. Worked example correct.
- Completeness nit (−0.5 Comp, −0.25 Clar): a cleaner, more direct Trino 467 built-in exists and was NOT mentioned —
  - `cardinality(regexp_extract_all(description,'timeout'))`, or
  - `cardinality(split(description,'timeout')) - 1`.
  Per the iter893 run-prompt and the iter882 lesson, this is **at most a COMPLETENESS nit, NOT an accuracy defect** — the length-diff trick is genuinely correct and portable. Do NOT over-penalize and do NOT defang the responder's trick. (Caveat the responder also did not state: the length-diff trick counts NON-OVERLAPPING occurrences and is case-SENSITIVE — same as `replace`/`regexp_extract_all` defaults — so the two approaches agree.)

**Q4 — 4.6875 — CORE CORRECT; one MINOR ACCURACY NIT in the rationale.** `week_of_year(signup_date) AS week_number, COUNT(*) ... GROUP BY week_of_year(signup_date)`; alt `EXTRACT(WEEK FROM signup_date)`; "both ISO week 1-53; Trino week starts Monday (ISO-8601), **week 1 is the first week that contains a Monday**."
- VERIFIED functions/datetime.html: `week()` / `week_of_year()` "Returns the **ISO week** of the year from x. The value ranges from 1 to 53"; `EXTRACT(WEEK FROM x)` is equivalent to `week()`. The function choice, the `EXTRACT(WEEK ...)` equivalence, the 1–53 range, and "weeks start on Monday" are ALL CORRECT and actionable.
- **NIT (−0.75 Acc):** the boundary rationale "week 1 is the first week that contains a **Monday**" is an INACCURATE definition of ISO-8601 week 1. VERIFIED (WebSearch, Wikipedia ISO 8601 / ISO week date): ISO-8601 week 1 is "the week with the **first Thursday** of the Gregorian year in it" — equivalently the week **containing January 4**, equivalently the first week with the **majority (≥4) of its days in the new year**. It is NOT "the first week containing a Monday." (Counter-example: when Jan 1 falls on a Friday/Saturday/Sunday, the week containing that first Monday is still week 1 only if it also contains the first Thursday — otherwise the early-January days belong to week 52/53 of the PRIOR ISO year.) The SQL the engineer will run (`week_of_year` / `EXTRACT(WEEK)`) is correct and produces correct ISO weeks regardless of this explanatory slip — so this is weighed as a **minor accuracy nit on the rationale only**, not a query defect.

---

## NAMED GAP for a possible iter894 LIGHT FIX-A

**ONE findable-but-wrong explanatory claim (Q4 ISO-week-1 boundary):**
- Defect: a resource (or the responder's synthesis) frames ISO-8601 **week 1 as "the first week that contains a Monday."** Correct framing: **week 1 is the week containing the year's first Thursday (equivalently the week containing January 4 / the first week with ≥4 days in the new year); weeks start on Monday.**
- Scope check before any edit (iter882 lesson — verify-first, do NOT defect-mark correct content): if a `resources/` week-of-year card already states the Thursday/Jan-4 rule correctly, this is a RESPONDER SYNTHESIS SLIP, not a resource gap → NO edit (NO-OP). If a card carries the "first Monday" framing, that is the precise line to correct in place (reconcile, don't append) + a keyword anchor (ISO week 1 / week containing first Thursday / week containing Jan 4 / why is early January sometimes week 52/53).
- Either way: the `week_of_year` / `EXTRACT(WEEK FROM x)` SQL itself is correct — do NOT add a "wrong" card around the function, do NOT churn it, do NOT touch the Monday-week-start fact.

**No other gaps.** Q1/Q2/Q3 are dialect-clean (Q2 tie-determinism + Q3 `cardinality(regexp_extract_all/split)` are completeness micro-nits only — optional one-line anchors, skip if they churn a pin). Did NOT flag any doc-correct claim as a defect (Q3 length-diff trick is correct; verified vs trino.io/docs/467 first).

---

## Directive for iter894

- **Default = NO-OP.** Overall 4.86 STRONG PASS; all 4 cores correct and actionable.
- **OPTIONAL LIGHT FIX-A (Q4 only), gated on the scope check above:** correct any "ISO week 1 = first week containing a Monday" framing in `resources/` to the Thursday/Jan-4 rule IN PLACE; if no such card exists, it was a responder slip → NO-OP. Do NOT add a "wrong" card; do NOT touch `week_of_year`/`EXTRACT(WEEK)` SQL or the Monday-week-start fact.
- Do NOT add "wrong" cards for Q1/Q2/Q3.
- Do NOT touch any iter534–892 pin.
- **PIN Trino 467. NO federation edits. DO NOT bump training/state.json (already passed).**
