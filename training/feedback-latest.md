# Judge Feedback — iter1037

**Overall: Q1 4.0 / Q2 4.8125 / Q3 4.8125 / Q4 4.8125 → 4.5625 PASS** (73.0/16; margin +1.0625; overall average governs, no per-Q veto).

Verified BOTH directions against RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/...) and trino.io docs — NOT resources/. Production stack (Trino 467 + Iceberg + MinIO + Hive Metastore) fits all four; no federation/auth angle (federation r22 §13.x hard-locked, not probed).

---

## Q1 — keep array elements starting with literal "evt_" — **4.0**

**LEAD CORRECT — FIX-A CONFIRMED REACHING RESPONDER.** The primary answer is
`filter(event_codes, code -> starts_with(code, 'evt_')) AS evt_codes_only`.

- `filter(array(T), function(T,boolean)) -> array(T)` EXISTS — array.md (467 RAW), "Constructs an array from those elements of `array` for which `function` returns true". Array shape preserved, no UNNEST/re-agg. Correct structure.
- `starts_with(string, substring) -> boolean` EXISTS — string.md (467 RAW), "Tests whether `substring` is a prefix of `string`". Literal prefix match, NO wildcard interpretation, so `starts_with(code,'evt_')` matches a LITERAL underscore — exactly the user's intent.

This is the canonical, safest form for a literal-underscore prefix inside an array lambda. **The iter1029/iter1036 FIX-A family (literal `_`/`%` prefix → use starts_with, not bare LIKE) is CONFIRMED reaching the responder: the lead now uses starts_with on the filter-lambda surface that relapsed at iter1036.**

**SECONDARY ASIDE — subtly buggy (the persistent broken-secondary trait).** The "for multiple prefixes" aside shows
`filter(event_codes, code -> code LIKE 'evt_%' OR code LIKE 'sys_%')`.
In LIKE, `_` is a SINGLE-CHARACTER WILDCARD — comparison.md (467 RAW): "`_` matches any single character", "`%` matches zero or more characters", with ESCAPE available (`'South_America' LIKE 'South\_America' ESCAPE '\'`). So `LIKE 'evt_%'` ALSO matches "evtXanything" (any char in the 4th position), NOT specifically a literal "evt_". For a LITERAL-underscore prefix this is subtly wrong; the correct LIKE form is `LIKE 'evt\_%' ESCAPE '\'`.

Mitigating: the responder DID hedge ("starts_with() is cleaner for literal text matching"), and the aside's purpose was a multi-prefix illustration where the underscore-literalness is incidental rather than the asked-for guarantee. Accuracy docked for the buggy throwaway form; the lead (the actual answer) is fully correct.

**Classification:** the broken `LIKE 'evt_%'` is the persistent broken-secondary / over-illustrative-aside trait, NOT a fresh resource gap (the lead used the FIX-A correctly; both the iter1029 r23 §653 bare-column caveat and the iter1036 r07 §759 filter-lambda caveat are present and intact per state.json). The LEAD relapse the FIX-A targeted did NOT recur. **Per-instance one-off — MONITOR only, no FIX-A, no churn.** Acc 3.5 / Comp 4.25 / Clar 4.25 / App 4.0.

## Q2 — price bands via width_bucket, cleaner than a giant CASE — **4.8125**

`width_bucket(amount, ARRAY[25.0,50.0,100.0,250.0])` + CASE mapping 0→'$0-25' … 4→'$250+'.

- **Array-form EXISTS — VERIFIED.** math.md (467 RAW): `width_bucket(x, bins) -> bigint`, "Returns the bin number of `x` according to the bins specified by the array `bins`"; bins "must be an array of doubles … sorted ascending". (The 4-arg equi-width `width_bucket(x, bound1, bound2, n)` also exists; the responder correctly used the array overload, which is the right tool for IRREGULAR bands.)
- **Bucket numbering EXACTLY correct — DISPOSITIVE from 467 source.** trino-main MathFunctions.java widthBucket(array) does a binary search with `if (operand < bin) upper=index; else lower=index+1; return lower;` — i.e. **lower-bound-inclusive** (a value equal to a bound goes to the HIGHER bucket), returns **0 below the first bound** and **n at/above the last bound**. With `ARRAY[25,50,100,250]` (n=4 bounds → 5 buckets):
  - `amt < 25` → 0
  - `25 <= amt < 50` → 1
  - `50 <= amt < 100` → 2
  - `100 <= amt < 250` → 3
  - `amt >= 250` → 4

  This matches the responder's stated 0/1/2/3/4 mapping and ranges EXACTLY, including the boundary inclusivity (`25 <=` lower-inclusive). No off-by-one, no boundary slip.

Genuinely cleaner than a 5-branch CASE on the boundaries; the CASE here only LABELS the integer bucket. (Question mentioned a `placed_at` column but clearly wants amount bands — using `amount` is the sensible reading, not a defect.) Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75.

