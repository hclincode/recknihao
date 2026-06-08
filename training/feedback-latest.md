# Iter709 Judge Feedback

## Per-Q Sub-scores (Accuracy / Completeness / Clarity / Actionability, 1–5)

### Q1 — semi-join "has orders vs never ordered"
- Accuracy: 3
- Completeness: 3
- Clarity: 4
- Actionability: 4
- Avg: 3.50

Verified vs trino.io/docs/467:
- IN (SELECT ...) auto-converted to semi-join: VALID.
- EXISTS (SELECT 1 ...) correlated subquery: VALID.
- LEFT-JOIN-then-COUNT must use COUNT(order_id) not COUNT(*) to avoid counting the NULL-padded unmatched row as 1: CORRECT.

CRITICAL ACCURACY DING — granularity mislabel (findable, not a one-off slip):
The responder's FIRST canonical query is:
```
SELECT customer_id,
       CASE WHEN customer_id IN (...) THEN 'has_orders' ELSE 'never_ordered' END AS order_status,
       COUNT(*) AS customer_count
FROM iceberg.app.users
GROUP BY customer_id, order_status
```
Because `users` has exactly one row per `customer_id`, GROUP BY (customer_id, order_status) yields exactly ONE row per customer with `customer_count = 1`. The column name `customer_count` and the prose framing ("TRUE/FALSE per customer") implies the engineer wanted the **two-row roll-up** the question literally asks for ("X customers have orders vs Y never ordered"). For that they'd write a CTE/subquery with the per-customer CASE and then GROUP BY order_status ONLY in the outer query:
```
SELECT order_status, COUNT(*) AS customer_count
FROM (
  SELECT customer_id,
         CASE WHEN customer_id IN (SELECT user_id FROM iceberg.app.orders)
              THEN 'has_orders' ELSE 'never_ordered' END AS order_status
  FROM iceberg.app.users
) per_customer
GROUP BY order_status;
```
This is the SAME granularity-mismatch shape as the iter702 Pattern-C4 bucket-rollup defect: GROUP BY the per-entity key when you wanted the per-LABEL roll-up. The EXISTS alternative the responder offered is clean and correct (and avoids the trap by not pretending to aggregate), but the LEAD canonical block is the one the SaaS engineer will copy first — and it's grain-wrong for the stated dashboard. This is a real Accuracy/Completeness ding, not prose nit.

### Q2 — top category per customer
- Accuracy: 5
- Completeness: 5
- Clarity: 4
- Actionability: 5
- Avg: 4.75

Verified vs trino.io/docs/467:
- ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY COUNT(*) DESC) composed on the outside of a GROUP BY (customer_id, category_name) inner query: VALID Trino 467. The window function is computed over the GROUPED rows (one per (customer, category)), and ORDER BY COUNT(*) inside OVER references the aggregate from the same SELECT level — composes cleanly.
- max_by(category_name, purchase_count) returns category_name at the row with max purchase_count: CORRECT for single-top-per-group.
- Both forms yield one row per customer.
- Naming nit: alias `rank` shadows the RANK window function reserved-ish name; works but `rn` is the typical convention. Minor.

### Q3 — integer status → label
- Accuracy: 4
- Completeness: 4
- Clarity: 5
- Actionability: 5
- Avg: 4.50

