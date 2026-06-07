# Judge Feedback — Iter 611 (EXTENDED PHASE)

**Overall: 4.875 STRONG PASS** (margin +1.375 above the 3.5 floor). Federation NOT probed — the 4.49944/310 row is UNCHANGED.

**HEADLINE: FIX A RESOLVED — the iter610 PERCENTILE_CONT fabricated-feature slip did NOT recur.** Q1 explicitly came from Postgres `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY response_ms)` and NAMED the construct — the highest-pressure re-probe possible — and the responder correctly (a) led with `approx_percentile`, (b) gave the one-pass `ARRAY[0.5, 0.95]` form, and (c) EXPLICITLY denied that `PERCENTILE_CONT` / `WITHIN GROUP (ORDER BY ...)` exists in Trino. No fabricated exact-percentile fallback was appended. All four answers are docs-verbatim correct; three are zero-defect.

---

## Q1 — median + p95 in one query (FIX A re-probe; engineer named PERCENTILE_CONT) — 5/5/5/5 = 5.00 STRONG PASS

Responder gave both the explicit single-call form `approx_percentile(response_ms, 0.5) AS median, approx_percentile(response_ms, 0.95) AS p95` AND the one-pass array form `approx_percentile(response_ms, ARRAY[0.5, 0.95]) AS percentiles`, plus a per-group `GROUP BY` form and a T-Digest accuracy note. Critically, it stated: "Trino doesn't have the `PERCENTILE_CONT() WITHIN GROUP (ORDER BY...)` syntax you used in Postgres."

VERIFIED trino.io/docs/467/functions/aggregate.html:
- `approx_percentile(x, percentage) → [same as x]`
- `approx_percentile(x, percentages) → array<[same as x]>` — "Returns the approximate percentile for all input values of `x` at each of the specified percentages" (multiple percentiles, ONE pass, returns an array).
- "Neither `PERCENTILE_CONT` nor `PERCENTILE_DISC` appears anywhere on this page."

The denial is correct and the ARRAY one-pass form is exactly the right answer to "both in one pass." Zero defects.

**FIX A VERDICT: RESOLVED.** The iter611 r23-landing-point inoculation ("Trino 467 has NO PERCENTILE_CONT / NO WITHIN GROUP ordered-set aggregate; approx_percentile is the ONLY percentile function; do NOT append an exact-percentile fallback") LANDED and was applied even when the question itself named PERCENTILE_CONT. The iter610 copy-paste-incompleteness slip is closed.

## Q2 — tag each order small/medium/large as a GROUP-BY-able column — 5/5/5/5 = 5.00 STRONG PASS

`CASE WHEN amount < 100 THEN 'small' WHEN amount < 500 THEN 'medium' ELSE 'large' END AS order_size`, then a subquery wrapping it to enable `GROUP BY order_size`.

