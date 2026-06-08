# Iter 703 — Judge Feedback (EXTENDED PHASE)

## Overall verdict: **PASS — 4.9375** (margin +1.4375 above 3.5 floor)

Both targeted re-probes from iter702 came back CLEAN. FIX-A1 (array_agg DISTINCT+ORDER BY shape) and FIX-A2 (per-segment bucket rollup) both **CLOSED**. Zero dialect defects, zero findability misses, zero new findable-but-missing gaps. Responder routed correctly to the new §1a.2A.1 inoculation card on Q1 and the new C4 companion card on Q2, and both citations land on the right lines.

---

## Per-Q sub-scores

### Q1 — array_agg ordered-distinct (FIX-A1 re-probe)
**Score: 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)**

Responder produced:
```sql
SELECT customer_id,
       array_join(array_agg(DISTINCT category ORDER BY category), ', ') AS categories
FROM purchases
GROUP BY customer_id;
```

- **Aggregate argument == ORDER BY key** (both are bare `category`, character-identical, both `varchar`). This is the **valid** shape per `trinodb/trino#20725` — the restriction "For aggregate function with DISTINCT, ORDER BY expressions must appear in arguments" only fires when the ORDER BY expression cannot be matched against an argument expression. Here it matches exactly. **Does NOT reproduce the iter702 Q4 CAST-mismatch parse error.**
- Verified against [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) — `array_agg(x)` signature confirmed, ORDER-BY-in-aggregate clause documented in "Ordering during aggregation" section.
- Verified against [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html) — `array_join(x, delimiter) → varchar` confirmed, NULLs omitted by default; with all-non-NULL varchar input this produces the exact comma-string requested.
- Responder cited resources/07 lines 232-245 — accurate cross-reference to the new §1a.2A.1 inoculation card.
- Quote "Use array_join(array_agg(DISTINCT col ORDER BY col), ', ') when the column is already varchar" matches the new Form C in the canonical.

**FIX-A1 verdict: CLOSED.** Inoculation card at r07 §1a.2A.1 caused the responder to pick the matching-arg form on first read. No regression to the iter702 mismatched-CAST shape.

### Q2 — bucket-rollup (FIX-A2 re-probe)
**Score: 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)**

Responder produced the two-CTE per-segment rollup shape:
```sql
WITH per_customer AS (
  SELECT customer_id, SUM(amount) AS total_revenue
  FROM orders GROUP BY customer_id
),
labeled AS (
  SELECT customer_id, total_revenue,
         CASE WHEN total_revenue<1000 THEN 'low'
              WHEN total_revenue<10000 THEN 'mid'
              ELSE 'high' END AS spending_tier
  FROM per_customer
)
SELECT spending_tier, COUNT(*) AS customer_count
FROM labeled
GROUP BY spending_tier
ORDER BY MIN(total_revenue);
```

- **Outer GROUP BY is `spending_tier` ONLY**, not `(customer_id, spending_tier)` — this is the correct per-band rollup granularity (one row per tier, customer_count populated correctly). **Does NOT reproduce the iter702 GROUP BY customer_id granularity bug.**
- Two-CTE shape (pre-aggregate per customer → label band → rollup by label) matches the new companion card at r07:3095 SHAPE (ii).
- `ORDER BY MIN(total_revenue)` is valid Trino 467 (aggregate in ORDER BY of a GROUP BY query — the ORDER BY expression is evaluated against the grouped rows; `MIN(total_revenue)` per spending_tier orders bands numerically rather than lexicographically). Verified against [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) ORDER BY grammar.
- Responder includes the explicit warning "if you include customer_id in the final GROUP BY, you'll get one row per customer with a count of 1, not the summary you want" — exact reproduction of the new ❌ DO NOT WRITE granularity trap block. This shows the inoculation card text propagated into the answer prose, which is the strongest possible signal that the FIX-A2 card is doing its job.
- Resource citation r07:3095-3154 lands on the new companion card.

**FIX-A2 verdict: CLOSED.** Companion card at r07:3095 caused the responder to pick the LABEL-ONLY GROUP BY shape on first read AND to surface the granularity-trap warning that was the iter702 root-cause confusion.

### Q3 — UNION vs UNION ALL
**Score: 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)**

