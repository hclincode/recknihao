# Judge Feedback — iter907 (EXTENDED PHASE, re-probe sweep)

## Verdict: PASS — overall average 4.84 / 5 (margin +1.34 over 3.5 threshold)

Per-Q: Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 4.375 = 19.375 / 4 = **4.84**. Overall average governs (no per-Q veto). All four answers are dialect-clean and runnable in Trino 467.

**FEDERATION NOT PROBED** — the federation row (4.49944 / 310) is UNCHANGED this iter.

---

## Q1 — per-product yes/no flag, total units sold >= 500, one row per product — 5.00

Answer: `SELECT product_id, CASE WHEN SUM(units_sold) >= 500 THEN 'yes' ELSE 'no' END AS has_500_units FROM sales GROUP BY product_id;` (plus the boolean-column variant `SUM(units_sold) >= 500`).

**WINDOW-OVER-GROUPED-COLUMN MUDDLE = ONE-OFF CONFIRMED — DID NOT RECUR. The iter906 slip is CLOSED.** The responder LED with the CLEAN, minimal form: a plain grouped aggregate with NO window function. There is no `SUM(...) OVER (...)` nested over a `GROUP BY`, no re-group on a windowed scalar. This is NOT a 3rd window-fn over-reach (after the iter904 window-in-WHERE and iter906 window-over-grouped-column slips). **NO findability-anchor FIX-A needed.**

VERIFIED vs trino.io/docs/467 select.html + aggregate.html + WebSearch 2026-06-10:
- `CASE WHEN SUM(units_sold) >= 500 THEN 'yes' ELSE 'no' END` is a SCALAR expression *over* an aggregate. `units_sold` appears ONLY inside `SUM()`, so the whole CASE is itself an aggregate expression — LEGAL in a GROUP BY query (the select.html rule "output expressions must be aggregate functions or GROUP BY columns" governs the *leaf column references*, which are all aggregated/grouped here). WebSearch explicitly confirmed: `SELECT CASE WHEN SUM(col) > value THEN result ELSE other END ... GROUP BY` is **legal**.
- The boolean-column form `SUM(units_sold) >= 500 AS ...` (comparison over an aggregate → boolean) is equally valid 467.
- `GROUP BY product_id` yields exactly one row per product. Correct shape for the ask.

(iter882 verify-first applied: an initial small-model WebFetch misread claimed "comparison over aggregate in SELECT is prohibited" — that is WRONG and contradicted by aggregate-wrapping precedent from iter899 Q3 / iter900–905; a targeted WebSearch confirmed the CASE-over-aggregate form is legal. I did NOT flag the doc-correct responder answer as a defect.)

## Q2 — how many orders include product 42 — 5.00

Answer: `SELECT COUNT(DISTINCT order_id) AS orders_with_product_42 FROM line_items WHERE product_id = 42;`

VERIFIED vs trino.io/docs/467 aggregate.html: `COUNT(DISTINCT x)` is supported (the docs reference it as the exact form `approx_distinct` approximates). The DISTINCT rationale — a product appearing on two line items within the SAME order would otherwise double-count that order — is CORRECT; counting distinct `order_id` gives the number of *orders* containing product 42, not the number of *line items*. The `WHERE product_id = 42` pre-filter is correct. Clean, idiomatic, exactly answers the question.

## Q3 — how many customers haven't ordered in the last 90 days — 5.00

Answer: `SELECT COUNT(DISTINCT c.customer_id) FROM customers c WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id AND o.order_date >= current_date - INTERVAL '90' DAY);` (+ an IDs variant).

VERIFIED vs trino.io/docs/467 datetime.html + comparison/subquery semantics + WebSearch 2026-06-10:
- **NOT EXISTS correlated anti-join is VALID in 467.** This is the canonical, decorrelatable form: a simple equality correlation (`o.customer_id = c.customer_id`) plus a constant range predicate, with NO LIMIT and NO nested subquery. The Trino correlated-subquery limitations that surfaced in search (no LIMIT inside the correlated subquery, no nested subqueries) do NOT apply to this textbook anti-join — it decorrelates cleanly and runs. (iter882 verify-first: a search result vaguely warned "NOT EXISTS may need workarounds" but that refers to LIMIT/nested edge cases, not this simple equality-correlated form — NOT a defect.)
- `current_date` is valid (no parens, date as of query start). `current_date - INTERVAL '90' DAY` is a valid DATE-minus-interval expression yielding a DATE.
- **"Sargable / partition pruning works" claim is ACCURATE.** `current_date - INTERVAL '90' DAY` is a query-level CONSTANT (evaluated once at query start, identical for every row — not a per-row function of `order_date`), so `order_date >= <const>` is a bare-column comparison against a constant and Trino can use it to prune partitions on `order_date`. (The "not a constant" phrasing a small-model WebFetch returned conflated compile-time literal with query-constant; for pruning purposes it is effectively constant.)
- **Semantics are CORRECT** for "customers with no order in the last 90 days": NOT EXISTS is TRUE when the customer has zero matching orders in the window — this correctly INCLUDES never-ordered customers (no orders row at all → no match → counted) AND customers whose most recent order is older than 90 days. `COUNT(DISTINCT c.customer_id)` is one row per qualifying customer.

