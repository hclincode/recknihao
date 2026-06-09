# Judge Feedback — iter845 (EXTENDED PHASE, DEFAULT NO-OP durability sweep)

**Date:** 2026-06-09
**Result:** PASS overall (overall avg 4.50; per-Q 5.00 / 3.50 / 5.00 / 4.50 = 18.00/4; margin +1.00; overall avg governs, no per-Q veto)
**Federation:** NOT probed this iteration.
**Teacher edits this iteration:** ZERO (declared DEFAULT NO-OP durability sweep).
**state.json:** NOT bumped (already 845).

All four dialect families verified against trino.io/docs/467 (datetime.html, string.html, aggregate.html, sql/select.html). PIN Trino 467.

---

## Per-question scores

### Q1 — map column → JSON string for an API — **5.00** (Acc5 / Comp5 / Clar5 / Act5)
`json_format(CAST(metadata AS JSON))` is the canonical correct form.
- VERIFIED: `CAST(map AS JSON)` → JSON object; `json_format(json)` → varchar. Correct two-step route.
- The DEBUG-FORMAT trap warning is the high-value part and is accurate: `CAST(map AS VARCHAR)` produces Trino's internal map render `{plan=enterprise, region=us-east}` (unquoted keys/values, `=` separators) which is NOT valid JSON. Telling the engineer to route through JSON first is exactly right for an API payload.
- Fresh-clean. No defects.

### Q2 — build a DATE from year/month/day INTEGER columns, filter last 90 days — **3.50** (Acc3 / Comp4 / Clar4 / Act3)
Two distinct things to grade:

(1) **Date-construction expression — CORRECT.** `CAST(date_parse(CONCAT(CAST(event_year AS VARCHAR),'-',LPAD(CAST(event_month AS VARCHAR),2,'0'),'-',LPAD(CAST(event_day AS VARCHAR),2,'0')), '%Y-%m-%d') AS DATE)`:
   - VERIFIED `date_parse` uses MySQL `%`-specifiers (`%Y`/`%m`/`%d`), NOT Joda — correct family, no cross-family bug.
   - `LPAD(..,2,'0')` zero-pads single-digit month/day to two chars — correct.
   - `date_parse` returns `timestamp(3)`; `CAST(... AS DATE)` narrows to DATE — correct, and the responder correctly stated the return type.
   - The "Trino has no construct-DATE-from-components function; ISO-concat-then-parse is the clean form" framing is accurate (no `make_date`/`date_from_parts` in Trino 467).

(2) **THE BUG — SELECT alias referenced in WHERE.** The example writes `... AS event_date FROM events WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY`. `event_date` is the SELECT-list alias. **VERIFIED against Trino 467 (sql/select.html): WHERE is evaluated BEFORE the SELECT projection, so output-column aliases do not exist when WHERE runs.** The query as written FAILS with `Column 'event_date' cannot be resolved`. This is a copy-and-break correctness bug: an engineer who copies it gets a parse/analysis error, not a working filter.
   - Correct fixes: repeat the full `CAST(date_parse(...) AS DATE)` expression in WHERE, OR wrap the SELECT in a CTE/subquery and filter the outer query. The `INTERVAL '90' DAY` arithmetic itself is fine.

**Verdict on the bug — RESPONDER-SLIP, NOT a findability gap.** The "no SELECT alias in WHERE" rule is documented AND findable, in multiple places, including one that is almost this exact scenario:
- `resources/27-oracle-plsql-to-dbt-trino.md:767` — "GOTCHA — filtering on a parsed timestamp (do NOT reference the SELECT output alias in WHERE)" — states WHERE-runs-before-SELECT, gives the precise `Column '<alias>' cannot be resolved` error, shows the WRONG form (alias-in-WHERE on a parsed time column), and gives BOTH fixes (CTE-preferred + repeat-expression). This is the parse-then-filter case, identical in shape to Q2.
- `resources/07-analytical-query-patterns.md:2702`, `:2716`, `:3222` — alias-not-visible-before-projection rule (GROUP BY / WHERE / HAVING / OVER ORDER BY), with a parse-error matrix row.
- `resources/23-sql-best-practices-olap.md:484` — GROUP BY alias asymmetry (ORDER BY can, WHERE/GROUP BY cannot).

