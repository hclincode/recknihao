# iter959 Judge Feedback — RE-PROBE sweep (teacher ZERO edits)

**Verdict: 3.78125 PASS** (overall avg governs; margin +0.28; per-Q Q1 3.0625 / Q2 4.5 / Q3 4.875 / Q4 4.6875 = 15.125/4 = 3.78125). FEDERATION NOT PROBED (4.49944/310 row UNCHANGED).

Verified vs trino.io/docs/467 (functions/aggregate.html, sql/select.html, functions/datetime.html) + WebSearch 2026-06-10 (SUM(DISTINCT) sums distinct VALUES; UnwrapCastInComparison rewrites CAST(ts AS date) comparisons into bare-column ranges that still prune — both RE-CONFIRMED). NOT against resources/.

---

## ★ ★ ★ Q1 VERDICT — iter958 many-side-vs-one-side confusion RESOLVED on the COMPLEMENT angle; BUT secondary alternative SUM(DISTINCT) is a NEW broken-secondary slip ★ ★ ★

**Q1 score: Acc 2.5 / Comp 3.25 / Clar 3.5 / Act 3.0 = 3.0625**

### (a) DIAGNOSIS — CORRECT
Responder correctly identifies the ONE-side-attribute fan-out mechanism: orders (one row per order, carries order_total) joined to order_items (many per order) REPLICATES the order row, so SUM(order_total) over the join multiplies each order's total by its line-item count. Worked example "Order 42 total=100, 3 items → SUM=300 not 100" is dialect-correct and the precise complement of iter958 (where the responder MIS-marked the many-side SUM(li.quantity) as over-counted). This iteration the diagnosis correctly distinguishes the ONE-side-OVER-COUNTS case from the MANY-side-FINE case. → **iter958 many-side-vs-one-side confusion = ONE-OFF responder synthesis miss, RESOLVED on the COMPLEMENT angle**.

### (b) Option A — CORRECT (lead fix)
`SELECT customer_id, SUM(order_total) FROM orders GROUP BY customer_id` (do NOT join order_items). TRACE on customer C with O1(total=100,2items), O2(total=100,2items), O3(total=50,2items): 100+100+50 = **250 = true revenue**. CORRECT. The "just don't join" lead fix is the canonical answer when the join is unnecessary.

### (c) Option B — BROKEN SUBTLE BUG (the SUM(DISTINCT) slip)
`SUM(DISTINCT o.order_total) ... FROM orders o JOIN order_items oi ...` — labeled "if you MUST join to order_items".

**TRACE on customer C** with O1(total=100, 2 items), O2(total=100, 2 items), O3(total=50, 2 items):
- After JOIN, the customer-C joined rows have order_total values: {100, 100, 100, 100, 50, 50} (6 rows).
- DISTINCT VALUES = {100, 50}.
- SUM(DISTINCT order_total) = **150 != 250**.

**SUM(DISTINCT col) sums distinct VALUES, not per-order values** — it collapses the two distinct orders O1 and O2 into one because they happen to share the same $100 total. Verified vs trino.io/docs/current/functions/aggregate.html (WebSearch 2026-06-10 RE-CONFIRMED): DISTINCT keyword ensures the aggregate is applied to a unique set of attribute VALUES — not unique per-entity values.

**This is a SUBTLE BUG**: it silently UNDERCOUNTS whenever two distinct orders for the same customer share a total dollar amount (extremely common in practice — round-number subscription tiers, fixed-price SKUs, identical promo amounts). The user will pass the surface "join-doesn't-overcount-anymore" check, then ship wrong revenue numbers in production.

The CORRECT "if you must join" fixes are:
1. **Pre-aggregate order_items to one-row-per-order first** (CTE: `WITH oi_per_order AS (SELECT order_id FROM order_items GROUP BY order_id) ...`), then join, then SUM(order_total) GROUP BY customer_id.
2. **De-dupe by one-side key**: `SELECT customer_id, SUM(order_total) FROM (SELECT DISTINCT o.customer_id, o.order_id, o.order_total FROM orders o JOIN order_items oi ON o.order_id=oi.order_id) GROUP BY customer_id`.
3. **ROW_NUMBER() = 1 by order_id** to keep one row per order before SUM.

NOT SUM(DISTINCT order_total).

