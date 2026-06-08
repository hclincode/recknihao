# Judge Feedback — iter747

**Theme:** durability-breadth — array lambda HOFs (reduce / transform / filter) + aggregate map-building (map_agg).

**Docs verification:** All four signatures verified against trino.io/docs/467 (functions/array.html, functions/aggregate.html) on 2026-06-09. resources/ NOT treated as ground truth.

---

## Per-question scores

### Q1 — Fold an array to a single value (running remaining-balance via `reduce`)
Answer: `reduce(payments, total_amount, (balance, payment) -> balance - payment, balance -> balance) AS final_balance`.

- **DOCS-CONFIRMED (HIGH-RISK claim this iter):** `reduce(array(T), initialState S, inputFunction(S,T,S), outputFunction(S,R)) -> R`. The inputFunction arg order is **(state, element)** — the responder's `(balance, payment)` maps state=balance FIRST, element=payment SECOND, which is exactly correct. The identity `outputFunction` `balance -> balance` is valid (S->R, R=S). Fold is **left-to-right** per docs, so subtracting payments in array order yields the correct final balance. All four argument slots and both lambda arities are correct.
- Bonus: correctly distinguished the single-value fold (`reduce`) from the full running-balance *sequence* (UNNEST + running SUM window) — accurate scoping, no overreach.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.00** |

### Q2 — Per-key frequency map in one aggregate (`map_agg`)
Answer: inner `SELECT user_id, event_type, COUNT(*) AS event_count ... GROUP BY user_id, event_type`, outer `map_agg(event_type, event_count) ... GROUP BY user_id`.

- **DOCS-CONFIRMED (HIGH-RISK claim this iter):** `map_agg(key, value) -> map(K,V)` "Returns a map created from the input key/value pairs." The two-step (inner GROUP BY key + COUNT, outer map_agg) is a correct and idiomatic way to build a per-key-count map, and is MORE flexible than the one-step shortcut (works for any value expression, not just occurrence counts). The inner `GROUP BY user_id, event_type` guarantees one distinct key per user, so the duplicate-key / NULL-key caveats of map_agg do not bite here — the answer is safe by construction.
- **Minor completeness ding:** for the narrow "count occurrences of one column" case, Trino 467 also offers the one-step `histogram(event_type) -> map(K,bigint)` (docs-verified: "Returns a map containing the count of the number of times each input value occurs"). Surfacing it as an alternative would have been a touch more complete. Not an error — both are docs-valid and the map_agg path is the right general answer; this is the only thing keeping Q2 below 5.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 4 | 5 | 5 | **4.75** |

### Q3 — Transform every array element, keep it an array (`transform`)
Answer: `transform(tag_list, tag -> upper(tag)) AS uppercase_tags`.

- **DOCS-CONFIRMED:** `transform(array(T), function(T,U)) -> array(U)` "applies function to each element." `upper()` is a valid Trino string function. One row in / one row out, no UNNEST — exactly addresses "no row explosion."

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.00** |

### Q4 — Keep only array elements matching a condition, keep it an array (`filter`)
Answer: `filter(amounts, amt -> amt > 0) AS positive_amounts`.

- **DOCS-CONFIRMED:** `filter(array(T), function(T,boolean)) -> array(T)` "constructs an array from those elements for which function returns true." The predicate lambda `amt -> amt > 0` is valid. In-array, no UNNEST — exactly addresses "keeping it an array."

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.00** |

---

## Overall

**Overall avg = (5.00 + 4.75 + 5.00 + 5.00) / 4 = 4.9375 — PASS.**

The two highest-risk claims this iteration (the `reduce` 4-arg signature with `(state, element)` inputFunction order, and `map_agg` map-building semantics) were both verified correct against the 467 docs. No accuracy defects, no dialect errors, no fabricated functions. The array-HOF family (reduce / transform / filter) is consistent with the iter673 MAP/JSON HOF locks and the iter746 array set-op locks.

## iter748 designation

**DEFAULT NO-OP / durability-breadth.** No new gap, no defect.

- Do NOT edit the array-HOF or map_agg resources — this is a near-perfect iteration and the iter693 churn-risk lesson applies (touching a working canonical risks regression).
- OPTIONAL low-prio additive (Q2 only): co-locate ONE line at the map_agg / frequency-map resource noting that `histogram(col) -> map(K,bigint)` is the one-step shortcut for counting occurrences of a single column's values, while `map_agg(key, COUNT(*))` over a GROUP BY subquery is the general (more flexible) form. Pure addition adjacent to the existing canonical; do NOT rewrite the working two-step map_agg block. Not blocking — both forms are docs-valid and the answer was already correct.
- Q1/Q3/Q4 perfect — do not touch.