## Q3 — each customer's % of TOTAL revenue, no separate subquery — **4.8125**

`ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)`.

- `SUM()` usable as a window function — window.md (467 RAW): "All aggregate functions can be used as window functions by adding the `OVER` clause." An empty `OVER ()` (no PARTITION, no ORDER BY) computes the grand total across the whole result set on every row — eliminates the self-join/scalar-subquery for the denominator. Correct.
- `NULLIF(SUM(revenue) OVER (), 0)` div-by-zero guard sound (INTEGER/DECIMAL `/0` THROWS DIVISION_BY_ZERO; NULLIF→NULL propagates).
- `100.0 *` forces decimal division (avoids integer truncation). Correct.
- `PARTITION BY account_category` variant for per-segment share — correct generalization.

Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75.

## Q4 — single most-recent session per user, cleaner than max-then-join-back — **4.8125**

`ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY started_at DESC NULLS LAST)` in a CTE/subquery, then `WHERE rn = 1`.

- row_number() — window.md (467 RAW): "Returns a unique, sequential number for each row, starting with one, according to the ordering of rows within the window partition." Canonical top-1-per-group. `DESC NULLS LAST` is harmless/safe (Trino default null ordering is already NULLS LAST, but explicit is fine).
- Window function NOT allowed in WHERE, so the subquery/CTE wrap before filtering `rn=1` is REQUIRED — responder did this correctly. (No QUALIFY in Trino 467, correctly avoided.)
- ALT `max_by(session_id, started_at)` + `MAX(started_at)` GROUP BY user_id — aggregate.md (467 RAW): `max_by(x, y)` "Returns the value of `x` associated with the maximum value of `y` over all input values." Correct for grabbing a FEW columns at the max timestamp without a join-back. Sound, NOT a broken secondary this time.

Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75.

---

## Source-verified facts this iter
- `filter(array(T),function(T,boolean))->array(T)` EXISTS — array.md 467 RAW.
- `starts_with(string,substring)->boolean` EXISTS (literal prefix, no wildcard) — string.md 467 RAW; `ends_with` ABSENT.
- LIKE `_` = single-char wildcard, `%` = zero-or-more, ESCAPE for literals — comparison.md 467 RAW.
- `width_bucket(x, bins[])->bigint` EXISTS — math.md 467 RAW; **lower-bound-inclusive, 0 below first, n at/above last — DISPOSITIVE from MathFunctions.java 467 source** (`operand < bin ? upper=index : lower=index+1; return lower`).
- `SUM()`/all aggregates usable with `OVER ()` for whole-result total — window.md 467 RAW.
- `row_number()` sequential-from-1 within partition; window fns not allowed in WHERE — window.md 467 RAW.
- `max_by(x,y)` returns x at max y — aggregate.md 467 RAW.

## TICS check
Clean except Q1 secondary `LIKE 'evt_%'` (literal-underscore-wildcard). No QUALIFY, no false semi-join, no fabricated functions (filter/starts_with/width_bucket/sum-OVER/row_number/max_by all real & verified; ends_with correctly absent), no regex-backslash, no INTERVAL quarter/week, no OFFSET-before-LIMIT, no `::` cast. Q1 LEAD broken-secondary is the only blemish and it's an aside, not the answer.

## Recommendation — **DEFAULT NO-OP** (margin +1.0625)

- **Q1 FIX-A is CONFIRMED reaching the responder.** The lead uses `starts_with(code,'evt_')` on the exact filter-lambda surface that relapsed at iter1036 — the targeted relapse did NOT recur. The buggy `LIKE 'evt_%'` is confined to a throwaway multi-prefix aside and is the persistent broken-secondary trait, NOT a fresh resource gap (both literal-prefix caveats r23 §653 and r07 §759 are present/intact). Classify as a **per-instance one-off — passive MONITOR only.** Do NOT churn the defang; the resource cards are already in place and the lead honored them.
- Q2/Q3/Q4 fully correct and source-verified, both directions; both KEY width_bucket array-form + bucket-numbering and the max_by/row_number alternatives resolved in the responder's favor.
- No 2-in-2 recurrence (the Q1 LEAD prefix misconception is resolved; only an aside slipped). No source-verified resource defect.

NO resource edit; NO FIX-A; NO git commit; MUST NOT bump state.json (already 1037; orchestrator commits).

**Re-probe (monitor only):** (a) literal-`_`/`%` prefix inside filter-lambda — confirm lead keeps using starts_with and watch whether the multi-prefix aside relapses to bare `LIKE 'x_%'`; if the LEAD (not just an aside) relapses → escalate; (b) width_bucket array-form bucket numbering (0 below first / n at/above last / lower-inclusive); (c) SUM() OVER () grand-total share + NULLIF guard; (d) ROW_NUMBER top-1-per-group wrap-then-rn=1 + max_by alternative. Federation r22 §13.x hard-locked, not probed (4.49944/310).
