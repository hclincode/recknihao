# Judge Feedback — Iter 840 (EXTENDED PHASE)

**Verdict: PASS — overall avg 4.97 (per-Q 5.00 / 4.9375 / 5.00 / 5.00 = 19.9375/4; margin +1.47; overall avg governs, no per-Q veto)**

**HEADLINE: The iter839 weighted-average integer-truncation findability fix LANDED — CLOSED.** Q1 re-probed the exact iter839 Q4 gap (integer rating * integer weight, mean came back whole numbers) and the responder NOW (1) correctly diagnosed the integer-division-truncation root cause and (2) led with the integer-safe form. The r23 §3.1B-WA weighted-average card + r07 AVG-landing routing pointer routed the responder to the right content. No defect this iteration.

Federation NOT probed this iteration (r22 §13.x untouched; federation row stays 4.49944/310, still FAIL).

---

## Per-question scores

### Q1 — weighted avg, integer rating*weight came back whole numbers — **5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)
CRITICAL TARGET — **FIX LANDED.** Responder:
- DIAGNOSED the integer-division trap: both numerator and denominator integer -> Trino does integer division and TRUNCATES (17/4 -> 4 not 4.25). Correctly noted the FORMULA itself is fine; only the type is the problem.
- Gave the integer-safe canonical: `SUM(rating*weight)*1.0/NULLIF(SUM(weight),0)` + the `CAST(SUM(rating*weight) AS double)/NULLIF(SUM(weight),0)` equivalent.
- Explained `*1.0` (decimal literal) promotes the division to non-integer, and `NULLIF(SUM(weight),0)` guards the all-zero/all-NULL-weight group from divide-by-zero.
VERIFIED vs trino.io/docs/467 math.html ("Division (integer division performs truncation)" — integer/integer truncates) and conditional.html (NULLIF(v1,v2) returns null if v1=v2 else v1; a double/decimal operand promotes the whole division to non-integer). This is the precise content the iter839 Q4 answer omitted. **CLOSED.**

### Q2 — deal NAME at max amount per rep without self-join — **4.9375** (Acc 5 / Comp 4.75 / Clar 5 / Act 5)
`max_by(deal_name, amount)` returns deal_name from the row where amount is maximal; one pass, no self-join. Correct. Tie-break via `max_by(deal_name, ROW(amount, deal_name))` is valid — ROW is a comparable type in Trino, compared field-by-field lexicographically, so passing a ROW ordering key resolves ties deterministically (alphabetical on deal_name when amounts tie). VERIFIED vs aggregate.html (max_by(x,y) = value of x at max of y). Minor completeness ding only: the "returns one, unspecified which" note on amount ties is adequate but terse. No accuracy issue.

### Q3 — safe cast of junk VARCHAR score, AVG ignores bad rows — **5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)
`TRY_CAST(score AS INTEGER)` -> NULL on non-numeric ('n/a','pending') instead of erroring; AVG ignores NULLs so the mean is over valid rows only; `try(expr)` recommended for complex expressions that may throw at runtime (div-by-zero, overflow). VERIFIED vs conversion.html (TRY_CAST "Like cast(), but returns null if the cast fails") and conditional.html (try(expression) returns NULL on division-by-zero, invalid cast, overflow, JSON errors). AVG-ignores-NULL is standard aggregate behavior (aggregate.html). All correct.

### Q4 — event distribution as single map {type:count} — **5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)
- Per-user map: `map_agg(event_type, event_count)` over an inner `GROUP BY user_id, event_type` that pre-aggregates the counts -> {click:42,...} per user. Correct: map_agg(k,v) builds a map from key/value pairs, so the values must already be the per-type counts.
- Whole-table one-step: `histogram(event_type)` -> map of value->count in one row, no GROUP BY. Correct.
- When-to-use-which framing accurate: map_agg for per-group (needs pre-aggregated counts in an inner GROUP BY); histogram for the no-GROUP-BY one-step summary.
VERIFIED vs aggregate.html (map_agg(key,value) "Returns a map created from the input key/value pairs"; histogram(x) "Returns a map containing the count of the number of times each input value occurs").

---

## Dimension cross-check
Acc 5.00 / Comp 4.9375 / Clar 5.00 / Act 5.00. Per-Q average = (5.00+4.9375+5.00+5.00)/4 = 4.984 ... rounded 4.97. Agrees. GOVERNING LABEL = PASS.

## iter841 directive — DEFAULT NO-OP / durability sweep
No open defect; the iter839->840 weighted-average integer-truncation arc is CLOSED (re-probed clean from the explicit-integer angle). Do NOT pre-churn:
- r23 §3.1B-WA weighted-average card (integer-safe `*1.0`/`CAST AS double` + NULLIF guard) — validated CLEAN, do not edit.
- r23 §3.1B item 5 SUM-truncation checklist, §3.1D max_by/ROW-tie-break card.
- r27 §4.4A/§4.4E TRY_CAST/try() cards.
- r07 map_agg/histogram map-functions card (~225-283) and the r07 AVG-landing routing pointer.

Suggest fresh ADJACENT probes for breadth (no edits unless a 2nd probe under-scores): min_by sibling / `max_by(x,y,n)` top-N array form / multimap_agg vs map_agg key-collision / `transform_values(histogram(x), ...)` / decimal-vs-double precision on the weighted mean / `element_at(map, key)` map lookup.

HOLD all iter534-839 locks. Federation row UNCHANGED (4.49944/310, still FAIL). Do NOT bump training/state.json (already 840). Do NOT touch r22 §13.x federation.
