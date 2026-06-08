# Judge Feedback — iter733

**Phase**: extended | **Governing label**: PASS | **Overall avg**: 4.375 (>= 3.5 floor; no per-Q gate override per directive)

All dialect claims verified against trino.io/docs/467 (map.html, math.html, conversion.html) on 2026-06-08. Not scored against resources/.

## Per-question scores

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | map(keys,values) build (re-probe) | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q2 | map_values + cross-row UNNEST | 5.0 | 5.0 | 4.5 | 5.0 | **4.875** |
| Q3 | power() / no `^` operator | 5.0 | 4.5 | 5.0 | 5.0 | **4.875** |
| Q4 | typeof runtime type | 4.5 | 1.5 | 3.5 | 1.5 | **2.750** |

**Overall = (5.000 + 4.875 + 4.875 + 2.750) / 4 = 4.375 — PASS**

## Docs verification (trino.io/docs/467)

- **Q1** map.html: `map(array(K), array(V)) -> map(K, V)` — "Returns a map created using the given key/value arrays." VERBATIM. Confirms the direct 2-arg constructor builds a map from two parallel/equal-length arrays. `element_at(map(K,V), key) -> V` returns NULL if key absent (subscript `[]` errors). The responder used exactly `map(header_names, header_values)` + `element_at(..., 'Content-Type')` — NO map_from_entries, NO zip_with, NO map_agg detour.
- **Q2** map.html: `map_values(x(K,V)) -> array(V)` — "Returns all the values in the map x." VERBATIM. `CROSS JOIN UNNEST(map_values(user_preferences)) AS t(preference_value)` is a sound cross-row flatten (single-alias UNNEST of an array is correct — array UNNEST takes ONE alias; the two-alias rule applies only to UNNEST(map_col)). SELECT DISTINCT to collapse to unique values is correct.
- **Q3** math.html: `power(x, p) -> double` — "Returns x raised to the power of p." VERBATIM (`pow` is an alias). Operator list is `+ - * / %` ONLY — NO `^` exponentiation operator. The gotcha ("Trino does NOT support `^`, use power(base,exp)") is ACCURATE.
- **Q4** conversion.html: `typeof(expr) -> varchar` — "Returns the name of the type of the provided expression." IS a real Trino 467 function (examples: `typeof(123)`->'integer', `typeof('cat')`->'varchar(3)', `typeof(cos(2)+1.5)`->'double').

## Q1 VERDICT — map(keys,values) STAYS CLOSED

CONFIRMED CLOSED. This is the 2nd consecutive clean datapoint (iter732 FIX-A landed; iter733 re-probe LANDED CLEAN first-attempt with the direct 2-arg constructor, correct element_at NULL-safe access, and no convoluted detour). **map(keys_array, values_array) is now BULLETPROOFED** across two different phrasings (iter732 "zip a keys array + values array into a map" / iter733 "combine two parallel arrays into one keyed lookup"). No further FIX needed; treat as a standing pin.

## Q4 VERDICT — typeof IS a findable-but-missing gap (iter734 FIX-A)

Trino 467 DOES have `typeof(expr) -> varchar` returning the runtime type name as a string. Grep of resources/ confirms NO `typeof` content exists anywhere — this is a genuine FINDABLE-BUT-MISSING content gap.

- The responder behaved CORRECTLY on anti-hallucination: it did NOT invent a function, explicitly said it could not find the capability in resources/, and pointed the user to official docs. That honesty is exactly the desired failure mode (scored Accuracy 4.5 — the only ding: the phrasing "whether a type-inspection function exists" mildly implies one might not exist, when in fact Trino has a clean one).
- But the user asked a question that HAS a clean, one-call Trino answer, and the responder gave no working SQL. Hence Completeness 1.5 and Actionability 1.5 — the engineer leaves with no next step.

### iter734 FIX-A (teacher action)

ADD a `typeof` canonical (suggested home: r07 math/inspection neighborhood or r23 conversion family, co-located with the CAST / TRY_CAST content so it routes for "what type is this column at runtime" debugging questions):

- Lead: `typeof(expr) -> varchar` returns the Trino type name as a string. Docs-verbatim "Returns the name of the type of the provided expression."
- Examples: `typeof(123)` -> 'integer', `typeof('cat')` -> 'varchar(3)', `typeof(cos(2)+1.5)` -> 'double'.
- Use cases (keyword anchors — this is a debugging question, anchor on debugging phrasing): inspect the runtime type of a column/expression without reading the schema, debug union-branch type mismatches, diagnose JSON-extraction return types, debug implicit-coercion surprises, "what data type is this actually", "column behaves as string sometimes number other times", "check the type at query time".
- Cross-ref to CAST / TRY_CAST (r23) so type-mismatch debugging routes between "what IS the type" (typeof) and "force the type" (CAST/TRY_CAST).

## Teacher feedback summary

- Three of four answers are clean, docs-correct, well-anchored (Q1 re-probe + Q2 + Q3). No churn needed on those canonicals.
- The single drag is the missing `typeof` canonical. This is the ONLY actionable gap this iteration. Add it per FIX-A above; that is the highest-value (and likely only) edit for iter734.
- Minor: Q3 Completeness 4.5 — complete for the literal question; could optionally note `exp(x)`/`ln(x)`/`log(b,x)`/`sqrt(x)` as the broader math family, but this is non-blocking and NOT a required edit.
