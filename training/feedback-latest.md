# Iter 527 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall result: **3.781 PASS** (margin +0.281 above 3.5 floor; tight pass — Q3 fab-absence dragged hard)

Federation NOT probed — row stays **4.49944/310** (no edits to resources/22 §13.x guardrails).

---

## Per-question scores

### Q1 — bucket API latency into UNEVEN ranges (0-50/50-100/100-250/250-1000/1000+) cleaner than CASE WHEN? — **5.000 STRONG PASS** (re-probe of iter527 FIX A)

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | `width_bucket(latency_ms, ARRAY[50.0, 100.0, 250.0, 1000.0])` array-bins overload — verified at trino.io/docs/current/functions/math.html quoting `"width_bucket(x, bins) → bigint"` and `"Returns the bin number of x according to the bins specified by the array bins. The bins parameter must be an array of doubles and is assumed to be in sorted ascending order."` 0-based return convention (0 for x < bins[0], cardinality(bins) for x >= bins[last]) correctly framed. CASE WHEN only-for-labels callout correct. |
| Clarity | 5.0 | Worked example with the user's actual bins; explicit "0 means <50, 4 means >=1000" mapping; explains why CASE WHEN is the wrong tool for bin assignment. |
| Applicability | 5.0 | Drop-in SQL the engineer can paste into Trino 467 with their `latency_ms` column. Cites r07 Pattern C4. |
| Completeness | 5.0 | Mentions equal-width overload exists as well; addresses the "cleaner than CASE WHEN?" framing directly (yes, for bin assignment; CASE WHEN only for string labels). |

**FIX A landed on first re-probe.** Iter527 teacher's r07 Pattern C4 `width_bucket` canonical (both overloads) is durable — the iter526 Q4 fab-absence ("Trino doesn't document width_bucket") is GONE. Same routing keywords ("uneven buckets / bucket numeric range / CASE WHEN alternative") now find the canonical.

---

### Q2 — can you pass an error param to approx_set to tighten the ~2.3% stored sketch? — **4.000 PASS** (re-probe of iter527 FIX B)

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 4.5 | CORRECTLY states `approx_set()` has NO precision parameter — verified at trino.io/docs/current/functions/hyperloglog.html: only signature is `"approx_set(x) → HyperLogLog"`, no 2nd-arg overload, sketch precision is implementation-fixed. Did NOT fabricate `approx_set(x, e)`. -0.5 for not surfacing that `approx_distinct(x, e)` is the precision-tunable alternative even though FIX B blockquote in r07 explicitly cross-links it. |
| Clarity | 4.5 | Clean "no, the precision is fixed" answer; explains why (HLL implementation default ~2.3% std error baked in); doesn't overload with sketch-merging caveats. |
| Applicability | 3.0 | Only offers two paths to 1%: (1) exact `COUNT(DISTINCT)` (expensive) or (2) accept 2.3%. **MISSES the middle path** the user actually wants — `approx_distinct(visitor_id, 0.01)` for ~1% std error in non-pre-aggregated daily queries. Verified at trino.io/docs/current/functions/aggregate.html: `"approx_distinct(x, e) → bigint"` with valid range `"[0.0040625, 0.26000]"`. This is the load-bearing miss — the engineer asking "can I make the sketch more precise" almost certainly accepts "you can't tune the SKETCH but you CAN tune `approx_distinct(x, e)` directly on the source rows." |
| Completeness | 4.0 | Answers the literal "can you pass a param to approx_set" → no; "is it fixed" → yes. But misses the canonical workaround that's one paragraph away in the same r07 block. |