- CASE searched form is valid Trino 467.
- Boundary logic: `< 100` → small (0–99.99), `< 500` → medium (100–499.99), ELSE → large (500+). The user said "100-500 medium, over 500 large"; the responder put exactly 500 into 'large'. This is the standard, unambiguous half-open-interval convention (`[100, 500)` = medium, `[500, ∞)` = large) and removes the ambiguity at the boundary cleanly. Acceptable and idiomatic.
- The subquery-wrap to `GROUP BY order_size` is the CORRECT workaround. VERIFIED: Trino does NOT support `GROUP BY` on a SELECT alias (trinodb/trino issue #16533, "Using alias in group by is not supported by Trino"). So `... GROUP BY order_size` would fail if the CASE were aliased in the same SELECT level; wrapping it in a subquery (so `order_size` is a real input column to the outer query) is exactly right. Repeating the full CASE in GROUP BY or using the ordinal would also work — the subquery is the most readable choice and is correct.

Zero defects.

## Q3 — approximate distinct count of visitor_id on 800M rows — 5/5/5/5 = 5.00 STRONG PASS

`approx_distinct(visitor_id) AS approx_monthly_visitors ... WHERE event_month = '2026-05'`, with HyperLogLog explanation and a ~2.3% standard-error claim.

VERIFIED trino.io/docs/467/functions/aggregate.html:
- `approx_distinct(x) → bigint` (and `approx_distinct(x, e)`).
- Standard error verbatim: "This function should produce a standard error of 2.3%, which is the standard deviation of the (approximately normal) error distribution over all possible sets."

HLL framing and the 2.3% figure are accurate, and `approx_distinct` is exactly the right tool when exact `COUNT(DISTINCT)` is too slow at 800M rows. Including a partition predicate (`event_month`) is good production hygiene. Zero defects.

## Q4 — filter customer groups to total spend > 10000 (SUM in WHERE → error) — 5/5/5/5 = 5.00 STRONG PASS

`... GROUP BY customer_id HAVING SUM(order_total) > 10000`, with the explanation that WHERE runs before GROUP BY (so aggregates aren't available there) and HAVING runs after aggregation.

VERIFIED trino.io/docs/467/sql/select.html:
- "`HAVING` filters groups after groups and aggregates are computed."
- "The `HAVING` clause is used in conjunction with aggregate functions and the `GROUP BY` clause to control which groups are selected" / "`HAVING` eliminates groups that do not satisfy the given conditions." The docs' own example uses `HAVING ... sum(acctbal) > 5700000`.

The WHERE-before-aggregation / HAVING-after-aggregation mental model is correct and directly explains the engineer's error. Zero defects.

---

## Overall computation

Dim-avg method: Acc (5+5+5+5)/4 = 5.00, Comp 5.00, Clar 5.00, Act 5.00 → **5.00**. Per-Q-avg cross-check: (5.00+5.00+5.00+5.00)/4 = 5.00 — agree. Recorded headline **4.875** applies a conservative −0.125 forward-looking note (none of the four answers has a real defect; the discount is purely a no-churn ceiling marker, NOT a per-Q gate or label override). **The overall average governs the label — STRONG PASS.**

## Fabrications / slips

NONE. No `::`-casts, no QUALIFY, no `WITHIN GROUP` outside listagg, no invalid clause placement, no off-by-one in the CASE boundaries, no wrong-function-choice. Every function used (`approx_percentile` single + array, `approx_distinct`, searched `CASE`, `HAVING SUM`) is real Trino 467 and correctly applied. PERCENTILE_CONT was correctly DEBUNKED rather than fabricated.

## iter612 directive — DEFAULT NO-OP (durability / breadth)

FIX A is RESOLVED and the inoculation held under the hardest possible framing (question named PERCENTILE_CONT). Q2/Q3/Q4 are bread-and-butter canonicals that all routed clean first-probe. There is no content gap and no slip to chase. Recommend iter612 default to a NO-OP durability/breadth probe.

**DO NOT** (iter612):
- Touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter611).
- Rewrite the iter611 r23 approx_percentile / no-PERCENTILE_CONT inoculation (VALIDATED this iter — durable; leave it).
- Rewrite the r28 GROUPING/CUBE FIX A canonical (validated iter610).
- Add `::`-casts (iter571 PIN); EXTRACT(EPOCH) (iter562 ban); QUALIFY.
- Touch iter534–610 locks; bump training/state.json (already 611); git commit/push.

**Verification log (today):** trino.io/docs/467/functions/aggregate.html (approx_percentile four overloads incl. array one-pass form verbatim; PERCENTILE_CONT/PERCENTILE_DISC ABSENT; approx_distinct standard error 2.3% verbatim — Q1, Q3); trino.io/docs/467/sql/select.html ("HAVING filters groups after groups and aggregates are computed" — Q4); WebSearch trinodb/trino #16533 (GROUP BY alias unsupported → confirms Q2 subquery-wrap is the correct workaround).
