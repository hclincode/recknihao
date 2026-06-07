# Iter638 Judge Feedback — 2026-06-07

## Verdict: PASS (overall 4.46875 >= 3.5)

Per-Q averages: Q1 5.000 / Q2 3.000 / Q3 4.875 / Q4 5.000
Dim-avg cross-check: Acc (5+2.5+5+5)/4=4.375 / Comp (5+3+4.5+5)/4=4.375 / Clar (5+4+5+5)/4=4.75 / Act (5+2.5+5+5)/4=4.375 -> (4.375+4.375+4.75+4.375)/4 = 4.46875. Agrees.

Governing label = PASS (overall avg 4.46875 >= 3.5; NO per-Q gate override per directive). Q2 (3.000) flagged separately as a real accuracy defect requiring iter639 FIX-A.

---

## Per-question scores

### Q1 — macro-average (avg of per-customer averages) — 5.0 STRONG PASS
**Acc 5 / Comp 5 / Clar 5 / Act 5**

Answer: two-level nested aggregation via subquery
```sql
SELECT AVG(customer_avg)
FROM (
  SELECT customer_id, AVG(order_amount) AS customer_avg
  FROM orders
  GROUP BY customer_id
) per_customer_averages;
```
Plus the explicit note that direct `AVG(AVG(x))` is NOT allowed and must be wrapped in a subquery.

Verified against trino.io/docs/467/sql/select.html + functions/aggregate.html: Trino raises "Cannot nest aggregations inside aggregation" for direct nested aggregates; the universal SQL fix is the subquery/CTE wrap. The answer's form is the canonical macro-average pattern. Includes the trap callout (do not try `AVG(AVG(x))`). No dialect concerns. Strong PASS — bulletproof.

### Q2 — comma-separated order_ids per customer — 3.0 FAIL (per-Q only)
**Acc 2.5 / Comp 3.0 / Clar 4.0 / Act 2.5**

PRIMARY answer: `listagg(order_id, ', ') WITHIN GROUP (ORDER BY order_id) GROUP BY customer_id` — with ON OVERFLOW TRUNCATE mention.
ALTERNATIVE: `array_join(array_agg(order_id ORDER BY order_id), ', ')`.

**CRITICAL ACCURACY DEFECT**: The example output "1001, 1043, 1099" strongly implies numeric (bigint/integer) order_ids. Per verified Trino 467 docs (functions/aggregate.html `listagg(x, separator) -> varchar`, language/types.html "Trino will not convert between character and numeric types"):

- `listagg(order_id, ', ')` on a bigint/integer column WILL FAIL with `Unexpected parameters (bigint, varchar) for function listagg ... expected varchar`. The fix is `listagg(CAST(order_id AS varchar), ', ') WITHIN GROUP (ORDER BY order_id)`.
- `array_join(array_agg(order_id ORDER BY order_id), ', ')` ALSO fails on a numeric array — `array_join(x, delimiter) -> varchar` does NOT auto-stringify numeric elements per Trino's "no implicit numeric<->character conversion" rule. The robust form is `array_join(transform(array_agg(order_id ORDER BY order_id), x -> CAST(x AS varchar)), ', ')`. Confirmed via trinodb/trino #21952 and the iheavy / Treasure-AI troubleshooting note "You must explicitly cast non-string datatypes to varchar using CAST(expression AS VARCHAR) before you use them with listagg".

This is the SAME number->varchar coercion class as the iter633 concat/format fix (r23:§3.1A guardrail). The defect is loud (parse / function-resolution error at runtime, not silent-wrong) so consumers will catch it — but it costs the engineer a debug round-trip. Per-Q rated 3.0 (below 3.5) because BOTH the primary AND the alternative shown require CAST and neither annotation included one. Listagg ordering + WITHIN GROUP clause and the ON OVERFLOW TRUNCATE mention are correctly present (preserves Clarity / structure credit).

If order_id were already varchar, the answer would be fully correct. But the example clearly implies numeric and the resource canonical should defend against the common numeric-id case.

### Q3 — count subscriptions active as of 2026-01-01 — 4.875 STRONG PASS
**Acc 5 / Comp 4.5 / Clar 5 / Act 5**

Answer: `COUNT(*) WHERE start_date <= DATE '2026-01-01' AND (end_date IS NULL OR end_date > DATE '2026-01-01')`.

