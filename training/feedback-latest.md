# Judge Feedback — iter804

**Mode:** DEFAULT NO-OP / durability-breadth sweep (teacher made ZERO resource edits; 4 fresh adjacent probes). Phase: extended.
**Date:** 2026-06-09

**Overall: 4.06 PASS** (overall average governs; no single-Q veto).

All dialect claims verified against trino.io/docs/467 (functions/datetime.html, functions/regexp.html, functions/aggregate.html) on 2026-06-09.

---

## Per-question scores

### Q1 — quarter (1-4) + ISO week-of-year from order_date — **avg 2.50 (DEFECT)**
- Accuracy: **2** — Completeness: 3 — Clarity: 3 — Actionability: 2
- Responder answer: `'Q' || quarter_of_year(order_date) AS quarter, week_of_year(order_date) AS week_of_year`.
- **DEFECT: `quarter_of_year()` is a FABRICATED function.** VERIFIED vs trino.io/docs/467/functions/datetime.html: Trino's quarter function is **`quarter(x) -> bigint`** ("Returns the quarter of the year from x. Ranges 1-4"). There is **NO `quarter_of_year()`** registered function or alias. The query would fail at planning with "function quarter_of_year not registered." (Only the `day_*` family has of-year-style aliases — day_of_week/dow, day_of_year/doy; quarter does NOT.)
- The week half is CORRECT: VERIFIED `week_of_year(x)` IS a documented **alias for `week(x)`** ("ISO week of the year, 1-53"). So `week_of_year(order_date)` compiles and is right.
- (Secondary: `'Q' || quarter_of_year(...)` would need a CAST of the bigint to varchar for `||`; moot given the fabrication.)
- **Correct forms:** `quarter(order_date)` or `EXTRACT(QUARTER FROM order_date)`; week is fine as-is (or `EXTRACT(WEEK FROM order_date)`).
- **Verdict: RESPONDER SLIP against CLEAN resources.** Resources never contain `quarter_of_year`. They show the correct `quarter()` repeatedly: `resources/07-analytical-query-patterns.md:3069` (`quarter(order_date) = quarter(current_date)`) and `:3075`, and `resources/27-oracle-plsql-to-dbt-trino.md:592` (`use quarter(ts)`). `EXTRACT(QUARTER ...)` documented at `resources/13-postgres-to-iceberg-ingestion.md:5683` (QUARTER listed among EXTRACT fields). The responder fabricated the `_of_year` suffix by over-generalizing the day_of_year alias pattern.

### Q2 — substring between markers: value after 'action=' before next space → 'login' — **avg 2.50 (DEFECT)**
- Accuracy: **2** — Completeness: 3 — Clarity: 3 — Actionability: 2
- Responder answer: `regexp_extract(log_message, 'action=(\S+)') AS action_value`; prose claim "extracts the first capture group (the parenthesized part)."
- **DEFECT: the 2-arg `regexp_extract` returns the WHOLE match, not the capture group.** VERIFIED vs trino.io/docs/467/functions/regexp.html: `regexp_extract(string, pattern) -> varchar` returns "the first substring matched by the regular expression pattern" (the ENTIRE match). So on `'user=42 action=login status=ok'` with `'action=(\S+)'` it returns **`'action=login'`** (includes the `action=` prefix), NOT `'login'` as claimed. The prose claim that the 2-arg form "extracts the first capture group" is **FALSE**.
- **Correct form:** `regexp_extract(log_message, 'action=(\S+)', 1)` — the **3-arg form with group index 1** returns capture group 1 = `'login'`. (`regexp_extract(string, pattern, group) -> varchar` returns capturing group N; group 0 = whole match.) The pattern `'action=(\S+)'` itself is fine; the missing group-index arg is the bug.
- **Verdict: RESPONDER SLIP against CLEAN resources.** r23 has the EXACT correct canonical: `resources/23-sql-best-practices-olap.md:2809` — `regexp_extract(s, 'id=([0-9]+)', 1)  -- 'id=987;x' -> '987' (group 1)`. Semantics spelled out correctly at `:2818` (2-arg = "FIRST substring matched") vs `:2819` (3-arg = "capture group N (1-indexed; group 0 = whole match)"). The responder had the right card, dropped the `, 1` group-index arg, and mis-attributed capture-group semantics to the 2-arg form.

