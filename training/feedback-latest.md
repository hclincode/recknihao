# Judge Feedback — iter749

**Topic batch:** durability-breadth — array combine / flatten / element-remove / array-to-string
**Phase:** extended (state.json already at 749; NOT touched by judge)
**Docs ground truth:** verified against trino.io/docs/467/functions/array.html on 2026-06-09 (do NOT rely on resources/ as ground truth)

---

## Docs verification (Trino 467 array functions)

| Function | Verified signature | Verdict |
|---|---|---|
| `zip` | `zip(array1, array2[, ...]) -> array(row)` — merges arrays element-wise into array of rows; uneven length filled with NULL | NATIVE — Q1 exactly right |
| `flatten` | `flatten(x) -> array` — "Flattens an `array(array(T))` to an `array(T)` by concatenating the contained arrays" | NATIVE — Q2 MISSED the one-call native form |
| `array_remove` | `array_remove(x, element) -> array` — "Remove all elements that equal `element` from array `x`" | NATIVE — dedicated alternative to Q3's filter() |
| `filter` | `filter(array(T), function(T, boolean)) -> array(T)` — keeps elements where lambda returns true | NATIVE — Q3's chosen form is fully valid |
| `array_join` | `array_join(x, delimiter[, null_replacement]) -> varchar` — concatenates elements with delimiter; NULLs omitted (or replaced) | NATIVE — Q4 exactly right |

All four target functions confirmed native in Trino 467. **flatten() existence is the load-bearing finding for Q2.**

---

## Per-question scores

### Q1 — Combine two parallel arrays element-wise into pairs (positional, not cross-product)
Answer: `zip(product_names, quantities) AS product_qty_pairs`; explained pairs equal-length arrays into array of rows, positional, no cross-product / no row-explosion.

- Accuracy: 5 — zip is native and pairs positionally into `array(row)`, exactly as described.
- Completeness: 5 — covers the positional semantic and the no-explosion guarantee the question cares about.
- Clarity: 5 — clean, confident, correct framing.
- Actionability: 5 — copy-paste runnable.
- **Q1 avg: 5.00**

### Q2 — Flatten an array-of-arrays into one flat array per row (no row explosion)
Answer: HEDGED ("Use flatten() or transform()+reduce()... Actually, let me check the resources...") then concluded resources only document flatten in the UNNEST context, and gave a UNNEST + CROSS JOIN UNNEST + `array_agg ... GROUP BY order_id` workaround. Did NOT give the clean native `flatten(shipments)`.

- Accuracy: 3 — the UNNEST/array_agg path produces a flat array but CHANGES SEMANTICS: it explodes to rows then re-aggregates, which can reorder elements and loses the clean per-row guarantee the question explicitly asked for (the native `flatten` concatenates in order with no explosion). Functionally workable, semantically degraded.
- Completeness: 2.5 — missed the dedicated native one-call function (`flatten(array(array(T))) -> array(T)`) entirely; this IS the question's purpose-built answer.
- Clarity: 3 — the audible "let me check the resources / actually..." hedge degrades clarity and signals low confidence to a beginner reader.
- Actionability: 3 — the workaround runs but is convoluted (GROUP BY, two UNNESTs) for what is a single function call.
- **Q2 avg: 2.875**

### Q3 — Remove a specific value from an array (strip every 'legacy'), keep as array, no row explosion
Answer: `filter(tags, tag -> tag != 'legacy') AS tags_without_legacy`; explained filter keeps where lambda true, no row explosion.

- Accuracy: 5 — fully correct and idiomatic; filter returns an array, removes matching elements, no explosion. (NULL nuance: `tag != 'legacy'` is NULL for NULL elements and filter drops non-TRUE, so NULL elements are also dropped — a minor edge that does not affect the stated goal of removing 'legacy'. `array_remove` has its own NULL semantics. Not penalized.)
- Completeness: 4 — correct, but did not surface the dedicated `array_remove(tags, 'legacy')` one-call form, which is the purpose-built answer for "remove a specific value."
- Clarity: 5 — clean and confident.
- Actionability: 5 — runnable.
- **Q3 avg: 4.75**

### Q4 — Join one row's array into a single delimited string (per-row, not aggregate)
Answer: `array_join(categories, ',') AS categories_str`; explained per-row concatenation with delimiter, distinct from across-row aggregation.

- Accuracy: 5 — native, correct signature, correctly distinguished from listagg/array_agg aggregate.
- Completeness: 5 — covered the per-row vs aggregate distinction (the trap the question probes).
- Clarity: 5 — clean.
- Actionability: 5 — runnable; the optional 3rd null_replacement arg is a non-essential extra.
- **Q4 avg: 5.00**

---

## Overall

**(5.00 + 2.875 + 4.75 + 5.00) / 4 = 4.406**

**RESULT: PASS** (overall avg 4.406 >= 3.5; the overall average governs, no single-Q veto). Note that Q2 alone falls below threshold at 2.875 — it does not sink the iteration but it IS a genuine findable-but-missing gap.

---

## iter750 designation: FIX-A (topic: Q2 native flatten)

**This is a genuine findable-but-missing gap.** `flatten()` is native in Trino 467 (`flatten(array(array(T))) -> array(T)`, docs-verbatim "Flattens an `array(array(T))` to an `array(T)` by concatenating the contained arrays"), yet the responder hedged and fell back to a semantically-degraded UNNEST/array_agg workaround. Per state.json STEP 2(d), `flatten` currently has ZERO matches in resources/ — it is not documented anywhere.

### Teacher action for iter750 (FIX-A)
Add a LEADING CANONICAL for native per-row `flatten` to the array-HOF section (r07 §1a, adjacent to the transform/filter/reduce family — place where array-of-arrays keywords land, per the findability lesson):

1. **Lead with the native one-call form:** `flatten(shipments) AS all_item_ids` — `flatten(array(array(T))) -> array(T)`, collapses ONE level of nesting per row, returns a single flat array, NO row explosion, preserves element order by concatenating the contained arrays in order.
2. **Keyword anchors:** "flatten an array of arrays", "collapse nested arrays", "array of arrays into one flat list", "one flat list per row", "merge nested arrays without row explosion", "flatten array(array(T))".
3. **Distinguish from UNNEST:** explicitly contrast `flatten` (per-row, in-place, one flat array, order-preserving) vs the `UNNEST` + `array_agg ... GROUP BY` route (explodes to rows then re-aggregates — can REORDER elements and loses the clean per-row guarantee). Mark the UNNEST/array_agg re-aggregation form as the WRONG tool for "one flat array per row" (inline-marked un-copyable per the iter693 defang lesson), so the responder stops reaching for it.
4. **Co-locate `array_remove`** while in the same array-HOF neighborhood: add `array_remove(tags, 'legacy') -> array` as the DEDICATED element-removal one-call alternative to `filter(tags, tag -> tag != 'legacy')`. Note both are valid; array_remove is purpose-built, filter is more flexible (predicate). Anchors: "remove a specific value from an array", "strip a value from an array", "array_remove vs filter". This closes the minor Q3 completeness ding at the same time, same section, single edit pass.

Do NOT edit zip (Q1), array_join (Q4) content — both perfect, iter693 churn-risk. Q3 filter is correct; only ADD array_remove as alternative, do not rewrite the filter canonical.

### Re-probe in iter751
Re-probe flatten() from a 2nd angle (different phrasing, e.g. "merge a list of lists of IDs") to confirm the FIX-A lands before marking the topic bulletproofed.
