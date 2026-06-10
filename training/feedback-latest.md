# iter962 Judge Feedback — 2026-06-11 (EXTENDED PHASE)

**Overall: 4.328125 PASS** (margin +0.828). Per-Q: Q1 4.6875 / Q2 4.0 / Q3 3.625 / Q4 4.6875 = 17.3125/4 = 4.328125. OVERALL AVERAGE governs (no per-Q veto). FEDERATION NOT PROBED (r22 §13.x hard-locked, 4.49944/310 UNCHANGED).

All dialect/logic verified BOTH directions (present AND absent) vs trino.io/docs/467 (functions/datetime.html, functions/window.html, functions/aggregate.html, sql/select.html grammar) + git-tag 467 + WebSearch 2026-06-11 — NOT against resources/.

---

## ★★★ iter961 Q1 QUALIFY/LAG-AS-OF SLIP = CONFIRMED ONE-OFF (RE-PROBE CLEAN) ★★★

iter961 Q1 shipped TWO real defects on a temporal as-of question: (1) `QUALIFY ROW_NUMBER()... = 1` (parse error — Trino 467 has NO QUALIFY) and (2) `LAG(...)` used as a stand-in for as-of state. iter962 Q1 is the targeted re-probe (price AS OF Jan 1 from price_history).

**iter962 Q1 used the CORRECT Trino-valid as-of pattern:**
```
SELECT product_id, price FROM (
  SELECT product_id, price, effective_date,
         ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY effective_date DESC) AS rn
  FROM price_history
  WHERE effective_date <= DATE '2026-01-01'
) WHERE rn = 1
```
- NO QUALIFY (subquery + outer `WHERE rn = 1` instead — the Trino-correct form).
- NO LAG (filter-to-cutoff-BEFORE-ranking is the genuine as-of pattern; LAG was correctly NOT reached for).
- Filter `effective_date <= DATE '2026-01-01'` applied BEFORE the window, then keep most-recent-per-product via `ROW_NUMBER() DESC = 1`. TRACE: product P with rows Dec-1-2025 ($10), Jan-1-2026 ($12), Feb-1-2026 ($15) → cutoff filter keeps Dec-1 & Jan-1; DESC rank → Jan-1 ($12) = rn 1 = correct price in effect as-of Jan 1. CORRECT.

**DISPOSITION FOR ORCHESTRATOR: the iter961 Q1 QUALIFY-parse + LAG-not-as-of slip is a CONFIRMED ONE-OFF responder synthesis miss. The re-probe is CLEAN. Resources teach the opposite extensively (r23 QUALIFY-not-Trino canonical, r27 §7A.2 QUALIFY landmine, max_by/as-of idioms). No resource defect, no findability gap. Do NOT churn QUALIFY/as-of content (adjacent over-attraction risk per feedback_new_card_over_attracts_adjacent.md).**

---

## Per-Q scores

### Q1 (price AS OF Jan 1) — 4.6875 (Acc 5 / Comp 4.75 / Clar 4.75 / Act 4.25)
Textbook-correct as-of. Filter-before-rank + ROW_NUMBER()=1 subquery; correctly labeled the "first row per group" canonical. No QUALIFY, no LAG. Clean clear explanation of why filter-before-rank gives the as-of price. Minor: did not note tie-on-effective_date edge (two prices same date → ROW_NUMBER picks one arbitrarily) but that's a trivial edge for this question.

### Q2 (% of category revenue from single biggest product) — 4.0 (Acc 4.25 / Comp 4.25 / Clar 3.0 / Act 4.5)
Final forms CORRECT: 3-CTE form (product_revenue / RANK() ranked_products / category_totals → JOIN → WHERE rank=1 → ROUND(100.0*revenue/total,2)) and single-pass `ROUND(100.0 * SUM(revenue) FILTER (WHERE rank=1) / SUM(revenue), 2) ... GROUP BY category`. VERIFIED: FILTER(WHERE) supported on all aggregates (functions/aggregate.html); 100.0 decimal promotion standard; RANK() valid.