### Q3 — SLA deadline = created_at + 2 hours 30 minutes — **avg 5.00 (CLEAN)**
- Accuracy: 5 — Completeness: 5 — Clarity: 5 — Actionability: 5
- `created_at + INTERVAL '2' HOUR + INTERVAL '30' MINUTE AS deadline` — VERIFIED valid chained interval addition on timestamp. Equivalent `date_add('minute', 150, created_at)` also correct. CASE-based SLA-status framing is a practical bonus. No defect.

### Q4 — most common device_type per country (mode per group) — **avg 5.00 (CLEAN)**
- Accuracy: 5 — Completeness: 5 — Clarity: 5 — Actionability: 5
- Inner `SELECT country, device_type, COUNT(*) AS cnt ... GROUP BY country, device_type`, outer `max_by(device_type, cnt) GROUP BY country`. VERIFIED vs functions/aggregate.html: `max_by(x, y)` returns x at the max of y → device_type with highest per-country count = the mode. Standing mode=max_by-over-COUNT pin reconfirmed. `max_by(device_type, ROW(cnt, device_type))` deterministic tie-break is valid (lexicographic ROW comparison). No defect.

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|-----|------|------|-----|-----|
| Q1 | 2 | 3 | 3 | 2 | 2.50 |
| Q2 | 2 | 3 | 3 | 2 | 2.50 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |
| **Overall** | | | | | **4.06 PASS** |

PASS on the overall-average rule, but with **TWO non-compiling/wrong-value defects (Q1, Q2)** — both pure responder slips against clean, correct resources. A findability/discipline regression, not a resource gap.

---

## Verdicts (explicit)

**(a) Q1 — `quarter_of_year` fabrication.** Correct = `quarter(order_date)` or `EXTRACT(QUARTER FROM order_date)`. **RESPONDER SLIP** — resources clean & correct: `resources/07-analytical-query-patterns.md:3069`/`:3075` show `quarter()`; `resources/27-oracle-plsql-to-dbt-trino.md:592` shows `use quarter(ts)`; `resources/13-postgres-to-iceberg-ingestion.md:5683` lists QUARTER as an EXTRACT field. No `quarter_of_year` anywhere. The responder over-generalized the `day_of_year`/`day_of_week` alias pattern onto quarter.

**(b) Q2 — `regexp_extract` 2-arg returns whole match.** Correct = 3-arg `regexp_extract(log_message, 'action=(\S+)', 1)` for the capture group. **RESPONDER SLIP** — `resources/23-sql-best-practices-olap.md:2809` already shows the exact `regexp_extract(s, 'id=([0-9]+)', 1)` 3-arg group-1 canonical, and `:2818`/`:2819` correctly state 2-arg=whole-match vs 3-arg=group-N. The responder dropped the group index and mis-described the 2-arg semantics.

**(c) iter805 designation — LIGHT INOCULATION FIX-A (both slips, clean resources).**
Both defects trace to clean resources, so no large rewrite is warranted. Two surgical, additive, keyword-landing inoculations:
1. **r07 date-part canonical:** add a short fenced "quarter + ISO week from a date" card LEADING with `quarter(order_date)` and `week_of_year(order_date)` (and `EXTRACT(QUARTER FROM ...)` / `EXTRACT(WEEK FROM ...)`), with an inline un-copyable WRONG-marker on `quarter_of_year(...)` ("not a Trino function — use `quarter()`"). Land on keywords: "quarter of year", "which quarter", "week number", "week of year", "ISO week". Directly answers Q1's phrasing and defangs the fabricated alias.
2. **r23 regexp_extract between-markers card:** add a short "pull value between two markers / after a delimiter" fenced canonical on the EXISTING correct `:2809` pattern — `regexp_extract(log_message, 'action=(\S+)', 1)` → `'login'` — with an explicit one-liner: "the **2-arg** form returns the WHOLE match (`'action=login'`); you MUST pass the **group index `, 1`** to get just the captured part." Land on keywords: "value after", "between markers", "substring after = before space", "extract field from log line".

If the teacher prefers zero churn, a pure NO-OP is defensible (resources are correct; these are responder slips) — but the same 2-arg-vs-3-arg regexp_extract confusion has appeared before, so inoculation #2 is the higher-value move. PRESERVE all existing verified cards (r07 quarter()/interval, r23:2806-2819 regexp_extract, r23 mode=max_by) — do NOT churn them.

**DO NOT bump training/state.json (already 804).**
