# Iter939 Judge Feedback — DEFAULT NO-OP durability sweep

**Iteration**: 939 (EXTENDED PHASE, ZERO resource edits)
**Date**: 2026-06-10
**Verdict**: PASS — overall avg **4.9375** / margin +1.4375 (overall-avg governs, no per-Q veto)
**Federation**: NOT PROBED (4.49944/310 row UNCHANGED)
**Phase / passed flags**: preserved (no state.json bump from judge)

All dialect verified vs trino.io/docs/467 (functions/aggregate.html, sql/select.html, optimizer.html) + WebFetch 2026-06-10 — NOT against resources/; iter882 verify-BOTH-directions applied throughout.

---

## Per-question scoring

### Q1 — Count DISTINCT carriers per region — 5.00

`SELECT region, COUNT(DISTINCT carrier_name) AS num_carriers FROM carrier_assignments GROUP BY region`. Notes COUNT(DISTINCT) ignores NULLs; COUNT(*) counts all rows.

- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0
- VERIFIED against trino.io/docs/467 functions/aggregate.html (WebFetch 2026-06-10): `count(x)` returns count of non-null input values (ignores NULLs); single-arg COUNT(DISTINCT carrier_name) signature valid. `count(*)` returns number of input rows (includes nulls in the count of rows themselves; correctly described).
- Responder's "COUNT(DISTINCT) ignores NULLs" + "COUNT(*) for row count" exposition matches docs verbatim.
- Clean canonical answer.

### Q2 — Count UNIQUE visitors per landing page — 5.00

`SELECT landing_page, COUNT(DISTINCT visitor_id) AS unique_visitors FROM page_views GROUP BY landing_page`. Notes COUNT(DISTINCT *) is a syntax error — must name the column.

- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0
- VERIFIED COUNT(DISTINCT *) IS invalid in Trino 467 — aggregate.html lists only two count signatures: `count(*)` (no DISTINCT permitted) and `count(x)` (DISTINCT-able with column expr). The wildcard form is NOT a documented signature ⇒ responder's warning is correct, NOT a fabrication. (This claim matches the pinned `count() single-arg / no DISTINCT *` rule.)
- COUNT(DISTINCT visitor_id) over GROUP BY landing_page correctly dedups repeat visits per page.
- Clean canonical answer with helpful explicit syntax warning.

### Q3 — Orders with NO matching invoice (anti-join) — 4.75

LEFT JOIN ... WHERE i.order_id IS NULL form + NOT EXISTS alternative; says LEFT JOIN form often runs faster on Trino.

- Acc 4.5 / Comp 5.0 / Clar 5.0 / Act 4.5 = **4.75**
- LEFT JOIN ... WHERE i.order_id IS NULL: CORRECT canonical anti-join idiom for "orders with no invoice"; using the JOIN KEY (i.order_id) for IS NULL test is the standard, sound pattern (true negative match implies all joined right cols are NULL, including the key).
- NOT EXISTS equivalent: CORRECT, NULL-safe alternative.
- "LEFT JOIN often runs faster on Trino" claim: weak/overstated — Trino's optimizer typically lowers BOTH LEFT-JOIN/IS-NULL and NOT EXISTS to the SAME semi-join (anti-join) physical operator (per iter934-pinned equivalence). Preferring one for perf is folklore, not documented behavior. Defensible as a colloquial hedge, not a dialect error → small Acc/Act ding only. Practical guidance still sound (both correct, both NULL-safe).
- Standing NOT IN nullable-column 3VL trap not raised (not asked, but worth flagging if a future probe uses a nullable join key) — no Comp ding here.

### Q4 — Products priced ABOVE their category's average price — 5.00

CTE `category_avg AS (SELECT category_id, AVG(price) FROM products GROUP BY category_id)` + JOIN + `WHERE p.price > ca.avg_price`. Notes "aggregate not allowed in WHERE".

- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0
- VERIFIED against trino.io/docs/467 sql/select.html (WebFetch 2026-06-10): aggregate functions cannot appear in WHERE; "HAVING filters groups after groups and aggregates are computed" — responder's "you can't put AVG(price) in WHERE directly (aggregate not allowed in WHERE); CTE computes per-category avg first" is CORRECT.
- CTE+JOIN form for per-category-comparison is the standard idiom; AVG(price) GROUP BY category_id + p.price > ca.avg_price logically answers "above own category average."
- Minor completeness nuance per run-prompt explicit guidance: window-fn alternative `AVG(price) OVER (PARTITION BY category_id)` + outer filter ALSO valid (one-pass, no join). Responder omitted it → run-prompt says "only a tiny completeness nuance, not a defect" → no Comp ding.

---

## Overall

- Per-Q: Q1 5.00 / Q2 5.00 / Q3 4.75 / Q4 5.00 = **19.75 / 4 = 4.9375 PASS**
- Margin to 3.5 threshold: **+1.4375**
- PIN 467; OVERALL AVERAGE governs.

## Defect scope

**NO RESOURCE DEFECT / NO RESPONDER SLIP on taught content / NO FINDABLE GAP.**

The Q3 "LEFT JOIN often runs faster" wording is a soft-heuristic colloquialism (proportionally small Acc/Act ding 0.5 each on one Q) — not a dialect/correctness defect. The pinned LEFT-JOIN/IS-NULL ≈ NOT EXISTS equivalence (iter934) makes this folklore, but resources already cover both forms correctly and emphasize correctness + NULL-safety; churning to add an "approximately equivalent perf" hedge risks New-Card/defang regression for zero correctness benefit.

## Recommendation for iter940

**DEFAULT NO-OP** — all 4 dialect-clean, zero new defects, all pinned facts honored.

Optional re-probes (NO pin touch, SKIP if duplicative):
- Anti-join with explicitly NULLABLE join key to confirm responder warns the NOT IN 3VL trap unprompted (and keeps LEFT-JOIN-IS-NULL / NOT EXISTS as the safe canonicals).
- "Above own group average" with HAVING (post-aggregation) vs CTE+JOIN to keep "aggregate not in WHERE → put in HAVING/CTE" rule durable.
- Per-category top-N comparison forcing window-fn `AVG OVER (PARTITION BY ...)` alternative.

Federation (4.49944/310) still the only thin-passing row — bulletproofed angles only. PRESERVE full iter534-937 pin inventory; NO federation edits. PIN 467. DO NOT bump training/state.json (already 939; passed=true preserved; overall 4.9375 PASS holds).
