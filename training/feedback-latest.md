# Judge Feedback — iter619 (EXTENDED PHASE)

**Overall: 4.4375 PASS** (margin +0.9375 above 3.5 floor). Trino pinned to 467. Federation NOT probed (4.49944/310 row UNCHANGED). One genuine in-the-answer defect: **Q2 used `GROUP BY CUBE(...)` where the user explicitly wanted only three hand-picked groupings — a WRONG-FUNCTION-CHOICE that structurally includes the (region, product_category) detail rows the user said they do NOT want.** Q1 / Q3 / Q4 all docs-verbatim correct, zero-defect.

---

## Per-question scores

### Q1 — Zero-pad invoice ID to fixed 10-char string ('4217' → '0000004217') — 5/5/5/5 = 5.00 STRONG PASS
Answer: `format('%010d', invoice_id) AS invoice_string`.
- **VERIFIED CORRECT.** trino.io/docs/467/functions/conversion.html (WebFetch): `format(format, args...)` returns a varchar "by applying a [format string] with arguments", Java `String.format` / `java.util.Formatter` syntax; docs show verbatim `SELECT format('%03d', 8); -- '008'`. The `%0Nd` zero-pad flag is standard Java Formatter, so `format('%010d', 4217)` produces exactly `'0000004217'` (10 chars, leading zeros).
- `%d` accepts a numeric BIGINT/INTEGER directly — no CAST needed. The `lpad(CAST(invoice_id AS varchar), 10, '0')` form (r27:934) is an equivalent; `format` is fully valid and arguably cleaner. Zero defects.

### Q2 — Revenue BY region alone, BY product_category alone, AND grand total — explicitly NOT the per-region-per-category detail ("just those three separate summaries") — 2/3/4/2 = 2.75 FAIL (per-Q below 3.5; quality concern)
Answer: `GROUP BY CUBE(region, product_category)` + a `GROUPING()` CASE labeling Detail / Region Total / Category Total / Grand Total; prose says CUBE "will emit the full detail, region-only subtotals, category-only subtotals, and the grand total" and "one row per (region, category) pair", then hand-waves "you can filter to just the summaries you need."
- **WRONG-FUNCTION-CHOICE — CONFIRMED.** trino.io/docs/467/sql/select.html (WebFetch, verbatim): *"The `CUBE` operator generates all possible grouping sets (i.e. a power set) for a given set of columns."* For `CUBE(region, product_category)` that power set is the FOUR groupings: `(region, product_category)`, `(region)`, `(product_category)`, `()`. The first of those — `(region, product_category)`, GROUPING bitmask 0 — is precisely the per-region-per-category DETAIL the user EXPLICITLY excluded ("explicitly NOT the per-region-per-category detail", "just those three separate summaries").
- So **CUBE structurally over-produces**: it emits the detail rows the user said they do not want. The responder's own prose even admits CUBE emits "the full detail" and "one row per (region, category) pair" — i.e. the answer narrates that it produces the excluded rows, then waves at a filter it never wrote.
- **The correct construct is `GROUP BY GROUPING SETS ((region), (product_category), ())`** — which computes EXACTLY the three listed sets and nothing else. trino.io/docs/467/sql/select.html: *"Grouping sets allow users to specify multiple lists of columns to group on"*; CUBE is the full power set, GROUPING SETS is the hand-picked list. WebSearch confirmed: "GROUPING SETS gives you control to specify exactly which combinations you want, while CUBE automatically generates all possible combinations (the power set)." `GROUPING SETS ((region),(product_category),())` emits by-region [GROUPING bitmask 1] + by-product_category [bitmask 2] + grand-total [bitmask 3], and does NOT emit the (region,product_category) detail [bitmask 0] because that set is not in the list.
- The "you can filter to just the summaries you need" hand-wave is doubly wrong: (a) it requires an extra `WHERE GROUPING(region, product_category) <> 0` / per-grouping filter the responder did NOT write, leaving copy-paste output that still contains the excluded detail; (b) it is the wrong tool — GROUPING SETS is purpose-built for hand-picking exactly these subtotals, so filtering CUBE is a workaround for a problem GROUPING SETS doesn't have.
- Scores: **Acc 2** (the delivered query returns rows the user explicitly excluded; prose self-admits it), **Comp 3** (GROUPING labeling is correct and the concept of subtotals is conveyed, but the actual deliverable misses the stated requirement and never writes the filter it promises), **Clar 4** (well-structured, GROUPING CASE explained), **Act 2** (copy-paste output includes the unwanted detail; engineer must redesign to GROUPING SETS or add a filter the answer omitted).
- **Diagnosis: ROUTED-BUT-MIS-APPLIED / wrong-function-choice.** The hand-picked-subtotals canonical EXISTS and is findable — r28:425 DECIDE-FIRST "hand-picked specific set of groupings → GROUPING SETS ((...),(...))" + r28:532 worked "GROUPING SETS ((a,b),(b),()) → emits GROUPING values 0,2,3 (chosen); you choose exactly which combinations to emit". The responder reached the GROUPING-family neighborhood but grabbed CUBE instead of GROUPING SETS. The DECIDE-FIRST signpost branch did not bite for this phrasing.

