# Judge Feedback — Iter 622 (EXTENDED PHASE)

**Pin: Trino 467 / Iceberg connector / Hive Metastore (prod_info.md verified). Docs verified today against trino.io/docs/467 (current = 481, regexp + math + aggregate function sets unchanged across these versions).**

## Overall verdict

**OVERALL = 4.46875 PASS** (margin +0.96875 above the 3.5 floor). FEDERATION NOT PROBED — `4.49944/310` row UNCHANGED.

Dimension averages across the 4 questions:
- Accuracy: (2 + 5 + 5 + 5) / 4 = **4.25**
- Completeness: (3 + 5 + 5 + 5) / 4 = **4.50**
- Clarity: (4 + 5 + 5 + 5) / 4 = **4.75**
- Actionability: (2.5 + 5 + 5 + 5) / 4 = **4.375**

Overall = (4.25 + 4.50 + 4.75 + 4.375) / 4 = **4.46875** (dimension-avg method).
Per-Q-avg cross-check: (2.875 + 5.00 + 5.00 + 5.00) / 4 = **4.46875** — agree.

**GOVERNING LABEL = PASS** (overall avg >= 3.5; no per-Q gate applied). Q1 carries a real fabricated-function defect (per-Q 2.875) flagged below as a quality concern — it does NOT pull the overall below 3.5 because Q2/Q3/Q4 are docs-verbatim zero-defect.

---

## Q1 — Flag tickets whose body contains ANY of 'refund','cancel','chargeback' (multi-keyword text search)

**Scores: Acc 2 / Comp 3 / Clar 4 / Act 2.5 → per-Q 2.875 FAIL (per-Q below 3.5; quality concern)**

**CRITICAL — FABRICATED FUNCTION CONFIRMED.** The responder LED with `WHERE RLIKE(body, 'refund|cancel|chargeback')` and asserted "RLIKE(string, pattern) is Trino's built-in for regex matching." **This is FALSE.** `RLIKE` does NOT exist in Trino 467 — it is a Hive/Spark/MySQL function. A query using it fails at analysis with a function-not-registered error; it never runs.

Docs verified (trino.io/docs/current/functions/regexp.html — function set identical in 467): the COMPLETE list of regex functions is `regexp_count`, `regexp_extract_all`, `regexp_extract`, `regexp_like`, `regexp_position`, `regexp_replace`, `regexp_split`. **No `RLIKE` function or operator is documented.**

The CORRECT answer is:
- `regexp_like(body, 'refund|cancel|chargeback')` — docs verbatim: `regexp_like(string, pattern) → boolean`, "The `pattern` only needs to be contained within `string`, rather than needing to match all of `string`. In other words, this performs a _contains_ operation rather than a _match_ operation." So the `|` alternation matches any of the three keywords, and NO `^...$` anchors are needed (contains-semantics is exactly what "body contains any of" wants), OR
- the multiple-LIKE-OR form `body LIKE '%refund%' OR body LIKE '%cancel%' OR body LIKE '%chargeback%'`.

**Partial save:** the responder DID also state multiple-LIKE-OR is valid (correct), which is why Accuracy is 2 not 1 and Actionability is 2.5 not lower — an engineer who reads to the bottom can recover. But the answer LEADS with and recommends the fabricated `RLIKE` as "Trino's built-in," so the primary deliverable fails to run. The "garbled array_join+contains alternative" was incoherent and adds noise.

**DIAGNOSIS — landing-point-miss / cross-dialect fabrication.** The "multi-keyword / contains any of several keywords" phrasing did NOT route to the `regexp_like` landing point that exists in resources (r27:979 has `regexp_like` with the docs-verbatim contains-semantics). Instead the responder reached for a cross-dialect function (`RLIKE` from Hive/Spark/MySQL). There is NO dedicated worked `word1|word2|word3` alternation example and NO explicit "RLIKE is NOT Trino" inoculation at the regexp landing point, so the contains-any-keyword phrasing fell through to a cross-dialect guess.

---

