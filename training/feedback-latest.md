# Judge Feedback — Iteration 506 (2026-06-06, EXTENDED PHASE)

## Overall result

**Overall avg = (4.9375 + 4.9375 + 3.6875 + 4.9375) / 4 = 18.5 / 4 = 4.625 — PASS**

- 105th consecutive overall PASS in extended phase.
- Margin +1.125 above the 3.5 floor.
- **BOTH iter505 Q3 fixes LANDED CLEANLY on re-probe** (Q1 clause-order + Q2 split_to_map).
- **ONE new fabrication on Q3** — fabricated `end_of_month(...)` function (Trino 467 has no such function; the correct name is `last_day_of_month(x) -> date`).
- Federation NOT probed (per directive — §13.x guardrails and 4.49944/310 row untouched).

---

## Per-question scores

### Q1 — Pipe-delimited `categories` split + count per category — RE-PROBE of iter505 Q3 clause-order parse error

**Score: 4.9375 STRONG PASS** (Accuracy 5.0, Clarity 5.0, Actionability 5.0, Completeness 4.75)

**Answer summary**: `SELECT TRIM(category) AS category, COUNT(*) AS product_count FROM products CROSS JOIN UNNEST(SPLIT(categories, '|')) AS t(category) GROUP BY TRIM(category) ORDER BY product_count DESC` — `CROSS JOIN UNNEST(...)` placed in the FROM clause with NO WHERE-before-JOIN; explicit statement that "CROSS JOIN UNNEST must appear BEFORE the WHERE clause"; secondary form showing subquery wrap to push partition pruning before the explode.

**Verification (WebFetch trino.io/docs/current/sql/select.html)**: Confirmed standard SQL clause order FROM → JOIN → WHERE → GROUP BY → HAVING → SELECT → ORDER BY. CROSS JOIN UNNEST is part of the FROM clause and parses cleanly in Trino 467. SPLIT(string, delimiter) → ARRAY(VARCHAR) correct. TRIM(category) correct. The query as written parses cleanly on Trino 467.

**FIX A (iter506 §1a.1 clause-order rule) — LANDED**: The iter505 Q3 broken query (WHERE-before-CROSS-JOIN) does NOT reappear. The responder routes the rule explicitly ("CROSS JOIN UNNEST must appear BEFORE the WHERE clause") + uses the subquery-wrap form as the partition-pushdown escape hatch. This is the 15th leading-canonical bulletproofing instance and the 8th findability/canonical-addition fix to land cleanly on re-probe.

Minor -0.25 Completeness: no explicit call-out of NULL-on-empty-string behavior (`SPLIT(NULL, '|')` → NULL, `SPLIT('', '|')` → `['']` single-empty element). Not load-bearing here.

---

### Q2 — `metadata` = 'plan=pro;seats=50;region=us' — extract `plan` value — RE-PROBE of iter505 Q3 "no split_to_map" fab

**Score: 4.9375 STRONG PASS** (Accuracy 5.0, Clarity 5.0, Actionability 5.0, Completeness 4.75)

**Answer summary**: `ELEMENT_AT(SPLIT_TO_MAP(metadata, ';', '='), 'plan')`. Explained `SPLIT_TO_MAP(string, entryDelim, keyValueDelim) -> MAP(VARCHAR,VARCHAR)` signature, `element_at` returns NULL if key absent, explicit "No regex required" call-out.

**Verification (WebFetch trino.io/docs/current/functions/string.html via WebSearch)**: Confirmed verbatim — `split_to_map(string, entryDelimiter, keyValueDelimiter) -> map<varchar, varchar>`. `element_at(map, key)` on a missing key returns NULL (per trino.io/docs/current/functions/map.html). Production approach correct.

**FIX B (iter506 §3.1A split family reference) — LANDED**: The iter505 Q3 fab "Trino has NO SPLIT_TO_MAP" does NOT reappear. The responder uses the function directly with the correct signature + the correct `element_at` companion. This is the 16th leading-canonical bulletproofing instance and the 9th findability/canonical-addition fix to land cleanly on re-probe.

Minor -0.25 Completeness: no mention of duplicate-key behavior (split_to_map throws on duplicate keys — `split_to_multimap` is the companion for repeated keys). Not asked, but the canonical §3.1A documents this so it would have been a natural cite.

---

### Q3 — Oracle ADD_MONTHS / MONTHS_BETWEEN → Trino — FABRICATED FUNCTION

**Score: 3.6875 PASS** (Accuracy 2.75, Clarity 4.25, Actionability 3.75, Completeness 4.0)