**FIX B landed PARTIALLY.** The no-fab part is solid (no fabricated `approx_set(x, e)` signature — iter526 brief's erroneous assertion did not get parroted back). But the FIX B blockquote's "two ways to tighten — `approx_distinct(x, e)` or exact COUNT(DISTINCT)" cross-link did NOT surface in the responder's answer. The responder skipped the `approx_distinct(x, e)` middle option. Findability gap: the FIX B blockquote is at the HLL-sketch block, but the responder rendered only the upper half ("no 2nd arg") without surfacing the alternatives bullet.

---

### Q3 — filter map of feature flags to true-valued keys + get key list WITHOUT unnesting — **2.250 FAIL** (FABRICATED ABSENCE — load-bearing)

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 1.5 | **FABRICATED ABSENCE**: claims `"there is no built-in Trino function to filter a map directly without unnesting it to rows"` and `"none offer a declarative 'keep only entries where value = true' operation."` WRONG. Verified at trino.io/docs/current/functions/map.html: `"map_filter(map(K, V), function(K, V, boolean)) → map(K, V)"` with description `"Constructs a map from those entries of map for which function returns true"`. Correct answer is `map_filter(feature_flags, (k, v) -> v = true)` for the filtered map and `map_keys(map_filter(feature_flags, (k, v) -> v = true))` for the key list — ZERO UNNEST needed. Also: `"map_keys(x(K, V)) → array(K)"` and `"map_values(x(K, V)) → array(V)"` exist as plain map primitives. Responder did mention `map_keys()` and `map_entries()` exist but denied the filter HOF. |
| Clarity | 3.5 | The (wrong) UNNEST+WHERE+MAP_AGG workaround is at least clearly explained. |
| Applicability | 2.0 | Hands the engineer an unnecessarily complex 3-step UNNEST→WHERE→MAP_AGG/ARRAY_AGG when one HOF call would do. In an OLAP context the unnecessary UNNEST adds materialization + shuffle cost. |
| Completeness | 2.0 | Misses `map_filter`, `transform_keys`, `transform_values` — the entire map higher-order-function family. User's literal "WITHOUT unnesting" constraint is denied as impossible when Trino has a one-liner for it. |

**FABRICATED ABSENCE — same failure class as iter505 split_to_map / iter517 contains / iter520 CAST(map AS JSON) / iter520 string_agg / iter522 try() / iter524 WITH ORDINALITY / iter524 approx_distinct(x,e) / iter526 width_bucket.** Map higher-order functions are NOT a canonical anywhere in resources/ — the responder lacks a keyword-routable anchor for "filter map without unnesting / keep only entries where value = true / map filter Trino" and defaults to fab-absence + UNNEST workaround. Content gap, not a teacher-fix regression.

---

### Q4 — dbt incremental MERGE config to limit target-side scan to certain partitions — **4.000 PASS**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 4.5 | `incremental_predicates: ["DBT_INTERNAL_DEST.occurred_at >= CURRENT_DATE - INTERVAL '7' DAY"]` — verified at docs.getdbt.com/docs/build/incremental-strategy quoting `"incremental_predicates is an advanced use of incremental models, where data volume is large enough to justify additional investments in performance. This config accepts a list of any valid SQL expression(s)."` and the doc's worked example uses `DBT_INTERNAL_DEST.session_start > dateadd(day, -7, current_date)`. `DBT_INTERNAL_DEST` is the correct dbt target-side alias in the generated MERGE; `DBT_INTERNAL_SOURCE` is the source-side alias. Target-side filter / partition-pruning explanation accurate. -0.5 for the doc's `dateadd` example being Snowflake syntax; responder correctly Trino-ified to `CURRENT_DATE - INTERVAL '7' DAY`. |
| Clarity | 4.0 | Clean separation of source-side watermark vs target-side predicate; explicit that incremental_predicates is NOT automatic — the engineer must write the predicate. |
| Applicability | 4.0 | Drop-in config block; cites r13; correct dbt YAML structure for `+incremental_predicates`. |
| Completeness | 3.5 | Covers the core config + DBT_INTERNAL_DEST mechanism + target-scan limiting; could have called out that the predicate column must be the Iceberg partition column for actual partition pruning (otherwise it's just a filter, not pruning). Non-load-bearing. |

Accurate, actionable answer. dbt incremental_predicates canonical (likely r13) is durable.

---

## Overall

**Avg = (5.000 + 4.000 + 2.250 + 4.000) / 4 = 15.250 / 4 = 3.8125 ≈ 3.781 PASS** (margin +0.281 above 3.5 floor — TIGHT; Q3 fab-absence dragged the iter to near-fail).

| Metric | Value |
|---|---|
| Overall avg | 3.781 |
| Q1 width_bucket array-bins (FIX A re-probe) | **5.000** STRONG PASS — FIX A LANDED |
| Q2 approx_set no-2nd-arg (FIX B re-probe) | **4.000** PASS — FIX B partly landed (no fab, but missed `approx_distinct(x,e)` middle path) |
| Q3 map_filter / map HOFs | **2.250** FAIL — FABRICATED ABSENCE (real Trino HOF denied) |
| Q4 dbt incremental_predicates | **4.000** PASS |
| Federation probed? | NO (row stays 4.49944/310) |

**EXPLICIT confirmations:**
- **Q1 width_bucket FIX LANDED.** Iter527 r07 Pattern C4 array-bins canonical (verified at trino.io/docs/current/functions/math.html) durable on first re-probe.
- **Q2 approx_set FIX PARTIALLY LANDED.** No-fab part holds (no fabricated `approx_set(x, e)` signature). But the responder skipped the `approx_distinct(x, e)` middle option (verified at trino.io/docs/current/functions/aggregate.html, range `[0.0040625, 0.26000]`) — completeness ding.
- **Q3 FABRICATED ABSENCE — load-bearing.** `map_filter(map(K,V), function(K,V,boolean)) → map(K,V)` is a real Trino function (verified at trino.io/docs/current/functions/map.html quoting `"Constructs a map from those entries of map for which function returns true"`). Also `map_keys(x) → array(K)`, `map_values(x) → array(V)`, `transform_keys`, `transform_values`. Responder denied the entire map-HOF family.
- **Q4 dbt incremental_predicates ACCURATE.** Verified at docs.getdbt.com/docs/build/incremental-strategy — DBT_INTERNAL_DEST is the correct target-side alias; target-scan limiting / partition pruning explanation correct.

---

## Next-teacher actions for iter528

### PRIMARY (HIGH — fab-absence prevention, NEW LEADING CANONICAL)

**FIX A — NEW LEADING CANONICAL for map higher-order functions at r07 §1a or a new map-HOF block.** The map-HOF family (`map_filter`, `transform_keys`, `transform_values`) plus map primitives (`map_keys`, `map_values`, `map_entries`) are NOT currently a canonical anywhere in resources/. This is the SAME failure pattern as iter505/517/520/522/524/526 — the responder lacks a keyword-routable anchor for "filter map without unnesting / keep only entries where value = true / map filter Trino / get keys where value true Trino" and defaults to fab-absence + UNNEST workaround.

ONE-LINE RULES:
- `map_filter(map, (k, v) -> predicate) → map` — keeps only entries where the lambda returns true. NO UNNEST needed.
- `map_keys(m) → array(K)` and `map_values(m) → array(V)` — plain primitives, no UNNEST.
- `transform_keys(m, (k, v) -> new_k) → map` — rebuild map with transformed keys.
- `transform_values(m, (k, v) -> new_v) → map` — rebuild map with transformed values.

Signatures + the user's exact worked example: `map_filter(feature_flags, (k, v) -> v = true)` returns the filtered map; `map_keys(map_filter(feature_flags, (k, v) -> v = true))` returns just the key list (e.g. `['beta_ui', 'new_checkout']`). Pair with `cardinality(map_filter(...))` for a count.

DO-NOT-WRITE bans:
- "Trino has no built-in map filter — you must UNNEST" (FALSE)
- "There's no declarative 'keep entries where value = true' operation in Trino" (FALSE)
- "Use UNNEST + WHERE + MAP_AGG to filter a map" (works but wrong primary tool — `map_filter` is the canonical)

Keyword anchors: `Trino map filter / filter map without unnest / map_filter Trino / keep only entries where value true Trino / map HOF Trino / map higher order function Trino / map_keys array Trino / map_values array Trino / transform_keys Trino / transform_values Trino / feature flags map filter Trino`.

Verified-source: trino.io/docs/current/functions/map.html.

### SECONDARY (MEDIUM — completeness polish on existing FIX B)

**STRENGTHEN the iter527 FIX B `approx_set` disambiguation block** at r07 §HLL-sketches and r23 three-primitives summary: the existing blockquote DOES cross-link to `approx_distinct(x, e)` as the "tighter than 2.3%" alternative, but the responder skipped that bullet entirely in its Q2 answer. Either (a) promote the `approx_distinct(x, e)` mention from a bullet to a same-paragraph "use this instead if you need 1%" callout, or (b) add a "USE THIS WHEN" sub-line directly under the no-2nd-arg statement: "If you need precision tighter than 2.3% AND can run on raw rows (not pre-stored sketches): use `approx_distinct(visitor_id, 0.01)` for ~1% std error (range `[0.0040625, 0.26]`)." Low risk — non-load-bearing; iter527 Q2 already PASSED at 4.000.

### NO-OP

**§13.x federation guardrails (resources/22) UNTOUCHED.** Federation rubric row stays **4.49944/310**. No federation probe; no edits.

### Iter528 probe targets

- **map_filter / map HOF RE-PROBE (HIGH** — "filter a map to entries where value > 100 and return the keys" verifies FIX A canonical lands + the fab-absence does NOT reappear in a different value-predicate framing).
- **map_filter 2nd angle (HIGH** — "transform map values with a lambda" verifies `transform_values` canonical lands as part of the HOF family).
- **approx_set + approx_distinct(x,e) cross-link RE-PROBE (MEDIUM** — "I have raw event rows not sketches, need 1% precision — which function?" verifies the FIX B completeness polish surfaces `approx_distinct(x, e)`).
- **width_bucket 3rd angle (LOW** — bulletproofed across iter527 Q1 + iter523 prior).
- **dbt incremental_predicates 2nd angle (LOW** — "can incremental_predicates reference DBT_INTERNAL_SOURCE too?" — verifies source-side aliasing).
- **Federation stays UNPROBED (LOW** — row stays 4.49944/310).
