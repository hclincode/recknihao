# Judge Feedback — iter739

All dialect claims verified against trino.io/docs/467 on 2026-06-09 via WebFetch (string.html / math.html → floating-point + operators / datetime.html / bitwise.html). NOT verified against resources/. Production stack: Trino 467 + Iceberg, on-prem; none of these answers touch auth/authz, so no prod-fit concerns. state.json NOT bumped.

## Per-question scores

### Q1 — last dot / final segment (strpos-negative-instance FIX-A re-probe) — CRITICAL
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **5.00**
- `strpos(file_path, '.', -1)` — docs-verbatim string.html: "strpos(string, substring, instance) — Returns the position of the N-th instance of substring in string. **When instance is a negative number the search will start from the end of string. Positions start with 1. If not found, 0 is returned.**" So `strpos(s, '.', -1)` returns the position of the LAST dot, 1-based, 0 if none. CONFIRMED.
- `substr(s, pos + 1)` — docs: `substr` is an alias for `substring`; the 2-arg form "Returns the rest of string from the starting position start." So `substr(s, strpos(s,'.',-1)+1)` returns everything after the last dot → `'invoices'`. CONFIRMED correct.
- The responder used the NATIVE negative-instance form as the primary answer AND explicitly demoted the `LENGTH(s) - strpos(REVERSE(s),'.') + 1` arithmetic as clunky. Cited resources/23 (~line 430) — the iter739 r23 addition landed and is findable from the file-extension/last-occurrence keyword path.
- **VERDICT: strpos-negative-instance FIX-A is CLOSED.** The responder used the native `strpos(s, sub, -1)` form (not only the clunky LENGTH/REVERSE arithmetic). This is a clean reversal of the iter738 Q3 -0.50 miss. Recommend one 2nd-angle re-probe (e.g. position of the last `/` in a path, or N-th-from-end) to bulletproof before retiring.

### Q2 — is_nan / is_infinite (responder DECLINED) — findable-but-missing gap
- Accuracy 5 / Completeness 2 / Clarity 4 / Actionability 2 → **3.25**
- The responder DECLINED honestly and did NOT fabricate — correctly noted that `try()`/`NULLIF()` handle divide-by-zero BEFORE it happens, not detect-after, and pointed the user to the docs. That honesty is the right failure mode and is rewarded on Accuracy/Clarity.
- BUT this is a genuine FINDABLE-BUT-MISSING gap. Docs-verified math.html (floating-point section): `is_nan(x) → boolean` "Determine if x is not-a-number"; `is_infinite(x) → boolean` "Determine if x is infinite"; `is_finite(x) → boolean` "Determine if x is finite." All three exist in Trino 467. The user's exact question ("check if a value is infinite or not a real number") has a clean one-function answer the responder could not produce.
- Trino nuance the teacher MUST encode (verified against operator semantics): only DOUBLE/REAL division produces Infinity/NaN (e.g. `CAST(x AS double)/0e0`). Integer division by zero ERRORS, and DECIMAL division by zero ERRORS — so `is_nan`/`is_infinite` only ever fire on float/double paths. A user filtering "bad ratios" must ensure the division is done in DOUBLE for inf/nan to appear at all; otherwise the query throws and there is nothing to detect-after.
- Score reflects merits: accurate + honest (no fabrication) but incomplete and not-actionable for a question with a clean native answer.

### Q3 — day_of_year (fresh)
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **5.00**
- `EXTRACT(DAY_OF_YEAR FROM signup_date)` and shorthand `day_of_year(date)` — docs-verbatim datetime.html: "Returns the day of the year from x. The value ranges from 1 to 366." Alias `doy` confirmed. CONFIRMED 1-366, leap-year-aware.
- `GROUP BY 1, 2` (ordinal group-by) is valid Trino — standard SQL ordinal GROUP BY by select-list position. CONFIRMED correct. Cited resources/13. Clean, directly answers "day-within-year directly".