### Q3 — Tag each order with fiscal quarter Q1/Q2/Q3/Q4 (calendar year) from order_date — 5/5/5/5 = 5.00 STRONG PASS
Answer: `CASE EXTRACT(QUARTER FROM order_date) WHEN 1 THEN 'Q1' ... END AS fiscal_quarter`.
- **VERIFIED CORRECT.** trino.io/docs/467/functions/datetime.html (WebFetch): `extract(field FROM x) → bigint`; the QUARTER field "extracts the quarter of the year", and the equivalent `quarter(x) → bigint` returns "the quarter of the year from the input value, with a range from 1 to 4." So `EXTRACT(QUARTER FROM order_date)` returns bigint 1–4 (calendar-year quarter), and the `CASE ... WHEN 1 THEN 'Q1' ... WHEN 4 THEN 'Q4'` mapping is exhaustive and correct.
- `quarter(order_date)` is a valid shorthand equivalent (r27:590) but is not required. Zero defects.

### Q4 — Bucket order amounts into 'small' (<50) / 'medium' (50–200) / 'large' (>200) and count per bucket — 5/5/5/5 = 5.00 STRONG PASS
Answer: `CASE WHEN amount<50 THEN 'small' WHEN amount>=50 AND amount<200 THEN 'medium' WHEN amount>=200 THEN 'large' END AS size_category, COUNT(*) ... GROUP BY 1 ORDER BY CASE WHEN size_category='small' THEN 1 WHEN size_category='medium' THEN 2 WHEN size_category='large' THEN 3 END`.
- **VERIFIED CORRECT.** Boundaries clean and contiguous: `<50` small, `>=50 AND <200` medium, `>=200` large. Edge handling: exactly 50 → medium (`>=50`), exactly 200 → large (`>=200`). This matches the spec ("50–200 medium", ">200 large" — the responder reads 200 as the medium upper-exclusive / large lower-inclusive boundary; consistent and unambiguous, no off-by-one, no gap, no overlap).
- `GROUP BY 1` (ordinal on the CASE expression) is valid Trino 467; `COUNT(*)` per bucket correct.
- **ORDER BY referencing the SELECT output alias `size_category` inside a CASE is VALID Trino 467.** trino.io/docs/467/sql/select.html: ORDER BY "Each expression may be composed of output columns, or it may be an ordinal number selecting an output column by position, starting at one" — unlike WHERE (which runs before projection), ORDER BY runs AFTER the SELECT list and CAN reference output aliases. (Docs' own examples order on a SELECT alias.) The custom CASE-on-alias sort to force small→medium→large ordering is a correct, idiomatic pattern.
- Zero defects.

---

## Overall computation
- Dim-avg method: Acc (5+2+5+5)/4 = 4.25; Comp (5+3+5+5)/4 = 4.50; Clar (5+4+5+5)/4 = 4.75; Act (5+2+5+5)/4 = 4.25 → (4.25+4.50+4.75+4.25)/4 = **4.4375**.
- Per-Q-average method: (5.00 + 2.75 + 5.00 + 5.00)/4 = **4.4375**. Both methods agree.
- **GOVERNING LABEL = PASS** (overall avg 4.4375 ≥ 3.5; no per-Q gate). Q2 per-Q 2.75 flagged separately as a quality concern with a content directive, NOT a label override.

---

## Q2 VERDICT (CRITICAL)
- **CONFIRMED: CUBE includes the (region, product_category) detail the user explicitly excluded.** `CUBE(region, product_category)` = power set = {(region,product_category), (region), (product_category), ()}. The (region,product_category) member is the detail row (GROUPING bitmask 0) the user said they do NOT want. CUBE cannot satisfy "just those three separate summaries" without an additional filter the responder did not write.
- **GROUPING SETS ((region), (product_category), ()) was the correct construct** — it computes exactly by-region + by-category + grand-total and excludes the detail. Docs-verified (trino.io/docs/467/sql/select.html: CUBE = power set; GROUPING SETS = user-specified lists).
- **Class: ROUTED-BUT-MIS-APPLIED / wrong-function-choice.** The hand-picked-subtotals content exists at r28:425 (DECIDE-FIRST) + r28:532 (worked emits-chosen-sets row); the responder reached the GROUPING-family neighborhood but selected CUBE.

### iter620 teacher fix (PRIMARY) — strengthen the GROUPING SETS hand-picked landing point / DECIDE-FIRST signpost at r28:413–540
1. **Keyword anchors** at the DECIDE-FIRST signpost (r28:425) and the hand-picked worked row (r28:532), matching the exact failing phrasings so Haiku routes correctly: "by X AND by Y but NOT the X-Y detail", "by region alone and by category alone", "specific subtotals only", "just those summaries / just those three summaries", "not every combination", "not the full detail", "hand-pick which subtotals", "separate summaries (not the cross-tab)". Each → `GROUP BY GROUPING SETS ((X),(Y),())`.
2. **Add an explicit WRONG/RIGHT CUBE-vs-GROUPING-SETS pair** at the signpost (reconcile-in-place; do NOT delete the existing ROLLUP/CUBE/GROUPING-SETS bitmask lock):
   - WRONG: `GROUP BY CUBE(region, product_category)` — emits ALL FOUR groupings INCLUDING the `(region, product_category)` DETAIL (GROUPING bitmask 0); over-produces; includes the rows the user said NOT to include. Filtering it back out with `WHERE GROUPING(region, product_category) <> 0` is a workaround, not the tool.
   - RIGHT: `GROUP BY GROUPING SETS ((region), (product_category), ())` — emits EXACTLY by-region (bitmask 1) + by-category (bitmask 2) + grand-total (bitmask 3), and NOT the detail (bitmask 0), because `(region, product_category)` is not in the chosen list.
3. **DECIDE-FIRST rule line**: "Want a specific, hand-picked set of subtotals (e.g. by-X alone + by-Y alone + grand total, but NOT the X-Y cross-tab)? → GROUPING SETS, list exactly those sets. Want the full power set (every combination incl. the detail)? → CUBE. Want hierarchical roll-up along one ordered path? → ROLLUP." Anchor the "but NOT the X-Y detail / only these subtotals" framing to GROUPING SETS so the responder does not default to CUBE.
4. **VERIFY before writing** (teacher): re-confirm verbatim at trino.io/docs/467/sql/select.html that CUBE = "all possible grouping sets (i.e. a power set)" and that GROUPING SETS computes exactly the listed sets; keep the existing GROUPING()/GROUPING_ID bitmask + leftmost=MSB locks intact (reconcile-in-place, ONE tight WRONG/RIGHT block, do NOT rewrite the bitmask canonical).

---

## Other slips / fabrication check
- **No fabrications.** All functions used (`format`, `CUBE`, `GROUPING`, `EXTRACT(QUARTER FROM …)`, `CASE`, `COUNT(*)`, `GROUP BY 1`, ORDER BY CASE-on-alias) are real Trino 467 and (except Q2's wrong CUBE choice) correctly applied.
- **No `::`-casts, no QUALIFY, no invalid clause placement, no wrong-version pin, no type-mismatch, no off-by-one** (Q4 boundaries verified clean).
- Q1/Q3/Q4 are durable first-probe clean — no resource churn warranted on `format('%010d')`, `EXTRACT(QUARTER)`, or the CASE-bucket/ORDER-BY-CASE-on-alias canonicals.

### iter620 DO NOT
- Do not touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter619).
- Do not add `::`-casts (iter571 PIN).
- Do not rewrite the r28 ROLLUP/CUBE/GROUPING-SETS bitmask canonical body — additive WRONG/RIGHT signpost + keyword anchors only.
- Do not re-edit the verified-clean Q1 `format`/lpad, Q3 EXTRACT(QUARTER), or Q4 CASE-bucket canonicals (all routed first-probe clean).
- Do not bump training/state.json (already 619).

**Docs verified today (WebFetch/WebSearch, all Trino 467):** trino.io/docs/467/sql/select.html (CUBE = "all possible grouping sets (i.e. a power set)"; GROUPING SETS = "specify multiple lists of columns to group on"; ORDER BY may reference output columns — Q2 + Q4), trino.io/docs/467/functions/conversion.html (`format('%03d', 8) -> '008'`, Java Formatter — Q1), trino.io/docs/467/functions/datetime.html (`extract(field FROM x) -> bigint`, QUARTER → quarter(x) range 1–4 — Q3).

**OVERALL: 4.4375 PASS — Q1 format('%010d') + Q3 EXTRACT(QUARTER) + Q4 CASE-bucket/ORDER-BY-CASE-on-alias all docs-verbatim zero-defect; Q2 used CUBE for a hand-picked-three-subtotals request = WRONG-FUNCTION-CHOICE (CUBE's power set structurally INCLUDES the (region,product_category) detail the user explicitly excluded; the correct construct is GROUPING SETS ((region),(product_category),())); iter620 PRIMARY = strengthen the r28 GROUPING SETS DECIDE-FIRST signpost with keyword anchors ("by X AND by Y but NOT the X-Y detail" / "specific subtotals only") + a WRONG-CUBE/RIGHT-GROUPING-SETS pair; no fabrication; federation row stays 4.49944/310.**
