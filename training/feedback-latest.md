# iter732 Judge Feedback

**Topic batch:** map-construction FIX-A re-probe + safe map-key lookup + map_keys + abs/sqrt math
**Docs verified against:** trino.io/docs/467 — functions/map.html + functions/math.html (WebFetch 2026-06-08). Not scored against resources/.
**Mode:** extended phase — per-iteration feedback.

---

## Per-question scores

### Q1 — build a MAP from two parallel arrays (FIX-A re-probe — CRITICAL)
Answer: `map(attr_names, attr_values)` 2-arg constructor + `element_at(attrs, 'size')` access; noted `[]` subscript throws if key missing.

- **Accuracy 5** — DOCS-VERIFIED map.html: `map(array(K), array(V)) → map(K, V)` "Returns a map created using the given key/value arrays." Exactly the direct 2-arg constructor for two parallel/equal-length arrays. element_at NULL-safe vs `[]` throws — also verbatim-correct.
- **Completeness 5** — Builds the map AND shows the lookup the user actually wanted (`attrs['size']` → element_at). Correctly flags the subscript-throws caveat unprompted.
- **Clarity 5** — "zips two equal-length arrays into one MAP" is a clean one-line mental model for a non-OLAP engineer; copy-ready SQL.
- **Actionability 5** — Single-call form, directly drop-in.
- **Q-avg 5.00**

**FIX-A VERDICT: CLOSED.** The responder led with the direct `map(keys_array, values_array)` constructor — the exact one-call form iter731 (4.25) MISSED. It did NOT reach for the convoluted `map_from_entries(zip_with(keys,vals,(k,v)->row(k,v)))` NOR `map_agg`. The iter732 canonical (r07 §1a "build a MAP from two parallel arrays") landed and surfaced. Regression risk eliminated on this probe.

### Q2 — safe single-key map lookup
Answer: `element_at(feature_flags, 'dark_mode')`; noted `[]` throws "Key not present in map".

- **Accuracy 5** — DOCS-VERIFIED map.html: `element_at(map(K,V), key) → V` "Returns value for given key, or NULL if the key is not contained in the map." `[]` subscript "throws an error if the key is not contained in the map." Both halves exactly right.
- **Completeness 5** — Answers the lookup AND the NULL-vs-error contrast the user explicitly asked about.
- **Clarity 5** — "never errors" / "strict and throws" is a crisp distinction.
- **Actionability 5** — Drop-in.
- **Q-avg 5.00**

### Q3 — get map keys as a list
Answer: `map_keys(feature_flags)` → array; plus `map_keys(map_filter(feature_flags, (k,v)->v))` for true-only keys.

- **Accuracy 5** — DOCS-VERIFIED map.html: `map_keys(x) → array(K)` "Returns all the keys in the map." `map_filter(map, function(K,V,boolean)) → map(K,V)` "Constructs a map from those entries for which function returns true." `(k,v)->v` is a valid boolean lambda when `v` is boolean. `map_values` also exists (not needed here). All correct.
- **Completeness 4** — Per-row keys array is the correct core answer and the bonus true-only filter is a nice touch. Minor gap: the user said "across all our customer rows" for an audit — a strictly account-wide DISTINCT-key set would also need `UNNEST(map_keys(...))` + aggregate (e.g. `array_agg(DISTINCT ...)` or `flatten`) across rows. The per-row answer is the right function answer; the cross-row roll-up is an unaddressed follow-on. As pre-framed, a minor completeness ding, not an error.
- **Clarity 5** — "no explosion" directly answers "without exploding into rows."
- **Actionability 5** — Drop-in.
- **Q-avg 4.75**

### Q4 — abs + sqrt math
Answer: `abs(current_score - baseline_score)` + `sqrt(variance_metric)`.

- **Accuracy 5** — DOCS-VERIFIED math.html: `abs(x) → [same as input]` "Returns the absolute value of x." `sqrt(x) → double` "Returns the square root of x." Both native lowercase. The "abs returns same type as input" claim matches docs exactly. (sqrt is always double — responder did not misstate its return type.)
- **Completeness 5** — Both requested ops covered.
- **Clarity 5** — Trivially clear, well-named aliases.
- **Actionability 5** — Drop-in.
- **Q-avg 5.00**

---

## Overall

| Q | Acc | Comp | Clar | Act | Q-avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 4 | 5 | 5 | 4.75 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall average = 4.9375 → STRONG PASS** (threshold 3.5; overall governs, no per-Q override).

All dialect forms docs-verified against trino.io/docs/467 (map.html + math.html), 2026-06-08.

---

## Teacher feedback / iter733 flags

- **FIX-A (Q1) CLOSED** — the direct `map(keys_array, values_array)` constructor now surfaces as the lead answer for "combine two parallel arrays into a map." iter732 canonical works. Keep it.
- **No new resource defect.** No false dialect claim in any answer; every form (map/element_at/[]-throws/map_keys/map_filter/abs/sqrt) is correct.
- **iter733 minor flag (Q3, LOW priority, not a defect):** the per-row `map_keys` answer is the correct core, but a question phrased as an account-WIDE audit ("across all our customer rows") wants a cross-row DISTINCT-key roll-up. Consider a LIGHT ADDITIVE note co-located with the map_keys content: to collapse keys across many rows into one distinct set, `SELECT array_agg(DISTINCT k) FROM t CROSS JOIN UNNEST(map_keys(feature_flags)) AS u(k);` (or flatten + array_distinct). Keyword anchors: "all keys used across all rows", "distinct map keys account-wide", "audit which features are set anywhere". Do NOT churn the per-row map_keys canonical — add adjacent only.
- **Re-probe suggestions for iter733:** (1) confirm FIX-A stays closed under a third phrasing (e.g. "make a lookup dictionary from a key column array and a value column array"); (2) probe the cross-row distinct-keys aggregation directly to see if the responder reaches for UNNEST(map_keys) + array_agg(DISTINCT).
