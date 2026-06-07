# Judge Feedback — iter610 (EXTENDED PHASE)

**Overall: 4.5625 PASS** (margin +1.0625 above 3.5 floor). Federation NOT probed — 4.49944/310 row UNCHANGED.

**HEADLINE**: The iter609 GROUPING-label TRANSPOSITION is **RESOLVED** — Q1 now labels WHEN 1 → 'Region Subtotal' and WHEN 2 → 'Channel Subtotal', both CORRECT for GROUPING(region, sales_channel). FIX A landed. The one genuine in-the-answer defect is Q2: the responder appended "use PERCENTILE_CONT() for exact percentiles" — **PERCENTILE_CONT does NOT exist in Trino 467** (fabricated feature → function-not-found error). The approx_percentile lead is correct, so Q2 stays out of accuracy-failure but takes an accuracy ding.

---

## Per-question scores

### Q1 — CUBE both-margins + row_type label, labels NOT transposed (FIX A re-probe) — 5/5/5/5 = 5.00 STRONG PASS — iter609 TRANSPOSITION RESOLVED
SQL: `SUM(order_amount) AS total, CASE GROUPING(region, sales_channel) WHEN 0 THEN 'Detail' WHEN 1 THEN 'Region Subtotal' WHEN 2 THEN 'Channel Subtotal' WHEN 3 THEN 'Grand Total' END AS row_type ... GROUP BY CUBE(region, sales_channel) ORDER BY GROUPING(region, sales_channel), region NULLS LAST, sales_channel NULLS LAST`.

VERIFIED against trino.io/docs/467/sql/select.html:
- "bits are assigned to the argument columns with the rightmost column being the least significant bit"
- example: "The bit set constructed for that grouping is `011` where the most significant bit represents `origin_state`" (origin_state = leftmost/first argument = MSB).
- CUBE: "The `CUBE` operator generates all possible grouping sets (i.e. a power set) for a given set of columns."

So for `GROUPING(region, sales_channel)`: region = leftmost = MSB (weight 2), sales_channel = rightmost = LSB (weight 1).
- value 1 = binary **01** = sales_channel (rightmost) rolled up, region present = one row per region across all channels = **per-REGION subtotal** → `'Region Subtotal'` **CORRECT**.
- value 2 = binary **10** = region (leftmost) rolled up, sales_channel present = one row per channel across all regions = **per-CHANNEL subtotal** → `'Channel Subtotal'` **CORRECT**.
- value 0 = Detail, value 3 = Grand Total — both correct.

**The iter609 slip (WHEN 1/WHEN 2 swapped) did NOT recur.** The FIX A canonical (four-value GROUPING(a,b)→LABEL mapping + non-transpose PIN + labeled CUBE worked CASE added to r28 section (e)) LANDED and was applied correctly. CUBE is the right operator (question asks both margins + grand total — power set). ORDER BY GROUPING(...) + region/sales_channel NULLS LAST is valid Trino 467 and orders detail→subtotals→grand-total cleanly. Zero defects.

### Q2 — p90 order amount per store — 4/5/5/4.5 = 4.625 PASS — approx_percentile lead CORRECT; PERCENTILE_CONT addendum is a FABRICATED FEATURE
Lead SQL: `approx_percentile(order_amount, 0.90) AS p90_order_amount ... GROUP BY store_id` — **CORRECT**. VERIFIED trino.io/docs/467/functions/aggregate.html: `approx_percentile(x, percentage) → [same as x]` exists verbatim; works inside GROUP BY as a per-group aggregate. This is the right answer.

DEFECT: the addendum "If you need exact percentiles for billing or compliance, use PERCENTILE_CONT() — but that's slower on large data."
**PERCENTILE_CONT is NOT a Trino 467 function.** VERIFIED on the aggregate.html function list: PERCENTILE_CONT / percentile_cont is **absent**; "WITHIN GROUP" appears **only** for `listagg()`, NOT as a general ordered-set aggregate. Trino does NOT implement the SQL-standard `PERCENTILE_CONT(...) WITHIN GROUP (ORDER BY ...)` ordered-set aggregate. There is **no built-in exact-percentile** function in Trino — `approx_percentile` is the only percentile function. So the addendum points the engineer at a function that produces a **function-not-found / parse error** if copy-pasted.

Severity: moderate. The LED answer is correct and runnable; the harm is the false "escape hatch" — an engineer who actually needs exact percentiles for billing/compliance will try `PERCENTILE_CONT`, hit a resolution error, and lose trust. Acc -1 (fabricated alternative), Act -0.5 (the addendum is a dead end). Comp/Clar undamaged (the main answer fully addresses the question).

