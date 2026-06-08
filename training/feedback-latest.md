# Judge Feedback — iter748

**Topic:** Durability-breadth probe — array predicate-quantifier (any_match) + array positional (array_position) + map-value filter (map_filter) + array sub-range (slice). All four are "reshape/test a collection per row, no row explosion / no UNNEST" idioms.

**Docs verification (trino.io/docs/467, array.html + map.html, 2026-06-09):** all four core forms confirmed. resources/ NOT treated as ground truth. No new defect, no gap.

---

## Per-question scores

### Q1 — ANY/ALL element satisfies a condition, boolean per row
**Answer:** `any_match(line_item_amounts, x -> x > 1000) AS has_large_item`; lambda tests each element; true if at least one passes; one row in/out, no UNNEST.

- DOCS: `any_match(array(T), function(T, boolean)) -> boolean` — VERBATIM "Returns `true` if one or more elements match the predicate; `false` if none match (special case: empty array → false); `NULL` if predicate returns NULL for one+ elements and false for all others." Responder's signature, lambda, and "true if at least one passes / no row explosion" semantics are exactly correct for the "ANY over $1000" ask.
- Not mentioning `all_match` / `none_match` is at most a micro-completeness note — the question asked specifically about ANY; choosing any_match is precisely right.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

### Q2 — 1-based position of a value in an ordered array
**Answer:** `array_position(completed_steps, 'checkout') AS checkout_position`; 1-based index of FIRST occurrence; returns **0 (not NULL)** if absent; caveat that duplicates collide on first match and to use UNNEST WITH ORDINALITY for per-element position.

- DOCS: `array_position(x, element) -> bigint` — confirmed 1-based indexing, locates the FIRST matching element, and yields **0 when the element is absent** (NOT NULL). This is the classic trap and the responder nailed it. Both 0-if-absent and first-occurrence-on-duplicates claims are docs-correct.
- The proactive duplicate caveat + correct route to `UNNEST ... WITH ORDINALITY` for per-element ordinals (consistent with standing r07:70/85/95/503 disambiguation locks) is exemplary — exceeds the question.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

### Q3 — keep only map entries whose value passes a test, smaller map, no explosion
**Answer:** `map_filter(feature_usage, (k, v) -> v > 10) AS heavily_used_features`; keeps entries where value > 10; returns a smaller map; worked example `{'export':3,'api_access':45,'bulk_upload':12} -> {'api_access':45,'bulk_upload':12}`; no UNNEST/aggregation.

- DOCS: `map_filter(map(K,V), function(K,V,boolean)) -> map(K,V)` — VERBATIM "Constructs a map from those entries of map for which function returns true." Lambda arity `(k,v)->boolean` confirmed; returns the filtered map. Worked example correct (drops export=3, keeps 45 and 12).
- Correctly distinguishes "filter a MAP in place → map_filter (returns a map)" from array `filter` / UNNEST — matches the standing r09:734 vs r07:533 disambiguation lock.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

### Q4 — slice a sub-range / first-N of an array, no sort, no unnest
**Answer:** `slice(page_visits, 1, 3)` first 3; `slice(page_visits, 2, 4)` pages 2-5; `slice(page_visits, -3, 3)` last 3. Signature `slice(array, start, length)`; 1-based; negative start counts from end. Caveat: Trino calls it `slice` NOT `array_slice` (Spark/BigQuery); start=0 is out of range, use start>=1 or negative.

- DOCS: `slice(x, start, length) -> array` — confirmed "Subsets array x starting from index start (negative → from the end) with length length." 1-based start confirmed (Trino arrays are 1-based throughout). `slice(x, -3, 3)` = last 3 elements is correct (start at 3rd-from-last, length 3). The name is indeed `slice`, NOT `array_slice` (that's Spark/BigQuery) — correct dialect disambiguation.
- **start=0 edge verified:** Trino arrays are 1-based; a 0 start index is invalid for slice (engine raises an array-subscript / "SQL array indices start at 1" style error). The responder's "start=0 is out of range, use start>=1 or negative" is ACCURATE — NOT an overstated claim. `slice(page_visits, 2, 4)` correctly yields positions 2,3,4,5 = pages 2-5.
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

---

## Overall

**Overall avg = (5.00 + 5.00 + 5.00 + 5.00) / 4 = 5.00 — STRONG PASS.**

Every dialect-specific claim docs-verified clean, including the two highest-risk traps flagged this iteration:
- **array_position 0-if-absent (NOT NULL) + 1-based-first-occurrence** — CORRECT.
- **slice 1-based / negative-start-from-end / start=0-out-of-range** — CORRECT (start=0 claim is accurate, not overstated).

The responder also volunteered correct, high-value caveats unprompted (duplicate-collision → WITH ORDINALITY for Q2; `slice` vs `array_slice` dialect note + start=0 edge for Q4), and correctly held the array-`filter`-returns-array vs `map_filter`-returns-map vs `any_match`-returns-boolean distinctions that the standing pins guard against conflating.

## iter749 designation

**NO-OP / durability-breadth.** No new gap, no defect. All four forms docs-confirmed; collection-HOF disambiguation clean. Do NOT edit r07 (any_match / array_position / slice), r09 (map_filter), or adjacent cards — perfect-score iteration, iter693 churn-risk applies. Standing locks (any_match/all_match/none_match boolean-quantifiers, array_position 1-based-0-if-absent, map_filter (k,v)->map, slice 1-based/negative/start=0) all HELD and CONFIRMED by this datapoint.

Optional (genuinely low-priority, do NOT act unless a future probe surfaces it): Q1 could one day be re-probed from the ALL/NONE angle to add a second-angle datapoint for all_match/none_match; any_match alone fully answered the asked question and is already well-covered in r07:535.
