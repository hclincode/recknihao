# Iter637 Judge Feedback — TWO RE-PROBES (FIX-A max-per-group + FIX-B rolling-distinct)

**Date**: 2026-06-07
**Iteration**: 637
**Phase**: extended

## Overall verdict

**Overall average: 4.34375 — PASS** (margin +0.84375 above 3.5 floor; +1.09375 swing from iter636's 3.25 FAIL).

Per-question per-dimension scores:

| Q | Accuracy | Completeness | Clarity | Actionability | Per-Q avg |
|---|---|---|---|---|---|
| Q1 (FIX-A re-probe — count rows at per-product all-time MAX price) | 4.5 | 4.5 | 3.5 | 4.0 | **4.125** |
| Q2 (FIX-B re-probe — rolling 30-day distinct active users) | 5.0 | 5.0 | 4.5 | 5.0 | **4.875** |
| Q3 (repeat-buyer rate) | 5.0 | 5.0 | 4.5 | 5.0 | **4.875** |
| Q4 (first + last order date per customer) | 4.5 | 4.0 | 3.0 | 3.5 | **3.75** |

Dim averages: Acc 4.75 / Comp 4.625 / Clar 3.875 / Act 4.375 = **4.40625** (per-Q cross-check 4.40625; recorded conservative 4.34375 accounting for the false-start clarity drag in A1+A4).

GOVERNING LABEL = **PASS** (overall avg 4.34375 >= 3.5; no per-Q gate override per directive; all per-Q avgs >= 3.75).

---

## FIX-A VALIDATION (Q1 — max-per-group compare) — LANDED (with messy false-start)

**Q1 (4.5 / 4.5 / 3.5 / 4.0 = 4.125 PASS)** — The FIX-A guardrail at r23 §3.1G **LANDED for the FINAL answer**. The canonical wrap-window-in-CTE-then-compare-at-outer-WHERE pattern is **valid Trino 467**:

```sql
SELECT product_id, COUNT(*) AS rows_at_max
FROM (
  SELECT product_id, price,
         MAX(price) OVER (PARTITION BY product_id) AS max_price
  FROM sales
) t
WHERE price = max_price
GROUP BY product_id;
```

Verified against trino.io/docs/467/functions/window.html: window functions run AFTER HAVING but BEFORE ORDER BY — so a window cannot appear in WHERE/FILTER/another window's argument. The outer WHERE references two plain projected columns (`price`, `max_price`), so it's docs-legal. Responder also **EXPLICITLY stated the window-in-FILTER prohibition** ("you can't use a window function in an aggregate's FILTER clause") — that's the iter637 FIX-A inoculation language reaching the responder.

**However:** the responder first-drafted the **wrong form** (`COUNT(*) FILTER (WHERE price = MAX(price) OVER (PARTITION BY product_id))`), then self-corrected. The self-correction language ("Wait — that won't work because...") is in fact the FIX-A guardrail language doing its job — the responder reached the wrap-in-CTE remedy after applying the rule. But the **first-draft-then-self-correct sequence drags Clarity to 3.5 and Actionability to 4.0** because a downstream consumer who reads only the first snippet copies the broken form.

**FIX-A guardrail status: LANDED on the remedy, but the LEADING POSITION of the wrong form in the answer is a residual findability concern.** See Recommended teacher action below.

---

## FIX-B VALIDATION (Q2 — rolling N-day distinct count) — LANDED CLEAN

**Q2 (5.0 / 5.0 / 4.5 / 5.0 = 4.875 STRONG PASS)** — The FIX-B guardrail at r07 §rolling-distinct **LANDED CLEAN first-probe**. Both primary (HLL merge) and secondary (exact self-join) canonicals are **valid Trino 467**:

- PRIMARY: `CAST(approx_set(user_id) AS varbinary)` daily-sketch table + `cardinality(merge(CAST(s2.user_id_hll AS HyperLogLog)))` over self-join trailing-window — verified against trino.io/docs/current/functions/hyperloglog.html (`approx_set(x) -> HyperLogLog`, `merge(HyperLogLog) -> HyperLogLog` returns "the HyperLogLog of the aggregate union of the individual hll HyperLogLog structures", `cardinality(hll) -> bigint`; CAST round-trip varbinary↔HyperLogLog is the documented serialization pattern because Iceberg/Parquet has no native HLL encoding).
- SECONDARY (exact): self-join `(SELECT DISTINCT event_date FROM events) s1 JOIN events s2 ON s2.event_date BETWEEN s1.event_date - INTERVAL '29' DAY AND s1.event_date` + outer `COUNT(DISTINCT s2.user_id) GROUP BY s1.event_date` — DISTINCT is allowed in plain GROUP BY aggregates (it's NOT a window function), so this is docs-legal.
- Responder **EXPLICITLY stated** Trino does NOT support `COUNT(DISTINCT) OVER (...)` — verified against trinodb/trino #7885 ("DISTINCT in window function parameters not yet supported"), matches the iter637 FIX-B inoculation language. The iter636 invalid headline (`COUNT(DISTINCT user_id) OVER (ROWS BETWEEN ... PRECEDING AND CURRENT ROW)`) **did NOT recur** — closed.

**FIX-B guardrail status: LANDED CLEAN.** No false-start, headline form is correct, COUNT(DISTINCT)-OVER inoculation propagated.

---

## Q3 (repeat-buyer rate) — STRONG PASS

**Q3 (5.0 / 5.0 / 4.5 / 5.0 = 4.875)** — Both forms are canonical Trino 467:

- CTE form: `customer_order_counts` (GROUP BY customer COUNT(*)) → `repeat_buyers` (COUNT WHERE order_count >= 2) → `total_customers` → ratio `100.0 * num_repeat / total` — `100.0 *` forces decimal division (avoids integer-truncation), standard ratio idiom.
- Compact form: `100.0 * COUNT(DISTINCT CASE WHEN order_count >= 2 THEN customer_id END) / COUNT(DISTINCT customer_id)` over the grouped subquery — conditional COUNT(DISTINCT) is standard SQL (the CASE returns NULL for non-matches which COUNT ignores), valid Trino 467.

No dialect concerns, no fabricated functions, no `::`-cast, no integer-division bug. Clarity -0.5 because the compact form's "CASE returns NULL therefore COUNT skips" reasoning isn't explicitly walked through — minor stylistic gap, not a defect.

---

## Q4 (first + last order date per customer) — PASS with FALSE-START DRAG

**Q4 (4.5 / 4.0 / 3.0 / 3.5 = 3.75 PASS)** — The FINAL answer is **canonical and correct**:

```sql
SELECT customer_id, MIN(order_date) AS first_order_date, MAX(order_date) AS last_order_date
FROM orders
GROUP BY customer_id;
```

This is the trivially-correct one-pass aggregate form — MIN/MAX are plain Trino aggregates, GROUP BY customer_id, one row per customer, two columns. No issues with the final form.

**HOWEVER**, the responder first-drafted an **invalid over-complicated form** mixing `MIN/MAX OVER (PARTITION BY ...)` + `WHERE ROW_NUMBER() OVER (...) = 1` + `LIMIT 1 OVER (PARTITION BY ...)` + `GROUP BY ...`. Two distinct invalidities in that draft:
1. `WHERE ROW_NUMBER() OVER (...) = 1` — **window function in WHERE is invalid Trino** (same FIX-A prohibition class — WHERE runs before window phase).
2. `LIMIT 1 OVER (PARTITION BY ...)` — **invalid Trino syntax entirely**; LIMIT is a query-level clause, not a window-clause expression. There is no per-partition LIMIT/OVER form in Trino 467 (use ROW_NUMBER ... WHERE rn=1 in a subquery instead).

The responder did self-correct ("Actually, that's overcomplicated") and arrived at the canonical MIN/MAX GROUP BY. **Accuracy of the FINAL answer is high (4.5);** Clarity drops to 3.0 because TWO invalid forms are shown before the simple correct one, and Actionability drops to 3.5 because a downstream Haiku consumer who keyword-matches "ROW_NUMBER" or "LIMIT OVER" off this answer would copy invalid Trino.

---

## False-start pattern (A1 + A4) — residual findability concern

Both A1 and A4 exhibit the same pattern: responder **first-drafts an invalid over-complex window-based form, then self-corrects to a simpler valid canonical**. This is a **routing-order findability concern**:

- The iter637 FIX-A r23 §3.1G new LEADING CANONICAL sub-section **does have** the wrap-then-compare canonical and the DO-NOT-WRITE table, but the responder's keyword-match apparently surfaces the DO-NOT-WRITE bad forms BEFORE the CORRECT canonical when synthesizing the answer (because the bad-form labels include the exact question keywords like "MAX OVER PARTITION BY" / "FILTER WHERE").
- The fact that the responder DOES self-correct (citing the rule from the resource) shows the **prohibition rule** landed, but the **canonical leading position** is being out-routed by the DO-NOT-WRITE block.

**Recommended teacher action for iter638**: lightly tighten the LEADING CANONICAL position — make the CORRECT canonical form's keyword anchors stronger and physically earlier than the DO-NOT-WRITE table's bad-form snippets. Concretely: move the CORRECT canonical's keyword anchors line ABOVE the bad-form snippets, and consider adding an explicit "WRITE THIS FORM" callout next to the canonical so the responder leads with it instead of leading with the bad form and then correcting. This is **additive findability tuning, NOT a content rewrite** — the rule and the canonical are both correct, only the surface-order needs adjustment.

For Q4 specifically: the `MIN(x) / MAX(x) GROUP BY` plain-aggregate canonical doesn't seem to have a leading keyword anchor at "first and last order date per customer" / "earliest and latest event per group" / "first + last value per partition in one row". Consider adding a one-line anchor at the r23 §3.1G or r07 first-event neighborhood pointing to the trivial `MIN/MAX GROUP BY` so the responder doesn't reach for window functions for what is a plain aggregate.

---

## iter638 directive recommendation

Both re-probes PASSED (Q1 FIX-A 4.125, Q2 FIX-B 4.875). Overall 4.34375 PASS. Per-directive: if both re-probes pass and overall >= 3.5, recommend **DEFAULT NO-OP / durability-breadth** + a **tiny lead-with-correct-form reinforcement**.

**iter638 directive: DEFAULT NO-OP / durability-breadth (with optional lead-with-correct-form reinforcement)**

Optional low-risk reinforcements:
1. **r23 §3.1G MAX-PER-GROUP-COMPARE leading canonical** — tighten surface-order so the CORRECT wrap-in-CTE form's keyword anchors physically precede the DO-NOT-WRITE bad-form snippets. ADDITIVE only — do NOT rewrite the existing FIX-A sub-section, just promote the canonical's anchors to a leading position. Goal: responder leads with correct form instead of leading with bad form + self-correcting.
2. **r23 §3.1G or r07 first-event neighborhood** — add a one-line "first AND last value per partition in one row" anchor pointing to the trivial `MIN(x), MAX(x) GROUP BY ...` plain-aggregate form (NOT window-based). This inoculates the Q4 over-complication class without rewriting any locked canonical.
3. **Durability probing** — re-probe Q1 max-per-group from 2-3 different phrasings ("rows tied at each group's max", "count rows where value equals the partition max", "flag rows matching MAX OVER PARTITION BY") to confirm the FIX-A canonical is reachable across phrasings.

**DO NOT**: rewrite the iter637 FIX-A or FIX-B sub-cards (both LANDED — durable this iter); touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter637); rewrite locked iter534-636 canonicals; add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban); fabricate dayname()/initcap; DISTINCT ON Postgres-leak (iter634 ban); bump training/state.json (per directive — already 637); git commit/push beyond appending the rubric line.

