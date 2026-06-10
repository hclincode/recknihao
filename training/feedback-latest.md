# Judge Feedback — iter915 (EXTENDED PHASE, NO-OP durability sweep)

**Overall: 4.54 PASS** (per-Q 3.40 / 5.00 / 5.00 / 4.75 = 18.15/4 = 4.5375; margin +1.04; OVERALL AVERAGE governs — no per-Q veto, no per-Q override)
**FEDERATION NOT PROBED** — the 4.49944/310 row is UNCHANGED this iteration.
**Verdict: PASS with ONE confirmed Q1 SHAPE slip on the LEAD form (correct concise form WAS delivered). Teacher ZERO edits — this is a RESPONDER synthesis slip on CLEAN resources → re-probe-don't-churn, NOT a resource gap.**

Trino 467 PINNED. All dialect claims docs-verified vs trino.io/docs/467 (aggregate/window/types .html) via WebFetch 2026-06-10, multi-source. Verified, NOT against resources/.

---

## Per-question verdicts

### Q1 — count customers with orders from >1 shipping address — 3.40 **SHAPE DEFECT on LEAD form (partial)**
The responder gave TWO forms.

**FIRST form (the muddled LEAD):**
```sql
SELECT COUNT(*) AS customers_with_multiple_addresses FROM (
  SELECT customer_id FROM orders
  GROUP BY customer_id, shipping_address
  HAVING COUNT(*) >= 1
) deduped
GROUP BY customer_id
HAVING COUNT(*) > 1
```
**SHAPE VERDICT — WRONG SHAPE (confirmed, NOT a dialect error — a logic/shape mistake):**
- Inner subquery `GROUP BY customer_id, shipping_address` yields **one row per (customer_id, shipping_address) pair** (the `HAVING COUNT(*) >= 1` is a no-op — every group has ≥1 row). Projects `customer_id` only.
- Outer `SELECT COUNT(*) ... GROUP BY customer_id HAVING COUNT(*) > 1` groups by customer and returns **one row PER qualifying customer**, each value = that customer's distinct-address count — NOT a single total. So it emits MULTIPLE rows, every one mislabeled `customers_with_multiple_addresses`.
- It is valid SQL that RUNS, but does NOT answer "how many customers" — it would need a further outer `SELECT COUNT(*)` wrap to collapse to one number.

**SECOND form (correct, labeled "more concise"):**
```sql
SELECT COUNT(*) FROM (
  SELECT customer_id, COUNT(DISTINCT shipping_address) AS address_count
  FROM orders GROUP BY customer_id
) WHERE address_count > 1
```
**CORRECT** — one number: count of customers with >1 distinct shipping address. `COUNT(DISTINCT x)` valid in 467.

**Net:** partial, not zero — the correct concise form IS delivered and IS labeled "more concise," so an engineer who picks it lands correctly. Scored DOWN for leading with a wrong-shape form that a beginner could copy and get a mislabeled multi-row result.

### Q2 — % of orders with a coupon — 5.00 CLEAN
`ROUND(100.0 * COUNT_IF(coupon_code IS NOT NULL) / COUNT(*), 2)`. Verified: `count_if(x)->bigint` EXISTS in 467 (aggregate.html, "number of TRUE input values"); `100.0` is a DECIMAL literal (types.html) → promotes the BIGINT counts to decimal division, NO integer truncation. `SUM(CASE WHEN coupon_code IS NOT NULL THEN 1 ELSE 0 END)` equivalent offered. Correct.

### Q3 — orders where shipping_cost > 20% of subtotal — 5.00 CLEAN
`SELECT COUNT(*) FROM orders WHERE shipping_cost > 0.2 * order_subtotal`. `0.2` is a DECIMAL literal so `0.2 * order_subtotal` is non-integer; pure comparison, no division → responder correctly says NO special handling needed. Correct.

### Q4 — count customers who churned then reactivated — 4.75 CLEAN
```sql
WITH ranked_subs AS (
  SELECT customer_id, status, created_at,
         LAG(status) OVER (PARTITION BY customer_id ORDER BY created_at) AS prev_status
  FROM subscriptions)
SELECT COUNT(DISTINCT customer_id) FROM ranked_subs
WHERE prev_status = 'cancelled' AND status = 'active'
```
Verified: `lag(x[,offset[,default]])` valid in 467 with `OVER (PARTITION BY ... ORDER BY ...)` (window.html). `cancelled`→`active` transition correctly detects reactivation; `COUNT(DISTINCT customer_id)` counts each reactivating customer once. The COUNT(*)-for-events note and the tiebreaker caveat (ties on `created_at`) are apt. Correct; tiny clarity-not-correctness margin only.

---

## Scope check & directives

- **(a) Q1 first-form shape issue CONFIRMED** — returns per-customer rows not a single count; second form correct. It is a **RESPONDER synthesis slip**, NOT a resource gap: the responder DID deliver a correct concise form (COUNT(DISTINCT…)>1 over a single subquery). Resources are clean. → **RE-PROBE, DON'T CHURN.** No FIX-A. Do NOT add/edit cards; a defang on a clean dedup/distinct-count card risks regressing the many passing COUNT(DISTINCT)/GROUP BY-HAVING neighbors (e.g. iter910/912 dup-detect, iter909 muddle already one-off-CLOSED).
- **(b) NO other defect** — no fabrication / wrong-signature / crossed-family / findability-slip / prod-env conflict. Every fn verified present + correct-signature in Trino 467; pure SQL, on-prem Trino 467 + Iceberg + MinIO + HMS + JWT/OPA unaffected.
- **(c) iter916 = DEFAULT NO-OP / durability-breadth.** Re-probe the "count-of-customers-with->1-distinct-X" family from a DIFFERENT phrasing (e.g. customers ordering >1 distinct product category; products sold to >1 distinct region) to confirm the Q1 lead-form muddle is a ONE-OFF and the responder LEADS with the COUNT(DISTINCT…)>1 form. Optional fresh adjacents: `COUNT(DISTINCT) FILTER (WHERE …)`, multi-col `COUNT(DISTINCT (a,b))`, `HAVING COUNT(DISTINCT x) > 1` dup-detect, RANK()=1 vs ROW_NUMBER()=1 ties.
- **(d) PRESERVE full iter534–914 pin inventory; NO federation edits (federation 4.49944/310, UNCHANGED — not probed this iter).**

**DO NOT bump training/state.json (already 915).**
