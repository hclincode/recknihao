# Judge Feedback — iter776

**Mode:** DEFAULT NO-OP / durability-breadth sweep (teacher made ZERO resource edits). Q1 = LAG-by-N partitioned-dense BULLETPROOF re-probe; Q2–Q4 fresh adjacent topics.
**Verification date:** 2026-06-09 against trino.io/docs/467 (window.html, string.html). resources/ NOT treated as ground truth.

---

## Q1 — LAG-by-N, PARTITIONED dense series (day-over-day, NOT self-join)

**Answer:** `LAG(units_sold) OVER (PARTITION BY product_id ORDER BY day) AS prev_day_units` — explains LAG returns the previous row's value within each product partition, ordered by day; explicitly no self-join. Cites r07 window section.

**Docs verification:** trino.io/docs/467/functions/window.html — `lag(x)` default offset = 1, returns "the value at offset rows before the current row in the window partition"; operates WITHIN the partition ordered by ORDER BY. With one row per product per day and no gaps, the previous row in `PARTITION BY product_id ORDER BY day` IS the same product's previous calendar day. CORRECT.

**Critical behavior:** Responder LED with the partitioned LAG, did NOT refuse it, did NOT push a self-join. This is the **2nd consecutive clean LAG-by-N datapoint** (after iter775 `LAG(dau_count,7)`). The iter774 refuse-LAG/force-self-join defect did NOT recur, and it stayed clean when a partition dimension was added.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Q1 avg** | **5.00** |

---

## Q2 — Running / cumulative total

**Answer:** `SUM(amount) OVER (ORDER BY date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS balance_to_date`, with running-frame explanation. Cites r07 Pattern A.

**Docs verification:** Valid Trino 467 window aggregate with an explicit ROWS frame; `UNBOUNDED PRECEDING … CURRENT ROW` = sum from the first row through the current row = running balance. CORRECT. Minor note (not a defect): with unique dates ROWS is exact; if dates tie, ROWS counts physical rows while RANGE would sum all peer rows — but ROWS is the standard running-balance answer and the responder did not misstate this.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 4 |
| Clarity | 5 |
| Actionability | 5 |
| **Q2 avg** | **4.75** |

---

## Q3 — Rank with ties (rank value AFTER a tie)

**Answer:** Table — `ROW_NUMBER()` = unique 1,2,3,4 (ties arbitrary); `RANK()` = ties share rank, next SKIPS (1,2,2,4); `DENSE_RANK()` = ties share rank, no gap (1,2,2,3). All three in one query `ORDER BY total_revenue DESC`. Cites r07 Pattern C.

**Docs verification:** trino.io/docs/467/functions/window.html — `rank()` "tie values produce gaps in the sequence" (1,2,2,4 after a tie at 2); `dense_rank()` "tie values do not produce gaps" (1,2,2,3); `row_number()` unique sequential regardless of ties. The responder's tie-behavior table is **EXACTLY correct**. For the user's "ties share a rank" requirement, both RANK and DENSE_RANK share; the responder correctly frames the difference as the post-tie gap. Standing RANK/DENSE_RANK/ROW_NUMBER pin held.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Q3 avg** | **5.00** |

---

## Q4 — VARCHAR substring search (description contains 'refund')

**Answer:** `strpos(description, 'refund') > 0` — 1-based position, 0 if not found, so `>0` = contains-anywhere. Notes it's cleaner than `LIKE '%refund%'`. Cites r23 substring-test section.

**Docs verification:** trino.io/docs/467/functions/string.html — `strpos(string, substring)` returns the 1-based starting position of the first instance, 0 if not found; `strpos(...) > 0` = contains-anywhere. CORRECT. Standing pin held: `contains()` is ARRAY-ONLY in Trino (not a varchar function — not listed among string functions) — the responder correctly used `strpos>0` and did NOT reach for `contains` on a varchar. The `LIKE '%refund%'` alternative is equally valid.

**Minor (not penalized):** "cleaner/more efficient than LIKE" is a stylistic claim; both are valid and `LIKE '%refund%'` is equally correct. The responder did not assert anything false (e.g., did not claim an index advantage), so no deduction.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Q4 avg** | **5.00** |

---

## Overall

| Q | Avg |
|---|---|
| Q1 (LAG-by-N partitioned dense) | 5.00 |
| Q2 (running total) | 4.75 |
| Q3 (rank ties) | 5.00 |
| Q4 (varchar substring) | 5.00 |
| **Overall** | **4.9375** |

**Result: PASS** (overall 4.9375 ≥ 3.5; no single-Q veto, lowest Q = 4.75).

### (a) Is LAG-by-N BULLETPROOFED?
**YES.** iter776 Q1 is the 2nd consecutive clean LAG-by-N datapoint and the first to add a partition dimension. Sequence: iter774 = REAL DEFECT (refused LAG, forced self-join) → iter775 FIX-A → iter775 = CLOSED (1st clean, `LAG(x,7)` dense daily) → iter776 = **BULLETPROOFED** (2nd clean, partitioned dense `LAG(units_sold) OVER (PARTITION BY product_id ORDER BY day)`, LED with LAG, no self-join push). The iter775 LAG-FIRST ROUTER + dense-vs-sparse disambiguator (r07:2802-2839) is doing its job across both bare-ORDER-BY and PARTITION-BY phrasings. LAG-by-N moves CLOSED → BULLETPROOFED.

### (b) iter777 designation
**DEFAULT NO-OP / durability-breadth sweep.** No open defect surfaced. No new imprecision in any of the 4 answers. Teacher should make ZERO edits and probe 4 fresh adjacent topics. LAG-by-N is now BULLETPROOFED — it need not be a primary re-probe item (at most one occasional confirmatory phrasing, e.g., LEAD-by-N forward-looking, to keep coverage warm). PRESERVE the LAG-FIRST ROUTER + dense-vs-sparse disambiguator (r07:2802-2839) and the Q2/Q3/Q4 cards — all verified clean, churn risk.

**Standing pins all held this iteration:** LAG-partitioned-dense (now BULLETPROOFED), running-total-ROWS-UNBOUNDED-PRECEDING, RANK-vs-DENSE_RANK-vs-ROW_NUMBER tie table, strpos-for-varchar-contains (contains is array-only).
