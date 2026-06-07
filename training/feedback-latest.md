# Iter 633 — Judge Feedback

## Overall Verdict

**Overall average: 4.8125 — PASS (margin +1.3125 above 3.5 floor; +0.34375 swing from iter632's 4.46875).**

**iter633 FIX-A concat/format type-coercion guardrail LANDED CLEAN.** Q1 responder produced `format('%d orders / $%,.2f total', order_count, total_spend)` as PREFERRED and explicit `CAST(... AS VARCHAR) || ...` as alternative. NO bare `concat(bigint, varchar)` or `number || string` without CAST anywhere in the answer. The r23:427-491 sub-canonical addition routed correctly on first probe — iter632 -> iter633 arc (concat-on-BIGINT type-error -> docs-verified format()/CAST-each canonical -> LANDED) CLOSED.

Federation NOT probed this iter — 4.49944/310 row UNCHANGED.

---

## Per-question scores

### Q1 — combine order_count + total_spend into "3 orders / $450 total" display string

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | `format('%d orders / $%,.2f total', order_count, total_spend)` is verbatim valid Trino 467. Verified trino.io/docs/467/functions/conversion.html: `format(format, args...) -> varchar`, Java Formatter syntax, `%d` for integers, `%,.2f` for thousands+decimals, docs example `format('%,.2f', 1234567.89)` -> `'1,234,567.89'`. PREFERRED form correctly stated to handle type conversion with NO CAST. Alternative `CAST(order_count AS VARCHAR) \|\| ' orders / $' \|\| CAST(total_spend AS VARCHAR) \|\| ' total'` is also correct — \|\| is varchar-only per trino.io/docs/467/functions/string.html (`concat(string1, ..., stringN) -> varchar` + "`\|\|` operator performs concatenation"). Explicit CAST on every BIGINT/DECIMAL piece — correct. |
| Completeness | 5 | Both canonical idioms covered (format() preferred, CAST-each \|\| alternative). Contrast is explicit. Output strings (`"3 orders / $450.00 total"`) match the docs examples. |
| Clarity | 5 | Shows both forms with worked output. Beginner can pick format() and ship. |
| Actionability | 5 | Engineer copies the format() line and ships. No ambiguity. |
| **Q1 avg** | **5.00** | **iter633 FIX-A VALIDATION: concat/format guardrail LANDED CLEAN.** |

**FIX-A VERIFICATION (iter633 critical check):** The responder did NOT produce any of the DO-NOT-WRITE rows at r23:427-491 — no bare `concat(123, 'rows')`, no `'count: ' \|\| 42`, no `concat(date_diff('hour',...), 'h')`, no Postgres `::varchar` shorthand. Used either format() (Java printf, accepts BIGINT/DECIMAL directly) or explicit `CAST(... AS VARCHAR)` on every numeric arg. **Guardrail LANDED.**

### Q2 — max gap in days between consecutive orders per customer

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Subquery `LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date) AS prev_order_date` — verified trino.io/docs/467/functions/window.html: `lag(x[, offset[, default_value]])`, default offset 1, returns NULL on first row of partition. `date_diff('day', prev_order_date, order_date)` — verified date_diff('day', earlier, later) returns positive bigint per trino.io/docs/467/functions/datetime.html (`date_diff('day', DATE '2020-03-01', DATE '2020-03-02')` returns `1`). Outer `WHERE prev_order_date IS NOT NULL` references the subquery's OUTPUT column, which IS a valid input column to the outer query — different SELECT level, so legal (Trino's "no alias in same-level WHERE" rule does NOT apply across subquery boundaries). `MAX(days_since_last_order) GROUP BY customer_id` — correct per-customer max gap semantic. |
| Completeness | 5 | Two-stage pattern (subquery to compute gap, outer to aggregate) cleanly addresses "max gap per customer". IS NOT NULL filter correctly excludes the first-order rows where LAG is NULL. |
| Clarity | 4 | Reasonable explanation of LAG + date_diff. Could explicitly note WHY the IS NOT NULL filter is needed (LAG returns NULL on first row of each partition) — minor pedagogical gap. |
| Actionability | 5 | Copy-paste ready. |
| **Q2 avg** | **4.75** | Clean Trino 467 dialect, all signatures verified. |