- UNION ALL keeps all rows including duplicates (concatenation only) — confirmed against [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html): "If the argument `ALL` is specified all rows are included even if the rows are identical."
- Bare UNION is implicit UNION DISTINCT (dedups rows) — confirmed against the same page: "If neither is specified, the behavior defaults to `DISTINCT`."
- Cost characterization (cheap concat vs sort/hash-dedup) is qualitatively correct — DISTINCT requires a deduplication step that the planner implements via hash or sort.
- "Default UNION ALL for analytics; bare UNION only when you need cross-result dedup" is the right operational guidance for the SaaS engineer.
- Resource citation r23:957-989 — appropriate.

### Q4 — COALESCE for NULL → 'Unknown'
**Score: 4.75 (Acc 5 / Comp 4 / Clar 5 / Act 5)**

- `COALESCE(country, 'Unknown')` returns first non-NULL — verified against [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html): signature `coalesce(value1, value2[, ...])`, "Returns the first non-null `value` in the argument list." Correct.
- "Trino has no DDL DEFAULT, handle defaults in SELECT" is consistent with the iter681 CREATE-TABLE-no-constraints lock and is accurate for Trino 467 Iceberg CREATE TABLE grammar.
- **Minor completeness nit (prose only, NOT a defect):** the example wraps the COALESCE in a `GROUP BY customer_id, country` aggregation. The user's intent was "show 'Unknown' instead of blank in reports" — a non-aggregated `SELECT customer_id, COALESCE(country,'Unknown') AS country FROM customers` would have been the cleaner first illustration. The GROUP BY also groups by the raw `country` column rather than the COALESCE'd expression, so the COALESCE only affects the displayed value, not the grouping bucket — fine for COUNT but worth flagging. This is a 0.25-point completeness shave, not a correctness error. COALESCE itself, the no-DDL-DEFAULT note, and the resource citation all land correctly.

---

## Score arithmetic

- Per-Q averages: (5.00 + 5.00 + 5.00 + 4.75) / 4 = **4.9375**
- Sub-score sum: (20 + 20 + 20 + 19) / 16 = 79/16 = **4.9375** — agrees
- Dimensional averages: Acc (5+5+5+5)/4=5.00 / Comp (5+5+5+4)/4=4.75 / Clar (5+5+5+5)/4=5.00 / Act (5+5+5+5)/4=5.00 → (5.00+4.75+5.00+5.00)/4 = **4.9375** — agrees
- Governing overall: **4.9375 PASS** (margin +1.4375; all four Qs at or above the 4.75 per-Q floor)

---

## Iter704 directive

**DEFAULT NO-OP.** Both FIX-A1 (array_agg DISTINCT+ORDER BY) and FIX-A2 (per-segment bucket rollup) **CLOSED on first re-probe** with maximum signal — responder both produced the correct shape AND surfaced the inoculation-card warning text verbatim on Q2. No new findable-but-missing gaps surfaced across Q3 (UNION/UNION ALL) or Q4 (COALESCE) durability probes.

Recommended HOLD list for iter704:
- HOLD iter703 FIX-A1 (r07 §1a.2A.1 array_agg DISTINCT+ORDER BY inoculation card) — 1-iter durability, want one more fresh angle in iter705/706 to stamp 2-iter.
- HOLD iter703 FIX-A2 (r07:3095 per-segment bucket-rollup companion) — 1-iter durability, want one more fresh angle to stamp 2-iter.
- HOLD iter698 MoM card r07:2486 (5-iter durability).
- HOLD iter697 approx_percentile mirror r07:589 + r23:2463 (6-iter durability).
- HOLD iter695 QUALIFY card r23:744 + r23:1014-1071 (8-iter durability).
- HOLD r22 federation guardrails (59-iter ZERO probe streak; 4.49944 vs 4.5 thin — do NOT touch).
- HOLD all iter534-702 locks (~260 locks across 17 resource files).

Optional LOW-priority STYLE nudge for iter704 (NOT a fix): r23 COALESCE canonical could lead with a non-aggregated `SELECT customer_id, COALESCE(country,'Unknown') AS country FROM customers` example before the GROUP BY framing — would close the 0.25-point Q4 completeness shave. Hold for second confirmation before writing.

**No new genuine gaps for iter704. iter704 reverts to DEFAULT NO-OP.**
