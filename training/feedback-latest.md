# Judge Feedback — iter857

**Verdict: PASS — overall average 4.875** (Q1 5.00 / Q2 4.75 / Q3 5.00 / Q4 4.75)

LIGHT FIX-A verification of the iter856 Q3 defect (per-row timezone-name-in-a-column). The fix LANDED. All four dialect claims verified against trino.io/docs/467 using multiple sources (category page + functions/list.html) plus WebSearch/WebFetch 2026-06-10. DO NOT bump training/state.json.

---

## Q1 — Convert UTC timestamp to a per-row timezone NAME held in a COLUMN (iter856 FIX RE-PROBE)

**Responder answer:** Led with `at_timezone(with_timezone(event_ts,'UTC'), user_tz)` for plain-UTC `timestamp` and `at_timezone(event_ts, user_tz)` for already-tz-aware `timestamp with time zone`. Explicitly stated `at_timezone`'s zone accepts a per-row varchar COLUMN and that you do NOT need a CASE-per-timezone.

**Verification (trino.io/docs/467 datetime.html + functions/list.html):**
- `at_timezone(timestamp(p) with time zone, zone) -> timestamp(p) with time zone` — the `zone` parameter is an ordinary varchar argument with NO `(constant)`/literal-only annotation. Trino explicitly annotates constant-required args; the absence of any such annotation means a column/expression is accepted and evaluated PER ROW.
- `with_timezone(timestamp(p), zone) -> timestamp(p) with time zone` — likewise a plain varchar zone, no constant restriction. Tagging a plain (zone-less) timestamp as UTC first via `with_timezone(ts,'UTC')` is exactly the right two-step before re-projecting with `at_timezone`.
- Docs show only literal examples (`'America/Los_Angeles'`) but state NO literal-only rule.

**Scores:** Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.00**

**FIX CONFIRMATION: LANDED.** The iter856 "AT TIME ZONE / with_timezone take literal zones only, a column cannot be used, must CASE-per-timezone" defect is GONE. Responder now correctly leads with `at_timezone(...,column)`, distinguishes the plain-UTC two-step (`with_timezone` first) from the already-tz path, and explicitly rejects the CASE hack. 1st post-fix datapoint clean; needs 1 more phrasing angle to bulletproof.

---

## Q2 — Average of rates (harmonic mean)

**Responder answer:** DECLINED a built-in, affirmed the harmonic-mean principle is real, offered the manual formula `1/AVG(1/rate)`.

**Verification (trino.io/docs/467 aggregate.html + functions/list.html H-section):**
- NO `harmonic_mean` aggregate exists. list.html H-section = hamming_distance, hash_counts, histogram, hmac_md5/sha1/sha256/sha512, hour, human_readable_seconds — no harmonic mean. aggregate.html confirms only `geometric_mean` among the "*_mean" family.
- `1/AVG(1/rate)` is the correct harmonic-mean formula (HM = n / Σ(1/x) = 1 / (mean of reciprocals)).

**Scores:** Accuracy 5 / Completeness 4.5 / Clarity 5 / Actionability 4.5 = **4.75**

**HONEST-DECLINE-CORRECT — scored well, NOT as a defect.** There is genuinely no built-in, so declining and giving the correct manual formula is DESIRED behavior. Minor completeness/actionability ding only: an integer-division/divide-by-zero guard would harden it (if `rate` is integer, `1/rate` truncates to 0; a zero rate makes the inner term undefined) — `1.0/AVG(1.0/NULLIF(rate,0))` is the bulletproof form. Not a fabrication, not wrong.

**GAP NOTE for iter858:** harmonic-mean has NO dedicated card in resources/. This is a findable-but-missing gap (like iter854 geometric_mean): the responder answered correctly from principle, but a §3.1B-HM card (canonical `1.0/AVG(1.0/NULLIF(rate,0))`, "no harmonic_mean built-in" stated, anchors: harmonic mean / average of rates / average of speeds / reciprocal mean) would lock it. Eligible for a LIGHT FIX-A only if a 2nd harmonic-mean datapoint also dings.

---

## Q3 — Slice the middle of an array (items 3-7, no UNNEST)

**Responder answer:** `slice(steps_array, 3, 5)` — 1-based, length=count, negative-start-from-end, short-array clamping; defanged `array_slice()` and Python `arr[3:7]`.

