# Judge Feedback — iter854 (DEFAULT NO-OP durability sweep; teacher made ZERO resource edits)

All dialect claims verified against trino.io/docs/467 (string.html, array.html, aggregate.html, functions/list.html) + WebSearch, 2026-06-10. Trino PINNED to 467.

## Per-question scores

### Q1 — first N chars / no LEFT/RIGHT — `substr(code,1,3)`, `substr(code,-3)`
- Accuracy **5** / Completeness **5** / Clarity **5** / Actionability **5** → **avg 5.00**
- VERIFIED CLEAN. string.html: `substr(string,start[,length])` is an alias for substring; "A negative starting position is interpreted as being relative to the end of the string." functions/list.html confirms NO `left()` and NO `right()`. `substr(code,1,3)` -> 'US-' (1-based, length form), `substr(code,-3)` -> last 3 chars. Oracle-parallel framing apt. Bulletproof.

### Q2 — position of the Nth occurrence — `strpos(file_path,'/',2)`
- Accuracy **5** / Completeness **5** / Clarity **5** / Actionability **5** → **avg 5.00**
- VERIFIED CLEAN. 3-arg `strpos(string, substring, instance)` exists (added Release 325, Nov 2019; confirmed PR #1811 + functions/list.html): returns position of the Nth instance, 1-based, 0 if not found, negative `instance` searches from the end. `strpos(file_path,'/',2)` = 2nd slash position; `strpos(s,'/',-1)` = last slash; `substr(..., strpos(...)+1)` after-2nd-slash extract all correct. Bulletproof.

### Q3 — array subset (user has ALL of a required set) — TWO DEFECTS
- Accuracy **2.5** / Completeness **2.5** / Clarity **3** / Actionability **2.5** → **avg 2.625**
- **DEFECT 1 — Option A is a real SYNTAX ERROR (confirmed):** `FROM users u, CROSS JOIN UNNEST(required_features.features) AS rf(feature)`. You cannot place a comma AND `CROSS JOIN` between the same two relations in Trino 467. It must be EITHER `FROM users u, UNNEST(...) AS rf(feature)` OR `FROM users u CROSS JOIN UNNEST(...) AS rf(feature)` — not `u, CROSS JOIN`. The leading example will not parse.
- **Option B is VALID:** the correlated subquery `(SELECT COUNT(*) = 3 FROM UNNEST(ARRAY[...]) AS t(req_feature) WHERE contains(u.enabled_features, req_feature))` is correct Trino 467 and returns the right boolean. So a working answer exists, but it is the SECOND option, behind a broken one, and uses a hardcoded `= 3` magic number.
- **DEFECT 2 — CLEANER NATIVE IDIOM MISSED (verified present in Trino 467):** the responder asserted "Trino has no built-in subset function ... must loop via UNNEST + count." That is a completeness miss. `array_except(x,y) -> array` ("elements in x but not in y, without duplicates") and `cardinality(x) -> bigint` both exist (array.html). Therefore the clean one-expression subset test is:
  ```
  cardinality(array_except(ARRAY['feature_a','feature_b','feature_c'], enabled_features)) = 0
  ```
  True iff every required element is present in `enabled_features` — no UNNEST, no count, no GROUP BY, no magic number. Equally valid lambda form:
  ```
  all_match(ARRAY['feature_a','feature_b','feature_c'], f -> contains(enabled_features, f))
  ```
  (`all_match` returns true when every element matches the predicate; verified array.html.) Either is dramatically simpler than both responder options.
- **Q3 VERDICT (responder-slip vs resource gap):** PARTIAL FINDABILITY GAP. grep of resources confirms `array_except` IS documented (resources/23 §INTERSECT/EXCEPT disambiguator lines 1526-1533; resources/07 §1a.3 cross-ref) and `all_match`/`contains`/`cardinality` are all in resources/07 §1a.3/§1a.4. BUT there is **no dedicated "does an array contain ALL of a required set / array subset test" card** anchored on subset/contains-all/superset keywords. The pieces exist scattered; the composed `cardinality(array_except(required, user)) = 0` subset idiom is NOT findable as a single card. The responder landing on a subset question never assembled it. This is a genuine (light) findability gap, not a pure slip.

### Q4 — geometric mean — FACTUAL ERROR (built-in EXISTS)
- Accuracy **2.5** / Completeness **3** / Clarity **4** / Actionability **3.5** → **avg 3.25**
- **VERIFIED FINDING: `geometric_mean(x) -> double` IS a built-in aggregate in Trino 467.** Confirmed by THREE sources: aggregate.html (`geometric_mean(x) -> double`, "Returns the geometric mean of all input values"), functions/list.html (listed under G), and WebSearch. The responder's flat statement "No built-in geometric mean" is a **FACTUAL ERROR**. The simplest correct answer is `geometric_mean(revenue)`.
- The responder's manual `EXP(AVG(LN(revenue))) WHERE revenue > 0` is mathematically AND dialectically correct (geom mean = exp(mean(ln x)); LN undefined for <= 0 so the x>0 caveat is right). But it is the workaround, not the primary answer, and the responder explicitly denied the native function exists. The collateral claims about avg/stddev/variance/approx_percentile being present are correct, and "no percentile_cont / no exact median" is true — but the geometric_mean denial is false.
- This is a **RESOURCE GAP**: grep confirms `geometric_mean` appears NOWHERE in resources/. The responder had no card to find it.

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 2.5 | 2.5 | 3 | 2.5 | 2.625 |
| Q4 | 2.5 | 3 | 4 | 3.5 | 3.25 |

**Overall avg = (5.00 + 5.00 + 2.625 + 3.25) / 4 = 3.969 → PASS** (>= 3.5; overall average governs, no per-Q veto).

Although the overall passes, this iteration exposed TWO real content gaps (Q3 array-subset idiom missing as a findable card; Q4 `geometric_mean` built-in entirely absent from resources AND wrongly denied). PASS is carried by the bulletproof Q1/Q2.

## iter855 directive — LIGHT FIX-A (two small additive cards; NO churn to existing pins)

This is NOT a DEFAULT NO-OP. Two genuine gaps warrant light additive fixes:

1. **(PRIMARY) Q4 geometric_mean built-in card.** Add a short keyword-anchored card (resources/23 aggregate area near the avg/percentile family). LEAD with the native `geometric_mean(revenue) -> double` (verified aggregate.html / functions/list.html). Note the manual `EXP(AVG(LN(x))) WHERE x > 0` as the equivalent / pre-existing-engine fallback (LN undefined for <= 0). Inline-defang the false claim "Trino has no built-in geometric mean" on its own un-copyable fenced line. Keyword anchors: geometric mean, geometric average, geomean, multiplicative average, compound growth average, geometric_mean Trino. Verify against trino.io/docs/467 aggregate.html before writing.

2. **(SECONDARY) Q3 array-subset / contains-ALL card.** Add a small card at resources/07 §1a.3/§1a.4 (the array-function landing) for "does this array contain ALL of a required set / array subset / superset test". LEAD with `cardinality(array_except(required, user_flags)) = 0` (true iff `user_flags` is a superset of `required`; array_except returns elements of arg1 not in arg2, empty = subset). Offer `all_match(required, f -> contains(user_flags, f))` as the lambda equivalent. Inline-defang the malformed `FROM a, CROSS JOIN UNNEST(...)` form (mark un-copyable: comma AND CROSS JOIN between the same two relations is a parse error) and the "Trino has no subset function / must loop with UNNEST+count" claim. Keyword anchors: array contains all, array subset, has all features, superset test, all required flags present, array contains every element. Verify against trino.io/docs/467 array.html.

Do NOT churn any iter534-853 pins. NO federation edits (federation stays 4.49944/310). Do NOT bump training/state.json (already 854).

## Defects/gaps summary
- Q3 Option A: real Trino 467 syntax error (`u, CROSS JOIN UNNEST`). Option B valid. Clean `cardinality(array_except(...))=0` / `all_match` subset idiom missed — PARTIAL findability gap.
- Q4: `geometric_mean()` IS a Trino 467 built-in (verified 3 sources); responder wrongly denied it; absent from resources — RESOURCE GAP. Manual `EXP(AVG(LN(x)))` workaround itself is correct.
