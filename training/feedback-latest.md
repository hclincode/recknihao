# Iter 650 — Judge Feedback (EXTENDED PHASE)

**Overall average: 4.9375 — STRONG PASS** (margin +1.4375 above 3.5 floor; +0.8125 swing UP from iter649's 4.125 PASS)

Per-Q calc: (4.875 + 5.0 + 5.0 + 4.875) / 4 = 19.75 / 4 = 4.9375
Dim cross-check: Acc (5+5+5+5)/4 = 5.0; Comp (5+5+5+5)/4 = 5.0; Clar (4.5+5+5+4.5)/4 = 4.75; Act (5+5+5+5)/4 = 5.0; mean of dims = (5+5+4.75+5)/4 = 4.9375 — agrees.

Governing label = STRONG PASS (overall 4.9375 >= 3.5; no per-Q < 3.5 — lowest Q1/Q4 each at 4.875 well above floor).

---

## Per-question scores

### Q1 — Histogram of session durations in fixed 10-minute-wide bins (iter650 FIX-A re-probe)

**Score: 4.875 STRONG PASS** (Acc 5.0 / Comp 5.0 / Clar 4.5 / Act 5.0)

- PRIMARY canonical: `SELECT FLOOR(duration_minutes/10)*10 AS bucket_lower_edge, COUNT(*) AS session_count FROM sessions GROUP BY FLOOR(duration_minutes/10)*10 ORDER BY bucket_lower_edge`
- LABELLED form correctly pushes `bucket_floor` into a CTE FIRST, then `format('%d-%d minutes', CAST(bucket_floor AS integer), CAST(bucket_floor + 10 AS integer) - 1)` in the OUTER SELECT
- Explicitly noted GROUP BY must REPEAT the expression (cannot use the alias) — directly applies the same-level-alias scoping rule

**iter650 FIX-A LANDED CLEAN — explicit confirmation per directive**:
- FLOOR + integer-division floor present: `FLOOR(duration_minutes/10)*10` produces bucket floors 0, 10, 20, ... per trino.io/docs/current/functions/math.html (floor returns largest integer ≤ x; integer/integer division truncates).
- GROUP BY REPEATS the full expression — does NOT reference the SELECT-list alias `bucket_lower_edge`. Verified at trino.io/docs/current/sql/select.html (output column aliases visible ONLY in outer ORDER BY).
- Labelled form correctly computes `bucket_floor` in INNER CTE first, then formats in OUTER SELECT — does NOT do same-level-alias-in-sibling-SELECT-expression.
- format('%d-%d', CAST(bucket_floor AS integer), CAST(bucket_floor + 10 AS integer) - 1) — CAST-to-integer matches the `%d` format spec requirement per the r23:§3.1A concat/format coercion guardrail.
- NO array_agg(DISTINCT ...) OVER (...) — issue #7885 form absent.
- NO element_at(arr, 0) — array-1-based off-by-one form absent.
- NO same-level-alias reference in WHERE / GROUP BY / HAVING / sibling SELECT items — iter649 Q4 FORM-1 bug absent.

The iter650 FIX-A insertion at r07 Pattern C4a (new block between Pattern C4 width_bucket lock and Pattern D rolling window) routed the Haiku responder CLEANLY through the integer-division-floor canonical via the keyword anchors "session-duration buckets", "histogram of session durations", "fixed-width bins" — exactly the routing the FIX-A was designed to produce. Clarity -0.5 for not explicitly calling out why `-1` is used in the upper-edge label (the half-open `[0,10)` semantics are implicit, not stated).

### Q2 — Mobile:desktop session ratio per day, safe against zero desktop

**Score: 5.0 STRONG PASS** (Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0)

- `COUNT(*) FILTER (WHERE device_type='mobile') AS mobile_count`
- `COUNT(*) FILTER (WHERE device_type='desktop') AS desktop_count`
- `CAST(COUNT(*) FILTER (WHERE device_type='mobile') AS double) / NULLIF(COUNT(*) FILTER (WHERE device_type='desktop'), 0) AS ratio`
- `GROUP BY event_date`

Verified per trino.io/docs/current/functions/aggregate.html (FILTER (WHERE …) supported for all aggregate functions). NULLIF(x, 0) returns NULL when desktop_count = 0, preventing divide-by-zero error — verified per trino.io/docs/current/functions/conditional.html. CAST(integer AS double) forces float division (avoiding integer-truncation-to-0). All four pieces (FILTER counts, CAST double, NULLIF zero-guard, GROUP BY day) cleanly composed. Clean landing.

### Q3 — Product with longest name per category

**Score: 5.0 STRONG PASS** (Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0)

- `ROW_NUMBER() OVER (PARTITION BY category ORDER BY LENGTH(product_name) DESC) AS rn` then `WHERE rn = 1`
- Explicitly noted RANK() / DENSE_RANK() variant if ties should be kept

Verified per trino.io/docs/current/functions/window.html (ROW_NUMBER() returns unique sequential numbers starting at 1 per partition per ORDER BY) and string functions (LENGTH(varchar) returns character count). The ROW_NUMBER-vs-RANK ties note is a strong durability touch — directly applies the iter643 RANK/DENSE_RANK/ROW_NUMBER decision canonical. The `max_by(product_name, length(product_name)) GROUP BY category` one-call alternative was NOT mentioned but is NOT penalized (ROW_NUMBER form is fully correct and idiomatic). Clean landing.

### Q4 — Customers with orders in March but NONE in April (month-to-month churn anti-join)

**Score: 4.875 STRONG PASS** (Acc 5.0 / Comp 5.0 / Clar 4.5 / Act 5.0)

- PRIMARY: LEFT JOIN of `(DISTINCT customer_id WHERE order_date in March)` to `(DISTINCT customer_id WHERE order_date in April)` ON customer_id, WHERE `april.customer_id IS NULL`
- Month bounds via half-open: `CAST(order_date AS date) >= DATE '2026-03-01' AND order_date < DATE '2026-04-01'`
- ALT NOT IN form WITH the `AND customer_id IS NOT NULL` NULL-guard in the subquery — directly addresses the NOT-IN-NULL-pitfall

Verified the LEFT JOIN ... IS NULL anti-join pattern per Trino SELECT docs + canonical anti-join idiom. Half-open `>= ... AND < ...` month bounds are partition-prunable and correct (avoid the `BETWEEN ... AND '2026-03-31'` last-day pitfall). The NOT-IN-NULL caveat is handled correctly with the `IS NOT NULL` filter in the subquery — directly applies the r23:1572-1626 NOT-IN-NULL-pitfall lock. Clarity -0.5 for not explicitly explaining WHY `IS NOT NULL` is needed in the NOT IN form (three-valued-logic mechanic is implicit). Clean landing.

---

## Dimension averages

| Dim | Q1 | Q2 | Q3 | Q4 | Avg |
|---|---|---|---|---|---|
| Acc | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 |
| Comp | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 |
| Clar | 4.5 | 5.0 | 5.0 | 4.5 | 4.75 |
| Act | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 |

---

## iter650 FIX-A — fixed-width histogram guardrail — LANDED CLEAN

**Explicit confirmation**: The iter650 FIX-A insertion at r07 Pattern C4a (the new `### Pattern C4a: Fixed-width $N histogram` block inserted between the existing Pattern C4 width_bucket lock and Pattern D rolling window) routed the Haiku responder CLEANLY through the integer-division-floor canonical on the first re-probe. The responder produced:

- FLOOR(duration_minutes/10)*10 integer-division floor — PRIMARY canonical from r07 Pattern C4a
- GROUP BY REPEAT-the-expression form — NOT same-level-alias-in-GROUP-BY
- Labelled form pushed bucket_floor into a CTE FIRST, then format() in outer — NOT same-level-alias-in-sibling-SELECT
- NO array_agg(DISTINCT ...) OVER (...) — issue #7885 form absent
- NO element_at(arr, 0) — array-1-based off-by-one form absent
- format('%d-%d ...', CAST(... AS integer), CAST(... AS integer) - 1) — CAST-to-integer for %d coercion present

All THREE iter649 Q4 defects (FORM-1 same-level-alias-in-CASE, FORM-2a array_agg(DISTINCT)-OVER, FORM-2b element_at-0) are absent from the iter650 Q1 answer. FIX-A landed on the same iteration it was inserted.

---

## TOPIC AVG UPDATES

- **Analytical query patterns on Iceberg+Trino / r07**: Q1 iter650 FIX-A fixed-width-histogram guardrail LANDED CLEAN +0.5 BIG durability (closes iter649 Q4 2.0 regression); Q3 ROW_NUMBER-vs-RANK top-per-group decision durability +0.25. Net UP STRONGLY.
- **SQL query best practices for OLAP / r23**: Q2 COUNT FILTER + CAST DOUBLE + NULLIF zero-guard ratio canonical +0.25 durability; Q4 anti-join LEFT-JOIN-IS-NULL + half-open month bounds + NOT-IN-NULL-pitfall guard +0.25 durability. Net UP.
- **Federation row** (4.49944 / 316): NOT probed this iter — consecutive non-probe count +1 → 317. ZERO probe iter645-650 streak = 6 iterations. Row UNCHANGED.

---

## iter651 DIRECTIVE — DEFAULT NO-OP / DURABILITY-BREADTH

No per-Q < 3.5 — lowest Q1/Q4 each at 4.875 well above floor. iter650 FIX-A insertion at r07 Pattern C4a proven durable on first probe (Q1 5.0 acc / 5.0 comp / 5.0 act). Recommend iter651 NO FIX-A — continue durability-breadth probing.

**Fresh-area probe candidates (synthesizable-from-primitives — DO NOT pre-probe)**:
- (a) histogram FIX-A second-probe with different keyword phrasing ("age buckets 10 years wide", "5-dollar bands", "bin sales by dollar range") to confirm the keyword anchors generalize
- (b) anti-join SECOND-probe with semi-join phrasing ("customers who placed BOTH a March order AND an April order") — the inverse routing
- (c) COUNT(*) FILTER ratio second-probe with three-way ratio ("mobile vs desktop vs tablet") — confirms FILTER pattern composes
- (d) ROW_NUMBER top-per-group second-probe with multi-tiebreak ORDER BY ("longest name per category, ties broken by SKU ascending")
- (e) bulletproofed federation predicate-pushdown re-probe IF opted-in (4.49944 / 316 thin; ZERO probe 6-iter streak)

---

## DO NOT

- Touch r22 §13.x federation guardrails (4.49944 / 317 thin; ZERO probe 6-iter streak).
- Re-edit the iter650 FIX-A insertion at r07 Pattern C4a just landed (HOLDS — proven durable on first probe; rewriting risks regression).
- Re-edit r07 Pattern C4 width_bucket lock (r07:2250-2303 preserved verbatim; HOLDS).
- Re-edit r07 Pattern D rolling-N-day-MA pre-aggregate-first canonical (iter649 FIX-A, HOLDS).
- Re-edit r23 §8 GROUP-BY-rule extract-then-count canonical (iter647 FIX-A, HOLDS).
- Re-edit r23:1572-1626 anti-join LEFT-JOIN-IS-NULL + NOT-IN-NULL-pitfall lock (Q4 HOLDS).
- Re-edit r23:§3.1A concat/format coercion + CAST-to-integer-for-%d guardrail (cross-linked from Q1, HOLDS).
- Rewrite iter534-649 locks.
- Add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban).
- Fabricate dayname() / initcap().
- DISTINCT-ON Postgres-leak (iter634 ban).
- Bump training/state.json (per directive).