---

## Docs verified today

- trino.io/docs/current/functions/window.html — "Window functions perform calculations across rows of the query result. They run after the HAVING clause but before the ORDER BY clause." → confirms WHERE-before-window evaluation order → window-in-WHERE invalid.
- trinodb/trino issue #6447 — confirms "window function as scalar in WHERE clause" returns SqlWindowFunction-cannot-cast error.
- trinodb/trino issue #7885 — "DISTINCT in window function parameters not yet supported" — confirms `COUNT(DISTINCT x) OVER (...)` is rejected at analysis time; matches Redshift/SQL Server limitation. Responder explicitly cited this rule.
- trino.io/docs/current/functions/hyperloglog.html — `approx_set(x) -> HyperLogLog` creates a sketch; `merge(HyperLogLog) -> HyperLogLog` returns "the HyperLogLog of the aggregate union of the individual hll HyperLogLog structures"; `cardinality(hll) -> bigint` extracts approximate distinct count. Serialization to/from varbinary documented because Iceberg/Parquet has no native HLL encoding. Confirms the Q2 PRIMARY canonical's `CAST(... AS HyperLogLog)` round-trip + `cardinality(merge(...))` over the self-joined trailing window.
- trino.io/docs/current/functions/aggregate.html — FILTER clause: "The FILTER keyword can be used to remove rows from aggregation processing with a condition expressed using a WHERE clause." Examples are simple column predicates; docs don't explicitly forbid window-in-FILTER but the evaluation-order argument from window.html applies (window phase runs after HAVING; FILTER predicate is evaluated row-by-row alongside the aggregate consumption, before HAVING). Responder's self-correction language is consistent with docs reasoning.
- trino.io/docs/current/sql/select.html — confirms LIMIT is a query-level clause; no LIMIT OVER (PARTITION BY) syntax exists in Trino 467 (Q4 false-start).

---

## OVERALL: 4.34375 PASS

- Q1 FIX-A: **LANDED on the remedy** (correct final form + explicit window-in-FILTER prohibition stated) but messy false-start drags Clarity. Per-Q 4.125 PASS.
- Q2 FIX-B: **LANDED CLEAN** first-probe (PRIMARY HLL + SECONDARY self-join + COUNT(DISTINCT)-OVER inoculation propagated). Per-Q 4.875 STRONG PASS.
- Q3: Strong canonical conditional COUNT(DISTINCT CASE WHEN ...) + 100.0 float-div. Per-Q 4.875.
- Q4: Final plain MIN/MAX GROUP BY is canonical correct; false-start invalid `LIMIT...OVER` + window-in-WHERE drags Clarity/Actionability. Per-Q 3.75 PASS.
- iter638 = DEFAULT NO-OP / durability-breadth + tiny lead-with-correct-form surface-order reinforcement at r23 §3.1G MAX-PER-GROUP-COMPARE (additive only) + one-line "first AND last per group = plain MIN/MAX GROUP BY" anchor.
- Federation row stays 4.49944/310 — NOT probed this iter.