**Verification (trino.io/docs/467 array.html + functions/list.html):**
- `slice(x, start, length) -> array` — "Subsets array x starting from index start (or starting from the end if start is negative) with a length of length." 1-based indexing (consistent with `element_at`/`array_position`; Trino arrays are indexed from one). `slice(steps_array, 3, 5)` = 5 elements from index 3 = items 3,4,5,6,7. Correct.
- `array_slice` does NOT appear in list.html — correctly defanged as non-Trino.
- `arr[3:7]` Python-style range subscript is invalid in Trino 467 (`array[i]` subscript takes a single index only) — correctly defanged.

**Scores:** Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.00**

CLEAN. Signature, 1-based, negative-start, clamping, and both defangs all docs-accurate. Cites §1a.4A slice card.

---

## Q4 — Map key lookup with a default instead of NULL

**Responder answer:** `COALESCE(element_at(feature_flags, key), default)`; explained `element_at` returns NULL for a missing key while bracket `map['key']` THROWS.

**Verification (trino.io/docs/467 map.html + functions/list.html):**
- `element_at(map(K,V), key) -> V` — "Returns value for given key, or NULL if the key is not contained in the map." Returns NULL, does NOT throw. Correct.
- Subscript operator `map[key]` — "This operator throws an error if the key is not contained in the map" (the "Key not present in map" error). Correct.
- `COALESCE(element_at(...), default)` is the right NULL→default substitution.

**Scores:** Accuracy 5 / Completeness 4.5 / Clarity 5 / Actionability 4.5 = **4.75**

CLEAN. The element_at-NULL-vs-subscript-throws distinction is exactly right and is the load-bearing nuance. Minor ding only: no note that the default must be type-compatible with element_at's value type for COALESCE — negligible.

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 4.5 | 5 | 4.5 | 4.75 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 4.5 | 5 | 4.5 | 4.75 |

**Overall average = 4.875 → PASS** (threshold 3.5; overall average governs, no per-Q veto).

**(a) Q1 FIX LANDED** — responder gives `at_timezone(with_timezone(ts,'UTC'), user_tz)` / `at_timezone(ts, user_tz)` with explicit per-row-column zone, no CASE-per-timezone. iter856 defect closed (1st post-fix datapoint; 1 more angle to bulletproof).

**(b) Q2-Q4 docs-correct + findable.** No fabrication, no parse-error risk, no crossed-family error, no findability slip. All pure SQL → no conflict with on-prem Trino 467 + Iceberg + MinIO prod stack.

**ONE GAP (non-blocking):** harmonic mean has no dedicated resource card. Responder answered correctly from principle, so this is not a current defect — but it parallels the iter854 geometric_mean gap.

---

## iter858 recommendation

**DEFAULT NO-OP / durability sweep** (NOT a FIX-A — no defect surfaced this iteration).

- Re-probe Q1 per-row timezone-column 2nd angle (e.g. "store users in their own tz then bucket by local day" phrasing) to bulletproof the iter857 fix — confirm responder still leads `at_timezone(...,column)` and never reaches for CASE-per-timezone.
- Re-probe harmonic mean 2nd angle (average of speeds / average of P/E ratios). IF it lands clean again from principle, hold. IF a 2nd harmonic-mean datapoint dings on findability/integer-guard, ESCALATE to a LIGHT FIX-A adding a §3.1B-HM card (`1.0/AVG(1.0/NULLIF(rate,0))`, "no harmonic_mean built-in", anchors harmonic mean / average of rates / reciprocal mean) — verify vs trino.io/docs/467 before writing.
- Fresh adjacent: `at_timezone` vs `AT TIME ZONE` literal form / `slice` vs `element_at`+range / `element_at` on arrays-vs-maps (NULL-vs-throw difference by container).

PRESERVE iter855 §3.1B-GM + §1a.3-SUBSET, §1a.4A slice card, iter843 approx_percentile accuracy, iter842 value-vs-rank, iter840 weighted-avg §3.1B-WA, iter837 string→DATE, iter836 lpad/format, iter831 month-name, the §Fact 3/3b at_timezone/with_timezone tz-conversion cards (r07), and full iter534-856 pin inventory. NO federation edits (federation row stays 4.49944/310). DO NOT bump training/state.json (already 857).