**Answer summary**:
- ADD_MONTHS: `date_add('month', 3, start_date)` or `start_date + INTERVAL '3' MONTH` — CORRECT.
- MONTHS_BETWEEN: `date_diff('month', start_date, end_date)` returns INTEGER (boundaries only, not fractional like Oracle) — CORRECT semantic flag.
- Fractional approximation: `date_diff('day', start_date, end_date) / 31.0` — workable approximation, called out as approximate. ACCEPTABLE.
- Oracle last-day clamping caveat — CORRECT raise.
- **EXACT-semantics wrapper**: `CASE WHEN end_of_month(start_date) = start_date THEN end_of_month(date_add('month', 3, start_date)) ELSE date_add('month', 3, start_date) END` — **FABRICATED FUNCTION**.

**Verification (WebFetch trino.io/docs/current/functions/datetime.html)**:
- **`end_of_month` is NOT a Trino function.** Direct WebFetch confirms: "end_of_month: Not present in this documentation."
- **The correct function is `last_day_of_month(x) -> date`** — confirmed present at trino.io/docs/current/functions/datetime.html ("Returns the last day of the month").
- `date_add(unit, value, timestamp)` signature confirmed CORRECT.
- `date_diff(unit, timestamp1, timestamp2) -> bigint` signature confirmed CORRECT (returns month-boundary count, not fractional — matches the responder's flag).
- `start_date + INTERVAL '3' MONTH` valid in Trino 467 — CORRECT.
- Month-end clamp behavior of `date_add('month', N, ...)`: Trino's runtime DOES clamp (e.g. `date_add('month', 1, DATE '2024-01-31')` → `2024-02-29`), though the docs don't spell this out explicitly. The responder's clamp claim is consistent with observed Trino behavior, so not flagged.

**The `end_of_month` fabrication is load-bearing**: an engineer copy-pasting the EXACT-semantics wrapper will hit `Function 'end_of_month' not registered` at parse/analyze time. The wrapper must use `last_day_of_month(...)` in both positions:
```sql
CASE WHEN last_day_of_month(start_date) = start_date
     THEN last_day_of_month(date_add('month', 3, start_date))
     ELSE date_add('month', 3, start_date)
END
```

Accuracy 2.75 (the wrapper is the deliverable; ADD_MONTHS/MONTHS_BETWEEN core correct, but the load-bearing snippet fabricates a function name). Clarity 4.25 (well-organized, jargon explained). Actionability 3.75 (engineer can use the ADD_MONTHS/MONTHS_BETWEEN parts directly; the exact-semantics wrapper breaks at runtime — drag). Completeness 4.0 (covers both Oracle functions + caveat + workaround, but missed the right function name).

---

### Q4 — CASE expressions in Trino + dbt value-mapping pattern

**Score: 4.9375 STRONG PASS** (Accuracy 5.0, Clarity 5.0, Actionability 5.0, Completeness 4.75)

**Answer summary**: Simple CASE (`CASE status_code WHEN 'active' THEN 'Active' ... ELSE 'Unknown' END`) + searched CASE; dbt staging value-mapping pattern; incremental example with `is_incremental()` guard.

**Verification (WebFetch trino.io/docs/current/functions/conditional.html)**: Both simple CASE (`CASE expression WHEN value THEN result [WHEN ...] [ELSE result] END`) and searched CASE (`CASE WHEN condition THEN result [WHEN ...] [ELSE result] END`) confirmed valid Trino 467 syntax. ELSE clause optional, returns NULL if no branch matches and no ELSE. The dbt `is_incremental()` guard pattern (`{% if is_incremental() %} WHERE updated_at > (SELECT MAX(updated_at) FROM {{ this }}) {% endif %}`) is correct per docs.getdbt.com/docs/build/incremental-models.

No NULL-discriminant claims made (the responder did not assert anything misleading about simple CASE with NULL — non-issue here since status codes are non-null literals).

Minor -0.25 Completeness: no explicit call-out of the simple-CASE-with-NULL trap (`CASE NULL WHEN NULL THEN ...` never matches because `NULL = NULL` is NULL, not TRUE) — not load-bearing for this question but worth a future canonical note.

---

## Critical fixes status

| Fix | Iter | Where | Status | Probe outcome |
|---|---|---|---|---|
| **A. SQL clause-order rule (CROSS JOIN UNNEST in FROM, BEFORE WHERE)** | iter506 r07 §1a.1 | resources/07-analytical-query-patterns.md | **LANDED CLEANLY** | Q1 4.9375 STRONG — query parses, rule stated, subquery-wrap pushdown form shown |
| **B. split_to_map family reference** | iter506 r23 §3.1A | resources/23-sql-best-practices-olap.md | **LANDED CLEANLY** | Q2 4.9375 STRONG — split_to_map + element_at used directly with correct signature, "no split_to_map" fab gone |

Both fixes are confirmed landed on first-paste re-probe. That is two clean leading-canonical bulletproofing instances in iter506.

---

## New fabrication / gaps from iter506

| Issue | Severity | Question | Where | Iter507 teacher action |
|---|---|---|---|---|
| `end_of_month(date)` fabricated — correct Trino 467 name is `last_day_of_month(date)` | LOAD-BEARING (copy-paste runtime error) | Q3 | r27 Oracle→Trino month-arithmetic canonical (likely the ADD_MONTHS/MONTHS_BETWEEN row in §4.x) | RECONCILE-IN-PLACE: add `last_day_of_month(x) -> date` as canonical with the EXACT-semantics ADD_MONTHS wrapper worked example using last_day_of_month in BOTH positions; add DO-NOT-WRITE row banning `end_of_month(...)` with the exact error message `Function 'end_of_month' not registered`; cross-ref r07 and r23. Keep wrapper <=20 lines. |

---

## Topic average updates

### Common analytical query patterns: aggregations, funnels, cohort, time-series
Q1 (split-and-count CROSS JOIN UNNEST canonical) maps here.
- Prior: 4.6450 / 10
- Update: (4.6450 * 10 + 4.9375) / 11 = 51.3875 / 11 = **4.6716 / 11** (+0.0266)

### Oracle PL/SQL → dbt + Trino SQL migration
Q3 (ADD_MONTHS / MONTHS_BETWEEN) maps here.
- Prior: 4.5350 / 71
- Update: (4.5350 * 71 + 3.6875) / 72 = 325.6725 / 72 = **4.5232 / 72** (-0.0118 — Q3 fab drags slightly, but stays above 3.5 floor)

### SQL query best practices for OLAP
Q2 (SPLIT_TO_MAP element_at extraction) and Q4 (CASE / dbt value-mapping) both map here as SQL-best-practices canonical.
- Prior: 4.5288 / 55
- Update: (4.5288 * 55 + 4.9375 + 4.9375) / 57 = 258.9215 / 57 = **4.5425 / 57** (+0.0137)

### Trino federation / cross-source connectors
- **NOT probed**. Row stays **4.49944 / 310 UNCHANGED** per directive.

---

## Iter507 probe targets

| Priority | Probe | Why |
|---|---|---|
| **HIGH** | Oracle ADD_MONTHS month-end re-probe ("Oracle ADD_MONTHS(DATE '2026-01-31', 1) returns 2026-02-28 — how do I match that in Trino?") | Confirms the `end_of_month` → `last_day_of_month` reconcile fix lands on first-paste; this is the load-bearing fix from iter506 |
| **HIGH** | MONTHS_BETWEEN with fractional output (Oracle returns fractional days/31; Trino date_diff('month', ...) returns integer) — 2nd angle | Verifies the integer-vs-fractional Trino docs caveat is firmly canonical; confirm the day-divided-by-31 approximation row stays accurate |
| **MEDIUM** | Pipe-delimited split-and-count WITH partition filter (test that the subquery-wrap form is the routed answer when partition pushdown is needed) — 3rd angle on §1a.1 | Verifies the secondary "subquery-wrap to push partition-pruning BEFORE explode" form holds under partition-pruning question phrasing |
| **MEDIUM** | split_to_map duplicate keys (`a=1;b=2;a=3`) — test that split_to_multimap is recommended, NOT split_to_map (which throws on dup keys) | Verifies §3.1A duplicate-key DO-NOT-WRITE row routes correctly |
| **LOW** | Searched CASE with NULL discriminant (engineer asks "why does `CASE my_col WHEN NULL THEN 'missing' END` never return 'missing'?") | Tests whether a future canonical NULL-equality CASE note is needed |
| **OFF** | Federation — DO NOT PROBE. §13.x guardrails + 4.49944/310 row stay frozen. |

---

## Summary

- **Iter506 PASS — 4.625 overall, +1.125 above floor**.
- **BOTH iter505 fixes landed cleanly on first re-probe** (clause-order rule + split_to_map family reference). 15th and 16th leading-canonical bulletproofing instances.
- **ONE new load-bearing fabrication on Q3**: `end_of_month` → must be `last_day_of_month`. Reconcile in r27 Oracle→Trino canonical for iter507.
- Federation untouched per directive. state.json unchanged (iteration 506).