## Q4 — orders where shipping_country and billing_country don't match incl NULLs (count + which) — 4.375

Answer: `WHERE shipping_country != billing_country OR (shipping_country IS NULL AND billing_country IS NOT NULL) OR (shipping_country IS NOT NULL AND billing_country IS NULL)`; explained that `!=` with a NULL operand yields NULL (not TRUE), so NULL cases need explicit handling.

VERIFIED vs trino.io/docs/467 comparison.html:
- The `!=`-with-NULL explanation is CORRECT: `!=`/`<>` returns NULL (not TRUE/FALSE) when either operand is NULL, so a row where exactly one of the two countries is NULL would NOT be flagged by `shipping_country != billing_country` alone — hence the explicit NULL branches are genuinely needed.
- The 3-branch logic is EXACTLY equivalent to `shipping_country IS DISTINCT FROM billing_country`:
  - Branch 1 (`!=`) flags both-non-null-and-different (NULL/false otherwise).
  - Branch 2 flags ship-NULL + bill-non-null.
  - Branch 3 flags ship-non-null + bill-NULL.
  - Both-NULL: none of the branches fire (branch 1 → NULL, branches 2/3 → false) → correctly NOT flagged.
  - Both-equal-non-null: branch 1 → false, 2/3 → false → correctly NOT flagged.
  This correctly flags all NULL-aware mismatches and only those. The answer RUNS and is CORRECT.

**Deduction (completeness nuance, NOT an accuracy defect):** Trino 467 has the cleaner null-safe `IS DISTINCT FROM` operator (confirmed in comparison.html: "treat NULL as a known value and guarantee either a true or false outcome even in the presence of NULL"), which collapses the entire 3-branch OR to a one-liner `WHERE shipping_country IS DISTINCT FROM billing_country`. The responder's verbose 3-branch form is fully correct but did not mention the idiomatic one-liner. Weighed proportionally: Acc 5.0 (correct + correct NULL explanation), Comp 3.5 (cleaner idiom unmentioned), Clar 4.5, Act 4.5 → 4.375. This is a nuance, not a defect — no FIX-A warranted.

---

## iter908 directive: DEFAULT NO-OP

All 4 answers dialect-clean. **Q1 window-over-grouped-column muddle = ONE-OFF CONFIRMED, DID NOT RECUR — iter906 slip CLOSED.** NO dialect defect, NO findable-but-missing gap, NO FIX-A, NO escalation. Teacher ZERO edits.

- Do NOT add any "wrong" card for Q1–Q4.
- Do NOT mark the Q1 plain-GROUP-BY + CASE-over-SUM / boolean-comparison form wrong (it is correct 467) and do NOT add a findability anchor for the window-over-grouped-column slip (it did not recur — adding a card risks defang-backfire and duplicates the existing GROUP-BY-output / window-eval-order pins).
- Do NOT mark Q2 COUNT(DISTINCT order_id), Q3 NOT EXISTS anti-join + current_date−INTERVAL pruning, or Q4 3-branch NULL-aware mismatch wrong (all correct).
- OPTIONAL micro-anchor ONLY if it touches NO existing pin: a 1-line "`IS DISTINCT FROM` is the null-safe one-liner equivalent of the 3-branch `!=` OR" note near a NULL-comparison card. SKIP if it churns/duplicates a comparison-operator pin — the 3-branch answer is correct as-is, so this is purely optional polish.
- Re-probe fresh adjacents next sweep. Federation (4.49944 / 310) is the only un-passed row — bulletproofed angles only.
- Do NOT touch any iter534–906 pin. PIN Trino 467. NO federation edits.
- **DO NOT bump training/state.json** (already passed; overall 4.84 PASS holds).

All facts VERIFIED vs trino.io/docs/467 (select / aggregate / comparison / datetime .html) + WebSearch 2026-06-10. iter882 verify-first applied DECISIVELY: two small-model WebFetch misreads (Q1 "CASE-over-aggregate prohibited", Q3 "NOT EXISTS unsupported / current_date not constant") were re-verified against authoritative sources and found to be the OPPOSITE of the responder being wrong — neither turned into a false defect.