### Defect scoping
This is the **broken-secondary-alternative meta-pattern** (iter936/943/948/950/954/958 family) — the LEAD fix is correct, but an "if you must / shortcut" alternative ships a subtle bug. Q1 diagnosis + Option A is the answer to the question and is correct; Option B is gratuitous and wrong-by-collapse-of-equal-values.

SCOPE: 1st-instance of SUM(DISTINCT)-as-dedup-by-key slip. NOT a recurring defect family yet — meta-pattern persists across surfaces but the SPECIFIC SUM(DISTINCT) form is new. iter958 many-side-vs-one-side confusion = ONE-OFF (RESOLVED on complement angle).

---

## Q2 — Acc 5 / Comp 4 / Clar 4.5 / Act 4.5 = 4.5 CLEAN

`SELECT product_id, new_price, changed_at FROM price_history WHERE changed_at >= current_timestamp - INTERVAL '30' DAY ORDER BY ...` — `INTERVAL '30' DAY` qualifier valid 467 per reference_trino_interval_qualifiers.md (DAY is one of the six valid qualifiers); `current_timestamp - INTERVAL` returns timestamp; comparison preserves timestamp type. CORRECT.

The day-precision variant `CAST(changed_at AS date) >= current_date - INTERVAL '30' DAY` plus the claim "Trino unwraps the CAST into a bare-column range so partition pruning still works" — VERIFIED CORRECT per reference_trino_unwrap_temporal_predicates.md and trino.io/blog/2023/04/11/date-predicates.html: UnwrapCastInComparison rule (default-on in 467) rewrites CAST(ts AS date) comparisons into bare-column timestamp range comparisons that STILL prune partitions. NOT a false claim.

Minor completeness knock: the question asked for **products** whose price changed; responder returned price_history change-event rows (product_id, new_price, changed_at) rather than `SELECT DISTINCT product_id`. A `SELECT DISTINCT product_id FROM price_history WHERE changed_at >= current_timestamp - INTERVAL '30' DAY` more directly answers "which products". Minor framing, not a defect.

## Q3 — Acc 5 / Comp 4.75 / Clar 5 / Act 4.75 = 4.875 CLEAN

`SELECT EXTRACT(YEAR FROM created_at) AS signup_year, COUNT(*) FROM users GROUP BY EXTRACT(YEAR FROM created_at) ORDER BY signup_year`. Verified valid 467 per functions/datetime.html: EXTRACT(YEAR FROM ts) returns integer year-field; GROUP BY repeats the expression (not the alias — sql/select.html); ORDER BY alias resolves; YEAR(created_at) equivalent shorthand also valid. NULL created_at produces its own bucket (standard SQL). Clean.

## Q4 — Acc 5 / Comp 4.5 / Clar 4.75 / Act 4.5 = 4.6875 CLEAN

`SELECT name, COUNT(DISTINCT category_id) AS num_categories FROM products GROUP BY name HAVING COUNT(DISTINCT category_id) > 1 ORDER BY num_categories DESC`. Verified valid 467: single-arg COUNT(DISTINCT) per reference_trino_count_distinct_single_arg.md; HAVING after aggregation per sql/select.html; HAVING references aggregate not alias — CORRECT; ORDER BY alias resolves. Clean.

---

## iter960 RECOMMENDATION = DEFAULT NO-OP + optional LIGHT FIX-A only if SUM(DISTINCT)-as-dedup slip OR many-side-vs-one-side confusion recurs on different surface in next 2 sweeps

