# iter951 Judge Feedback (RE-PROBE sweep; teacher made ZERO resource edits)

**Date**: 2026-06-10
**Phase**: extended
**Overall: 4.21875 PASS** (per-Q Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 1.875 = 16.875/4 = 4.21875; margin +0.71875; OVERALL AVERAGE governs, no per-Q veto)

Dialect verified vs trino.io/docs/467 (sql/select.html, functions/window.html, functions/datetime.html) via WebFetch 2026-06-10 — NOT against resources/. iter882 verify-BOTH-directions discipline.

FEDERATION NOT PROBED (4.49944/310 row UNCHANGED).

---

## Q1 — Best-selling product per category — 5.00 (Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0)

```sql
WITH product_sales AS (
  SELECT p.category, oi.product_id, SUM(oi.quantity) AS total_units
  FROM order_items oi JOIN products p ON p.product_id = oi.product_id
  GROUP BY p.category, oi.product_id
),
ranked AS (
  SELECT category, product_id, total_units,
         ROW_NUMBER() OVER (PARTITION BY category ORDER BY total_units DESC) AS rn
  FROM product_sales
)
SELECT category, product_id, total_units FROM ranked WHERE rn = 1;
```

**RE-PROBE VERDICT — iter950 Q3 nested-max_by SLIP = ONE-OFF / SLIP CLOSED.** Responder LED with the CORRECT two-level argmax-per-group shape: pre-aggregate SUM(quantity) per (category, product_id) in inner CTE, THEN ROW_NUMBER() PARTITION BY category ORDER BY total_units DESC in second CTE, outer WHERE rn=1. NO single-level `MAX_BY(product_id, SUM(quantity)) GROUP BY category` nested-aggregate footgun appeared. ROW_NUMBER over a pre-aggregated CTE referencing the SUM as a plain column is VALID 467 per sql/select.html (window functions evaluate over the result set after GROUP BY/HAVING). Ties get an arbitrary single winner — acceptable for "single top product/category"; if ties matter RANK()=1 returns all tied winners (natural follow-up). Clean textbook.

iter950 Q3 single-level MAX_BY(x, SUM(y)) nested-aggregate slip CONFIRMED 1st-instance one-off. Argmax/max_by/ROW_NUMBER neighborhood (r07 L832/L2179/L3698-3717/L3764/L4743 + r23 L1355-1372/L1732-1820 + GROUP-BY anti-nesting r07 L1624) durable and applied correctly. No FIX-A needed.

---

## Q2 — Customers with NO orders in last 6 months (incl. never-ordered) — 5.00 (5.0/5.0/5.0/5.0)

```sql
SELECT c.customer_id, c.customer_name
FROM customers c
LEFT JOIN orders o
  ON c.customer_id = o.customer_id
 AND o.created_at >= current_timestamp - INTERVAL '6' MONTH
WHERE o.customer_id IS NULL;
```

**Anti-join shape correct.** Date predicate `o.created_at >= current_timestamp - INTERVAL '6' MONTH` is in the **ON clause** (not WHERE), which is the canonical anti-join-preserving shape: the LEFT JOIN keeps every customer row, and the right side matches ONLY recent orders. WHERE `o.customer_id IS NULL` then keeps customers with no qualifying recent orders — BOTH never-ordered (no rows existed) AND ordered-before-but-not-recently (rows existed but failed the date predicate in ON) survive correctly.

Critical correctness contrast: putting the date predicate in WHERE (`WHERE o.created_at >= ... AND o.customer_id IS NULL`) breaks the anti-join — `o.created_at` IS NULL for never-ordered customers, `NULL >= ...` evaluates UNKNOWN, drops them. Responder placed the predicate correctly.

INTERVAL '6' MONTH valid qualifier per SqlBase.g4 (YMD-HMS only). `current_timestamp - INTERVAL '6' MONTH` returns TIMESTAMP per datetime.html operator table (verified WebFetch 2026-06-10: timestamp minus interval example documented). NOT IN nullable-trap warning correct (NULL customer_id in subquery makes `customer_id NOT IN (SELECT ...)` return UNKNOWN for every outer row → empty result; classic 3VL footgun). Clean textbook.

