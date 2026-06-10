# Judge Feedback — iter967 (EXTENDED PHASE, NO-OP breadth sweep)

**OVERALL: 4.92 / 5 — STRONG PASS** (threshold 3.5; margin +1.42). Overall average governs; no per-Q veto.

All 4 dialect/logic claims verified BOTH directions against trino.io/docs/467 AND git-tag 467 source — NOT against resources/. This set is fully CLEAN: no broken-secondary tic, no QUALIFY/semi-join/MAX-varchar/percent_rank-inversion/fabricated-rule slips.

| Q | Topic | Acc | Clar | Act | Comp | Avg |
|---|---|---|---|---|---|---|
| 1 | avg line items / order, overall + by category | 5 | 5 | 5 | 5 | 5.00 |
| 2 | busiest hour of day (EXTRACT/hour, group across days) | 5 | 5 | 5 | 5 | 5.00 |
| 3 | spend-tier bucketing (width_bucket vs CASE) | 5 | 4.5 | 5 | 5 | 4.88 |
| 4 | multi-payment-method (json_array_length on VARCHAR) | 4.75 | 5 | 5 | 4.5 | 4.81 |

**Overall = (5.00 + 5.00 + 4.88 + 4.81) / 4 = 19.69/4 = 4.92 PASS**

---

## Per-question verification

### Q1 — avg line items per order (5.00)
- CTE materialization: overall `WITH items_per_order AS (SELECT order_id, COUNT(*) AS item_count GROUP BY order_id) SELECT AVG(item_count)` — CORRECT.
- **VERIFIED: `AVG(COUNT(*))` nested directly IS illegal in Trino** ("cannot use an aggregate on an expression containing an aggregate"; WebSearch 2026-06-11 + aggregate.html). Materializing the inner count in a CTE/subquery is the correct fix. The responder's explicit statement of this rule is accurate.
- By-category form `GROUP BY order_id, category` then outer `AVG GROUP BY category` reads as "avg items OF THAT CATEGORY per order that contains that category" — a coherent reading for cross-category orders. Not a defect.
- GROUP BY ordinal valid in Trino.

### Q2 — busiest hour of day (5.00)
- **VERIFIED BOTH `EXTRACT(HOUR FROM ts)` AND `hour(ts)` exist in Trino 467** and return 0-23 (datetime.html: EXTRACT lists HOUR field; `hour(x)` documented 0-23).
- GROUP BY the hour expression aggregates across all days, so 2pm-Tue + 2pm-Wed both fold into hour 14 — CORRECT. Postgres-equivalence note accurate.

### Q3 — spend-tier bucketing (4.88) — **width_bucket VERIFIED EXACTLY CORRECT (key check)**
- **VERDICT: responder's `width_bucket(lifetime_spend, ARRAY[100.0, 500.0])` mapping is PRECISELY right.** Verified against git-tag 467 `MathFunctions.java` array-bins variant: binary search returns `lower`; operand below first boundary → 0; an operand AT or ABOVE a boundary moves into the UPPER bin (boundaries are HALF-OPEN `[lower, upper)`); operand at/above the last boundary → numberOfBins.
- So `ARRAY[100.0, 500.0]` → `<100` = **0** ($0-100 = A), `100 <= x < 500` = **1** ($100-500 = B), `>= 500` = **2** ($500+ = C). Exactly the responder's claim.
- **CONSISTENT with CASE option B**: `< 100` A / `< 500` B / else C → exactly $100 → B, exactly $500 → C — same half-open boundaries as width_bucket. Both options agree at the boundary values. Correct.
- Guidance (width_bucket for equal-width / CASE for readable labels or unequal bins) is accurate.
- **-0.25 Clarity only**: the 3 tiers are unequal-width ($0-100 / $100-500 / $500+), so CASE is arguably the more natural primary; the bucket-number → tier-label mapping step (0→A, 1→B, 2→C) is left implicit. Minor; not an accuracy issue.

### Q4 — multi-payment-method (4.81) — **json_array_length VERIFIED (other key check)**
- **VERDICT: `json_array_length(payment_methods) > 1` directly on the VARCHAR column is CORRECT.** Verified json.html: `json_array_length(json) -> bigint`, documented argument "a string containing a JSON array" — it ACCEPTS a JSON-formatted VARCHAR directly, no `json_parse` needed (`json_array_length('["a","b"]')` = 2).
- **-0.25 Accuracy**: the "NEVER cast the JSON array to an ARRAY type and then call cardinality()" advice is slightly OVERSTATED — `cardinality(CAST(json_parse(x) AS ARRAY(VARCHAR)))` is ALSO a valid approach. But `json_array_length` IS the cleaner/correct tool, so the steer is right in spirit; not a defect. -0.25 Completeness for the absolutist "NEVER" framing where a hedged "prefer" would be more accurate.

---

## Scope / recommendation

- **NO resource defect. NO findability gap. ZERO resource edits warranted.**
- All four secondary alternatives this set were CORRECT (`hour()` alt, CASE alt, the cardinality caveat) — no broken-secondary-alternative tic this iteration, breaking the recent run of tacked-on-aside slips.
- **iter968 = DEFAULT NO-OP.** For fresh-angle durability, breadth-probe (a) a width_bucket EQUAL-WIDTH multi-boundary form (e.g. `ARRAY[10,20,30,40]`) and (b) `json_array_length` on a NESTED/2-d JSON array, to confirm boundary numbering and VARCHAR coercion hold from new angles.
- Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN per directive).
- MUST NOT bump training/state.json (already 967; `passed: true` preserved; `final_iterations_remaining: 0`). NOT bumped by judge.