**Reasoning**:
1. Overall 3.78125 PASS (margin +0.28 — TIGHT but holds; overall average governs, no per-Q veto).
2. iter958's many-side-vs-one-side confusion = **RESOLVED on complement angle** — responder correctly diagnosed the ONE-side over-counting mechanism this iteration. The iter958 slip was a one-off synthesis miss, not a routing failure or findability gap. The r23 fan-out card LIGHT FIX-A deferral from iter958 still holds — do NOT add a card now.
3. Q1's Option B SUM(DISTINCT) slip is the broken-secondary-alternative meta-pattern recurring on a NEW surface (1st-instance for SUM(DISTINCT)-as-dedup specifically). Diagnosis + lead fix is correct; the "if you must join" alternative ships a subtle undercount.
4. Per `feedback_new_card_over_attracts_adjacent.md`: adding a SUM(DISTINCT)-WRONG card now risks pulling adjacent legitimate-SUM(DISTINCT) questions ("sum of distinct order subtotals across catalog tiers", "sum of distinct discount amounts applied") to the wrong canonical. Defer.
5. Q2/Q3/Q4 all clean across distinct families (temporal range + UnwrapCast / EXTRACT YEAR + GROUP BY / COUNT(DISTINCT) + HAVING > 1) — no other defects.
6. Optional LIGHT FIX-A trigger: if SUM(DISTINCT)-as-dedup-by-key OR many-side-vs-one-side confusion recurs on a different surface in next 2 sweeps, add ONE brief card to r23 near the fan-out section with copy-attractive CORRECT (pre-aggregate per order_id CTE) vs WRONG-DO-NOT-COPY (SUM(DISTINCT order_total) over join — collapses different orders sharing same total) + WHICH-X router. Use inline-WRONG-marked DO-NOT-COPY per `feedback_defang_donotwrite_snippets.md`. Keep BRIEF.
7. NEXT SWEEP PROBES: a different one-side-over-counts angle (e.g., AVG(order_total) over orders x line_items; MAX(order_total) over the join — verify responder doesn't conflate "MAX-of-replicated-value is fine, SUM-of-replicated-value is broken"); a question explicitly designed to elicit a legitimate SUM(DISTINCT) use to test if the responder still reaches for it correctly when appropriate; window-frame BETWEEN N PRECEDING AND N FOLLOWING; GROUPING SETS / ROLLUP / CUBE; lateral JOIN UNNEST. Do NOT re-probe gaps-and-islands streak-construction yet. Do NOT probe federation outside bulletproofed angles.
8. DO NOT TOUCH: r23 fan-out card (defer to recurrence-driven LIGHT FIX-A) / r07 L3226-3263 strengthened B-Streak defang / r07 L37 (HAVING-perf) / r07 L1624 (anti-nesting) / r07 NESTED_WINDOW WRONG #1+#2 / two-GROUP-BY WRONG #2 / r23 §3.1G argmax / COUNT(DISTINCT) canonical / HAVING-vs-WHERE / QUALIFY-not-Trino / regexp_like card / NULLS-LAST default / geometric/harmonic mean cards / r09 partition DDL strings + bucket(col,N) column-first / r28 DATE-literal + date_trunc-to-range nuance / r13 json_exists strict path / r22 section 13.x federation (all rows hard-locked) / percentile cards / INTERVAL qualifier cards / format_datetime-vs-to_char card / PARTITIONED-BY guidance / price-suffix canonical / MAX_BY-nested defang.

**PINS REINFORCED**:
- **SUM(DISTINCT col) sums distinct VALUES, not per-entity values** — collapses different entities that happen to share the same column value; NOT a valid de-dup-by-key fix for fan-out. Verified vs trino.io/docs/current/functions/aggregate.html WebSearch 2026-06-10.
- **One-to-many JOIN over-counts SUM of a ONE-side attribute** (replicated per match); fix = (a) pre-aggregate the many side to one-row-per-one-side first, (b) sum the one-side attr WITHOUT the join, or (c) de-dupe by one-side key (ROW_NUMBER=1 / SELECT DISTINCT on one-side-key + one-side-attr).
- **SUM of a MANY-side attribute over the one-to-many JOIN is FINE** (each many-side row contributes its value exactly once) — iter958 confusion RESOLVED on complement angle this iteration.
- **INTERVAL '30' DAY** qualifier valid (DAY is one of six valid qualifiers per reference_trino_interval_qualifiers.md).
- **UnwrapCastInComparison** rewrites CAST(ts AS date) comparisons to bare-column timestamp range comparisons that STILL prune partitions (default-on 467) per reference_trino_unwrap_temporal_predicates.md.
- **EXTRACT(YEAR FROM ts)** / **YEAR(ts)** return integer year-field; GROUP BY repeats expression not alias per sql/select.html.
- **HAVING COUNT(DISTINCT x) > 1** for "in more than one distinct group"; single-arg COUNT(DISTINCT) per reference_trino_count_distinct_single_arg.md.
- **broken-secondary-alternative meta-pattern** persists across surfaces (iter936/943/948/950/954/958/959 family); LEAD fix routinely correct, "if you must / shortcut" alternative ships subtle bugs.

PIN 467. DO NOT bump training/state.json (already 959; passed=true preserved; overall 3.78125 PASS holds; final_iterations_remaining 0).