Two knocks:
- **CLARITY ding: visible thinking-out-loud churn.** Showed a `SUM(CASE WHEN rank=1...)` form, wrote "Wait — that's overcomplicating it," then pivoted. Messy stream-of-consciousness in a delivered answer; reader has to discard a false start. NOT an accuracy issue (the discarded form wasn't wrong per se), purely presentation.
- **ACCURACY minor: RANK() vs ROW_NUMBER() TIE risk.** VERIFIED vs functions/window.html: RANK() assigns the SAME rank to tied rows. If two products TIE for top revenue in a category, both get rank=1, and `SUM(revenue) FILTER (WHERE rank=1)` sums BOTH — slightly OVER-stating "single biggest product's share." For "single biggest" strictly, ROW_NUMBER() (unique, picks one) is the safer choice; RANK() answers "co-top products' share." Minor because exact-revenue ties are rare and arguably "co-top" is defensible — NOTED not heavily penalized.

### Q3 (users active on BOTH web AND mobile in last 30 days) — 3.625 (Acc 4.5 / Comp 2.0 / Clar 4.0 / Act 4.0)
Logic CORRECT for both-platforms: `GROUP BY user_id HAVING COUNT(DISTINCT platform) = 2` (single-arg COUNT(DISTINCT) valid 467; HAVING after aggregation valid). Correctly framed as the avoid-two-subqueries-and-join answer; IN-subquery-to-recover-sessions form + "IN = semi-join" note both correct.

- **COMPLETENESS MISS (-): DROPPED the explicit "last 30 days" filter.** The question says "active on both web AND mobile **in the last 30 days**." The answer counts ALL-TIME both-platform users, not last-30-days. Missing `WHERE session_start >= current_date - INTERVAL '30' DAY` (or equivalent on the sessions timestamp column). A user who used web 2 years ago and mobile today would be wrongly included. This is a real semantic miss — the answer solves a slightly different question than asked. The COUNT(DISTINCT platform)=2 logic is correct, but the answer is INCOMPLETE without the date predicate.

### Q4 (avg tenure days, active employees, Trino vs Postgres gotchas) — 4.6875 (Acc 5 / Comp 4.75 / Clar 4.75 / Act 4.25)
`SELECT AVG(date_diff('day', hire_date, current_date)) AS avg_tenure_days FROM employees WHERE end_date IS NULL`. ALL gotcha claims VERIFIED vs functions/datetime.html:
- date_diff is unit-first: `date_diff('day', a, b)` with quoted unit then two args — CONFIRMED.
- current_date / current_timestamp are keywords with NO parens; `current_date()` WITH parens is INVALID — CONFIRMED ("SQL-standard functions do not use parenthesis").
- AVG skips NULL hire_date — correct (aggregates ignore NULLs).
- date_diff preferred over raw timestamp subtraction / to_unixtime for readability + DST — sound.
- CAST-to-DOUBLE variant — fine.
Clean and accurate; the Postgres-contrast framing (no `current_date()`, unit-first not `age()`) is exactly the kind of dialect gotcha the question wanted.

---

## Scope notes
- Q1: iter961 QUALIFY/LAG-as-of slip CONFIRMED ONE-OFF — re-probe clean. No action.
- Q2: correct final forms; CLARITY ding for visible "Wait — overcomplicating it" churn (messy-thinking presentation, NOT a resource defect); RANK()-vs-ROW_NUMBER() tie over-count is a minor NOTED accuracy nuance (ties rare/co-top defensible). Per-instance, NOT a resource fix.
- Q3: COUNT(DISTINCT platform)=2 logic correct BUT dropped the question's "last 30 days" date filter — real COMPLETENESS miss. Single-instance responder omission (dropped a stated constraint), consistent with the broken-secondary/incomplete-synthesis meta-pattern family (iter936/943/948/950/954/958/959/960/961). NOT a resource/findability gap — the date-filter pattern is taught extensively (every recent INTERVAL '30' DAY probe passed). Re-probe-don't-churn: re-probe a both-conditions Q with an explicit recency window next sweep to confirm one-off.
- Q4: clean and accurate; all dialect gotchas verified.
- NO resource defect / NO findability gap this sweep.

## RECOMMENDATION = DEFAULT NO-OP
Overall 4.328 PASS, margin +0.828. iter961 Q1 slip confirmed one-off (the headline outcome). Q2 churn and Q3 dropped-constraint are per-instance Haiku synthesis/presentation slips against correct, findable resources — no single resource fix; adding content risks adjacent over-attraction. NEXT SWEEP PROBES: re-probe a both-conditions-WITH-recency-window Q (confirm Q3 dropped-30-day-filter is one-off — verify responder carries ALL stated constraints into the query); RANK-vs-ROW_NUMBER "single top" with a deliberate tie (confirm responder picks ROW_NUMBER for strict single); window-frame BETWEEN N PRECEDING AND N FOLLOWING; GROUPING SETS/ROLLUP/CUBE; lateral JOIN UNNEST. Do NOT re-probe gaps-and-islands streak-construction. Federation (4.49944/310) bulletproofed angles only.

PINS REINFORCED:
- **as-of / point-in-time = filter ts <= cutoff BEFORE ranking, then ROW_NUMBER() OVER (PARTITION BY key ORDER BY ts DESC) = 1 in a SUBQUERY (NO QUALIFY — parse error in 467; NO LAG — LAG returns the preceding CHANGE not the state-in-effect). iter961 QUALIFY/LAG-as-of slip CONFIRMED ONE-OFF.**
- **RANK() assigns SAME rank to tied rows (functions/window.html) — for STRICT "single biggest" use ROW_NUMBER() (unique); RANK()=1 FILTER-share OVER-states on a top-revenue tie (co-top); ROW_NUMBER() picks exactly one.**
- **FILTER (WHERE cond) supported on ALL aggregates (functions/aggregate.html); 100.0 * x / y forces decimal/double promotion.**
- **COUNT(DISTINCT platform) = 2 (single-arg) for "active on both of two platforms" via GROUP BY user HAVING — BUT carry the question's recency window: WHERE <ts_col> >= current_date - INTERVAL '30' DAY; dropping a stated time filter answers all-time not last-30-days.**
- **date_diff('day', a, b) unit-first; current_date / current_timestamp keywords NO parens, current_date() WITH parens INVALID (functions/datetime.html); AVG ignores NULL; date_diff preferred over raw ts subtraction for readability/DST.**
- **default NULLS LAST in 467.**

DO NOT TOUCH (hard-locked): r22 §13.x federation / r23 QUALIFY-not-Trino canonical + argmax + COUNT(DISTINCT) + HAVING-vs-WHERE + regexp_like + fan-out card + geometric/harmonic mean + percentile/percentile_cont footgun cards / r07 L3226-3263 B-Streak defang + L37 HAVING-perf + L1624 anti-nesting / r09 partition DDL strings + bucket(col,N) column-first / r28 DATE-literal + UnwrapDateTruncInComparison / r13 json_exists strict path + 'partitioning' Iceberg key / r27 QUALIFY landmine §7A.2 / INTERVAL qualifier cards / format_datetime-vs-to_char / NULLS-LAST default / price-suffix canonical / MAX_BY-nested defang. PIN 467. DO NOT bump training/state.json (already 962; passed=true; final_iterations_remaining 0).