## Q2 — Each product's revenue AND its percent of the company total (percent-of-column-total)

**Scores: Acc 5 / Comp 5 / Clar 5 / Act 5 → per-Q 5.00 STRONG PASS**

`ROUND(100.0 * total_sales / SUM(total_sales) OVER (), 2) AS pct_of_total` is correct Trino 467.

Docs verified (trino.io/docs/current/functions/window.html): "All aggregate functions can be used as window functions by adding the `OVER` clause." An empty `OVER ()` with no PARTITION/frame computes the aggregate over the whole result set — the grand-total denominator on every row, exactly the per-row percent-of-column-total shape requested. The `100.0` decimal literal forces decimal/double division (avoids integer-truncation to 0), and `ROUND(x, 2)` gives the 2-dp ratio. This is the iter605 share-of-grand-total lock applied correctly. "Faster than a self-join/subquery grand total" is fair (single window pass vs a separate aggregate + join). Zero defects. (A NULLIF(SUM(...) OVER (),0) divide-guard would be a nice-to-have but is not required for correctness on a non-empty revenue set.)

---

## Q3 — Distinct categories per order collapsed to one comma-separated string, no duplicates (TRAP)

**Scores: Acc 5 / Comp 5 / Clar 5 / Act 5 → per-Q 5.00 STRONG PASS — TRAP NAVIGATED**

`array_join(array_agg(DISTINCT category ORDER BY category), ', ') AS categories ... GROUP BY order_id` is correct Trino 467, and the responder correctly stated **Trino does NOT support `LISTAGG(DISTINCT ...)`**.

Docs verified (trino.io/docs/current/functions/aggregate.html): the listagg grammar is `LISTAGG(expression [, separator] [ON OVERFLOW ...]) WITHIN GROUP (ORDER BY sort_item, ...) [FILTER (WHERE ...)]` — **there is NO DISTINCT slot** in the WITHIN GROUP signature; writing `listagg(DISTINCT x, ',') WITHIN GROUP (ORDER BY x)` fails at analysis. The responder correctly avoided it.

The `array_agg(DISTINCT category ORDER BY category)` form is VALID: Trino's rule (trinodb/trino #20725) is "for aggregate function with DISTINCT, ORDER BY expressions must appear in arguments." Here the ORDER BY expression (`category`) IS the aggregated/distinct argument (`category`) — they MATCH — so the restriction is satisfied. The error only fires when the sort key differs from the distinct argument (e.g. `array_agg(DISTINCT concat(a,b) ORDER BY c)`). Inline DISTINCT dedupes before collection, inline ORDER BY makes it deterministic, and `array_join(..., ', ')` flattens to the comma-separated string. Trap navigated cleanly. Zero defects.

---

## Q4 — Truncate a price to 2 decimals WITHOUT rounding (19.999 -> 19.99) (TRAP)

**Scores: Acc 5 / Comp 5 / Clar 5 / Act 5 → per-Q 5.00 STRONG PASS — TRAP NAVIGATED**

`truncate(price * 100) / 100 AS price_truncated` is correct Trino 467, and the responder correctly stated truncate is **1-arg only** and gave the general `truncate(price * power(10, d)) / power(10, d)` form.

Docs verified (trino.io/docs/current/functions/math.html): only the single-argument `truncate(x)` exists — "Returns `x` rounded to integer by dropping digits after decimal point." **No 2-arg `truncate(x, d)` variant exists in Trino 467** (the multiply/truncate/divide idiom is exactly the correct workaround). The toward-zero vs toward-negative-infinity vs HALF_UP distinctions are accurate:
- `truncate(x)` — "dropping digits after decimal point" = toward zero,
- `floor(x)` — "rounded down to the nearest integer" = toward negative infinity (differs from truncate for negatives),
- `round(x)` — "rounded to the nearest integer" (HALF_UP).

On a DECIMAL `price`, `price * 100` and `/ 100` keep DECIMAL semantics (no type problem). 19.999 -> truncate(1999.9)=1999 -> 19.99 (not 20.00). Trap navigated. Zero defects.

