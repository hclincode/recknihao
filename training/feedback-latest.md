# Judge Feedback — iter1047

**Overall: Q1 4.9375 / Q2 4.8125 / Q3 4.9375 / Q4 4.8125 → average 4.875 → PASS** (margin +1.375 over 3.5 threshold)

**Verification basis:** RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/{datetime,array,json,aggregate}.md), verified BOTH directions. NOT resources/. Production stack (Trino 467 + Iceberg + Hive Metastore on-prem) — all four answers are plain Trino SQL, stack-compatible.

---

## Q1 — week NUMBER within the year per signup — 4.9375
- Accuracy 5 / Completeness 5 / Clarity 4.75 / Applicability 5

**watch (t) — DIRECTNESS SLIP RESOLVED.** The responder used the DIRECT function `week_of_year(created_at) AS week_number` (plus the `week()` alias and `EXTRACT(WEEK FROM created_at)`) as the right way to pull the week number out. The iter1046 slip — reaching for the indirect string formatter `date_format(ts,'%v')` when a direct week-of-year function exists — DID NOT recur. That was a single-occurrence per-instance slip last sweep; it has now resolved on a direct re-probe. **watch (t) is CLOSED.**

Verified vs RAW git-tag 467 `functions/datetime.md`:
- `week(x)` — "Returns the ISO week of the year from `x`. The value ranges from `1` to `53`." Returns `bigint`.
- `week_of_year(x)` — "This is an alias for `week`." Both confirmed to exist and return bigint ISO week.
- `EXTRACT(WEEK FROM ...)` — the extract field table lists `WEEK` as a supported field mapping to `week`. Confirmed valid in 467.
- ISO definition (week 1 = first week with ≥4 days, Monday-start, no Sunday-start option) — correct; the responder correctly noted there is no Sunday-start variant.

GROUP BY week_of_year(created_at) for the busiest-weeks variant repeats the expression — valid, no #16533. Tiny clarity ding only because three near-equivalent forms are offered without crisply naming one as the default (cosmetic).

## Q2 — sum array of prices per order, no join/unnest — 4.8125
- Accuracy 5 / Completeness 4.75 / Clarity 4.75 / Applicability 4.75

`reduce(line_items, 0, (sum, price) -> sum + price, sum -> sum) AS total` is the canonical array-sum.

Verified vs RAW git-tag 467 `functions/array.md`:
- No `array_sum` built-in documented.
- `reduce(array(T), initialState S, inputFunction(S,T,S), outputFunction(S,R)) -> R` — 4-arg signature exact; doc example uses identity `s -> s` output function.

Integer initial `0` + DOUBLE prices coerces to DOUBLE — fine. No UNNEST as required. Sound.

## Q3 — group events by nested JSON device.os, count per OS — 4.9375
- Accuracy 5 / Completeness 5 / Clarity 4.75 / Applicability 5

**watch (r) — PROACTIVE CAVEAT, durability-positive.** The question was phrased with the Postgres `properties -> 'device' -> 'os'` arrow operator, which Trino does NOT support. The responder correctly TRANSLATED it to `json_extract_scalar(properties, '$.device.os')`. More notably, the responder PROACTIVELY taught the #16533 GROUP-BY-alias prohibition without being prompted: `GROUP BY os` (alias) fails; the fix is ordinal `GROUP BY 1` or repeating the expression, while `ORDER BY` can use the alias.

Verified:
- `json.md` — `json_extract_scalar(json, json_path) -> varchar`; nested paths supported (doc example `$.store.book[0].author`); no `->` arrow operator documented.
- #16533 / SELECT semantics — GROUP BY accepts expressions/ordinals, not SELECT aliases; ORDER BY does resolve aliases. The responder's guidance is fully accurate.

The (now-closed) watch (r) surfacing here as proactive, accurate teaching rather than a slip is a durability positive — confirms the r13 ~L3366 / L3371 FIX-A is durably reaching the responder.

## Q4 — count of active/cancelled/past_due in one query, side by side — 4.8125
- Accuracy 5 / Completeness 4.75 / Clarity 4.75 / Applicability 4.75

`COUNT(CASE WHEN status='active' THEN 1 END) AS active_count, ...` — CASE yields NULL on non-match and `COUNT(expr)` skips NULLs, so this counts matching rows. One row, 3 columns, side by side. Also offered `COUNT(*) FILTER (WHERE status='active') AS active_count, ...` as the SQL-standard equivalent.

Verified vs RAW git-tag 467 `functions/aggregate.md`: "The FILTER keyword can be used to remove rows from aggregation processing... supported for all aggregate functions"; documented form `aggregate_function(...) FILTER (WHERE <condition>)`. Both forms valid, both one row / three columns. Sound.

---

## Cross-cutting checks
- `::` cast shorthand absent in all 4 answers.
- No QUALIFY / false semi-join / fabricated functions / regex-backslash / INTERVAL quarter-week / OFFSET-before-LIMIT / over-warning folklore / broken-secondary alternative.
- No production-environment mismatch (Trino 467 + Iceberg on-prem); all SQL is valid 467 dialect.

## Recommendation: DEFAULT NO-OP
No source-verified resource defect; no 2-in-2 same-shape slip. Margin +1.375.
- **watch (t)** (week-of-year directness) — CLOSED; direct `week_of_year`/`week`/`EXTRACT(WEEK)` used; iter1046 indirect-formatter slip did not recur.
- **watch (r)** (JSON GROUP-BY-alias) — durability confirmed via proactive accurate teaching; remains closed.

NO resource edit. NO commit. MUST NOT bump state.json (already 1047).
