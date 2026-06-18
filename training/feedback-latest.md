# Judge Feedback — iter1087 (2026-06-18)

Verified BOTH directions vs RAW git-tag 467 source (functions/aggregate.md, functions/array.md, functions/string.md, functions/math.md, MathFunctions.java widthBucket(array), ArrayMaxFunction.java) + WebSearch. Clean sweep; zero source-verified defects.

## Per-question scores

### Q1 — per-status counts in one row, no 4 queries
**Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — avg 5.00**

Primary answer `COUNT(CASE WHEN status='trial' THEN subscription_id END) AS trial_count, ...` with no GROUP BY is the canonical conditional-aggregation pivot — one row, one pass, correct. `COUNT(col)` ignores NULLs so the CASE-without-ELSE (NULL on non-match) counts only matching rows per column. VERIFIED.

The offered alternative `COUNT(*) FILTER (WHERE status='trial') AS trial_count, ...` is ALSO valid Trino 467 — aggregate.md confirms: "The `FILTER` keyword can be used to remove rows from aggregation processing with a condition expressed using a `WHERE` clause," supported for all aggregate functions. Both forms produce identical per-status counts in one row in a single pass exactly as the responder claims. This is the OPPOSITE of the broken-secondary-alternative family — the secondary form here is fully correct and genuinely more compact.

### Q2 — single largest payment per customer from ARRAY column, no UNNEST
**Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5 — avg 4.75**

`array_max(payment_amounts)` VERIFIED real in 467 (array.md: `array_max(x) -> x` "Returns the maximum value of input array"; it is `array_max`, NOT `array_maximum`/fabrication). Returns one value per row, no explosion — exactly the right tool. Correctly marks the UNNEST+MAX+GROUP BY form as the inefficient/wrong-shape approach.

Minor completeness note (NOT a defect, no dimension below 4): raw ArrayMaxFunction.java shows array_max returns NULL if ANY element is NULL (`if (block.isNull(position)) return null;`) and NULL on an empty array. The responder didn't surface the any-NULL-poisons-the-result caveat; on payment_amounts this is usually fine, but a customer row with a NULL in the array yields NULL largest. Not wrong, just an unstated edge.

### Q3 — character position where keyword starts in a string
**Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — avg 5.00**

`strpos(merchant_name, 'AMZN')` VERIFIED in string.md: `strpos(string, substring) -> bigint` "Returns the starting position of the first instance of `substring` in `string`. Positions start with `1`. If not found, `0` is returned." Responder's claims all correct: 1-based, returns 0 if not found, example `'BEST BUY AMZN LOGISTICS'` → 11 (verified: A of AMZN at position 11). The `WHERE strpos(...) > 0` filter for found rows is correct. (`position(substring IN string)` is the SQL-standard equivalent but strpos as used is fully valid.)

### Q4 — bucket price into tiers without a long CASE
**Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — avg 5.00**

`width_bucket(price, ARRAY[500.0, 1000.0, 2000.0])` VERIFIED. math.md confirms the array overload `width_bucket(x, bins) -> bigint` "Returns the bin number of `x` according to the bins specified by the array `bins`." The docs do NOT state boundary semantics, so I went to RAW MathFunctions.java widthBucket(array): below the first bound → returns `0`; at/above the last bound → returns `numberOfBins` (= array length = 3 here); the binary search uses `if (operand < bin) upper = index; else lower = index + 1`, i.e. equal-to-bound advances to the HIGHER bucket = **lower-inclusive half-open intervals**.

So the responder's stated semantics are EXACTLY correct, both directions:
- bucket 0 = price < 500
- bucket 1 = 500 <= price < 1000
- bucket 2 = 1000 <= price < 2000
- bucket 3 = price >= 2000

The optional `CASE width_bucket(...) WHEN 0 THEN 'under 500' ...` label wrapper is correct. Note on the DECIMAL literals `ARRAY[500.0, ...]`: docs say bins "must be an array of doubles"; Trino's implicit DECIMAL→DOUBLE coercion makes the DECIMAL-literal array (and the DECIMAL `price` operand) coerce to DOUBLE, so the query runs. Stylistically `ARRAY[500e0, 1000e0, 2000e0]` or explicit casts are more literal, but this is not a defect.

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| 1 | 5 | 5 | 5 | 5 | 5.00 |
| 2 | 5 | 4 | 5 | 5 | 4.75 |
| 3 | 5 | 5 | 5 | 5 | 5.00 |
| 4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall average = (5.00 + 4.75 + 5.00 + 5.00) / 4 = 4.9375 → 4.94**

**Verdict: PASS** (margin +1.44 over the 3.5 threshold).

**Source-verified defects: ZERO.** Only a single unstated edge note on Q2 (array_max NULL-poisoning), which did not lower any dimension below 4.

No `::`/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary-alternative patterns present. width_bucket array boundary semantics and array_max NULL handling confirmed from RAW git-tag 467 source (dispositive over the docs, which were silent on both).

RECOMMENDATION = DEFAULT NO-OP. NO resource edit; NO commit; NO federation probe. MUST NOT bump state.json (already 1087).
