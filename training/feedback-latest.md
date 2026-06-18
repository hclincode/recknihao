# Judge Feedback — iter1081 (2026-06-18)

**Overall average: 4.69 — PASS** (margin +1.19 over 3.5 threshold)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions against RAW git-tag 467 source (dispositive over rendered HTML):
- functions/datetime.md — quarter / week / week_of_year / EXTRACT
- functions/array.md — array_sort 1-arg + 2-arg comparator (verbatim example pulled)
- functions/conversion.md — try_cast

## Per-question scores

### Q1 — group by calendar quarter (quarter() + EXTRACT(YEAR)) — 5.00
`SELECT EXTRACT(YEAR FROM created_at) AS year, quarter(created_at) AS quarter, COUNT(*) FROM events GROUP BY EXTRACT(YEAR FROM created_at), quarter(created_at) ORDER BY year, quarter;`
- Accuracy 5: datetime.md VERIFIED `quarter(x) -> bigint` "Returns the quarter of the year from x. The value ranges from 1 to 4"; EXTRACT supports YEAR (→year()) and QUARTER (→quarter()). GROUP-BY repeats the expressions (not the SELECT alias) per the Trino #16533 GROUP-BY-alias asymmetry — correct.
- Completeness 5: pairs year+quarter so Q1s across years are not lumped — exactly the trending need. date_trunc('quarter', created_at) is a valid alternative (single column, keeps a real date) but not required.
- Clarity 5 / Actionability 5: copy-paste ready, Q1=months 1-3 explained.

### Q2 — sort an array of strings — 4.13
`SELECT id, array_sort(tags) AS sorted_tags FROM orders;` (ascending)
Descending: `array_sort(tags, (a, b) -> IF(a > b, -1, 1))`
- Accuracy 3.5: ascending form fully correct — array.md VERIFIED `array_sort(x) -> array` "Sorts and returns the array x... Null elements will be placed at the end." BUT the descending COMPARATOR is a source-verified contract deviation. The 467 doc states the comparator "returns -1, 0, or 1 as the first nullable element is less than, **equal to**, or greater than the second" and its own verbatim example uses `WHEN x = y THEN 0`. The responder's `IF(a > b, -1, 1)` returns **1 for equal elements** instead of 0. It will NOT raise an error (1 is a legal value; only values outside {-1,0,1}/NULL fail), and on distinct strings the visible result is correct — but on arrays with duplicate tags it is an inconsistent/non-transitive comparator (declares equal pairs as "greater"). Canonical: `(a, b) -> CASE WHEN a > b THEN -1 WHEN a = b THEN 0 ELSE 1 END`, or simply `reverse(array_sort(tags))`.
- Completeness 4 / Clarity 4.5 / Actionability 4.5: "stays an array, no unnest/reassemble" correct and useful; the descending idiom mostly works but is not the documented contract-clean form.

### Q3 — safe varchar→decimal tolerating 'N/A'/empty — 4.88
`SELECT product_id, TRY_CAST(price AS DECIMAL(10, 2)) AS price_numeric FROM products;`
- Accuracy 5: conversion.md VERIFIED `try_cast(value AS type)` "Like cast, but returns null if the cast fails." 'N/A'→NULL, ''→NULL; CAST would throw. Exactly right.
- Completeness 5 / Clarity 5 / Actionability 4.5: contrast with CAST + downstream NULL-handling note is the right defensive guidance. DECIMAL(10,2) precision is a reasonable default (could note picking precision to fit the data).

### Q4 — extract ISO week to GROUP BY weekly — 4.75
`SELECT EXTRACT(YEAR FROM opened_at) AS year, week_of_year(opened_at) AS week_number, COUNT(*) FROM tickets GROUP BY EXTRACT(YEAR FROM opened_at), week_of_year(opened_at) ORDER BY year, week_number;`
- Accuracy 5: datetime.md VERIFIED `week_of_year` is an alias for `week`; `week(x) -> bigint` "Returns the ISO week of the year from x. The value ranges from 1 to 53" — ISO-8601, Monday start. The "week 1 = first week with 4+ days, Monday start" description is the correct ISO definition. GROUP-BY repeats expressions correctly.
- Completeness 4.5: MINOR EDGE CAVEAT (not a correctness defect) — pairing `EXTRACT(YEAR FROM opened_at)` (calendar year) with the ISO week can mis-bucket year-boundary dates: e.g. 2024-12-30 is ISO week 1 of ISO-year **2025**, but EXTRACT(YEAR)=2024, so it buckets as 2024/wk1 alongside early-Jan-2024. For most trending this is acceptable; to be ISO-exact the year companion should be the ISO week-year (no direct iso_year() built-in in 467 — derive it, or accept the rare boundary skew). The week_of_year=ISO-week fact is correct and the calendar-year pairing is the common practical approach.
- Clarity 5 / Actionability 4.5: clear, runnable.

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5.0 | 5.0 | 5.0 | 5.0 | 5.00 |
| Q2 | 3.5 | 4.0 | 4.5 | 4.5 | 4.13 |
| Q3 | 5.0 | 5.0 | 5.0 | 4.5 | 4.88 |
| Q4 | 5.0 | 4.5 | 5.0 | 4.5 | 4.75 |

Overall average = (5.00 + 4.13 + 4.88 + 4.75) / 4 = **4.69 PASS** (threshold 3.5).

## Source-verified notes
- quarter() = 1-4, EXTRACT YEAR/QUARTER supported — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/datetime.md
- week()/week_of_year() = ISO-8601 week 1-53, Monday start, week_of_year alias of week — same source
- array_sort(x) ascending nulls-last; array_sort(array(T), function(T,T,int)) comparator MUST return -1/0/1 with **0 for equal**; verbatim 467 example uses `WHEN x = y THEN 0` — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md
- try_cast returns NULL on failed cast vs CAST throws — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/conversion.md

## Recommendation
PASS (margin +1.19). One source-verified minor defect: Q2 descending comparator `IF(a>b,-1,1)` returns 1 for equal elements instead of the documented 0 — does not error and is visually correct on distinct strings, but is a non-transitive comparator on arrays with duplicates and deviates from the 467 contract. This is the "broken secondary alternative" responder family (the PRIMARY ascending answer is fully correct) — scope as a per-instance slip, NOT a resource defect. Worth a re-probe of array-sort-descending from a 2nd angle to see whether the responder produces the contract-clean `CASE ... WHEN a=b THEN 0` form or `reverse(array_sort(...))`. Do NOT churn resources on one slip. MUST NOT bump state.json (already 1081).