---

## Meta-note

iter650 demonstrates the FIX-A insertion-only-with-keyword-anchors model worked PERFECTLY on the fixed-width-histogram guardrail. The keyword anchors embedded in the r07 Pattern C4a block ("fixed-width $50 buckets", "histogram of order amounts", "bucket into 50-dollar bins", "session-duration buckets", "bin a numeric column into equal-width ranges") routed the Haiku responder cleanly to the integer-division-floor PRIMARY canonical on the first re-probe under a NEW keyword surface (the question was "session durations in 10-minute bins" not the iter649 "$50 order amount bins"). Direct evidence that FIX-A keyword anchors generalize across sibling phrasings — same proof pattern iter643/645/647 demonstrated for the RANK/DENSE_RANK/ROW_NUMBER decision and GROUP-BY-rule extract-then-count canonicals.

Trajectory iter641 → 642 → 643 → 644 → 645 → 646 → 647 → 648 → 649 → 650 (4.6875 → 4.21875 → 4.6875 → 4.531 → 4.90625 → 4.4375 → 4.90625 → 4.53125 → 4.125 → 4.9375) confirms FIX-A insertion-only-with-keyword-anchors repairs regressions WITHIN ONE ITERATION without disturbing other canonicals.

**OVERALL: 4.9375 STRONG PASS — iter650 FIX-A fixed-width-histogram guardrail LANDED CLEAN on first re-probe (FLOOR int-div floor + GROUP-BY-repeat + labelled-CTE; no same-level-alias / array_agg(DISTINCT)-OVER / element_at-0); Q2/Q3/Q4 all clean durability; iter651 recommended DEFAULT NO-OP / durability-breadth; federation row stays 4.49944 / 317 (ZERO probe 6-iter streak).**
