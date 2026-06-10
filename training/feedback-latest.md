# iter950 Judge Feedback — DEFAULT NO-OP DURABILITY SWEEP (teacher ZERO edits)

**Date**: 2026-06-10
**Phase**: extended
**Sweep type**: DEFAULT NO-OP durability sweep — 4 fresh Qs covering JOIN+GROUP BY (Q1), date-range count (Q2), top-spender-per-country (Q3 — argmax-per-group with explicit "avoid subquery mess" framing), and per-carrier shipment duration (Q4); teacher made ZERO resource edits.
**Overall**: 4.40625 PASS | **Margin**: +0.90625 | **Federation NOT probed** (4.49944/310 row unchanged)
**Dialect verification source**: trino.io/docs/467 (functions/aggregate.html, functions/window.html, functions/datetime.html, sql/select.html) + WebFetch + WebSearch 2026-06-10 — NOT against resources/. Verify-BOTH-directions discipline (iter882).

---

## Per-question scores

### Q1 — AVG items per product category (subqueries feel overcomplicated) — 5.00
(Acc 5 / Comp 5 / Clar 5 / Act 5)
- `SELECT p.category, AVG(oi.quantity) AS avg_items_per_order FROM products p JOIN order_items oi ON p.product_id=oi.product_id GROUP BY p.category` — clean two-level GROUP BY, no subquery; VERIFIED valid 467 (functions/aggregate.html AVG ignores NULL; sql/select.html JOIN+GROUP BY canonical).
- `HAVING COUNT(*) >= 10` variant is a legitimate group-count output filter, NOT the "HAVING trims memory" folklore — pedagogy correct.
- Addresses user's "subqueries are overcomplicated" framing with the simplest canonical shape.

### Q2 — Count orders per status MORE THAN 7 DAYS OLD — 5.00
(Acc 5 / Comp 5 / Clar 5 / Act 5)
- `WHERE created_at < current_date - INTERVAL '7' DAY GROUP BY status` — VERIFIED valid 467; DAY is one of the six valid INTERVAL qualifiers per SqlBase.g4 (YEAR/MONTH/DAY/HOUR/MINUTE/SECOND only — QUARTER/WEEK would be PARSE errors); current_date - INTERVAL → DATE.
- TIMESTAMP `created_at` < DATE expression: DATE→TIMESTAMP coercion EXISTS in 467 (TypeCoercion.java; per pinned `reference_trino_timestamp_tz_coercion.md`) — responder's "Trino handles TIMESTAMP-vs-DATE type mixing" claim is ACCURATE, not a type error.
- `current_timestamp` variant for TIMESTAMP `created_at` valid alternative — both forms correct.

### Q3 — Top-spending customer per country (avoid "subquery mess") — 2.625
(Acc 2.0 / Comp 3.0 / Clar 3.5 / Act 2.0)

**THE KEY DEFECT — Q3 NESTED-AGGREGATE VERDICT (verified BOTH directions):**

(a) **Approach 1 (ROW_NUMBER) is CORRECT** ✓
- Inner: `GROUP BY c.country, c.customer_id` with `SUM(o.amount) AS total_spend` and `ROW_NUMBER() OVER (PARTITION BY c.country ORDER BY SUM(o.amount) DESC) AS spend_rank` — VALID 467.
- Window functions run AFTER GROUP BY/aggregation per functions/window.html ("they run after the HAVING clause but before the ORDER BY clause"). By the time ROW_NUMBER evaluates, `SUM(o.amount)` is already an aggregate result — ordering by it is legal, this is NOT a nested-aggregate situation.
- Outer `WHERE spend_rank = 1` picks top customer per country. Textbook canonical argmax-per-group shape.

(b) **Approach 2 (MAX_BY alternative) is INVALID — nested aggregation error** ✗
- Written form: `SELECT c.country, MAX_BY(c.customer_id, SUM(o.amount)) AS top_customer_id, MAX(SUM(o.amount)) AS top_spend FROM customers c JOIN orders o ON c.customer_id=o.customer_id GROUP BY c.country`.
- `SUM(o.amount)` is being passed as an ARGUMENT to `MAX_BY(...)` and `MAX(...)` at a SINGLE GROUP BY level (`GROUP BY c.country` only — no per-customer aggregation step exists). This is a nested-aggregation pattern Trino does NOT allow — would throw a "Cannot nest aggregations inside aggregation" / "expression contains aggregations" planner error and NOT execute.
- The correct max_by-per-group form requires TWO LEVELS:
  - Inner CTE: `GROUP BY country, customer_id` computing `SUM(amount) AS total_spend`.
  - Outer: `GROUP BY country` with `max_by(customer_id, total_spend)` + `max(total_spend)` (key is now a plain pre-aggregated column, not a nested aggregate).
- A reader copying Approach 2 verbatim ships broken SQL that fails at plan time. The user explicitly asked to avoid subquery mess, and Approach 2 is presented as the *cleaner* alternative — making the broken option especially copy-attractive.

