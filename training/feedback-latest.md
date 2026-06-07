# iter644 Judge Feedback — Durability-Breadth NO-OP Probe (2026-06-07)

**Iteration**: 644
**Phase**: extended (default-NO-OP doctrine; iter643 STRONG PASS 4.6875)
**Verdict**: PASS
**Overall average: 4.531**

---

## Per-question scores

### Q1 — "customers who bought product A but NEVER product B" (did-X-not-Y anti-join)
- Accuracy: 4.5
- Completeness: 4.5
- Clarity: 4.5
- Actionability: 4.5
- **Q1 avg: 4.5**

Notes: Both forms (`NOT IN` with caveat + `LEFT JOIN ... IS NULL`) are correct in Trino 467. Answer explicitly steered to the LEFT-JOIN anti-join as more performant and NULL-safe, and called out the NOT IN NULL pitfall. Verified against Trino docs and known Trino issues: anti-join via LEFT JOIN + IS NULL on right-side key is the canonical robust form; NOT IN is unsafe when the inner subquery may produce a NULL. Minor nit: leading with `NOT IN` before the safer form is a stylistic risk for a beginner who might copy the first snippet — but the caveat language is present, so deduction is small. Would have been 5.0 if the LEFT JOIN form (or NOT EXISTS) was the PRIMARY and NOT IN was the "DO NOT WRITE" inoculation.

### Q2 — "customers who bought from >= 3 DISTINCT categories" (HAVING COUNT(DISTINCT))
- Accuracy: 5.0
- Completeness: 4.5
- Clarity: 4.5
- Actionability: 5.0
- **Q2 avg: 4.75**

Notes: `GROUP BY customer_id HAVING COUNT(DISTINCT category) >= 3` is the textbook-correct Trino 467 shape — verified against trino.io aggregate-functions and SELECT docs (HAVING with DISTINCT aggregations is fully supported; HAVING is evaluated after GROUP BY on the grouped row). The optional detail variant projecting the count is a nice extra. No dialect issues.

### Q3 — "bucket customers into LTV tiers, count per tier" (two-level aggregation + searched CASE)
- Accuracy: 4.0
- Completeness: 4.5
- Clarity: 4.5
- Actionability: 4.5
- **Q3 avg: 4.375**

Notes: The structural pattern is correct — `customer_spend` CTE (SUM per customer), `spend_tiers` CTE (searched CASE), final `SELECT tier, COUNT(*) GROUP BY tier ORDER BY CASE tier ...`. All three layers are valid Trino 467 syntax (CTE composition, searched CASE, CASE-in-ORDER-BY all verified). Column-scope discipline is clean (`tier` projected in the inner CTE before being referenced outside).

Boundary minor deviation: question states "Silver $100-500 / Gold >$500". Answer's CASE puts `total_spend = 500` in Gold (`WHEN total_spend >= 500 THEN 'Gold'` paired with `WHEN total_spend >= 100 AND total_spend < 500 THEN 'Silver'`). Strict reading of "Gold >$500" would put exactly $500 in Silver. This is an off-by-one at the exact boundary — a real-world engineer would likely catch and adjust in code review. Not a Trino dialect issue, a requirements-precision nit. -0.5 on Accuracy.

No dialect issues; CASE branches are otherwise gap-free and non-overlapping. CASE-in-ORDER-BY is verified valid Trino 467 (ORDER BY accepts arbitrary expressions including CASE per the SELECT docs).

### Q4 — "day-over-day retention" (yesterday∩today / yesterday)
- Accuracy: 4.5
- Completeness: 4.5
- Clarity: 4.5
- Actionability: 4.5
- **Q4 avg: 4.5**

Notes: `current_date - INTERVAL '1' DAY` is valid Trino 467 (date minus interval yields date — verified; the invalid form would be date minus date, which the answer correctly does NOT use). INNER JOIN of `yesterday_active` and `today_active` on user_id gives the intersection; COUNT(*) on the join = retained users. The final cross-join of two single-row CTEs (`overlap`, `yesterday_count`) is valid Trino and is a clean scalar-broadcast pattern. `100.0 * x / y` forces double division — correct float-coercion idiom.

Optional polish (not penalized): `INTERSECT` of two DISTINCT user-id sets would be a cleaner one-shot for the overlap count, and `NULLIF(yesterday_count, 0)` would protect against division-by-zero on the empty-yesterday edge case. Both are non-blocking enhancements.

---

## Overall

- Q1 avg: 4.5
- Q2 avg: 4.75
- Q3 avg: 4.375
- Q4 avg: 4.5
- **Overall average: 4.531**
- **Verdict: PASS** (overall ≥ 3.5; no per-Q < 3.5)

All four durability-breadth probes held cleanly. The iter644 NO-OP decision is vindicated by the data: every probed area (anti-join did-X-not-Y, HAVING COUNT(DISTINCT) ≥ N, two-level aggregation with searched-CASE tier-bucketing, day-over-day retention with INNER-JOIN overlap) returned ≥ 4.3 average. No dialect violations detected (no QUALIFY, no date-minus-date, no LIMIT-OVER, no PIVOT, no DISTINCT ON, no COUNT(DISTINCT) OVER, no window-in-WHERE, no nested window, no `::cast`). Resource base is durable from these four angles.

---

## Recommendation for iter645

**DEFAULT NO-OP / DURABILITY-BREADTH continuation.** No per-question average dropped below 3.5; no FIX-A target required. The weakest answer (Q3 at 4.375) has only a requirements-precision nit (off-by-one at the $500 boundary) — not a dialect or resource issue, and not worth manufacturing churn to "fix" since the engineer would catch this in code review.

Suggested iter645 fresh-area probes (synthesizable-from-primitives only; do NOT pre-probe with new content):
- Sessions: gap-based session segmentation with LAG + date_diff threshold (already covered by r07 max-gap canonical).
- Top-N-per-group with ties: DENSE_RANK vs RANK comparison (r23:982 PIN covers this).
- Funnel: ordered-event conversion across stages (r07 §3 cohort canonical covers via sequence_match-style primitives).
- Active-streak: consecutive-day-active customers with island-and-gap (r07 covers via date_diff + row_number difference primitive).

If any of those probe-areas fails, name the lowest as iter646 FIX-A target with concrete failure evidence. Otherwise continue NO-OP doctrine.

---

## Notes on judge verification

WebSearch-verified against trino.io 467 / current docs:
- HAVING + COUNT(DISTINCT) supported (aggregate-functions docs + SELECT docs).
- `current_date - INTERVAL '1' DAY` valid date arithmetic (datetime functions docs).
- CASE expressions valid in ORDER BY (ORDER BY accepts arbitrary expressions per SELECT docs).
- LEFT JOIN + WHERE right-key IS NULL is canonical anti-join form; NOT IN NULL pitfall is real and well-documented (trinodb/trino #21457 and related issues).