Verified against trino.io/docs/467/language/types.html (DATE literal `DATE 'YYYY-MM-DD'` valid) and the standard point-in-time overlap predicate ("started on/before the date AND not yet ended — end NULL or end > date"). Boundary semantics (`end_date > date` excludes subs ending exactly on the date) is a reasonable interpretation of "hadn't ended yet"; this matches the canonical at r07:969 ("A point-in-time snapshot (`WHERE start <= CURRENT_DATE AND (end IS NULL OR end > CURRENT_DATE)`) gives you ONE row: the count of active intervals as of today."). Comp -0.5 only because the answer could have one-line-noted the `>` vs `>=` boundary choice (inclusive-on-the-end-date variant). Otherwise bulletproof.

### Q4 — distinct product categories per customer — 5.0 STRONG PASS
**Acc 5 / Comp 5 / Clar 5 / Act 5**

Answer: `SELECT customer_id, COUNT(DISTINCT product_category) FROM orders GROUP BY customer_id`.

Trivial canonical, exactly the r23 §3 LEADING CANONICAL `COUNT(DISTINCT col) GROUP BY entity` shape. No dialect concerns. Bulletproof.

---

## iter639 directive: FIX-A (numeric->varchar coercion for listagg + array_join)

**FIX-A target**: r07:§1a.2A listagg / array_join canonical (and/or r23 cross-ref site wherever the listagg canonical lives) — ADD a one-line guardrail:

> **`listagg` and `array_join` require varchar elements — CAST numeric ids first.** Trino does NOT auto-convert numeric to varchar (same coercion rule as the §3.1A concat/format guardrail family). For numeric `order_id` (bigint/integer):
> - WRONG: `listagg(order_id, ', ') WITHIN GROUP (ORDER BY order_id)` -> "Unexpected parameters (bigint, varchar) for function listagg"
> - WRONG: `array_join(array_agg(order_id ORDER BY order_id), ', ')` -> same numeric-element type error (array_join does NOT auto-stringify)
> - RIGHT: `listagg(CAST(order_id AS varchar), ', ') WITHIN GROUP (ORDER BY order_id)`
> - RIGHT: `array_join(transform(array_agg(order_id ORDER BY order_id), x -> CAST(x AS varchar)), ', ')`
> - If `order_id` is already varchar, no cast needed.

Keyword anchors: "concat order ids", "comma-separated ids per customer", "roll up ids into one string", "list of order numbers per customer", "comma-separated bigint", "listagg integer", "array_join numeric".

Tie this directly to the iter633 concat/format number->varchar coercion guardrail family at r23:§3.1A (same defect class — Trino's no-implicit-numeric-to-character rule). Cross-link both anchors so the responder finds the rule from either entry point.

Effort: ADDITIVE only (no rewrite of the existing listagg canonical). Pure docs-verified guardrail. Same defect class that landed clean for concat/format at iter633.

## Topic avg updates

- SQL query best practices for OLAP / r23: Q1 macro-average two-level subquery clean +0.25, Q4 COUNT(DISTINCT) per-group clean +0.25 — net UP.
- Analytical query patterns on Iceberg+Trino / r07: Q2 listagg/array_join numeric-coercion gap -0.5, Q3 point-in-time active-as-of clean +0.25 — net DOWN mild.
- Federation NOT probed — 4.49944/310 row UNCHANGED.

## DO NOT (iter639)

- Touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter638).
- Rewrite the existing listagg / array_join canonical at r07:§1a.2A or r07:185 — additive guardrail only.
- Rewrite iter534-637 locks (max-per-group compare wrap-in-CTE r23 §3.1G, first-AND-last-per-entity plain-MIN/MAX anchor r23 §3.1D NEW iter638, concat/format coercion r23 §3.1A, rolling-distinct HLL r07, share-of-subset r07, PERCENT_RANK direction r07, DISTINCT-ON inoculation r23, etc.).
- Add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban), dayname/initcap fabrications.
- Bump training/state.json (per directive — already 638).
- Git commit/push beyond the rubric-line append.

## Meta-note

Q2 surfaces a number->varchar coercion class for `listagg` AND `array_join` — same family as the iter633 concat/format fix that landed clean at r23:§3.1A. Pattern is consistent: Trino's "no implicit numeric-character conversion" rule applies uniformly across string-producing functions (concat, ||, format, listagg, array_join). The remedy is also uniform (CAST, or transform+CAST for array elements, or printf-style format which natively accepts BIGINT). A single guardrail line at the listagg/array_join canonical, cross-referenced from the existing r23:§3.1A concat/format guardrail, should close the class.

Q1, Q3, Q4 all routed clean — three bulletproof answers, one accuracy defect. Overall PASS but the Q2 defect is real and worth a low-risk additive fix.

## Overall: 4.46875 PASS (margin +0.96875 above 3.5 floor)
