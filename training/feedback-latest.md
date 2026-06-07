# iter643 Judge Feedback — 2026-06-07 (EXTENDED PHASE)

**Overall: 4.6875 PASS** (margin +1.1875 above 3.5 floor; +0.46875 swing back up from iter642's 4.21875). Per-Q averages: Q1 = 5.00, Q2 = 4.50, Q3 = 5.00, Q4 = 5.00. No per-Q FAIL. iter643 FIX-A (Nth-largest-per-group DENSE_RANK=N decision canonical) LANDED CLEAN.

---

## Per-question scores

### Q1 — Third-most-expensive product per category (Nth-DISTINCT-value, FIX-A validation)

**Accuracy: 5** — `DENSE_RANK() OVER (PARTITION BY category ORDER BY price DESC) AS price_rank ... WHERE price_rank = 3` is the CORRECT tool for "Nth-DISTINCT-value" semantics. The walked-through math is exactly right:
- $200, $200, $150, $100, $100, $80 → DENSE_RANK = 1, 1, 2, 3, 3, 4 → rank=3 returns the two $100 rows. CORRECT.
- Verified against trino.io/docs/467/functions/window.html: DENSE_RANK "tie values do not produce gaps in the sequence" (1,1,2,3); RANK would give 1,1,3 with the tied top (GAP at 2 — rank=3 would land on the FIRST $150, not the $100 — the exact trap FIX-A targets).
- Responder explicitly contrasted ROW_NUMBER=3 (literal 3rd row = $150, wrong) — perfect.
- The nested-ROW_NUMBER one-row-per-category variant uses a CTE-then-outer-WHERE composition (the dialect-safe pattern in Trino 467, which disallows window-in-WHERE). Valid Trino 467.

**Completeness: 5** — Covered the three-way DENSE_RANK / RANK / ROW_NUMBER decision, the worked tie example with explicit math, AND a one-row-per-category collapse variant.

**Clarity: 5** — Step-by-step math trace removes all ambiguity. "$200,$200,$150,$100,$100,$80 → 1,1,2,3,3,4" is the kind of trace a beginner needs.

**Actionability: 5** — Drop-in Trino 467 SQL.

**FIX-A LANDED: CONFIRMED.** The iter643 directive's Nth-largest-per-group canonical (DENSE_RANK=N for distinct level, ROW_NUMBER=N for literal row, RANK=N is the trap) is reflected accurately. Math is correct, contrast with ROW_NUMBER is explicit, CTE composition is dialect-safe. The iter642 silent-wrong RANK=N bug is fully inoculated.

Q1 avg: **5.00**

---

### Q2 — Count customers who never placed an order (anti-join)

**Accuracy: 5** — `LEFT JOIN orders o ON c.customer_id = o.customer_id WHERE o.customer_id IS NULL` is the canonical anti-join shape. NOT IN pitfall on nullable right-side keys correctly flagged (three-valued logic returns UNKNOWN → row dropped — standard SQL trap, valid in Trino 467).

**Completeness: 4** — Core anti-join correct + NOT IN caveat. Minor framing ding: question asked for the COUNT; responder returned the customer rows rather than wrapping in `SELECT COUNT(*)`. Trivial one-line wrap but a beginner reading the answer may not realize they need to add COUNT.

**Clarity: 5** — Anti-join structure clearly explained; NOT IN trap concrete.

**Actionability: 4** — Engineer must add COUNT themselves. One-line gap.

Q2 avg: **4.50**

---

### Q3 — Customers with total spend > $1000 (HAVING on aggregate)

**Accuracy: 5** — `GROUP BY c.customer_id, c.customer_name HAVING SUM(o.amount) > 1000`. Verified against trino.io/docs/467/sql/select.html: "HAVING filters groups after groups and aggregates are computed." The alias-not-allowed-in-HAVING claim is accurate: HAVING references aggregate functions and grouped columns, NOT SELECT output aliases — responder correctly says you must repeat `SUM(o.amount)` in HAVING.

**Completeness: 5** — WHERE vs HAVING distinction, GROUP BY column list (customer_id AND customer_name both needed), alias-not-in-HAVING warning.

**Clarity: 5** — Execution-order explanation (WHERE → GROUP BY → HAVING) explains WHY HAVING exists.

**Actionability: 5** — Drop-in Trino-valid SQL.

Q3 avg: **5.00**

---

### Q4 — Most recent status per device (latest-row-per-key)

**Accuracy: 5** — `ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY event_timestamp DESC) WHERE rn = 1` (CTE+outer-WHERE, dialect-safe since Trino 467 disallows window-in-WHERE). The `max_by(status, event_timestamp) GROUP BY device_id` alternative is verified against trino.io/docs/467/functions/aggregate.html: "Returns the value of x associated with the maximum value of y." `ORDER BY ... DESC NULLS LAST` verified against trino.io/docs/467/sql/select.html: `ORDER BY expression [ASC|DESC] [NULLS {FIRST|LAST}]`.

**Completeness: 5** — Two canonical shapes (ROW_NUMBER and max_by) PLUS the NULLS LAST nuance for nullable timestamps.

**Clarity: 5** — Both alternatives clearly distinguished; NULLS LAST footnote shows real-world data awareness.

**Actionability: 5** — Both Trino 467 valid; pick whichever fits.

Q4 avg: **5.00**

---

## Overall average

Q1=5.00, Q2=4.50, Q3=5.00, Q4=5.00 → (5.00 + 4.50 + 5.00 + 5.00) / 4 = **4.6875**

Per-dimension:
- Accuracy: (5+5+5+5)/4 = 5.00
- Completeness: (5+4+5+5)/4 = 4.75
- Clarity: (5+5+5+5)/4 = 5.00
- Actionability: (5+4+5+5)/4 = 4.75

Grand mean across all 16 cells: 4.6875

**PASS** (≥ 3.5 cleared by margin +1.1875).

---

## FIX-A LANDED confirmation (iter643)

The Nth-largest-per-group decision canonical landed in r23 §3.1G (per state.json: inserted between r23:978 max-per-group-compare canonical's Cross-references and the IGNORE-NULLS-placement lock at r23:982). The Q1 answer demonstrates clean adoption:
- DENSE_RANK = 3 used (not fragile RANK = 3, not ROW_NUMBER = 3).
- The DENSE_RANK 1,1,2,3,3,4 math trace matches the docs-verified behavior verbatim.
- The $100 answer (third-distinct-level) is correct.
- The ROW_NUMBER contrast is explicit (would return $150 — wrong for "third-distinct").
- The CTE-then-outer-WHERE composition is dialect-safe for Trino 467.

The iter642 silent-wrong RANK=N bug pattern is fully inoculated. The iter641→642→643 trajectory (4.6875 → 4.21875 → 4.6875) shows the FIX-A insertion fully repaired the regression without disturbing any other canonical.

---

## Q2 framing ding (minor, does not threaten PASS)

The question asked for a COUNT of customers; the responder returned rows. The wrap is trivial (`SELECT COUNT(*) FROM (... WHERE o.customer_id IS NULL)` or `SELECT COUNT(*) FROM customers c LEFT JOIN ... WHERE o.customer_id IS NULL`), but a beginner may not connect the dots. Cost: -1 each on Completeness and Actionability for Q2. Does not threaten PASS.

---

## Recommendation for iter644: DEFAULT NO-OP / DURABILITY-BREADTH

All four answers passed individually (lowest per-question avg = Q2 at 4.50, well above 3.5). The iter643 FIX-A canonical landed cleanly; iter642's RANK=N bug is closed. Recommend iter644 be a DURABILITY-BREADTH probe — re-probe a different durability-critical canonical from a fresh angle (anti-join "find customers WHO did X but NOT Y" form, or HAVING with COUNT(DISTINCT) instead of SUM, or max_by vs ROW_NUMBER tiebreaker semantics with NULL timestamps, or the Nth-largest canonical at N=4/5 to stress beyond N=2,3), rather than a targeted FIX. No teacher edits required for iter644 unless a regression surfaces.

Optional tiny polish target (if teacher wants to make any edit): a one-line cross-reference in the anti-join canonical reminding the responder that "count of X never doing Y" should be wrapped in `SELECT COUNT(*)` — the only gap surfaced this iteration. Pure additive, no rewrite.

---

## Per-fact docs verifications performed (2026-06-07)

- trino.io/docs/467/functions/window.html — verbatim quotes: ROW_NUMBER "unique, sequential number"; RANK "tie values in the ordering will produce gaps"; DENSE_RANK "tie values do not produce gaps". Q1 DENSE_RANK 1,1,2,3,3,4 math matches.
- trino.io/docs/467/functions/aggregate.html — verbatim: `max_by(x, y)` "Returns the value of x associated with the maximum value of y over all input values." Q4 alternative valid.
- trino.io/docs/467/sql/select.html — verbatim: "HAVING filters groups after groups and aggregates are computed"; `ORDER BY expression [ASC|DESC] [NULLS {FIRST|LAST}]`. Q3 timing explanation and Q4 NULLS LAST valid.
- LEFT JOIN ... IS NULL anti-join + NOT IN NULL three-valued-logic pitfall: SQL-standard, valid in Trino 467 (cross-checked via Trino issue tracker and SELECT docs — LEFT JOIN + IS NULL is the canonical anti-join pattern).
- Nested window in WHERE / window-in-WHERE: Trino 467 disallows; responder uses the dialect-safe CTE+outer-WHERE composition in Q1 nested variant and Q4. Valid.
