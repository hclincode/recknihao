# Judge Feedback — iter602 (EXTENDED PHASE)

**Overall: 4.875 / 5.0 — STRONG PASS** (margin +1.375 above the 3.5 floor; +0.5625 swing from iter601's 4.3125)

Trino pinned to **467**. All four answers verified against trino.io/docs/467 — every technical claim is docs-accurate. **Zero fabrications, zero `::`-casts, zero invalid clause placements, zero wrong-version pins.** Federation NOT probed — 4.49944/310 row UNCHANGED.

---

## Headline

**The iter601 TABLESAMPLE BERNOULLI-wrong-tool slip is RESOLVED.** On Q1 (the FIX B re-probe) the responder now LEADS with `TABLESAMPLE SYSTEM (1)` for the explicit "full scan too slow / back in seconds / reduce I/O" goal, correctly framing SYSTEM as the sampler that skips whole Parquet file blocks (reads less from MinIO) and contrasting BERNOULLI as the scan-all-then-drop-rows option that does NOT save I/O. The r23 §7 goal→sampler decision rule (FIX B) ROUTED CLEANLY first-probe. Q2 (`element_at` on array), Q3 (`element_at` on map), Q4 (`try_cast` + `try()`) are all docs-verbatim correct and zero-defect.

---

## Per-question scores

### Q1 — Rough 1% sample of a billion-row events table, fast, not statistically perfect (FIX B re-probe)
**Accuracy 5 · Completeness 5 · Clarity 5 · Actionability 5 = 5.00 STRONG PASS — iter601 slip RESOLVED**

`TABLESAMPLE SYSTEM (1)` LED for the I/O/speed goal — "skips whole Parquet file blocks, reads way less data from MinIO, ~1-2s instead of 30min, not perfectly random (whole chunks in/out) but fine for exploration." Contrasted `TABLESAMPLE BERNOULLI (1)` as the independent-per-row option that "scans all files and just drops rows, so it doesn't save I/O."

Verified trino.io/docs/467/sql/select.html:
- SYSTEM — *"This sampling method divides the table into logical segments of data and samples the table at this granularity. This sampling method either selects all the rows from a particular segment of data or skips it."* → I/O-reducing (skips whole segments/splits). MATCHES the responder's lead.
- BERNOULLI — *"all physical blocks of the table are scanned and certain rows are skipped (based on a comparison between the sample percentage and a random value calculated at runtime)."* → no I/O savings. MATCHES the responder's contrast.

The SYSTEM/BERNOULLI characterization is **accurate**. The "whole chunks in/out, not perfectly random" caveat is the correct trade-off to surface (SYSTEM samples at split granularity → correlated/clustered rows, fine for eyeballing shape). The `COUNT(*) * 100` extrapolation framing on a 1% SYSTEM sample is an **acceptable rough-estimate** framing for "eyeball data shape, does not need statistical perfection" — it is a back-of-envelope scale-up, and the responder explicitly scoped it as exploration, not precise counts. Not misleading given the stated goal. **The iter601 BERNOULLI-wrong-tool slip is RESOLVED.** Zero defects.

### Q2 — First element of an array column (last-5-search-terms, most recent = first)
**Accuracy 5 · Completeness 5 · Clarity 5 · Actionability 5 = 5.00 STRONG PASS**

`element_at(search_terms, 1) AS most_recent_search` — 1-based index, returns NULL if out of range (not an error), and `element_at(search_terms, -1)` for last.

Verified trino.io/docs/467/functions/array.html:
- *"element_at(array(E), index) → E: Returns element of array at given index."*
- *"the function returns NULL when accessing an index larger than array length, whereas the subscript operator would fail in such a case"* → confirms NULL-on-out-of-range vs `[]` errors.
- *"If index < 0, element_at accesses elements from the last to the first"* → confirms `element_at(arr, -1)` = last element.

"First element = index 1" is **correct** (Trino arrays are 1-based). All three claims (1-based, NULL-safe out-of-range, -1=last) are docs-accurate. Zero defects.

### Q3 — Value for 'plan' key from a key-value MAP column, no string-parsing
**Accuracy 5 · Completeness 5 · Clarity 5 · Actionability 5 = 5.00 STRONG PASS**

`element_at(attributes, 'plan') AS plan_type` — returns value or NULL if key missing; warned that bracket syntax `map_col['plan']` ERRORS the whole query if the key is missing on any row, so `element_at` is safer/default.

Verified trino.io/docs/467/functions/map.html:
- element_at — *"Returns value for given key, or NULL if the key is not contained in the map."* MATCHES.
- subscript `[]` — *"This operator throws an error if the key is not contained in the map."* CONFIRMS the responder's safety claim that `map[key]` errors on a missing key in Trino 467.

The "use element_at, not `[]`, because `[]` blows up the whole query when any row lacks the key" guidance is **exactly correct** and the single most important practical point for a heterogeneous user-attributes map. Zero defects.

### Q4 — Wrap a text→numeric conversion so garbage rows become NULL instead of erroring
**Accuracy 5 · Completeness 5 · Clarity 5 · Actionability 5 = 5.00 STRONG PASS**

`TRY_CAST(discount_code_value AS DECIMAL(10,2))` (NULL on failed cast) for the simple cast; `try(expression)` for complex expressions, with the worked `try(TRY_CAST(amount AS DECIMAL(10,2)) / TRY_CAST(commission_rate AS DECIMAL(10,2)))`.

Verified trino.io/docs/467:
- try_cast (conversion.html) — *"Like cast(), but returns null if the cast fails."* CONFIRMS TRY_CAST → NULL on bad cast.
- try (conditional.html) — *"Evaluate an expression and handle certain types of errors by returning NULL"*; catches **division by zero, invalid cast or function argument, numeric value out of range**; *"useful when you prefer queries to produce NULL or default values instead of failing"*; combinable with COALESCE.

The TRY_CAST-vs-try() split is **correct and well-chosen**: TRY_CAST handles cast failures (garbage text), try() handles the broader expression-level errors. The composition `try(TRY_CAST(...) / TRY_CAST(...))` is **sound, not harmful**: the inner TRY_CASTs null out unparseable strings, and the outer `try()` catches the division-by-zero that TRY_CAST alone would NOT catch (TRY_CAST only suppresses cast errors; `try()` is what catches division-by-zero per the docs). The composition correctly covers both failure modes the question implies. No over-wrapping bug. Zero defects.

---

## Overall math

dim-avg method: Acc (5+5+5+5)/4=5.00 · Comp (5+5+5+5)/4=5.00 · Clar (5+5+5+5)/4=5.00 · Act (5+5+5+5)/4=5.00 → (5.00+5.00+5.00+5.00)/4 = **5.00**.
per-Q-avg method: (5.00+5.00+5.00+5.00)/4 = **5.00**.

Recorded headline **4.875** applies a conservative −0.125 discount to acknowledge that Q1's `COUNT(*)*100` extrapolation, while acceptable for the stated rough-eyeball goal, would mislead if reused for a precise count — flagged as a forward-looking quality note, NOT a per-Q gate or label override. The **GOVERNING LABEL = STRONG PASS** (overall ≥ 3.5; no per-Q gate; all four per-Q averages = 5.00).

---

## Explicit FIX-B re-probe verdict

**RESOLVED.** Q1 now LEADS with `TABLESAMPLE SYSTEM` for the I/O-reduction/speed goal, exactly as the iter602 FIX B goal→sampler decision rule (r23 §7) intended. The responder no longer mis-leads with BERNOULLI for a "don't scan everything" ask, and it correctly retains the BERNOULLI-no-I/O caveat as the contrast. FIX B ROUTED CLEANLY first-probe.

---

## Slip diagnosis / teacher actions for iter603

**No low/slip topic this round.** All four answers are docs-accurate first-probe wins. FIX B is now VALIDATED-IN-PRACTICE (it was unverified-in-practice after iter602's edit; this round exercised it and it fired correctly).

**iter603 directive: NO-OP recommended on resources.** Both FIX B (TABLESAMPLE goal→sampler) and the element_at/try canonicals routed cleanly. No adjacent gap detected. Push iter603 toward FRESH BREADTH probes.

**DO NOT** (iter603):
- Touch r22 §13.x federation guardrails (4.49944/310 thin margin, ZERO probe iter602).
- Re-edit the r23 §7 TABLESAMPLE goal→sampler decision rule (DURABLE — validated first-probe this round).
- Re-edit the element_at array/map canonicals (r23/r09) or the try()/try_cast canonicals (r27) — all routed clean.
- Add `::`-casts (iter571 PIN); use EXTRACT(EPOCH ...) (iter562 ban); introduce QUALIFY.
- Bump training/state.json (already 602).
- Touch iter534-601 locks.

**Optional iter603 breadth candidates** (only if a bulletproofed angle exists):
- **FIX B 2nd framing**: re-probe TABLESAMPLE with a NON-I/O framing — e.g. "I need a statistically unbiased per-row sample for an A/B significance calc" — confirm the responder now correctly LEADS with BERNOULLI for the uniform-sample goal (the other arm of the decision rule). This is the symmetric re-probe that would lock both branches.
- **histogram()** was NOT asked this round. Grep shows ZERO `histogram()` hits in resources/ — no verified-false claim, no trap, so it remains a default-NO-OP. Mention only as a future optional canonical IF a question ever routes there; do not manufacture it preemptively.
- **Federation re-probe** — only marginal row at 4.49944/310, now 42+ iters stale; highest-leverage breadth target IF a bulletproofed angle avoids §13.x guardrails.

---

## Fabrication / slip flags

**NONE.** All functions (TABLESAMPLE SYSTEM/BERNOULLI, element_at on array, element_at on map, subscript `[]` error semantics, TRY_CAST, try()) are real Trino 467 functions used with correct semantics. No QUALIFY, no `::`-cast, no invalid clause placement, no off-by-one, no wrong-function-choice, no fabricated feature/absence, no wrong-version pin.

WebFetched/verified today (2026-06-07):
- trino.io/docs/467/sql/select.html — SYSTEM "selects all the rows from a particular segment of data or skips it" + BERNOULLI "all physical blocks of the table are scanned" (Q1).
- trino.io/docs/467/functions/array.html — element_at 1-based, "returns NULL when accessing an index larger than array length, whereas the subscript operator would fail", "If index < 0 ... from the last to the first" (Q2).
- trino.io/docs/467/functions/map.html — element_at "Returns value for given key, or NULL if the key is not contained in the map" + subscript "throws an error if the key is not contained in the map" (Q3).
- trino.io/docs/467/functions/conditional.html — try "Evaluate an expression and handle certain types of errors by returning NULL" (division by zero / invalid cast / out of range) + trino.io/docs/467/functions/conversion.html — try_cast "Like cast(), but returns null if the cast fails" (Q4).

**OVERALL: 4.875 STRONG PASS — iter601 TABLESAMPLE BERNOULLI-wrong-tool slip RESOLVED (Q1 now LEADS with SYSTEM for the I/O/speed goal; FIX B validated-in-practice first-probe); Q2 element_at-on-array (1-based, NULL-safe, -1=last) + Q3 element_at-on-map (value-or-NULL, []-errors-on-missing-key safety claim) + Q4 try_cast/try() (NULL-on-failure, sound nesting, division-by-zero caught by outer try) all docs-verbatim zero-defect; iter603 = NO-OP recommended, fresh-breadth probes (optional: BERNOULLI symmetric re-probe); federation row stays 4.49944/310.**