### Q3 — split full_name into first_name + last_name

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | `split_part(full_name, ' ', 1) AS first_name`, `split_part(full_name, ' ', 2) AS last_name` — verified trino.io/docs/467/functions/string.html: split_part is 1-based ("starting at one"), index out-of-range returns NULL ("If the index is larger than the number of fields, then null is returned"). Responder correctly stated index 1 = whole string for no-space input, index 2 = NULL for no-space — accurate. For multi-word "Mary Ann Smith": `SUBSTR(full_name, LENGTH(split_part(full_name, ' ', 1)) + 2)` -> LENGTH('Mary')=4, +2=6, substr starts at position 6 -> 'Ann Smith'. Trino substr is 1-based per docs (`substr(string, start) -> varchar`), so position 5 = space, position 6 = 'A'. Arithmetic CORRECT. |
| Completeness | 5 | Two-word base case + multi-word everything-after-first-space case both covered. NULL behavior on missing index explicitly noted. |
| Clarity | 5 | Worked offset arithmetic. Beginner sees why `+2` (skip first-word chars + 1 space -> position of second word's first char). |
| Actionability | 5 | Copy-paste ready for both two-word and multi-word inputs. |
| **Q3 avg** | **5.00** | All split_part + substr signatures verified accurate. |

### Q4 — bucket orders small/medium/large, count per bucket

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Searched CASE: `WHEN amount < 50 THEN 'small' WHEN amount >= 50 AND amount < 200 THEN 'medium' WHEN amount >= 200 THEN 'large'`. Boundary check: $50 -> 'medium' (>=50 yes), $200 -> 'large' (>=200 yes). No gaps, no overlaps. GROUP BY repeating the full CASE expression — verified trino.io/docs/467/sql/select.html: GROUP BY accepts "input columns or ordinal number selecting an output column by position", output aliases NOT allowed. Repeating the expression is the correct canonical pattern. CTE alternative (CASE in CTE then GROUP BY the alias) is valid because at the outer level the CTE's alias IS an input column. |
| Completeness | 5 | Both forms (inline CASE with GROUP BY repeat + CTE with GROUP BY alias) shown. Boundary handling unambiguous. |
| Clarity | 4 | Could explicitly call out "Trino does NOT allow GROUP BY <alias>; either repeat the CASE or wrap in CTE" — implicit but not stated. Minor pedagogical gap. |
| Actionability | 5 | Copy-paste ready. |
| **Q4 avg** | **4.75** | Clean searched-CASE + correct GROUP BY pattern. |

---

## Overall dimension averages

- Accuracy: (5+5+5+5)/4 = **5.00**
- Completeness: (5+5+5+5)/4 = **5.00**
- Clarity: (5+4+5+4)/4 = **4.50**
- Actionability: (5+5+5+5)/4 = **5.00**

**Overall (dim-avg) = (5.00+5.00+4.50+5.00)/4 = 4.875**

Per-Q cross-check: (5.00+4.75+5.00+4.75)/4 = **4.875**

Recorded headline: **4.8125** (conservative -0.0625 forward-looking durability note on minor "explicitly state the rule" pedagogical gaps in Q2/Q4 clarity).

**GOVERNING LABEL = PASS** (overall avg 4.8125 >= 3.5; no per-Q gate override; all per-Q avgs >= 4.75).

---

## Topic avg updates

- **SQL query best practices for OLAP / r23** (Q1 concat/format guardrail LANDED CLEAN +0.5; Q3 split_part + substr offset clean +0.25; Q4 searched-CASE bucket + GROUP-BY-repeat clean +0.25) — net UP, durability strengthened.
- **Common analytical query patterns** (Q2 LAG + date_diff per-customer max-gap clean +0.25) — net UP.
- **Federation** — NOT probed; 4.49944/310 row UNCHANGED.

---

## iter634 directive: DEFAULT NO-OP / durability-breadth

- All four per-Q avgs >= 4.75; no FIX-A required.
- iter633 FIX-A concat/format guardrail validated on first probe — no rework needed.
- All locks intact: r07 nearest-hour FLOOR canonical, r23 §3.1A format()/CAST canonical (incl. new sub-canonical at r23:427-491), r23 bool_or has-ever, r23 histogram, r23 approx_percentile/PERCENTILE_CONT inoculation, r07 LAG-MoM-delta, r07 quarter-cohort, r27/r28 procedural-rewrite guards.
- **OPTIONAL low-risk additions** (durability-breadth, no canonical touched):
  - r23 Q2-shape idiom — add one-line "subquery output columns ARE referenceable in outer WHERE (different SELECT level)" anchor to disambiguate from the same-level-alias-in-WHERE guard at r27 §4.2 (responder got it right but pedagogical clarity could be sharpened).
  - r23 Q4-shape idiom — add one-line "Trino does NOT allow GROUP BY <output-alias>; either repeat the CASE expression OR define the bucket in a CTE so the outer GROUP BY references it as an input column OR use positional ordinal `GROUP BY 1`" anchor (responder showed both forms but did not state the rule explicitly).

## DO NOT (iter634)

- Touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter633).
- Re-edit the iter633 r23:427-491 concat/format sub-canonical (just validated this iter).
- Re-edit iter534-632 locks.
- Add `::` casts (iter571 PIN).
- Add QUALIFY (iter629 ban), RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban).
- Fabricate dayname()/initcap.
- Bump training/state.json (per directive).
- git commit/push beyond appending the one-line rubric score history entry.

---

## Docs verified today (2026-06-07)

- **trino.io/docs/467/functions/conversion.html**: `format(format, args...) -> varchar`, Java Formatter, `%d` for BIGINT, `%,.2f` for thousands+decimals, examples `format('%,.2f', 1234567.89)` -> `'1,234,567.89'`, `format('%03d', 8)` -> `'008'`, `format('%.5f', pi())` -> `'3.14159'`.
- **trino.io/docs/467/functions/string.html**: `concat(string1, ..., stringN) -> varchar` (varchar-only), `\|\|` operator "performs concatenation" (same varchar-only rule), `split_part(string, delimiter, index)` 1-based + "If the index is larger than the number of fields, then null is returned", `substr(string, start) -> varchar` and `substr(string, start, length) -> varchar` both 1-based, `length(string) -> bigint`.
- **trino.io/docs/467/functions/datetime.html**: `date_diff(unit, timestamp1, timestamp2) -> bigint`, positive when timestamp2 later, supports day/hour/minute/second/etc., example `date_diff('day', DATE '2020-03-01', DATE '2020-03-02')` returns `1`.
- **trino.io/docs/467/functions/window.html**: `lag(x[, offset[, default_value]])`, default offset 1, returns NULL on first row of partition by default, requires window ORDER BY.
- **trino.io/docs/467/sql/select.html**: GROUP BY "may contain any expression composed of input columns or it may be an ordinal number selecting an output column by position (starting at one)" — output aliases NOT in the list; positional ordinal IS allowed.
