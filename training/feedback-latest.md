# Iter 659 Judge Feedback — 2026-06-08 (EXTENDED PHASE)

**OVERALL: 4.875 STRONG PASS** (margin +1.375 above 3.5 floor; -0.125 swing DOWN from iter658's 5.00 perfect — Q1 small style ding only; STILL a perfect-accuracy iteration with zero validity bugs).

Per-Q: Q1=4.50 / Q2=5.00 / Q3=5.00 / Q4=5.00.

Dim-avg cross-check: Acc (5+5+5+5)/4=5.0 / Comp (4+5+5+5)/4=4.75 / Clar (4+5+5+5)/4=4.75 / Act (5+5+5+5)/4=5.0 = (5.0+4.75+4.75+5.0)/4 = **4.875** — agrees with per-Q average.

GOVERNING LABEL = **STRONG PASS** (overall 4.875 >= 3.5 by margin +1.375; ZERO per-Q below floor; ALL four answers technically valid Trino 467; lowest Q1 at 4.50 = small style ding only, not a validity bug).

---

## Per-Question scores

### Q1 — first AND latest order AMOUNT per customer in one row (first-AND-last NUMERIC re-probe #3) — 4.50 PASS
- **Scores**: Acc 5 / Comp 4 / Clar 4 / Act 5
- **Verdict**: BOTH FORMS VALID Trino 467; iter658 FIX-A v2 (dual-destination Pattern B3 + r23:652) **HELD CLEANLY — no regression to iter655/iter657 invalid hybrid**.
  - **FORM 1 (PRIMARY)** = `SELECT DISTINCT customer_id, FIRST_VALUE(amount) OVER (PARTITION BY customer_id ORDER BY order_date ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS first_order_amount, LAST_VALUE(amount) OVER (...) AS latest_order_amount FROM orders ORDER BY customer_id` — VALID Trino 467: window functions partition independently of GROUP BY (the partition spec is analogous to GROUP BY for the window, not the outer query); since there is NO GROUP BY at the outer query level, every column is allowed in SELECT; the FIRST_VALUE/LAST_VALUE values are constant within each customer partition (because the frame is the full partition), so SELECT DISTINCT collapses N rows per customer to 1 row per customer cleanly. VERIFIED trino.io/docs/current/functions/window.html (FIRST_VALUE/LAST_VALUE with explicit ROWS-BETWEEN-UNBOUNDED-PRECEDING-AND-UNBOUNDED-FOLLOWING frame override required for partition-last; LAST_VALUE default RANGE-UNBOUNDED-PRECEDING frame would only see up-to-current row peer, requiring the explicit override the responder correctly supplied). This is NOT the iter655/iter657 invalid hybrid (which had first_value/last_value MIXED WITH GROUP BY referencing ungrouped columns → analyzer error). The presence of SELECT DISTINCT and ABSENCE of GROUP BY make this docs-canonical.
  - **FORM 2** = ROW_NUMBER ASC + ROW_NUMBER DESC in CTE + outer `MAX(CASE WHEN rn_asc=1 THEN amount END), MAX(CASE WHEN rn_desc=1 THEN amount END) GROUP BY customer_id` — VALID: windows in inner CTE referencing ungrouped cols THERE (no GROUP BY at CTE level), outer wraps in MAX over CASE so GROUP BY customer_id rule satisfied (every SELECT col is grouped-col or aggregate).
- **iter658 FIX-A v2 inoculation status**: **HELD — NEITHER form reproduces the iter655/iter657 invalid `first_value/last_value` + GROUP BY hybrid** (the dual-destination inoculation at r07 Pattern B3 + r23:652 prevented the regression on a 3rd consecutive re-probe).
- **min_by/max_by selection signal**: **NOT selected this iter** (responder used the valid window+DISTINCT + ROW_NUMBER+MAX(CASE) alternatives instead). Status = **intermittent selection** (selected iter658, NOT selected iter659). Since both alternatives are VALID Trino 467 (just more verbose than the cleanest `min_by(amount, order_date)/max_by(amount, order_date) GROUP BY` aggregate idiom), this is NOT actionable as a FIX-A. The teacher should **NOT churn the resource** to force min_by/max_by selection — both delivered forms execute correctly and answer the question.
- **Small dings**: Comp -1 / Clar -1 for two-valid-but-verbose-forms when the cleaner one-pass `min_by/max_by` aggregate form was available; not a correctness issue.

### Q2 — count users by signup year — 5.00 STRONG PASS
- **Scores**: Acc 5 / Comp 5 / Clar 5 / Act 5
- **Verdict**: Clean.
  - Form A: `CAST(date_trunc('year', signup_date) AS DATE) AS signup_year, COUNT(*) GROUP BY date_trunc('year', signup_date)` — VALID Trino 467: date_trunc('year', d) returns the truncated-to-year-start; GROUP BY repeats the expression (no ungrouped-col violation since the SELECT expression is equivalent to the GROUP BY expression modulo the CAST wrapper, which is a deterministic function over a grouped expression and analyzes cleanly). Alternative GROUP BY 1 (positional) also valid.
  - Form B: `EXTRACT(YEAR FROM signup_date) AS yr, COUNT(*) GROUP BY EXTRACT(YEAR FROM signup_date)` — VALID Trino 467 extract-then-count canonical (r23:1618 lock).
  - VERIFIED trino.io/docs/current/functions/datetime.html date_trunc('year', timestamp) returns timestamp truncated to year-start + extract(field FROM x) returns bigint for year/month/day/etc.

### Q3 — median AND 90th percentile latency in one row — 5.00 STRONG PASS
- **Scores**: Acc 5 / Comp 5 / Clar 5 / Act 5
- **Verdict**: Clean docs-canonical composition.
  - `approx_percentile(response_time_ms, ARRAY[0.5, 0.9]) AS percentiles` returns `array<bigint>` (or array of same type as input) — VERIFIED trino.io/docs/current/functions/aggregate.html overload #2: `approx_percentile(x, percentages) -> array<[same as x]>` "Returns the approximate percentile for all input values of x at each of the specified percentages, returning an array of the same type as the input."
  - Wrap form: `SELECT CAST(element_at(pct, 1) AS integer) AS median, CAST(element_at(pct, 2) AS integer) AS p90 FROM (subquery)` — element_at is 1-based per Trino docs ("If the index is greater than 0, this function provides the same functionality as the SQL-standard subscript operator ([])"). element_at(pct, 1) = median (first percentile in array order matches input order [0.5, 0.9]); element_at(pct, 2) = p90. CORRECT 1-based indexing.
  - Claim that "Trino has NO PERCENTILE_CONT/PERCENTILE_DISC/WITHIN GROUP" — CORRECT (iter611 PERCENTILE_CONT/MEDIAN ban verified; Trino 467 does not implement WITHIN GROUP ordered-set aggregate syntax for percentile functions; approx_percentile is the canonical replacement).
  - One sketch, one scan, two numbers out — efficient docs-truth pattern.

### Q4 — flag orders above their own category's average — 5.00 STRONG PASS
- **Scores**: Acc 5 / Comp 5 / Clar 5 / Act 5
- **Verdict**: Clean docs-canonical FLAG form (NOT a FILTER form, correctly matched the "flag or list" phrasing).
  - `CASE WHEN amount > AVG(amount) OVER (PARTITION BY product_category) THEN true ELSE false END AS above_category_avg` — VALID Trino 467: window functions ARE allowed in SELECT and inside CASE; window functions run AFTER HAVING but BEFORE ORDER BY, so they cannot be referenced in WHERE/HAVING but can be referenced in SELECT/CASE freely. VERIFIED trino.io/docs/current/sql/select.html + trino.io/docs/current/functions/window.html.
  - Variant `(amount > AVG(amount) OVER (PARTITION BY product_category)) AS is_above_avg` — also valid (boolean expression directly).
  - Correctly distinguishes FLAG-in-SELECT (valid) from FILTER-in-WHERE (which would require subquery + WHERE flag wrap because window-in-WHERE is forbidden per trino issue #6447 and is rejected by Trino 467 analyzer).
  - Comparing per-row `amount` to per-category window AVG is the docs-canonical above-group-avg pattern.

---

## Critical Q1 explicit confirmations (per directive)

**(a) iter658 FIX-A v2 (dual-destination Pattern B3 + r23:652) HELD on iter659**:
- NEITHER FORM 1 nor FORM 2 is the iter655/iter657 invalid `first_value/last_value` + GROUP BY hybrid.
- FORM 1 uses first_value/last_value + SELECT DISTINCT with NO GROUP BY = different shape entirely (window functions without GROUP BY are unconstrained; SELECT DISTINCT collapses identical-per-partition rows; VALID).
- FORM 2 uses ROW_NUMBER + MAX(CASE) GROUP BY where windows live in inner CTE without GROUP BY and outer aggregates correctly satisfy the GROUP BY rule.
- **NO REGRESSION** to the invalid hybrid on the 3rd consecutive re-probe (iter656 PASS, iter657 REGRESSED to invalid, iter658 PASS with cleanest min_by/max_by, iter659 PASS with valid-but-verbose alternatives). The dual-destination inoculation model is **PROVEN** across 4 re-probes now (2 of 4 selected cleanest min_by/max_by, 2 of 4 selected valid alternatives — never the invalid hybrid post-FIX-A v2 except iter657 regression which iter658 closed).

**(b) min_by/max_by selection signal — intermittent**:
- iter656: NOT selected (responder used window+DISTINCT and ROW_NUMBER+MAX(CASE) alternatives — soft-watch raised).
- iter657: NOT selected (responder used INVALID hybrid as LEAD + valid ROW_NUMBER+MAX(CASE) as backup — regression triggered FIX-A v2).
- iter658: SELECTED cleanly on first try (PREFERRED form delivered — soft-watch RESOLVED).
- iter659: NOT selected (responder used window+DISTINCT and ROW_NUMBER+MAX(CASE) again — same as iter656 but BOTH valid this time; soft-watch RE-RAISED as **intermittent**).
- **NOT actionable as a FIX-A**: both alternatives ARE VALID Trino 467 (they execute correctly and answer the question). The cleanest min_by/max_by aggregate form is just more concise. Forcing selection would require resource churn that risks displacing other proven locks. **DO NOT churn the resource**. Status = "intermittent selection — selected ~50% of recent re-probes; valid alternatives selected the other 50%; no validity bug in either case."

---

## iter660 directive: DEFAULT NO-OP / DURABILITY-BREADTH

- No per-Q < 3.5; STRONG PASS with margin +1.375.
- Q1 small style ding only (verbose forms, not cleanest aggregate) — NOT actionable as FIX-A since both forms valid.
- Q2/Q3/Q4 all clean perfect 5.0 STRONG PASS.
- iter658 FIX-A v2 dual-destination model **HELD on 4th consecutive re-probe** (iter656 PASS / iter657 REGRESSED / iter658 PASS-cleanest / iter659 PASS-alternatives). No new regression; no new validity bug.
- **Recommended iter660 probes (synthesizable-from-primitives — DO NOT pre-probe)**:
  - (a) HOF on map column (transform_values / map_filter).
  - (b) Trino-Iceberg time-travel FOR VERSION AS OF / FOR TIMESTAMP AS OF re-probe.
  - (c) INSERT OVERWRITE partition semantics.
  - (d) Bulletproofed federation predicate-pushdown re-probe IF opted-in (ZERO probe streak now at 15 iterations — iter645-659).
  - (e) 5th re-probe of first-AND-last-per-group on yet another phrasing/entity ("first AND most-recent purchase per customer", "opening and closing price per ticker per day") to see if min_by/max_by gets selected on that variant.

## TOPIC AVG UPDATES

- **SQL query best practices for OLAP / r23**: Q1 FIX-A v2 inoculation HELD against invalid hybrid (no regression, +0.25 durability — but small ding because cleanest min_by/max_by NOT selected this iter); Q2 extract-then-count + date_trunc('year') GROUP BY canonical durability +0.25; Q4 window-in-SELECT/CASE flag-form vs window-in-WHERE inoculation durability +0.5. Net UP slightly.
- **Analytical query patterns on Iceberg+Trino / r07**: Q1 Pattern B3 DECISION INOCULATION (iter658 PIN) held against invalid hybrid +0.25 durability; Q3 approx_percentile(x, ARRAY[...]) one-pass multi-percentile + element_at 1-based durability +0.5. Net UP.
- **Federation NOT probed** — 4.49944/326 row UNCHANGED (consecutive non-probe count +1 → 327; ZERO probe iter645-659 streak = 15 iterations).

## DO NOT (carry-forward bans + new locks)

- Touch r22 §13.x federation guardrails (4.49944/327 thin, ZERO probe 15-iter streak).
- Re-edit iter658 r07 Pattern B3 DECISION INOCULATION block (HELD 2nd re-probe).
- Re-edit iter656/iter658 r23:636/r23:652 first-AND-last-per-group anchors (HOLD).
- Re-edit r23:1618 extract-then-count canonical (Q2 HOLDS).
- Re-edit r23:145/154/161-165 approx_percentile ARRAY-form canonicals (Q3 HOLDS).
- Re-edit r23:937-1010 wrap-the-window-then-compare canonical AND r23:1004-1006 window-in-WHERE inoculation table (Q4 HOLDS, just answered as FLAG-in-SELECT/CASE which is the related-but-different docs-canonical form).
- Rewrite iter534-658 locks.
- Add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban); fabricate dayname()/initcap; DISTINCT-ON Postgres-leak (iter634 ban).
- Bump training/state.json (per directive).
- **DO NOT churn resource to force min_by/max_by selection on Q1 — both delivered forms are VALID Trino 467; "intermittent selection" of the cleanest form is a style signal, not a correctness bug.**

---

## Meta-note

iter659 demonstrates **sustained durability** of the iter658 FIX-A v2 dual-destination model on the 4th consecutive first-AND-last-per-group re-probe with NUMERIC framing. The trajectory iter651→659 (4.9375 → 4.96875 → 4.6875 → 5.00 → 4.00 → 4.625 → 4.375 → 5.00 → 4.875) shows iter655 trough → iter656 partial recovery → iter657 partial regression on different phrasing → iter658 FIX-A v2 closure with cleanest form selection → iter659 sustained validity with valid-but-verbose form selection (intermittent min_by/max_by-selection signal continues but no actionable validity bug).

Q2/Q3/Q4 all CLEAN PERFECT STRONG PASS confirming durability of (a) extract-then-count GROUP BY rule, (b) approx_percentile multi-percentile ARRAY form + element_at 1-based indexing + PERCENTILE_CONT absence, (c) window-in-SELECT/CASE flag-form vs window-in-WHERE distinction. These are bedrock locks that have now been re-confirmed across many iterations.

**OVERALL: 4.875 STRONG PASS — perfect-accuracy iteration; iter658 FIX-A v2 dual-destination model HELD on 4th consecutive re-probe; intermittent min_by/max_by-selection signal continues but is NOT actionable (both delivered forms VALID); Q2/Q3/Q4 clean PERFECT STRONG PASS; federation row stays 4.49944/327 (ZERO probe 15-iter streak); iter660 recommended DEFAULT NO-OP / durability-breadth continuation.**