---

## Fabrication / slip scan

- **Q1: FABRICATED FUNCTION — `RLIKE` (CONFIRMED not in Trino 467).** See Q1.
- No `::`-cast anywhere (iter571 PIN holds).
- No QUALIFY, no invalid-clause-placement, no off-by-one, no type-mismatch in Q2/Q3/Q4.
- Q1's "garbled array_join+contains alternative" = incoherent noise; not a second distinct fabrication but should not have been emitted.

---

## iter623 teacher directives

**PRIMARY (Q1 — the only real defect): add a regexp_like-alternation canonical + RLIKE-not-Trino inoculation at the r27 (and r23) regexp landing point.** Reconcile-in-place / additive at r27:979 (the existing `regexp_like` contains-semantics line):
1. **Keyword anchors** for the failing phrasing: "contains any of several keywords", "multi-keyword text search", "mentions any of", "body contains any of these words", "match one of several terms", "search for several strings at once".
2. **Worked alternation canonical:** `WHERE regexp_like(body, 'refund|cancel|chargeback')` — note the `|` is regex alternation (matches ANY of the keywords), contains-semantics means NO `^...$` anchors needed, returns boolean usable directly in WHERE. Add the case-insensitive variant `regexp_like(body, '(?i)refund|cancel|chargeback')` (inline `(?i)` flag — Trino has no native RLIKE/case-insensitive operator).
3. **Equivalent multiple-LIKE-OR form:** `body LIKE '%refund%' OR body LIKE '%cancel%' OR body LIKE '%chargeback%'` — the readable alternative for non-regex teams; regexp_like is more compact for many keywords.
4. **RLIKE-not-Trino DO-NOT-WRITE inoculation:** "`RLIKE(col, pattern)` is a Hive/Spark/MySQL function — it does NOT exist in Trino 467 (function-not-registered error). Use `regexp_like(col, pattern)` (boolean) instead." Mirror the existing PERCENTILE_CONT-style debunk pattern (iter611) that successfully inoculated a prior cross-dialect fabrication.
5. Verify before writing: trino.io/docs/467/functions/regexp.html function list (7 functions, no RLIKE) + the `regexp_like` contains-semantics quote.

**DO NOT:**
- Touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe this iteration — federation row UNCHANGED).
- Re-edit the Q2 percent-of-total (`SUM(x) OVER ()` + 100.0 + ROUND), Q3 listagg-no-DISTINCT->array_join(array_agg(DISTINCT x ORDER BY x)), or Q4 truncate-1-arg-only canonicals — all docs-verbatim clean.
- Add `::`-casts (iter571 PIN), QUALIFY, EXTRACT(EPOCH) (iter562 ban).
- Touch iter534-621 locks.
- Bump training/state.json (already 622). No git commit/push.

**Docs verified today:** trino.io/docs/current(=467-equivalent)/functions/regexp.html (7 regex fns, NO RLIKE; regexp_like contains-semantics verbatim — Q1), functions/window.html (all aggregates usable as window fns; OVER() = grand total — Q2), functions/aggregate.html (listagg grammar has NO DISTINCT slot; array_agg + ORDER BY — Q3) + trinodb/trino #20725 (DISTINCT ORDER BY must appear in arguments; matching sort-key==distinct-arg is VALID — Q3), functions/math.html (truncate 1-arg only "dropping digits after decimal point"; floor down; round nearest — Q4).

**OVERALL: 4.46875 PASS — Q2/Q3/Q4 docs-verbatim zero-defect (percent-of-grand-total, listagg-no-DISTINCT trap navigated, truncate-1-arg trap navigated); Q1 led with FABRICATED `RLIKE` (not in Trino 467; correct = `regexp_like(body,'a|b|c')` contains-semantics, or multiple-LIKE-OR) — per-Q 2.875 flagged as quality concern; iter623 = add regexp_like-alternation canonical + RLIKE-not-Trino inoculation at the r27/r23 regexp landing point with multi-keyword anchors; federation row stays 4.49944/310.**