The content exists and is keyword-rich ("filter", "parsed", "WHERE", "alias", "cannot be resolved"). The responder reproduced the exact anti-pattern the resource warns against. This is a synthesis slip — the responder correctly built the date expression but then dropped it behind an alias and filtered on the alias, the precise mistake r27 §4.2 inoculates against. No resource defect.

### Q3 — filter file paths ending '.pdf' — **5.00** (Acc5 / Comp5 / Clar5 / Act5)
- VERIFIED: Trino 467 has `starts_with()` but NO `ends_with()` (pinned fact, confirmed again on string.html). Correctly stated, with the right rationale (commonly fabricated when porting from Spark/Snowflake).
- `WHERE file_path LIKE '%.pdf'` is the canonical form; `regexp_like(file_path, '\.pdf$')` offered as the regex alternative (correct — literal-dot-anchored-end). The "LIKE pushes down better" note is a sound applicability tip.
- Fresh-clean. No defects.

### Q4 — population vs sample standard deviation — **4.50** (Acc5 / Comp5 / Clar4 / Act4)
- VERIFIED against aggregate.html: `stddev_samp` (sample, divides by n-1), `stddev_pop` (population, divides by n); `stddev` IS an alias for `stddev_samp`; `variance`/`var_samp` (n-1) and `var_pop` (n) analogues all present. Every characterization correct.
- Correctly told the Postgres user that `stddev()` is the same default (n-1 sample) in both Trino and Postgres — directly resolves the migration concern. The sample-vs-population guidance (unbiased estimate vs entire-population) is correct and useful.
- Minor: no runnable SELECT snippet (formula prose only), and no note on small-n behavior (`stddev_samp` over n=1 → NULL since n-1=0). Cosmetic completeness/actionability nits only; no inaccuracy.

---

## Patterns / observations

- 3 of 4 questions fresh-clean and fully docs-correct. The one ding (Q2) is a synthesis slip against already-correct, well-placed content — not a content gap.
- No dialect fabrication. `ends_with`-absence (Q3) and `stddev=stddev_samp` (Q4) both held; `date_parse` MySQL-specifier family (Q2) was correct — none of the recurring "import foreign priors into Trino" failure modes fired at the function level.
- The Q2 failure is at the QUERY-COMPOSITION level (alias scoping), not the function level — a different class than the function-name slips logged in MEMORY.md.

## iter846 directive — **DEFAULT NO-OP durability sweep** (no FIX-A warranted)

The Q2 alias-in-WHERE bug is a responder-slip against content that is already correct, prominent, and findable (r27 §4.2 line 767 is nearly this exact case). Per the reconcile-don't-churn discipline and the "one-off slip vs already-correct resource ⇒ do not edit" guard used in iter838/iter784, this does NOT justify a resource edit.

**Recommended for iter846:**
1. DEFAULT NO-OP durability sweep. HOLD all iter534–844 locks. Federation r22 untouched (row stays 4.49944/310).
2. RE-PROBE the alias-in-WHERE rule from the date-construction angle once more (e.g. "build a timestamp from parts then filter recent" or "compute a derived column then filter on it") to confirm whether the Q2 slip recurs. If it recurs on a 2nd independent date/derived-column phrasing, THEN escalate to a LIGHT FIX-A: add a keyword-anchored cross-link from the r23/r07 date-construction & string→DATE cards (where date-build questions land) to the r27 §4.2 alias-in-WHERE GOTCHA, so a responder building a date column is routed to filter-it-correctly guidance co-located. Do NOT edit r27 §4.2 itself (it is correct and complete) and do NOT churn any verified canonical.
3. If the re-probe is clean, leave everything as-is.

DO NOT bump training/state.json (already 845).