---

## Q3 — Products with ZERO reviews — 5.00 (5.0/5.0/5.0/5.0)

```sql
SELECT p.product_id, p.product_name
FROM products p
LEFT JOIN product_reviews pr ON p.product_id = pr.product_id
WHERE pr.product_id IS NULL;
```

Canonical anti-join for "rows in A with no matching rows in B." LEFT JOIN preserves all products; WHERE `pr.product_id IS NULL` keeps only unmatched (= zero-review) products. Responder correctly warned that INNER JOIN drops unreviewed products entirely (wrong semantics) and that `NOT IN (SELECT product_id FROM product_reviews)` is unsafe if product_reviews.product_id is nullable (3VL trap). Clean textbook.

---

## Q4 — Failed-attempts streak before each success — 1.875 (Acc 1.5 / Comp 2.0 / Clar 2.5 / Act 1.5) — LOGIC BUG / ALWAYS-ZERO DEFECT

```sql
WITH events_flagged AS (
  SELECT user_id, event_type, event_timestamp,
         CASE WHEN LAG(event_type) OVER (PARTITION BY user_id ORDER BY event_timestamp) = 'success'
              THEN 1 ELSE 0 END AS is_new_streak
  FROM login_events
),
streaks AS (
  SELECT user_id, event_type, event_timestamp,
         SUM(is_new_streak) OVER (PARTITION BY user_id ORDER BY event_timestamp) AS streak_id
  FROM events_flagged
)
SELECT user_id, event_timestamp,
       SUM(CASE WHEN event_type = 'failed' THEN 1 ELSE 0 END) AS failed_attempts_before_success
FROM streaks
WHERE event_type = 'success'
GROUP BY user_id, event_timestamp, streak_id;
```

**Q4 LOGIC-BUG VERDICT — CONFIRMED ALWAYS-ZERO FILTER-THEN-COUNT-THE-FILTERED-OUT-TYPE DEFECT.**

Traced on the prompt's example F,F,S,F,S,F,F,F,S for one user:

| event | LAG(event_type) | is_new_streak | streak_id (running SUM) |
|---|---|---|---|
| F | NULL | CASE WHEN NULL='success' → UNKNOWN → ELSE 0 | 0 |
| F | F | 0 | 0 |
| S | F | 0 | 0 |
| F | S | 1 | 1 |
| S | F | 0 | 1 |
| F | S | 1 | 2 |
| F | F | 0 | 2 |
| F | F | 0 | 2 |
| S | F | 0 | 2 |

Streaks: {F,F,S} (streak_id=0), {F,S} (streak_id=1), {F,F,F,S} (streak_id=2). **Layers 1+2 are structurally CORRECT** gaps-and-islands scaffolding — LAG-flag in one CTE, running-SUM streak_id in the next, no nested windows (cleanly separated per Trino's window-can't-reference-window-in-same-SELECT-expr rule).

**Layer 3 is the bug.** `WHERE event_type = 'success'` runs BEFORE GROUP BY per sql/select.html (verified WebFetch 2026-06-10: HAVING-filters-after-aggregation is the documented dual; WHERE filters input rows before groups are built). So only the 3 success rows reach the GROUP BY:
- (streak_id=0, 'success')
- (streak_id=1, 'success')
- (streak_id=2, 'success')

Then `SUM(CASE WHEN event_type='failed' THEN 1 ELSE 0 END)` over each one-row group = **0 for every success**. The failures were filtered out BEFORE being counted. Query RUNS as valid 467 SQL but returns 0 for every success — answers the wrong question (always-zero).

**Correct shape:** keep ALL rows through the per-streak aggregation, group by (user_id, streak_id), SUM failures per streak, then keep only streaks that END in a success. Example:

```sql
WITH ... -- layers 1+2 unchanged
per_streak AS (
  SELECT user_id, streak_id,
         SUM(CASE WHEN event_type = 'failed' THEN 1 ELSE 0 END) AS failed_count,
         MAX(CASE WHEN event_type = 'success' THEN event_timestamp END) AS success_ts
  FROM streaks
  GROUP BY user_id, streak_id
)
SELECT user_id, success_ts AS event_timestamp, failed_count AS failed_attempts_before_success
FROM per_streak
WHERE success_ts IS NOT NULL;
```

Several equivalent forms exist — the key is: aggregate first over the unfiltered streak, filter to success-ending streaks afterward.

**Side claim wrong.** Responder asserted "can't nest windows" as the reason for 3 layers. Trino 467 prohibits a window function referencing another window function in the SAME SELECT-list expression, but the 3-layer split is required here for ORDERING (running SUM must read the LAG-flag column), not for nesting prohibition. Pedagogical micro-defect, not a query bug.

**Scope: RESPONDER LOGIC SLIP on a complex gaps-and-islands SYNTHESIS.** This is NOT a dialect/syntax slip — the SQL is valid Trino 467 throughout. The B-Streak/gaps-and-islands pattern IS taught at r07 L3155, but this specific filter-then-count-the-filtered-out-type bug is a SYNTHESIS error at Layer 3 (the responder muddled "count failures per streak" with "show one row per success"). 1st-instance for this specific filter-then-count-wrong-type defect. PRIMARY (only) Q4 answer — a broken MAIN answer, not a broken secondary alternative.

Score rationale: Acc 1.5 (query runs but returns wrong answer for every row — semantic correctness FAIL, not parse error so not 1.0); Comp 2.0 (Layers 1+2 scaffolding correct, Layer 3 broken; no alternative offered); Clar 2.5 (clearly written, but the wrong-shape pedagogy compounds the slip — and the "can't nest windows" misframing is misleading); Act 1.5 (engineer who copies this ships a query that returns all-zeros and looks plausible — silent wrong result is the worst failure mode for analytics).

---

## Disposition & iter952 recommendation

**Pattern across the 4 Qs:**
- Q1 RE-PROBE CLEAN — iter950 Q3 nested-max_by slip ONE-OFF / SLIP CLOSED. Argmax/max_by/ROW_NUMBER neighborhood durable.
- Q2/Q3 textbook clean — anti-join + NOT-IN-nullable-trap pedagogy applied correctly.
- Q4 1st-instance filter-then-count-the-filtered-out-type LOGIC SLIP on a complex gaps-and-islands SYNTHESIS — valid SQL, wrong answer (always-zero).

**iter952 = DEFAULT NO-OP / RE-PROBE-DON'T-CHURN.** Reasoning:
1. Overall 4.21875 PASS — margin +0.71875.
2. Q1 RE-PROBE explicitly closes the iter950 slip. Argmax/two-level pattern is durable.
3. Q4 slip is a 1st-instance SYNTHESIS bug, not a findable resource gap. The gaps-and-islands pattern IS taught at r07 L3155; the WHERE-vs-HAVING-vs-aggregation-order rule IS reinforced at r07 L37 (iter948 LIGHT FIX-A) + r23 §8; aggregation-shape pins (filter-then-aggregate vs aggregate-then-filter) are pinned across the rubric. The bug is the responder muddling the OUTPUT SHAPE ("one row per success" vs "one row per streak") with the AGGREGATION SCOPE — not a missing primitive.
4. Adding a "filter-then-count-the-filtered-out-type" defang card on 1st-instance risks:
   - `feedback_new_card_over_attracts_adjacent.md` — dense gaps-and-islands / WHERE-vs-HAVING / per-streak-aggregation neighborhood; could pull adjacent sessionization / cohort / streak Qs to the wrong canonical.
   - `feedback_defang_donotwrite_snippets.md` — literal-WHERE-then-SUM-of-the-filtered-type wrong-form text surface area.
