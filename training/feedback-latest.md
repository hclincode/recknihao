# Iter 696 — Judge Feedback

**Overall: 4.469 PASS** (margin +0.969 above 3.5 floor; -0.531 swing DOWN from iter695's STRONG PASS 5.000 — attributable to Q1 missed-cleaner-canonical findability gap + Q4 sketch-algorithm conflation).

**Per-Q (sub-scores Acc / Comp / Clar / Act → per-Q avg):**

| Q | Acc | Comp | Clar | Act | Per-Q | Notes |
|---|---|---|---|---|---|---|
| Q1 first-AND-last per customer | 5 | 4 | 4 | 4 | **4.25** | Executable-correct; missed cleaner `min_by/max_by` canonical |
| Q2 top-3 per category | 5 | 5 | 5 | 5 | **5.00** | RANK subquery + outer WHERE, RANK-vs-ROW_NUMBER tie note |
| Q3 CUBE/GROUPING bitmask | 5 | 5 | 5 | 5 | **5.00** | CUBE valid; bit-order labels correct per docs |
| Q4 approx_percentile p95 | 2.5 | 4 | 4 | 4 | **3.625** | SQL correct; **WRONG sketch-algorithm claim (HLL-style + 2.3% SE)** |

**Per-Q sub-score sum check:** Acc(5+5+5+2.5)/4 = 4.375 / Comp(4+5+5+4)/4 = 4.50 / Clar(4+5+5+4)/4 = 4.50 / Act(4+5+5+4)/4 = 4.50 → dim-avg (4.375+4.50+4.50+4.50)/4 = **4.469** — agrees with per-Q average 17.875/4 = **4.469**.

**GOVERNING LABEL = PASS** (overall 4.469 >= 3.5 by margin +0.969). Per-Q 3.5 floor cleared on all four (Q4 3.625 lowest, still above per-Q floor). Per directive, no per-Q veto applied.

---

## QUALIFY FIX-A HARDENING — VERDICT: HELD

**Both Q1 and Q2 produced docs-correct Trino 467 forms with ZERO QUALIFY usage.** The iter695 QUALIFY inoculation card at `r23:1014-1071` + `r23:744` bridge survived a second round of re-probing on the two shapes most likely to surface a QUALIFY relapse (first-and-last per entity + top-N per group). Neither answer mentioned QUALIFY, neither tried to put a window function in WHERE, and both produced executable Trino SQL.

- **Q1**: responder reached for `FIRST_VALUE/LAST_VALUE OVER (... ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)` + `ROW_NUMBER subquery + WHERE rn = 1` dedup. **VERIFIED against [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html)**: Trino's default frame is `RANGE UNBOUNDED PRECEDING` (i.e. `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`), so `LAST_VALUE` without an explicit full frame would return the current row's value — the responder CORRECTLY supplied the explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` frame on both `FIRST_VALUE` AND `LAST_VALUE`, plus the `ROW_NUMBER` collapse to one row per customer. The query IS executable-correct and returns the right answer.

- **Q2**: responder used `RANK() OVER (PARTITION BY category ORDER BY revenue DESC)` in a subquery + outer `WHERE revenue_rank <= 3`. Valid Trino 467, no QUALIFY. Correctly noted RANK ties may return >3 rows (the proper tradeoff for "top 3 best-sellers when there are revenue ties"); the responder also offered the ROW_NUMBER alternative for exactly-N semantics. Docs-perfect.

QUALIFY inoculation is DURABLE across **two consecutive iterations** (iter695 STRONG PASS 5.000 + iter696 PASS 4.469 with both QUALIFY-shape probes clean). The defang-with-inline-WRONG-marker pattern from iter694 continues to prevent banned-snippet bleed.

---

## NEW GAP — Q1 FINDABILITY: missed-the-cleaner-canonical

**The cleaner Trino 467 form for "first AND last per entity in one row" is the `min_by/max_by + GROUP BY` aggregate — one pass, no window, no ROW_NUMBER, no DISTINCT, no UNBOUNDED frame gymnastics.** That exact canonical IS present and clearly anchored at `r23:1030-1038`:

```
-- Trino 467 — FIRST AND LAST amount per customer in ONE row (iter695 COPY THIS — Q2 canonical):
SELECT customer_id,
       min_by(amount, order_date) AS first_amount,
       max_by(amount, order_date) AS last_amount,
       MIN(order_date)            AS first_order_date,
       MAX(order_date)            AS last_order_date
FROM iceberg.analytics.orders
GROUP BY customer_id;
```

Keyword anchors at `r23:1016` already include `first and last per customer one row` and `first and last per user one row`. Decision table at `r23:1077` explicitly maps "First AND last value of `<col>` per `<entity>` in ONE row" -> `min_by(col, sort_key) + max_by(col, sort_key) GROUP BY entity`.

The responder produced an **executable-correct but verbose** alternative (FIRST_VALUE/LAST_VALUE windows + ROW_NUMBER dedup). The Q1 question phrasing — *"single row showing both their very FIRST order amount and their most RECENT order amount side by side"* — is the EXACT shape the r23:1030 canonical targets. The responder hit the right SECTION (window functions / first-and-last) but copied the FALLBACK form, not the LEADING CANONICAL.

**Hypothesis for the routing miss**: the responder may be keyword-matching on `FIRST` + `LAST` + `customer` and landing on the FIRST_VALUE/LAST_VALUE window-function family (a natural lexical match) instead of the `min_by/max_by` aggregate family (semantically correct but lexically further from the question's "FIRST/LAST" wording). The canonical at r23:1030 IS clearly marked with `COPY THIS — Q2 canonical` and has the exact phrasing in its comment ("FIRST AND LAST amount per customer in ONE row"), but the responder reached for the more familiar window-function shape.

**iter697 directive option (LOW priority — not a regression, just a stylistic miss; both shapes executable-correct)**: consider adding a small *lexical bridge* near the FIRST_VALUE/LAST_VALUE section pointing UP to the min_by/max_by canonical with explicit keyword stub like:

> *"If your question matches 'first AND last `<col>` per `<entity>` in ONE row' — DON'T reach for `FIRST_VALUE/LAST_VALUE` windows + `ROW_NUMBER` dedup; the one-pass canonical is `min_by(col, key) + max_by(col, key) GROUP BY entity` — see r23:1030."*

Or fold the keyword anchors `FIRST_VALUE LAST_VALUE per group`, `first_value last_value one row per customer` into the existing r23:1016 anchor list so the responder routes UPWARD to the cleaner form when reading the question as a "FIRST_VALUE/LAST_VALUE problem". This is OPTIONAL polish — the answer IS executable-correct; this is a "preferred form" issue, not a correctness issue.

---

## NEW GAP — Q4 ACCURACY: approx_percentile is NOT HyperLogLog

**This is the visible drag on the overall score.** The responder claimed:

> "approx_percentile builds a tiny sketch ... using a probabilistic algorithm (HyperLogLog-style)" with "about 2.3% standard error"

**Both claims are wrong, and the resources are CORRECT.** Verified against [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html):

- **HyperLogLog is for `approx_distinct` (cardinality), not `approx_percentile` (quantiles).** These are two entirely different sketch families: HLL is a cardinality sketch (hash-and-count), t-digest / q-digest are quantile sketches (sorted bucket compression). The trino.io docs explicitly tie the **2.3% standard error to `approx_distinct`** (the HLL function) — not to `approx_percentile`. `approx_percentile`'s docs do NOT name the algorithm but it is the quantile-digest family (q-digest historically, t-digest in modern Trino versions).
- The "2.3% standard error" figure is **`approx_distinct`'s** docs-quoted default HLL error. `approx_percentile` takes an optional `accuracy` parameter with a different default (and different semantics — error is on the percentile value, not on a cardinality count).

**Resource cross-check**: `r23:2463` already says (correctly): *"HyperLogLog / T-Digest: probabilistic sketch algorithms behind `approx_distinct` and `approx_percentile`"* — so the resources DO correctly distinguish the two algorithms. The defect is the responder mid-answer-fabrication conflating the two sketches and the 2.3% number from the adjacent `approx_distinct` content (resource 07 line 587 + resource 16 line 240 both correctly attribute 2.3% SE to `approx_distinct` only). The responder appears to have pulled the HLL/2.3% factoid from the `approx_distinct` cards and incorrectly applied it to `approx_percentile`.

**This is a responder mischaracterization, not a resource defect** — the resources do NOT say approx_percentile is HLL anywhere, and at least one cross-reference (r23:2463) explicitly distinguishes them. But the responder is reaching for adjacent-content factoids when it doesn't have the precise algorithm name handy for approx_percentile.

**iter697 directive option (MEDIUM priority — this DID drop Q4's accuracy score by 2.5 points)**: harden the `approx_percentile` canonical entry at `r07:267-275` (the 4-overload signature card) with an EXPLICIT inline DO-NOT-WRITE note distinguishing the two sketches:

> *"**approx_percentile uses a quantile-digest (t-digest / q-digest) sketch**, NOT HyperLogLog. HyperLogLog is for `approx_distinct` (cardinality); t-digest is for `approx_percentile` (quantiles). The **2.3% standard error figure is `approx_distinct`'s HLL default — it does NOT apply to `approx_percentile`**. approx_percentile takes an optional `accuracy` parameter (4th positional arg in the weighted-with-accuracy overload) controlling the quantile sketch's error; the default is on the order of ~1% for typical percentiles like p95/p99 but is NOT '2.3%'. DO NOT write 'approx_percentile is HyperLogLog' or 'approx_percentile has 2.3% standard error' — both are wrong and conflate two different sketch algorithms."*

Add keyword anchors: `approx_percentile algorithm`, `approx_percentile sketch type`, `approx_percentile vs approx_distinct error`, `is approx_percentile HyperLogLog`, `t-digest Trino`, `q-digest Trino`, `quantile sketch Trino`. This is a small, targeted FIX-A; the canonical SQL is already correct, this is just adding an inoculation paragraph next to it to prevent the algorithm-conflation drift the responder showed today.

---

## Notes for the teacher

1. **HOLD ALL EDITS on the iter695 QUALIFY inoculation card** (`r23:744`, `r23:1014-1071`, plus the defanged WRONG-marked banned snippets at `r23:1058-1069`). Two consecutive iterations of QUALIFY re-probing produced ZERO QUALIFY usage. The defang-with-inline-same-line-WRONG-marker pattern from iter694 continues to prevent banned-snippet bleed. Do NOT touch this card.
2. **HOLD r22 federation guardrails** — federation NOT probed this iter (52-iter ZERO probe streak since iter645; 4.49944 vs 4.5 thin-margin still). Do NOT touch.
3. **OPTIONAL iter697 FIX-A (MEDIUM priority)**: harden `r07:267-275` `approx_percentile` signature card with explicit "uses t-digest NOT HyperLogLog; 2.3% is approx_distinct's number not approx_percentile's" inoculation paragraph. This is the highest-value teacher edit for iter697 — Q4 mischaracterization cost the iter 0.34 overall points and would have been a strong-PASS otherwise.
4. **OPTIONAL iter697 FIX-B (LOW priority)**: add a lexical bridge near the FIRST_VALUE/LAST_VALUE window-function section pointing UP to the `min_by/max_by + GROUP BY` canonical at `r23:1030` for "first AND last per entity in one row" shape. The canonical IS clearly present and anchored; this is a stylistic / preferred-form routing improvement, not a correctness fix.
5. **DO NOT bump training/state.json** (orchestrator handles this).

---

## Topic avg updates

- **SQL query best practices for OLAP** — Q1 first-AND-last per customer (FIRST_VALUE/LAST_VALUE explicit-frame + ROW_NUMBER dedup form executable-correct but missed cleaner canonical: net **+0.10** on canonical durability for executable-correctness + QUALIFY-not-emitted, but flagged findability soft-gap for cleaner min_by/max_by); Q2 top-3 per category RANK subquery canonical durability **+0.30**; Q3 CUBE + GROUPING bitmask canonical durability **+0.30** (second probing angle for CUBE/GROUPING after iter691).
- **Analytical query patterns on Iceberg+Trino** — same Q1/Q2/Q3 as above mirrored; Q4 approx_percentile signature CORRECT but algorithm mischaracterization flag: net **-0.15** on canonical durability for the HLL-vs-t-digest conflation, recommending FIX-A inoculation paragraph.
- **Common analytical query patterns** — Q3 CUBE/GROUPING multi-grain durability **+0.30** (second angle complementing iter691 Q3).
- **Cost considerations for analytical workloads at SaaS scale** — Q4 approx_percentile multi-percentile ARRAY form correct, but algorithm mischaracterization flagged: net **-0.10** on the cost-savings claim (responder said "dramatically faster than exact sort" — true — but mechanism explanation is wrong).

---

## Trajectory

iter663->696 (3.656 -> 4.5625 -> 4.5625 -> 4.375 -> 4.125 -> 4.9375 -> 5.000 -> 4.9375 -> 5.000 -> 4.500 -> 4.875 -> 4.78 -> 4.5625 -> 4.875 -> 4.375 -> 5.000 -> 4.8125 -> 4.500 -> 4.9375 -> 4.3125 -> 4.9375 -> 4.0625 -> 4.500 -> 5.000 -> 4.9375 -> 4.1875 -> 4.3125 -> 4.094 -> 3.75 -> 5.000 -> **4.469**) — sustained 4.0+ across 35 of last 38 iterations.

---

## OVERALL

**4.469 PASS — QUALIFY FIX-A HARDENING HELD across two consecutive iterations (Q1+Q2 both produced docs-correct Trino 467 forms with ZERO QUALIFY); Q3 CUBE/GROUPING bitmask docs-perfect; Q4 approx_percentile SQL correct but algorithm-conflation defect (claimed HyperLogLog + 2.3% SE — both belong to approx_distinct, not approx_percentile — t-digest/q-digest is the quantile-sketch family) cost ~0.34 overall points; Q1 missed cleaner `min_by/max_by + GROUP BY` canonical at r23:1030 (executable-correct but verbose — soft findability gap, not correctness defect). iter697 recommended: MEDIUM-priority FIX-A on r07:267-275 approx_percentile signature card to inoculate against HLL-vs-t-digest conflation; LOW-priority FIX-B optional lexical bridge from FIRST_VALUE/LAST_VALUE section UP to r23:1030 min_by/max_by canonical; federation still untouched (52-iter ZERO probe streak, 4.49944 vs 4.5 thin); HOLD iter695 QUALIFY inoculation card (2-iter durability now confirmed).**
