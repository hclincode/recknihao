# Judge Feedback — iter853 (DEFAULT NO-OP durability sweep; zero resource edits)

## Verdict: PASS — overall avg 4.69

DEFAULT NO-OP / honest-decline-correct. Teacher made no resource edits; this sweep confirms durability. No defects found. One optional findability note (see below) — does NOT require an edit.

## Per-question scores

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | parse 'k=v;k=v' string -> map (split_to_map) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | Oracle 'Y'/'N' VARCHAR -> boolean | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | filter map to true-valued entries (map_filter) | 5 | 4 | 5 | 5 | 4.75 |
| Q4 | GCD per row (honest decline + Euclid CTE) | 4 | 4 | 4 | 4 | 4.00 |

**Overall avg = (5.00 + 5.00 + 4.75 + 4.00) / 4 = 4.69 — PASS** (threshold 3.5; overall average governs, no per-Q veto).

## Verification (all PINNED to Trino 467)

**Q1 — split_to_map: CONFIRMED.** trino.io/docs/467 function list.html links `split_to_map()` (under string.html); WebSearch confirms signature `split_to_map(string, entryDelimiter, keyValueDelimiter) → map(varchar,varchar)`. `element_at(map,key) → V` and `map_keys` confirmed on map.html. Responder's `split_to_map(config, ';', '=')` + `element_at(...,'retry')` + CTE-to-avoid-re-parse advice is fully correct and idiomatic. Flawless.

**Q2 — Y/N -> boolean: CONFIRMED.** Trino's `CAST(varchar AS boolean)` accepts only true/false/t/f/1/0-style tokens, NOT 'Y'/'N' — there is no auto-detect cast. The responder's `CASE WHEN is_active='Y' THEN true ELSE false END` and `if(is_active='Y', true, false)` are both correct, and the "no built-in CAST that auto-detects Y/N" disclaimer is accurate. (Minor unstated bonus: the bare boolean expression `is_active='Y'` is itself usable in WHERE/JOIN; responder implicitly conveyed this with "use in WHERE/joins after.") No error.

**Q3 — map_filter: CONFIRMED.** map.html gives `map_filter(map(K,V), function(K,V,boolean)) → map(K,V)`, "constructs a map from those entries for which function returns true." Responder correctly offered BOTH the string-value form `(k,v) -> v = 'true'` AND the boolean-value form `(k,v) -> v`, returns a map, and `map_keys(map_filter(...))` for just the enabled key names. Completeness docked 1 only because the question's example showed actual `true`/`false` boolean literals, so the boolean form `(k,v) -> v` is the primary answer and the string form is the secondary case — responder led with the string form. Minor ordering nit, not an error; both forms are valid.

**Q4 — gcd() EXISTENCE: VERIFIED ABSENT (multi-source).**
- Source 1: WebFetch trino.io/docs/467/functions/math.html — no gcd.
- Source 2: WebSearch across Trino docs (467/481/435) — no gcd in any math-function listing.
- Source 3 (DISPOSITIVE): WebFetch trino.io/docs/467/functions/list.html (the authoritative alphabetical function index) — explicit "No, there is no function named gcd in this list." This same list.html call correctly FOUND split_to_map, so the page rendered fully and its negative on gcd is trustworthy (not a converter-miss like the historical math.html truncate collapse).

**Conclusion: Trino 467 has NO built-in gcd(). The responder's honest decline ("Trino 467 does not expose a built-in gcd()... recommend checking the docs") is CORRECT behavior, not a gap.** This is an HONEST-DECLINE-CORRECT, NOT a findable-but-missing gap. Do NOT add a gcd canonical (there is no real function to point to) and do NOT penalize the decline.

**Q4 workaround assessment (separate, minor):** WITH RECURSIVE IS supported in Trino 467 (trinodb/trino PR #4250; session `max_recursion_depth` default 10). The responder's Euclid CTE is structurally VALID and correct:
- anchor: `a = GREATEST(width,height)`, `b = LEAST(width,height)`
- step: `SELECT width,height, b, MOD(a,b) FROM gcd_calc WHERE b>0` (single recursive reference — allowed)
- terminal: `WHERE b=0`, returns `a` as the GCD.
This converges correctly (1920,1080 -> gcd 120 -> 16:9 in a handful of steps).
- Caveat NOT mentioned by responder (the −1 on Q4 accuracy/completeness): the default `max_recursion_depth` is 10; for large coprime inputs the Euclidean iteration could exceed 10 steps and the query would FAIL until `SET SESSION max_recursion_depth` is raised. For image-aspect-ratio reduction this is a non-issue, but the responder did not surface the depth cap. Clarity/actionability docked slightly because a per-row recursive CTE is a moderately advanced pattern and the framing leaned heavily on "verify the docs / edge case" rather than fully owning the workaround.

Net: Q4 is a GOOD honest decline with a working (if depth-capped) fallback. 4.0 is fair — rewards the correct decline, lightly dings the unflagged recursion-depth caveat.

## Defects / gaps

- None requiring a resource edit. No fabricated functions, no wrong signatures, no crossed-family errors, no dialect slips. All four answers fit the on-prem Trino 467 + Iceberg production stack (no cloud-only tooling invoked).

## iter854 directive: DEFAULT NO-OP

All four answers clean; Q4 is an HONEST-DECLINE-CORRECT (gcd genuinely absent — verified across math.html + list.html + WebSearch). NO LIGHT FIX-A: do not add a gcd canonical, because Trino 467 has no gcd() to document and the recursive-CTE Euclid workaround is already what the responder correctly produced unaided.

Optional (NON-BLOCKING) consideration for a FUTURE iteration only IF the Euclid-CTE / WITH RECURSIVE pattern resurfaces and scores below threshold: a small WITH RECURSIVE card could note the `max_recursion_depth` default-10 cap + the GREATEST/LEAST anchor + MOD-step Euclid template. Not warranted now — single datapoint, scored 4.0, no edit this iteration.

PRESERVE the full iter534-852 lock inventory. NO federation edits (r22 §13.x stays untouched; federation row 4.49944/310).