Verified vs trino.io/docs/467:
- CASE simple form `CASE expr WHEN val THEN result ... END`: VALID.
- if(cond, t, f): VALID.
- "GROUP BY must repeat the CASE" claim — VERIFIED CORRECT for Trino 467. The SELECT docs state GROUP BY may contain "any expression composed of input columns OR an ordinal number selecting an output column by position (starting at one)." Trino 467 does NOT support GROUP BY by SELECT-list alias (GH #16533 confirms; reproduces in 467). So the responder's "verbose but unavoidable in standard SQL" framing is technically accurate.
- Minor nit (completeness): the responder did NOT mention the ordinal-position shortcut `GROUP BY 1, 2` which Trino DOES allow — that would have softened the "verbose but unavoidable" phrasing and shown the engineer a one-liner shortcut. Small completeness ding, not accuracy.

### Q4 — array length + filter
- Accuracy: 5
- Completeness: 5
- Clarity: 5
- Actionability: 5
- Avg: 5.00

Verified vs trino.io/docs/467/functions/array.html:
- cardinality(array) → bigint: CORRECT.
- array_distinct: CORRECT.
- contains(array, value) → boolean: CORRECT.
- element_at(array, n) negative-index = element from the end, NULL-safe out-of-range (vs subscript [] which errors): BOTH CONFIRMED in docs verbatim ("If `index` < 0, `element_at` accesses elements from the last to the first" and "returns NULL when accessing an `index` larger than array length, whereas the subscript operator would fail in such a case").
- 1-based indexing: implied/correct.
Bulletproof answer.

---

## Overall

Sub-scores sum: 14 + 19 + 18 + 20 = 71
Average: 71 / 16 = **4.4375**

**PASS** (>= 3.5).

---

## Findable-but-missing gap flagged for iter710 (FIX-A candidate)

**Q1 GROUP-BY-customer_id-count-mislabel — YES, this is a findable bucket-rollup gap.**

It's the SAME granularity-mismatch shape as iter702's Pattern-C4 bucket-rollup defect (GROUP BY the per-entity key when you wanted the per-LABEL rollup). The responder offered the EXISTS alternative correctly, but the LEAD copy-attractive canonical IN(SELECT) block is wrapped in a `GROUP BY customer_id, order_status COUNT(*)` shape that yields one-row-per-customer-with-count=1 — NOT the two-bucket "X have orders vs Y never ordered" summary the question phrasing and the alias `customer_count` BOTH promise.

The existing Pattern-C4 inoculation appears to cover the "split into N buckets by range/case and count per bucket" framing but is NOT reaching the specific has-X-vs-no-X 2-bucket pattern where the temptation is to KEEP customer_id in GROUP BY (because "I want one row per customer, then aggregate"). The recipe the responder needs:

> **2-bucket per-entity-has-X rollup pattern**: when the question is "how many entities have X vs don't", the per-entity label assignment goes in an INNER subquery/CTE, and the OUTER query GROUPs BY the label ONLY. Putting both the entity key AND the label in one GROUP BY yields per-entity rows with count=1 (because the entity key already uniquely identifies each row).

Recommended iter710 FIX-A: add a small landing-point card under r07 §1a (semi-join section) or r23 §10 (where the responder is currently pointing) titled "2-bucket has-X-vs-doesn't roll-up — inner CTE labels, outer GROUP BY label only", with a worked SQL pair (WRONG: `GROUP BY customer_id, label`; CORRECT: CTE + `GROUP BY label`). Defang the WRONG shape inline with a comment showing "this yields one row per customer with count=1, NOT the 2-row dashboard summary you wanted." Cross-ref to iter702 Pattern-C4. Use the iter693 defang-inoculation pattern: mark the WRONG block un-copyable and make the CORRECT block the visually-attractive one.

**Q3 "GROUP BY must repeat the CASE" — NOT a defect.** Verified against Trino 467 SELECT docs: only input-column expressions OR ordinals are allowed in GROUP BY; aliases are NOT supported (GH #16533). The responder's claim is accurate for Trino 467. Optional minor add (NOT required for PASS): the resource could mention the `GROUP BY 1, 2` ordinal-position shortcut as a less-verbose alternative — but the responder's claim itself is correct.

**Q2, Q4 — no defects.** Q4 in particular is a bulletproof reference answer (cardinality + array_distinct + contains + element_at with negative index and NULL-safety all correctly stated).

---

## Posture for iter710

- DEFAULT NO-OP probe is the baseline given 170+ consecutive passes; this iter is also a PASS at 4.4375.
- ONE FIX-A candidate: Q1 2-bucket rollup landing-point card (above). This is a real findable-but-missing gap, not a one-off slip — the responder constructed a canonical block whose grain doesn't match the question's stated dashboard need, and the bucket-rollup-GROUP-BY-label-only lesson did not surface despite resources/23 §10 being cited.
- If teacher acts on FIX-A: write a small landing-point card (≤30 lines), inline-defang the WRONG shape per the iter693 defang-inoculation pattern (don't write a bare snippet that the weak responder can copy as the canonical), cross-ref to iter702/703 Pattern-C4. Keep r22 federation file UNTOUCHED (HARD LOCK preserved).
- All other locks preserved.
- Do NOT bump state.json (per run prompt).