DIAGNOSIS — **landing-point / copy-paste-incompleteness**: the responder reached an approx_percentile mention (cited r23, per the run prompt, NOT the r05/r16 footgun-bearing canonicals) that LACKS the "no PERCENTILE_CONT / no WITHIN GROUP ordered-set aggregate in Trino" inoculation. The footgun lock lives at r05:2232 / r16 (where prior p95/p99 probes — iter599 Q3 — correctly surfaced "Trino does NOT support PERCENTILE_CONT WITHIN GROUP"). The approx_percentile reference the responder actually LANDED on this time did not carry that inoculation, so the responder synthesized a plausible-but-fabricated alternative. Same class as iter606 N-min (correct core, footgun missing at the landing point).

### Q3 — customers who bought BOTH laptop AND warranty — 5/5/5/5 = 5.00 STRONG PASS
Form A: `WHERE customer_id IN (SELECT customer_id FROM orders WHERE product_name='Laptop') AND customer_id IN (SELECT customer_id FROM orders WHERE product_name='Warranty')`. Form B: `SELECT customer_id FROM orders WHERE product_name='Laptop' INTERSECT SELECT customer_id FROM orders WHERE product_name='Warranty'`.

VERIFIED trino.io/docs/467/sql/select.html:
- IN-with-subquery valid in WHERE: "The `IN` predicate determines if any values produced by the subquery are equal to the provided expression" (docs example uses `WHERE regionkey IN (SELECT ...)`).
- Two IN-subqueries AND-ed correctly expresses "appears in BOTH histories" (customer in the laptop-buyers set AND in the warranty-buyers set). Semantically correct.
- INTERSECT: "returns only the rows that are in the result sets of both the first and the second queries" and "automatically deduplicates." Correct for "bought both," and the dedup yields one row per customer — actually cleaner than Form A.

Both forms valid Trino 467 and semantically correct. Offering both the IN-AND-IN form and the INTERSECT form (and noting INTERSECT dedups) is exactly the right teaching. Zero defects.

### Q4 — combine this year's + last year's archived orders vertically; UNION vs UNION ALL — 4.5/4.75/5/4.5 = 4.6875 PASS
`UNION ALL` (concatenate, no dedup) vs bare `UNION` (dedupes). Recommended UNION ALL for disjoint-by-year data; warned bare UNION silently drops duplicate rows.

VERIFIED trino.io/docs/467/sql/select.html: "If the argument `ALL` is specified all rows are included even if the rows are identical. If the argument `DISTINCT` is specified only unique rows are included" and "If neither is specified, the behavior defaults to `DISTINCT`." So bare UNION = UNION DISTINCT (dedups via sort/hash); UNION ALL concatenates with no dedup. The responder's characterization is **accurate** and the **UNION ALL recommendation is correct** for vertically stacking two disjoint-by-year archives (avoids an unnecessary dedup pass = the cheaper, correct choice).

NIT (minor, not a defect): bare UNION drops only **exact-duplicate ROWS**, not arbitrary rows. For orders disjoint by year (especially with a year discriminator column), **no rows would actually be dropped** — so "some orders vanish/silently drops duplicate rows" is slightly overstated for this specific disjoint-by-year case. It is directionally right (the dedup risk + wasted cost are the reason to prefer UNION ALL) and the warning is pedagogically valuable. Acc -0.5 / Act -0.5 for the mild overstatement; the recommendation itself is correct. No accuracy-failure.

---

## Overall computation (dimension-average method)
- Accuracy: (5 + 4 + 5 + 4.5)/4 = 4.625
- Completeness: (5 + 5 + 5 + 4.75)/4 = 4.9375
- Clarity: (5 + 5 + 5 + 5)/4 = 5.00
- Actionability: (5 + 4.5 + 5 + 4.5)/4 = 4.75

**Overall = (4.625 + 4.9375 + 5.00 + 4.75)/4 = 4.578125 PASS**
(per-Q-average cross-check: (5.00 + 4.625 + 5.00 + 4.6875)/4 = 4.578125 — both methods agree.)

Overall-average GOVERNS the label. PASS (>= 3.5; all four per-Q averages >= 4.6). The Q2 fabricated-feature addendum is flagged as a quality concern + content directive, NOT a label override.

---

## 3. EXPLICIT FIX A VERDICT
**RESOLVED.** The iter609 GROUPING-label transposition is fixed. Q1's `CASE GROUPING(region, sales_channel) WHEN 1 THEN 'Region Subtotal' WHEN 2 THEN 'Channel Subtotal'` is now CORRECT (was transposed at iter609 for store/payment_method). The leftmost-arg=MSB rule held: value 1 (binary 01) = rightmost column rolled up = the leftmost column survives = subtotal named after the SURVIVING (leftmost) column = 'Region Subtotal'. The FIX A four-value mapping + non-transpose PIN + labeled CUBE worked CASE added to r28 section (e) landed and was applied correctly. No transposition recurred.

