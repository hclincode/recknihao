# Judge Feedback — iter758 (DUAL FIX-A re-probe)

**Overall: 4.19 / 5 — PASS** (threshold 3.5; overall average governs, no single-Q veto)

All dialect claims verified against trino.io/docs/467 (window.html, datetime.html, aggregate.html, math.html) on 2026-06-09. Resources are NOT treated as ground truth. Production stack (Trino 467 + Iceberg, on-prem) accounted for; no auth/authz scope involved.

---

## Per-question scores

### Q1 — Running/cumulative PRODUCT of weekly retention fractions
Answer: `EXP(SUM(LN(retention_fraction)) OVER (ORDER BY week_number ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))`, explained ln-sum-exp = product, stated "requires all values positive," cited new running-product canonical.

- Accuracy: **5** — DOCS-VERIFIED. sum() is a valid window fn with OVER+frame; ln/exp confirmed; ln(x) requires x>0 (ln(0)=-inf, ln(neg) not real). No native product()/cumulative-product fn in Trino 467, so log-sum-exp is the correct idiom. The x>0 caveat is exactly right.
- Completeness: **5** — Frame clause correct, positivity caveat present, identity explained.
- Clarity: **4** — Solid; the ln-sum-exp explanation is accessible, but a one-line worked example ($1 compounding) would lift it further.
- Actionability: **5** — Copy-paste ready for the new canonical.
- **Per-Q avg: 4.75**

### Q2 — Fraction of products with rating AT OR BELOW this one (highest=1.0, middle~0.5, lowest near 0)
Answer: `PERCENT_RANK() OVER (ORDER BY avg_rating)`, claimed it returns "fraction of rows at or below," "lowest ≈ 0.0, middle ≈ 0.5, highest = 1.0." Did NOT use cume_dist().

- Accuracy: **2** — WRONG FUNCTION + WRONG BOUNDARY CLAIM (docs-verified). `percent_rank() = (r-1)/(n-1)`: the lowest row = **0.0**, which is NOT "fraction at or below" (the lowest row is at-or-below itself, so its true at-or-below fraction is ≥ 1/N, never 0). The correct function for "fraction of rows at or below" is `cume_dist()` (lowest ≈ 1/N, top = 1.0, ties included). cume_dist's lowest is ~1/N (close to 0 for large N), so it also satisfies the "close to 0" phrasing while being semantically correct. This is the SAME selection defect as iter757, now repeated.
- Completeness: **3** — Produced a runnable query and addressed the shape, but answered the wrong question.
- Clarity: **4** — Well-written and confident — which makes the wrong claim more dangerous in production.
- Actionability: **3** — Copy-pasteable but would mislead the engineer into shipping the wrong metric.
- **Per-Q avg: 3.0**

### Q3 — Truncate order_date to first day of its month (monthly rollup)
Answer: `date_trunc('month', order_date) AS month_start ... GROUP BY date_trunc('month', order_date)`.

- Accuracy: **5** — DOCS-VERIFIED: `date_trunc('month', x)` returns the first day of the month at midnight; day/week/month/quarter/year all supported units.
- Completeness: **5** — Truncation + GROUP BY both shown, full rollup pattern.
- Clarity: **5** — Clear, zero assumed knowledge.
- Actionability: **5** — Drop-in.
- **Per-Q avg: 5.0**

### Q4 — Median (50th pct) order value per category, NOT the mean, robust to outliers
Answer: `approx_percentile(order_amount, 0.5) AS median_order_value ... GROUP BY product_category`; explained 0.5=median, t-digest, robust at scale; noted Trino has NO percentile_cont / NO median() (those are Postgres/SQL-Server).

- Accuracy: **5** — DOCS-VERIFIED: approx_percentile(x, 0.5) is the native median idiom; no percentile_cont, no median() in Trino 467. Minor loose phrasing if it implied "exact for small N" (it is always approximate, though highly accurate) — noted, not a hard defect.
- Completeness: **5** — Addresses median vs mean, outlier robustness, the no-percentile_cont/no-median trap.
- Clarity: **5** — Clear contrast with mean.
- Actionability: **5** — Drop-in per-category median.
- **Per-Q avg: 5.0**

---

## Overall
(4.75 + 3.0 + 5.0 + 5.0) / 4 = **4.19 / 5 — PASS.**

---

## Topic verdicts

- **running-product — CLOSED (1st post-fix datapoint).** The iter758 FIX-1 canonical landed: responder found `exp(sum(ln(x)) OVER (... ROWS UNBOUNDED PRECEDING ...))`, cited it, and stated the x>0 caveat. Docs-verified clean. Keep one more re-probe before treating it as fully bulletproofed, but this datapoint is a clean PASS.
- **date_trunc-month — solid.** Clean.
- **approx_percentile-median — solid.** Clean; only watch the "exact for small N" phrasing.
- **cume_dist-vs-percent_rank — STILL FAILING.**

---

## Q2 cume_dist verdict: iter758 findability fix was INSUFFICIENT

The iter758 FIX-2 added at-or-below keyword anchors + a router at the **cume_dist "Sibling" card**. The responder STILL picked `percent_rank()`. It cited the percent_rank Pattern C2 region (which now contains the cume_dist sibling) — so it landed in the RIGHT AREA but chose percent_rank anyway. Root cause: percent_rank is the PRIMARY/leading card in that region; cume_dist is only a subordinate "Sibling," so the percent_rank card out-pulls. Anchoring the disambiguation only at the sibling does not intercept a responder that lands on the leading card first.

### iter759 = FIX-A (stronger cume_dist-vs-percent_rank disambiguation AT the percent_rank card)

Put an INLINE DEFANG/disambiguation **on the percent_rank card itself** — where the responder actually lands — not only at the cume_dist sibling. Make it same-line and un-copyable (iter693 defang style). Suggested defang line to place directly on the percent_rank card:

> `-- percent_rank() is NOT "fraction of rows at or below" — its lowest row = 0.0 (strictly-below ranking). For "fraction of rows AT OR BELOW this value" / "what percentile does this value sit at" / percentile standing, use cume_dist() (lowest ~ 1/N, top = 1.0).`

Also add a one-line ROUTER at the TOP of the percent_rank card (before the COPY block) so it is read before the copy idiom:
- "fraction AT OR BELOW / percentile standing / cumulative distribution (lowest ~ 1/N, top=1.0)" -> **cume_dist()**
- "relative rank position 0..1, strictly-below (lowest=0.0)" -> **percent_rank()**

Do NOT remove the percent_rank canonical — keep it for genuine strictly-below-rank questions. The fix is interception at the landing card, not deletion. PRESERVE the existing cume_dist sibling anchors/router added in iter758 (they reinforce). Reconcile-in-place; do not append a duplicate.

---

## Production-fit note
All four answers fit the on-prem Trino 467 + Iceberg stack. No federation/auth/authz scope was touched. resources/22 lock unaffected.