**DEFECT SCOPING**: This is the recurring **"correct lead + broken secondary form"** family (iter936 / iter943 / iter944 / iter948 Q4). Approach 1 (the lead) is correct, the alternative is silently broken. 1st-instance for the specific `MAX_BY(x, SUM(...))` single-level form; Nth instance overall for the family.

**DISPOSITION**: RESPONDER SLIP. Resources teach two-level argmax-per-group correctly elsewhere; no resource defect surfaced (this is synthesis from generic aggregate primitives, not a misread of a canonical card). RE-PROBE-DON'T-CHURN.

### Q4 — AVG time between shipped_at and delivered_at per carrier — 5.00
(Acc 5 / Comp 5 / Clar 5 / Act 5)
- `AVG(date_diff('day', shipped_at, delivered_at))` + `AVG(date_diff('hour', shipped_at, delivered_at))` — VERIFIED valid 467 per functions/datetime.html (`date_diff(unit, timestamp1, timestamp2) → bigint`; day/hour valid units; day-aware/complete-units per pinned `reference_trino_datediff_dayaware.md`).
- `CAST(date_diff('hour',...) AS decimal) / 24.0` fractional-days variant valid (avoids integer truncation).
- `date_diff('hour',...) % 24` remainder variant valid (`%` operator on bigint valid 467).
- Correctly AVOIDS timestamp-minus-timestamp — no `delivered_at - shipped_at` Postgres-import (467 has no `TIMESTAMP - TIMESTAMP → INTERVAL` operator).

---

## Overall

- Per-Q: 5.00 / 5.00 / 2.625 / 5.00 = 17.625 / 4 = **4.40625 PASS** (margin +0.90625). Q3 broken-alternative drags but the overall average governs (no per-Q veto per iter949 doctrine), and Q3's lead (Approach 1) is correct.

---

## iter951 RECOMMENDATION

**DEFAULT NO-OP / RE-PROBE-DON'T-CHURN**

- Teacher should remain ZERO-edit / NO-OP.
- **Do NOT** add a `MAX_BY(x, SUM(...))` nested-aggregate defang card — 1st-instance for this exact form; defang-DO-NOT-WRITE backfire risk (`feedback_defang_donotwrite_snippets.md`) + New-Card-over-attracts-adjacent risk in dense argmax/max_by/ROW_NUMBER neighborhood; resources teach the correct two-level pattern elsewhere.
- **Do NOT** touch r07 L37 (HAVING-perf reword, iter948 FIX-A holding), federation row, percentile cards, PARTITIONED-BY guidance, INTERVAL qualifier cards, COUNT(DISTINCT) single-arg pin.
- **RE-PROBE Q3 next sweep** with a fresh argmax-per-group / "top X per Y" question (e.g., "highest revenue product per region", "most recent order per customer with amount", "top 3 cities per country by population") to verify responder leads with the correct two-level shape AND, if presenting a max_by alternative, structures it with the inner per-entity SUM CTE (NOT a nested aggregate at single GROUP BY level).
- **Escalate to LIGHT FIX-A** (additive two-level max_by canonical card with WRONG-mark on single-level nested form) ONLY if the nested-aggregate-in-max_by slip recurs in 2+ further sweeps without intervening clean answer.

## PINS REINFORCED

- **Nested aggregation ILLEGAL** at a single GROUP BY level: `MAX_BY(x, SUM(y))`, `MAX(SUM(y))`, `SUM(COUNT(*))`, etc. are planner errors ("Cannot nest aggregations inside aggregation"). Correct argmax-per-group = (a) ROW_NUMBER()=1 in subquery OR (b) two-level aggregation (inner per-entity SUM CTE, outer max_by(entity, total) at coarser group).
- **Window function ORDER BY CAN reference an aggregate of the grouped query** — window runs AFTER GROUP BY/HAVING per functions/window.html, so `ROW_NUMBER() OVER (PARTITION BY country ORDER BY SUM(amount) DESC)` with `GROUP BY country, customer_id` is VALID.
- `max_by(x, key)` / `min_by(x, key)` valid when `key` is a plain column or pre-aggregated value, NOT a nested aggregate.
- `date_diff(unit, earlier, later) → bigint` day-aware/complete-units; no `TIMESTAMP - TIMESTAMP` operator in 467.
- INTERVAL qualifiers: only YEAR/MONTH/DAY/HOUR/MINUTE/SECOND per SqlBase.g4 (QUARTER/WEEK → PARSE errors).
- DATE→TIMESTAMP coercion EXISTS (TypeCoercion.java); TIMESTAMP→TIMESTAMP_WITH_TIME_ZONE also exists (iter916 pin).
- AVG ignores NULL natively; GROUP BY repeats expr/ordinal not alias; HAVING-on-aggregate is canonical group-count filter, NOT a memory optimization (r07 L37 reworded iter948).
- Federation (4.49944/310) only un-passed row — bulletproofed angles only.

PIN 467. DO NOT bump training/state.json (orchestrator handles).
