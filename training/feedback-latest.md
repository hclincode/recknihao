# iter1092 Judge Feedback (2026-06-18)

Verified BOTH directions against RAW git-tag 467 source (functions/array.md, functions/map.md, functions/aggregate.md, functions/datetime.md). Clean sweep; ZERO source-verified defects.

## Q1 — array adjacency, 'assigned' directly after 'triaged' without exploding (ADJACENCY RE-PROBE of iter1091 FIX-A)
**Score: 5.00**
- Responder used `WHERE contains_sequence(status_history, ARRAY['triaged','assigned'])`.
- **FIX-A REACHED. CANONICAL USED (CORRECT).** The responder used the purpose-built `contains_sequence`, NOT the iter1091-defective hand-rolled `array_position(...) = array_position(...) + 1` arithmetic. This is exactly the resolution the iter1091 FIX-A targeted, and it reached the responder on the second-angle re-probe.
- array.md VERIFIED: `contains_sequence` "Return true if array `x` contains all of array `seq` as a subsequence (all values in the same consecutive order)." So `contains_sequence(x, ARRAY['triaged','assigned'])` is TRUE only when 'triaged' is immediately followed by 'assigned' (contiguous, same order) — exactly the "directly after, nothing in between" requirement.
- The responder's explicit claim that it **handles repeated elements correctly** is VERIFIED CORRECT: contains_sequence scans for the contiguous pair anywhere in the array, so `['submitted','triaged','assigned','triaged','resolved']` still matches on the first 'triaged'→'assigned' adjacency. This is precisely the case where the old array_position arithmetic produced false negatives (array_position returns only the FIRST occurrence). No-explosion requirement satisfied (pure boolean predicate, no UNNEST).

## Q2 — MAP column, pull list of all KEYS in a row as a plain list
**Score: 4.94**
- `map_keys(metadata) AS key_list`. map.md VERIFIED: `map_keys(x(K,V)) -> array(K)` "Returns all the keys in the map x." Returns ARRAY<VARCHAR> per row exactly as the responder stated.
- Correctly answers the literal ask (plain list per row, no explosion) and helpfully notes `CROSS JOIN UNNEST(map_keys(metadata))` as the later rows-form option without forcing it. Clean.

## Q3 — count DISTINCT calendar days with any activity
**Score: 4.91**
- `COUNT(DISTINCT CAST(event_timestamp AS DATE)) AS days_with_activity`. datetime.md VERIFIED: `date(x)` "is an alias for CAST(x AS date)", confirming `CAST(timestamp AS DATE)` is valid in 467 and extracts the calendar date (drops time). Distinct-count of those dates = distinct calendar days = correct.
- `date_trunc('day', event_timestamp)` is a valid alternative (keeps timestamp type at midnight), but CAST AS DATE is cleaner for calendar-day distinctness. Answer is correct and idiomatic.

## Q4 — standard deviation across all rows; built-in or manual?
**Score: 4.94**
- `stddev(response_ms)`; also lists stddev_samp (N-1), stddev_pop (N), variance/var_pop/var_samp. aggregate.md VERIFIED: `stddev` "is an alias for stddev_samp" (sample, divides by N-1); `stddev_pop` is population (divides by N); `variance` is an alias for `var_samp`; all six exist.
- The responder's alias relationship and N-1 vs N distinction are exactly correct. "Built-in, no manual computation needed" answered directly. Correctly frames bare `stddev` as the sample default. Clean — NOT a broken-secondary; every listed function is real and accurately described.

## Negative-family screen
No `::`/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary/Spark-Oracle-spillover.

## Overall
| Q | Accuracy | Completeness | Clarity | Actionability |
|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 |
| Q2 | 5 | 4.75 | 5 | 5 |
| Q3 | 5 | 4.75 | 5 | 4.88 |
| Q4 | 5 | 5 | 4.88 | 4.88 |

Per-question means: Q1 5.00, Q2 4.94, Q3 4.91, Q4 4.94.
**Overall average: 4.95 — PASS.**

ZERO source-verified defects. Q1 confirms the iter1091 contains_sequence FIX-A reached the responder and is the correct canonical.

RECOMMENDATION = DEFAULT NO-OP (margin +1.45); NO resource edit; NO commit; NO federation probe. MUST NOT bump state.json (already 1092).
