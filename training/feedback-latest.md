# Judge Feedback — Iter 624 (EXTENDED PHASE)

**Pin: Trino 467 / Iceberg connector / Hive Metastore (prod_info.md verified). Docs verified today against trino.io/docs/467.**

**Overall: 5.00 STRONG PASS** (margin +1.50 above the 3.5 floor; +0.0625 swing from iter623's 4.9375). FEDERATION NOT PROBED — the 4.49944/310 row is UNCHANGED.

**Headline:** FIX confirmed durable — the iter624 strpos-3-arg re-probe lands clean. Q1 uses `strpos(SKU, '-', 2)` (3-arg N-th-occurrence) DIRECTLY, with correct substring arithmetic extracting '1234'. The r27:931 verified-false-claim ("Trino strpos is 2-arg only / no n-th-occurrence form" base-training myth) is NOT re-introduced — the responder used the 3-arg form as the resource now documents. Q2/Q3/Q4 are all docs-verbatim zero-defect. Zero fabrications, no `::`-cast, no parse errors, no off-by-one in the substring arithmetic.

---

## Per-question scores

### Q1 — Position of the SECOND dash in 'AA-1234-X' + extract middle segment '1234' — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS

Responder: `strpos(SKU, '-', 2) AS second_dash_pos`; middle = `substring(SKU, strpos(SKU,'-',1)+1, strpos(SKU,'-',2)-strpos(SKU,'-',1)-1)`.

**STRPOS-3-ARG VERIFIED VALID (CRITICAL re-probe).** trino.io/docs/467/functions/string.html, verbatim: *"Returns the position of the N-th `instance` of `substring` in `string`. When `instance` is a negative number the search will start from the end of `string`. Positions start with `1`. If not found, `0` is returned."* (The N-th-occurrence variant was added in Release 325, WebSearch-confirmed.) So `strpos('AA-1234-X', '-', 2)` = 8 (the second dash) — CORRECT, 1-indexed.

**SUBSTRING ARITHMETIC VERIFIED CORRECT.** trino.io/docs/467/functions/string.html, verbatim: *"Returns a substring from `string` of length `length` from the starting position `start`. Positions start with `1`."* — so `substring(string, start, length)` is the right 1-indexed start+length signature. Trace for 'AA-1234-X': strpos('-',1)=3, strpos('-',2)=8 → start = 3+1 = **4**, length = 8−3−1 = **4** → `substring(SKU, 4, 4)` = chars 4..7 = **'1234'**. CORRECT, no off-by-one.

**FIX VERDICT (CRITICAL): the iter624 strpos-3-arg fix is applied CORRECTLY.** The responder routed to the 3-arg form directly (not the debunked "no single-call equivalent" myth at r27:931) and composed the +1 / −1 boundary arithmetic exactly right. This closes the strpos-3-arg re-probe arc.

### Q2 — Single longest review (by character count) per product — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS

Responder: inner `ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY length(review_text) DESC) AS rn`, outer `WHERE rn = 1`.

VALID Trino 467 outer-wrapper pattern — window functions are computed in the SELECT projection, so the `rn` alias must be filtered in an OUTER query (not a same-level `WHERE rn=1`, which would fail alias-scoping). The responder correctly wrapped it. `length(string)` returns char count — docs verbatim: *"Returns the length of `string` in characters."* PARTITION BY product_id + ORDER BY length DESC + rn=1 = the longest review per product. Ties: ROW_NUMBER picks one arbitrarily (minor, inherent). `max_by(review_text, length(review_text))` is a valid one-aggregate alternative but not required (ROW_NUMBER keeps the full row). Correct.

### Q3 — Combine address_line1 + address_line2 with comma separator, skip null line2 — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS

Responder: `concat_ws(', ', address_line1, address_line2) AS full_address`; stated concat_ws skips NULL args.

VERIFIED CORRECT. trino.io/docs/467/functions/string.html, verbatim: *"Returns the concatenation of `string1`, `string2`, ..., `stringN` using `string0` as a separator. If `string0` is null, then the return value is null. Any null values provided in the arguments after the separator are skipped."* So null line2 → skipped → no trailing ', ' — exactly the stated requirement. Minor (non-penalized) completeness nit: concat_ws skips NULL but NOT empty-string `''` — a `line2=''` would still yield a trailing ', '. The question said "null", so this is fine; the edge is a documented-as-optional caveat, not a defect.

### Q4 — Real boolean column for whether renewal_date is in the future — Acc 5 / Comp 5 / Clar 5 / Act 5 = 5.00 STRONG PASS

Responder: `renewal_date > current_date AS is_still_active`; stated direct comparison returns a real boolean (not 1/0), no CAST/CASE needed.

VERIFIED CORRECT. Trino comparison operators return BOOLEAN (trino.io/docs/467/functions/comparison.html — `>` is a comparison operator yielding boolean). No `CASE WHEN ... THEN true ELSE false` or `CAST(... AS boolean)` wrapping is needed; the bare comparison IS a boolean expression. Type check: `renewal_date` is a DATE, `current_date` is a DATE → comparison valid, no type mismatch. The boolean-as-column claim is accurate. (NULL renewal_date → NULL flag, standard SQL three-valued logic; not in scope of the question.)

---

## Overall computation

Dimension averages across the 4 questions:
- Accuracy: (5+5+5+5)/4 = 5.000
- Completeness: (5+5+5+5)/4 = 5.000
- Clarity: (5+5+5+5)/4 = 5.000
- Actionability: (5+5+5+5)/4 = 5.000

Overall = (5.000 + 5.000 + 5.000 + 5.000)/4 = **5.00**. Per-Q cross-check: (5.00+5.00+5.00+5.00)/4 = 5.00 — agree. **GOVERNING LABEL = STRONG PASS**; no per-Q gate triggered; all per-Q avgs = 5.00.

## Fabrication / slip scan

NONE. No fabricated feature/absence (strpos-3-arg is REAL and correctly used; concat_ws null-skip is REAL; boolean comparison is REAL). No `::`-cast (iter571 PIN clean), no QUALIFY, no RLIKE, no invalid-clause-placement, no off-by-one (substring 4,4 arithmetic verified), no type-mismatch (DATE>DATE valid), no wrong-function-choice, no substring-arithmetic error.

## Diagnosis

No slip to diagnose — all four answers routed to the correct landing points and applied them correctly. The strpos-3-arg fix at r27:931 is now both findable and correctly applied (Q1 led with the 3-arg form + correct boundary arithmetic).

## iter625 recommendation — DURABILITY NO-OP

The strpos-3-arg fix landed and is durable; Q2/Q3/Q4 are docs-verbatim clean. DO NOT:
- touch the r27:931 strpos-3-arg canonical (now correctly applied — leave it),
- touch the substring / concat_ws / boolean-comparison canonicals (all docs-verbatim),
- touch the r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe this iter),
- add any `::`-casts (iter571 PIN),
- bump training/state.json (already at 624).

Optional (reactive-only, did NOT bite): a one-line concat_ws "skips NULL but NOT empty-string ''" note could be added at the concat_ws landing point if a future empty-string edge probe ever fails — but no action needed now.

Docs verified today (trino.io/docs/467): functions/string.html (strpos N-th-instance, substring(string,start,length) 1-indexed, concat_ws null-skip verbatim, length=char count), functions/comparison.html (`>` returns boolean); WebSearch confirmed strpos 3-arg variant added Release 325.

**OVERALL: 5.00 STRONG PASS — strpos-3-arg fix CONFIRMED durable (3-arg form + correct substring '1234' arithmetic); Q2 ROW_NUMBER-outer-wrapper longest-per-product / Q3 concat_ws null-skip / Q4 boolean comparison column all docs-verbatim zero-defect; federation row stays 4.49944/310.**
