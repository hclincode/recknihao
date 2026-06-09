# Judge Feedback — Iter 812 (EXTENDED PHASE)

**Date**: 2026-06-09
**Mode**: DEFAULT NO-OP / durability-breadth sweep (teacher made ZERO resource edits).
**Federation**: NOT PROBED.
**State**: NOT bumped (already 812).
**Docs verified**: trino.io/docs/467 — functions/aggregate.html, functions/datetime.html, sql/select.html (fetched 2026-06-09). Resources NOT treated as ground truth. Prod stack confirmed: Trino 467 + Iceberg connector (prod_info.md).

---

## Per-question scores

### Q1 — BOOL_AND all-flag re-probe (order true only if EVERY line item in_stock)
Answer: `bool_and(in_stock) AS all_items_in_stock ... GROUP BY order_id`; TRUE only if every input true; `bool_and(quantity>0 AND in_stock)` composite variant. Cites r23 §3.1D. **LED with bool_and.**

- VERIFIED aggregate.html: `bool_and(boolean) -> boolean` = "Returns TRUE if every input value is TRUE, otherwise FALSE." Exact fit for "all line items in stock." Composite-predicate variant valid.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- **Per-Q avg: 5.00**

### Q2 — Epoch-millis → timestamp (convert 1748736000123 ms bigint)
Answer: `from_unixtime(created_at / 1e3)`; from_unixtime expects SECONDS; `/1e3` float-divide (NOT `/1000` integer which drops millis); returns timestamp(3); `from_unixtime_nanos` for nanos. Cites r13.

- VERIFIED datetime.html: `from_unixtime(unixtime) -> timestamp(3) with time zone`, "number of seconds since 1970-01-01." `/1e3` float division preserves sub-second precision; `/1000` integer division would truncate millis. `from_unixtime_nanos -> timestamp(9)` correct. The float-divide pin is the load-bearing correctness point and is right.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- **Per-Q avg: 5.00**

### Q3 — Companion of max (each salesperson's deal_name of highest deal_amount)
Answer: `max_by(deal_name, deal_amount) AS biggest_deal_name` + `MAX(deal_amount)` GROUP BY salesperson; ROW_NUMBER() OVER (PARTITION BY salesperson ORDER BY deal_amount DESC)=1 for the whole row. Cites r23 §3.1D.

- VERIFIED aggregate.html: `max_by(x, y)` = "value of x associated with the maximum value of y." `max_by(deal_name, deal_amount)` returns deal_name at the highest deal_amount per group. ROW_NUMBER()=1 whole-row alternative valid and correctly scoped. Tie behavior (max_by picks arbitrary among ties) not raised but ask is unambiguous — no penalty.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- **Per-Q avg: 5.00**

### Q4 — Set difference (user_ids active this month but NOT last month)
Answer: June SELECT `EXCEPT` May SELECT; set difference, returns DISTINCT, NULL-safe vs NOT IN; anti-join alternative. Cites r23 §3.1F.

- VERIFIED select.html: EXCEPT = "rows in the result set of the first query, but not the second"; DISTINCT semantics by default (EXCEPT ALL preserves dups). June EXCEPT May = newly-active users. NULL-safe-vs-NOT-IN claim accurate (EXCEPT treats NULLs as comparable; NOT IN with a NULL in the subquery returns UNKNOWN → no rows). Anti-join alt valid.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- **Per-Q avg: 5.00**

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg: 5.00** (20.00/4) — **STRONG PASS** (margin +1.50; overall avg governs, no per-Q veto). ZERO new dialect defects.

---

## Teacher feedback

**(a) Boolean-flag-pivot BULLETPROOFED.** Q1 (`bool_and` all-true flag) is the 2nd consecutive clean datapoint after iter811's `bool_or` any-true flag. Responder LED with `bool_and(in_stock)`, gave the exact-fit GROUP BY per order_id, AND offered the composite-predicate variant — no regression to redundant MAX(CASE)/FILTER. The all-true companion to bool_or is now confirmed durable across two distinct phrasings. **boolean-flag-pivot = BULLETPROOFED.** Do NOT churn the r23 §3.1D / r07 bool_or/bool_and pivot cards.

**Standing pins held zero-drift:**
- from_unixtime-seconds-millis-`/1e3` (Q2) — float-divide-not-integer pin confirmed durable.
- max_by-companion-of-max (Q3) — confirmed.
- EXCEPT-set-difference-null-safe (Q4) — confirmed.
- All iter534–811 inventory unchanged.

**(b) iter813 designation: DEFAULT NO-OP / durability-breadth sweep.** No open defect, no new imprecision, no findability gap. Suggest fresh adjacent picks (e.g. min_by-companion-of-min / INTERSECT row-level / from_unixtime_nanos nanos branch / NTILE-quartile) plus optional maintenance re-probes. Do NOT pre-churn any bulletproofed card. FIX-A only if a defect surfaces. Federation row remains untouched (4.49944, thin vs 4.5). DO NOT bump training/state.json.