5. RE-PROBE Q4 next sweep via fresh "streak / gaps-and-islands / per-event consecutive-prior-of-other-type" Q (e.g., "for each successful payment, how many failed retries preceded it" / "for each session-end event, how many clicks in the session" / "for each shipped order, count the events leading up to it"). Verify responder leads with the CORRECT per-streak aggregation shape (aggregate over UNFILTERED streak, THEN filter to streaks ending in the target event), NOT filter-to-target-then-count-the-other-type.

**Escalation threshold:** dedicated FIX-A canonical card for the failed-attempts-before-success / gaps-and-islands per-streak-aggregation pattern requires 2+ further recurrences of the filter-then-count-the-filtered-out-type defect within the next ~5 sweeps WITHOUT intervening clean answer on an equivalent question. Until then: re-probe-don't-churn.

Do NOT touch: r07 L37 (HAVING-perf reword iter948 holds), r07 L3155 (gaps-and-islands pattern), r07 L1624 (anti-nesting), r23 §3.1G argmax canonical, federation row (4.49944/310), percentile cards, PARTITIONED-BY guidance, INTERVAL qualifier cards, COUNT(DISTINCT) single-arg pin.

---

## Pins reinforced

- **Two-level argmax-per-group canonical confirmed durable** (iter950 Q3 slip closed): inner CTE GROUP BY (group, entity) computing the metric → outer CTE ROW_NUMBER() PARTITION BY group ORDER BY metric DESC, WHERE rn=1. Equivalent: outer max_by(entity, metric) GROUP BY group when metric is a pre-aggregated plain column (NOT a nested aggregate).
- Window functions evaluate AFTER GROUP BY/HAVING per sql/select.html — ROW_NUMBER OVER (PARTITION BY ... ORDER BY agg_alias) over a grouped CTE is valid.
- **Anti-join canonical = LEFT JOIN ... WHERE right_col IS NULL**, with right-table date/scoping filters placed in the **ON clause** (NOT WHERE) to preserve never-matched rows. Date filter in WHERE breaks anti-join semantics for never-matched rows whose right-side timestamp is NULL.
- INTERVAL '6' MONTH valid per SqlBase.g4 (YMD-HMS qualifiers only; QUARTER/WEEK PARSE error in INTERVAL literals though valid as date_add/date_trunc unit strings — pinned `reference_trino_interval_qualifiers.md`).
- `current_timestamp - INTERVAL '6' MONTH` → TIMESTAMP valid per datetime.html operator table.
- NOT IN (SELECT nullable_col ...) 3VL trap: any NULL in subquery → UNKNOWN for every outer row → empty result. Use NOT EXISTS or LEFT JOIN IS NULL.
- **WHERE runs BEFORE GROUP BY / aggregation** per sql/select.html (HAVING-filters-after-aggregation is the documented dual). Filtering out a type with WHERE before aggregating that type = always-0 conditional-SUM bug.
- Gaps-and-islands = LAG-flag CTE + running-SUM streak_id CTE, separate layers (window-can't-reference-window in same SELECT expr). Layers 1+2 must NOT pre-filter — the per-streak aggregation in Layer 3 must run over the FULL streak (failures + ending success row), THEN filter to streaks ending in the target event.
- CASE WHEN NULL = 'literal' → UNKNOWN → ELSE 0 (first-row LAG-NULL handled correctly without explicit IS NULL guard).
- Window fn cannot reference another window fn in the same SELECT-list expression (the source of the "can't nest windows" colloquialism); resolved by separating into CTEs — but that's a syntax restriction not a logic-shape requirement.

Federation (4.49944/310) only un-passed row — bulletproofed angles only. PRESERVE full iter534-950 pin inventory; NO federation edits, NO percentile-card edits, NO PARTITIONED-BY defang card, NO INTERVAL-qualifier edits, NO HAVING-perf defang card, NO price-suffix canonical card, NO MAX_BY-nested defang card, NO gaps-and-islands-filter-shape defang card (1st-instance — RE-PROBE-DON'T-CHURN). PIN 467. DO NOT bump training/state.json (orchestrator does that; passed=true preserved; overall 4.21875 PASS holds).
