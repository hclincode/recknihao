# Judge Feedback — iter760 (EXTENDED PHASE)

**Mode**: re-probe-for-BULLETPROOFED (Q1 cume_dist 4th scenario) + durability-breadth (Q2/Q3/Q4 fresh)
**Overall**: 4.5625 — **PASS** (margin +1.0625 above 3.5 floor; OVERALL AVERAGE governs, no per-Q veto)

All four dialect claims verified against trino.io/docs/467 (window.html, sql/select.html, comparison.html) — NOT taken from resources/ as ground truth.

---

## Per-question scores

### Q1 — cume_dist RE-PROBE (fraction of warehouses at or below this one) — 5.00
- Accuracy **5** / Completeness **5** / Clarity **5** / Actionability **5**
- `CUME_DIST() OVER (ORDER BY avg_fulfillment_time) AS fraction_at_or_below`.
- VERIFIED [trino.io/docs/467/functions/window.html](https://trino.io/docs/current/functions/window.html): cume_dist() = "the number of rows preceding or peer with the row ... divided by the total number of rows" = fraction AT OR BELOW (ties included), range 0..1, top row = 1.0, lowest ~1/N (never 0, since every row is at-or-below itself). EXACTLY matches the question (fastest≈1/N, slowest=1.0).
- Responder EXPLICITLY rejected percent_rank with the correct reason: "percent_rank measures rank position (rank-1)/(n-1), lowest=0.0; you want CUME_DIST for fraction at or below." Docs-confirmed: percent_rank() = (r-1)/(n-1), first row = 0.0 = relative-rank POSITION, NOT the at-or-below fraction.
- **cume_dist is BULLETPROOFED.** This is the 2nd consecutive clean datapoint post-fix (iter759 landing-card router/defang + iter760). The iter759 FIX-A (at-or-below STOP router + inline ✅cume_dist/❌percent_rank defang placed at the percent_rank LEADING card where the responder lands) is now confirmed durable across a fresh 4th business phrasing ("fraction of warehouses at or below"). No further work on this axis.

### Q2 — Hierarchical rollup: (region,product) detail + subtotal JUST PER REGION + grand total — 3.25
- Accuracy **3** / Completeness **3** / Clarity **4** / Actionability **3**
- Responder used `GROUP BY CUBE(region, product)` + GROUPING(region,product) bitmask CASE (0=detail, 1=region-total, 2=product-total, 3=grand-total). Noted GROUPING SETS as an alternative for "no detail". **Did NOT mention ROLLUP at all.**
- **ROLLUP vs CUBE verdict (docs-verified [trino.io/docs/467/sql/select.html](https://trino.io/docs/current/sql/select.html)):**
  - The question asked for EXACTLY: `(region,product)` detail + a subtotal **just per region** + grand total. That is precisely `GROUP BY ROLLUP(region, product)` → grouping sets `(region,product), (region), ()`.
  - `CUBE(region, product)` → `(region,product), (region), (product), ()` — it ADDITIONALLY emits the per-PRODUCT subtotal (region rolled up) rows that the user **explicitly did not want** ("just per region").
  - So the CUBE answer is a **SUPERSET that over-produces unwanted per-product subtotal rows.** ROLLUP is the precise fit.
- The GROUPING bitmask the responder gave IS docs-correct (leftmost=region=MSB; 0=both present=detail, 1=binary 01=product rolled up=region subtotal, 2=binary 10=region rolled up=per-product subtotal, 3=binary 11=grand total). So the construct is valid Trino, just the WRONG operator for the stated requirement — and the bitmask even includes a "2=product-total" branch for rows the user never asked for.
- This is NOT a dialect error (CUBE is valid Trino 467) — it is a **selection/findability imprecision**: the responder returns extra rows and never named the exact-fit operator.

### Q3 — Zero-fill all five fixed priority levels (0 for empty ones) — 5.00
- Accuracy **5** / Completeness **5** / Clarity **5** / Actionability **5**
- `VALUES ('critical'),('high'),('medium'),('low'),('none')` spine LEFT JOIN ticket_counts + `COALESCE(cnt, 0)`.
- VERIFIED: VALUES-spine + LEFT JOIN + COALESCE is the correct Trino 467 zero-fill idiom (left side preserves all five fixed categories; unmatched right side NULL-pads; COALESCE→0). The responder's warning is **accurate**: `COUNT(*)` on a left-joined NULL-padded row returns 1 (counts the padded row), so use `COALESCE(SUM(...),0)` or `COUNT(right_col)`. Fresh-clean.

### Q4 — Clamp a value to [-50, +50] — 5.00
- Accuracy **5** / Completeness **5** / Clarity **5** / Actionability **5**
- `GREATEST(LEAST(credit_adj, 50), -50) AS clamped`.
- VERIFIED [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/current/functions/comparison.html): greatest()/least() are native, return largest/smallest of provided values. `GREATEST(LEAST(x, hi), lo)` clamps to [lo, hi] (LEAST caps the ceiling at 50, GREATEST floors at -50). NULL-propagation caveat is **accurate** — docs: "they return null if any argument is null" (unlike Postgres which only nulls when ALL are null); wrapping COALESCE if NULL→0 is the right guard. Fresh-clean.

---

## Overall computation
- Per-Q avg: (5.00 + 3.25 + 5.00 + 5.00) / 4 = 18.25 / 4 = **4.5625**
- Dim-avg cross-check: Acc (5+3+5+5)/4=4.50 / Comp (5+3+5+5)/4=4.50 / Clar (5+4+5+5)/4=4.75 / Act (5+3+5+5)/4=4.50 → (4.50+4.50+4.75+4.50)/4 = 4.5625 — agrees.
- **GOVERNING LABEL = PASS** (4.5625 ≥ 3.5, margin +1.0625).

---

## Teacher feedback / iter761 designation

**cume_dist = BULLETPROOFED** (2nd consecutive clean datapoint, iter759+iter760; the landing-card router+defang is durable). **Q3 zero-fill and Q4 clamp = fresh-clean** on first probe (no resource gap, no dialect defect).

**iter761 = FIX-A (ROLLUP-vs-CUBE selection-router), LOW/MINOR priority.**

This is a **findability/selection gap, NOT a missing-canonical gap.** The ROLLUP canonical DOES exist and is excellent:
- `resources/28-complex-sql-performance-trino-dbt.md:413` — "LEADING CANONICAL — Trino GROUPING SETS / ROLLUP / CUBE with the GROUPING() bitmask"
- The `### DECIDE FIRST` router at r28:419-427 already states it precisely: "Need ONLY hierarchical / prefix subtotals — a drill-down where each level rolls up the **RIGHTMOST** column → `ROLLUP(a, b)`" and "**KEY:** `ROLLUP(a, b)` emits `(a,b), (a), ()`."

So the content is correct and present, but the responder still routed to CUBE and never surfaced ROLLUP. The defect is that the existing router is framed almost entirely around the **CUBE-vs-GROUPING-SETS** distinction ("subtotals on BOTH dimensions" / "every combination" / "hand-picked set"). The **business phrasing this question used** — "subtotals per (region,product) PLUS a subtotal just per region PLUS a grand total" / "hierarchical rollup" / "drill-down" / "subtotal per group + grand total" — does not strongly hit the existing keyword anchors, which are weighted toward the both-dimensions/every-combination cases. The ROLLUP branch is the only one without business-phrased decision anchors at the top. The very FIRST SQL block under the card (r28:430) is also a "WRONG — ROLLUP drops the (category) subtotal" defang for the both-dimensions case, which may be steering the responder AWAY from ROLLUP even when the case is genuinely hierarchical.

**Recommended FIX-A (single edit, r28:413 card, reconcile-in-place — do NOT churn the existing CUBE/GROUPING-SETS content):**
1. Add ROLLUP-side decision keyword anchors to the "Decision keyword anchors" block (r28:417) and the DECIDE-FIRST ROLLUP bullet (r28:424): "subtotal per group + grand total", "subtotals down a hierarchy", "detail rows + a subtotal just per <leftmost dim> + grand total", "drill-down totals", "rollup by region then product", "subtotal for each region plus overall total".
2. Add a one-line disambiguator to the ROLLUP bullet: "If the question asks for `(a,b)` detail + a subtotal **just for `a`** (the leftmost/outer dimension) + grand total — and does NOT ask for a per-`b` subtotal — that is `ROLLUP(a, b)`, NOT `CUBE`. CUBE would add the unwanted `(b)`-only per-`b` subtotal rows."
3. Add a copy-attractive clean `GROUP BY ROLLUP(region, product)` worked example with correct `WHEN 1 THEN 'Region Subtotal' WHEN 3 THEN 'Grand Total'` labeling, positioned so it reads as the canonical for "detail + per-region subtotal + grand total" (not buried after the both-dimensions defang block).

This is a thin/minor imprecision (overall still a comfortable PASS at 4.5625; CUBE is valid Trino and the bitmask was correct), but the responder returning extra rows the user explicitly excluded is a real selection defect worth a targeted router nudge. Re-probe in a later iter with explicit hierarchical phrasing ("product detail within each region, then a subtotal per region, then one grand total — no per-product-across-regions row") to confirm the ROLLUP route lands.

**HOLD** all standing locks: iter759 percent_rank-card at-or-below router+defang (CONFIRMED durable this iter), cume_dist sibling, running-product r07 §5, LOCF, event-gap, full regex/map/array/window/date/string/math/aggregate families. Federation r22 untouched. Do NOT bump state.json.