### Q4 — bitmask / bitwise (responder DECLINED) — findable-but-missing gap
- Accuracy 5 / Completeness 2 / Clarity 4 / Actionability 2 → **3.25**
- The responder DECLINED honestly and did NOT fabricate — searched for AND/OR/XOR/shifts/bit-counting, found nothing, and pointed at the docs with plausible candidate names. Right failure mode; rewarded on Accuracy/Clarity. Note: it guessed `popcount()` — Trino's name is `bit_count`, so the candidate-name guess was partly off (do not penalize a declined answer for this, but the teacher should encode the real name).
- Genuine FINDABLE-BUT-MISSING gap. Docs-verified bitwise.html: `bitwise_and(x,y)`, `bitwise_or(x,y)`, `bitwise_xor(x,y)`, `bitwise_not(x)`, `bitwise_left_shift`, `bitwise_right_shift`, `bitwise_right_shift_arithmetic`, and `bit_count(x, bits) → bigint`. Test bit n: `bitwise_and(flags, 1 << n) <> 0` (or `bitwise_and(flags, pow2) <> 0`). Count set bits: `bit_count(flags, 64)`.
- **CRITICAL NUANCE for the teacher: `bit_count` REQUIRES the 2-arg form `bit_count(x, bits)`** — the second arg is the number of bits (e.g. `bit_count(9, 64)`), treating x as a `bits`-bit signed integer in 2's complement. There is NO 1-arg `bit_count(x)` and NO `popcount`. A resource that writes `bit_count(flags)` will be a parse error.
- Score reflects merits: accurate + honest (no fabrication) but incomplete and not-actionable for a question with a clean native answer.

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 2 | 4 | 2 | 3.25 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 2 | 4 | 2 | 3.25 |

**OVERALL AVERAGE = (5.00 + 3.25 + 5.00 + 3.25) / 4 = 4.125 → PASS** (threshold 3.5; overall average governs, no per-Q override).

## Verdicts and iter740 recommendation

- **Q1 strpos-negative-instance FIX-A: CLOSED.** Native `strpos(s, sub, -1)` used as the primary answer; REVERSE/LENGTH arithmetic correctly demoted. The iter739 r23 findability ADD worked. One 2nd-angle re-probe (last `/` in a path, or N-th-from-end) recommended to bulletproof.

- **Q2 is_nan/is_infinite/is_finite: FINDABLE-BUT-MISSING gap — FIX-A for iter740.** Add a float-state-detection canonical: `is_nan(x)/is_infinite(x)/is_finite(x) → boolean`. Encode the division-by-zero nuance: ONLY double/real div-by-zero yields Infinity/NaN (`CAST(x AS double)/0e0`); integer AND decimal div-by-zero ERROR (so there is nothing to detect-after unless the division is in DOUBLE). Anchors: "detect infinity", "is not a number / NaN", "filter bad float ratios", "is_nan / is_infinite / is_finite". Contrast with the existing try()/NULLIF before-the-fact divide-by-zero content (route by before-vs-after keywords; do not contradict it). Pure ADDITION.

- **Q4 bitwise functions: FINDABLE-BUT-MISSING gap — FIX-A for iter740.** Add a bitwise canonical: `bitwise_and/or/xor/not`, `bitwise_left_shift/right_shift`, and `bit_count(x, bits)`. Test-a-bit: `bitwise_and(flags, 1 << n) <> 0`. Count-set-bits: `bit_count(flags, 64)`. **PIN the bit_count 2-arg requirement** — `bit_count(x, bits)`, NO 1-arg form, NO `popcount` (would be parse error). Anchors: "permission bitmask", "test if a bit is set", "count set bits / enabled flags", "bitwise AND/OR". Pure ADDITION.

- Two findable-but-missing gaps surfaced this iteration (Q2, Q4). The two-FIX-A pattern (cf. iter736 dual-canonical 4.97 PASS) is appropriate for iter740. Both are pure additions to the function-reference resources (r05/r27 math; new bitwise content) with no contradictory content to reconcile.
- Honesty discipline holding: the responder declined cleanly on both unknown-function questions rather than fabricating signatures — the right behavior, and the reason overall still PASSES despite two real coverage gaps.
