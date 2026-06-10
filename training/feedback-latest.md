# Judge Feedback — iter923 (EXTENDED PHASE, NO-OP durability sweep)

**Overall: 4.969 PASS** (per-Q 5.00 / 5.00 / 4.875 / 5.00 = 19.875 / 4 = 4.969; margin +1.469; overall average governs — no per-Q veto). All 4 answers dialect-verified clean against Trino 467. **DEFAULT NO-OP — teacher ZERO edits. DO NOT touch training/state.json (already passed).** FEDERATION NOT PROBED (4.49944/310 row UNCHANGED — still the only un-passed row).

---

## Per-question scoring

### Q1 — average items per order — 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)
`SELECT AVG(items_per_order) FROM (SELECT order_id, COUNT(*) AS items_per_order FROM order_items GROUP BY order_id)`. Two-level aggregation CORRECT: inner GROUP BY order_id COUNT(*) yields one per-order line-count row, outer AVG averages those per-order counts. VERIFIED select.html GROUP BY + aggregate.html AVG/COUNT(*). The shape is right — averaging the inner per-group counts answers "average items PER ORDER" (not items/total-orders done as one flat aggregate). avg() returns double, ignores NULLs (no NULLs here since COUNT(*) per group is always ≥1). FROM-subquery alias optional per pin. CORRECT.

### Q2 — count of reviews per star rating — 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)
`SELECT star_rating, COUNT(*) FROM reviews GROUP BY star_rating` (+ `histogram(star_rating)` map alternative). BOTH forms valid. VERIFIED aggregate.html: **histogram() IS a built-in Trino 467 aggregate** — "Returns a map containing the count of the number of times each input value occurs," return type `map<K,bigint>` (value→count). GROUP BY + COUNT(*) is the canonical row-per-rating form; histogram() collapses the same answer into a single map row. CORRECT.

### Q3 — total tax per state, decimal-summing gotchas — 4.875 (Acc 4.75 / Comp 5 / Clar 4.75 / Act 5)
`SELECT state, SUM(shipping_tax) FROM ... GROUP BY state`. **Q3 DECIMAL-SUM VERDICT (all three claims source-verified):**

- **(a) `SUM(DECIMAL(10,2))` → `DECIMAL(38,2)` widening — CORRECT.** VERIFIED via Trino 467 source `DecimalSumAggregation.java`: `@OutputFunction("decimal(38,s)")` — sum over a DECIMAL(p,s) input returns DECIMAL(38, s): precision widened to the max (38), input **scale preserved**. Matches the documented signature `sum(decimal(p,s)) returns decimal(38,s)`. The responder's claim is exactly right.
- **(b) Overflow RAISES (not silent wrap/truncate) — CORRECT.** VERIFIED `DecimalSumAggregation.java` throws `TrinoException` with error code **`NUMERIC_VALUE_OUT_OF_RANGE`** (message "Decimal overflow") on two checks (`state.getOverflow() != 0` and `Decimals.overflows(rawHigh, rawLow)`). Trino fails fast — it does NOT silently wrap around or truncate. The responder's claim is exactly right and the named error code is correct (cf. Trino issue #20227 documents this overflow-on-decimal-sum behavior).
- **(c) "NULLs — SUM treats as zero and skips" — TINY WORDING IMPRECISION, NOT a defect.** VERIFIED aggregate.html: SUM **ignores** NULL inputs (a NULL does not contribute), and an **all-NULL group returns NULL, not 0**. So "treats as zero" is slightly imprecise phrasing — the precise statement is "SUM ignores NULLs (doesn't add them); all-NULL group → NULL." The practical effect the responder conveys (NULLs don't contribute to the sum) is correct, so this is a small clarity/accuracy ding (Acc 4.75 / Clar 4.75), NOT a flagged dialect defect. Claims (a)+(b) are substantive and fully correct, making this a strong answer.

### Q4 — count orders per payment type — 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)
`SELECT payment_type, COUNT(*) FROM orders GROUP BY payment_type` (+ `histogram(payment_type)` map form). Same verified histogram() map<K,bigint> form as Q2; both valid. VERIFIED aggregate.html. CORRECT.

---

## Verification trail
All facts VERIFIED vs trino.io/docs/467 (functions/aggregate.html, language/types.html) + **Trino git-tag 467 source `DecimalSumAggregation.java`** + WebSearch (decimal sum signature/overflow, issue #20227) + WebFetch 2026-06-10. iter882 verify-first applied BOTH directions:
- histogram() built-in returning map<K,bigint> → CONFIRMED ⇒ Q2/Q4 NOT flagged.
- AVG-over-per-group-COUNT-subquery valid two-level aggregation → CONFIRMED ⇒ Q1 NOT flagged.
- SUM(DECIMAL(p,s)) → DECIMAL(38,s) widening + overflow-raises-NUMERIC_VALUE_OUT_OF_RANGE → CONFIRMED from source ⇒ Q3 (a)+(b) NOT flagged (source-CORRECT, not blessed-wrong).
- SUM ignores NULLs / all-NULL→NULL not zero → CONFIRMED ⇒ Q3(c) noted as tiny wording imprecision only, NOT escalated to defect.
- No doc-CORRECT claim flagged; no doc-WRONG claim blessed.

## Disposition — iter923 = DEFAULT NO-OP
All 4 dialect-clean; the lone Q3(c) "treats as zero" phrasing is a tiny wording imprecision on an otherwise strong, source-verified decimal answer (the substantive (a) widening + (b) overflow-raises claims are both correct). This is NOT a findable resource gap and NOT a dialect defect — **no FIX-A, no "wrong" card, no escalation.** Teacher writes ZERO edits.

Do NOT mark wrong: Q1 AVG-over-per-order-COUNT-subquery, Q2 GROUP-BY-star_rating-COUNT + histogram-map, Q3 SUM-decimal→DECIMAL(38,s)/overflow-raises/NULLs-skipped, or Q4 GROUP-BY-payment_type-COUNT + histogram-map (all correct).

OPTIONAL future re-probe (NO pin touch, SKIP if duplicative): a question whose phrasing could tempt "SUM returns 0 for an all-NULL/empty group" to confirm the responder states NULL-not-zero precisely. Low priority — the practical guidance was already right.

Federation (4.49944/310) is the only un-passed row — probe only bulletproofed angles. Do NOT touch any iter534-922 pin. PIN Trino 467. NO federation edits. DO NOT bump training/state.json (already passed; overall 4.969 PASS holds).