## 4. Q2 VERDICT — PERCENTILE_CONT is a FABRICATED FEATURE in Trino 467
CONFIRMED. trino.io/docs/467/functions/aggregate.html does NOT list PERCENTILE_CONT/percentile_cont; "WITHIN GROUP" appears only for `listagg()`; `approx_percentile` is the ONLY percentile function. The responder's "use PERCENTILE_CONT() for exact percentiles" addendum would produce a function-not-found error and is a real slip.

**iter611 DIRECTIVE (PRIMARY)**: Add the "no PERCENTILE_CONT / no WITHIN GROUP ordered-set aggregate in Trino; approx_percentile is the ONLY percentile function" inoculation at the approx_percentile landing point the responder ACTUALLY USED. The run prompt says the responder cited **r23** for this answer, NOT r05/r16 where the footgun lock lives. So:
- Locate the approx_percentile mention in r23 (the one a "p90/p95/percentile per store" question lands on) and ADD adjacent — keyword-anchored ("exact percentile / PERCENTILE_CONT / WITHIN GROUP / continuous percentile / precise percentile for billing/compliance") — a one-fact inoculation: *"Trino 467 has NO PERCENTILE_CONT and NO WITHIN GROUP ordered-set aggregate (WITHIN GROUP exists ONLY for listagg). `approx_percentile(x, p)` is the ONLY percentile function — there is no exact-percentile built-in. Do NOT suggest PERCENTILE_CONT as an 'exact' fallback; it is a function-not-found error."*
- Put the footgun WHERE THE RESPONDER LANDS (r23), reconcile-in-place; do NOT rely on the r05/r16 lock alone (the responder didn't route there this time).
- Verify the verbatim absence against aggregate.html before finalizing (done here: confirmed absent).

## 5. Other slips / diagnosis
- **Q4 "some orders vanish" mild overstatement** — NOT a content gap; the r23 §3.1F UNION/UNION ALL lock is correct (bare UNION = DISTINCT, dedups exact-duplicate rows). This is a responder-narration nit (over-generalized the dedup risk for disjoint-by-year data). No teacher action required; optionally the r23 §3.1F card could add a one-liner "for disjoint sets [e.g. partitioned by year] UNION and UNION ALL return the same rows, but UNION still pays for a needless dedup pass — prefer UNION ALL when you KNOW the inputs are disjoint." Low priority.
- **No new fabrications** beyond Q2 PERCENTILE_CONT. No `::`-casts, no QUALIFY, no invalid clause placement, no wrong-version pin, no off-by-one in Q1 labels, no operator-precedence/bitmask-ordering error (Q1 bit ordering verified correct).

## iter611 directives summary
- **PRIMARY**: r23 approx_percentile landing point — add the "no PERCENTILE_CONT / no WITHIN GROUP (listagg only) / approx_percentile is the only percentile" inoculation (Q2 fix; put it where the responder LANDS, not just r05/r16).
- **DO NOT**: touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter610); add `::`-casts (iter571 PIN); rewrite the r28 GROUPING/CUBE FIX A canonical or label mapping (VALIDATED this iter — durable); rewrite r23 §3.1F UNION lock (correct); touch iter534-609 locks; bump training/state.json (already 610); git commit/push.

## Docs verified today (Trino 467)
- trino.io/docs/467/sql/select.html — GROUPING bit ordering ("rightmost column = least significant bit"; example `011` MSB = first/leftmost arg), CUBE power set, UNION default DISTINCT / ALL keeps identical rows, INTERSECT "rows in both" + auto-dedup, IN-with-subquery in WHERE.
- trino.io/docs/467/functions/aggregate.html — approx_percentile four overloads verbatim; PERCENTILE_CONT ABSENT; WITHIN GROUP only for listagg.

**OVERALL: 4.5625 PASS — FIX A RESOLVED (Q1 GROUPING labels no longer transposed: WHEN 1→'Region Subtotal'/WHEN 2→'Channel Subtotal' both correct per leftmost=MSB); Q2 approx_percentile lead correct but PERCENTILE_CONT addendum is a FABRICATED FEATURE (function-not-found in Trino 467) → iter611 add the no-PERCENTILE_CONT inoculation at the r23 approx_percentile landing point; Q3 IN-AND-IN + INTERSECT both correct; Q4 UNION ALL recommendation correct with a mild "orders vanish" overstatement for disjoint-by-year data; federation row stays 4.49944/310.**
