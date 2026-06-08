# Judge Feedback — iter731

**Phase**: extended | **Verdict**: PASS | **Overall avg**: 4.78

All four answers were verified against trino.io/docs/467 (map.html, array.html, regexp.html, conversion.html) on 2026-06-08. No factual defects found.

---

## Per-question scores

| Q | Topic | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|---|
| Q1 | strip leading char SET | 5 | 5 | 5 | 4.5 | 4.875 |
| Q2 | zip two arrays into a map | 5 | 4.5 | 4 | 3.5 | 4.25 |
| Q3 | filter text col to valid numbers | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | first/Nth array element | 5 | 5 | 5 | 5 | 5.00 |

**Overall average: 4.78 → PASS** (threshold 3.5).

---

## Q1 — strip a SET of leading chars — DOCS-VERIFIED CORRECT

`regexp_replace(product_code, '^[#*0]+', '')` is a fully valid and correct Trino 467 answer.
- regexp.html confirms `regexp_replace(string, pattern, replacement) -> varchar` uses **Java pattern syntax**, so the char class `[#*0]` matches any of {#,*,0}, the `^` anchor pins to the start, and `+` removes one-or-more leading set members in **one pass** — '#00ABC'→'ABC', '*0042'→'42'. No defect. NOT penalized for choosing regexp over trim.

**trim char-SET clarification — NOT EXERCISED / REMAINS UN-RE-PROBED.** The iter731 clarification targeted the `trim(LEADING '#*0' FROM code)` char-SET FROM-form. The responder chose a different, equally-valid path (regexp_replace), so this probe did **not** test whether the responder reaches for the trim char-set form. Both forms are correct; trim is the lighter-weight (no regex engine) idiom. Because both are correct, this is **LOW PRIORITY**. The only ding is a -0.5 completeness nit for not also surfacing the trim FROM-form as the lighter alternative. If you want the trim char-set form bulletproofed, iter732 should use a more trim-constraining phrasing (e.g., explicitly "using trim, strip a set of leading characters") — but it is not blocking.

## Q2 — zip two arrays into a map — CORRECT BUT MISSED THE CANONICAL

`map_from_entries(zip_with(question_keys, responses, (k,v)->row(k,v)))` is correct and produces a valid map; the `map_agg` + UNNEST alt is also correct (map_agg is an aggregate needing GROUP BY, which the answer correctly used). Verified:
- zip_with(array(T), array(U), function(T,U,R)) -> array(R) — pairs element-wise. OK
- map_from_entries(array(row(K,V))) -> map(K,V). OK
- map_agg is an aggregate (GROUP BY needed). OK

**MISSED CANONICAL — `map(keys_array, values_array)` direct 2-arg constructor.** map.html confirms Trino 467 has `map(array(K), array(V)) -> map(K, V)` — "Returns a map created using the given key/value arrays." This is the **simplest one-call answer** to exactly this question: `SELECT map(question_keys, responses) AS response_map FROM user_profiles;` then `response_map['preferred_plan']`. The responder's zip_with + map_from_entries is correct-but-convoluted: it routes through a HOF + entry array to do what the built-in 2-arg `map()` does directly. This is a genuine Completeness/Actionability gap (-1.5 completeness, -1 applicability) — the engineer would copy a needlessly complex form when a built-in 2-arg `map()` exists.

**FLAG FOR iter732 (teacher):** Add a LEADING CANONICAL for "combine/zip two parallel arrays into a map" that LEADS with `map(keys_array, values_array)` (the direct 2-arg constructor, docs-verified map.html), with `map_from_entries(zip_with(...))` as the secondary form (useful when you must transform pairs) and `map_agg` as the aggregate alt (when keys/values arrive as rows, needs GROUP BY). Keyword anchors: zip two arrays into a map, build a map from key array and value array, parallel arrays to map, two arrays into key-value pairs, map from two columns of arrays. Re-probe in iter732.

## Q3 — filter text to valid numbers — DOCS-VERIFIED CORRECT, FULL MARKS

`TRY_CAST(customer_id_text AS INTEGER)` + `WHERE TRY_CAST(...) IS NOT NULL`. conversion.html confirms try_cast "returns null if the cast fails" — 'N/A'/empty → NULL, filtered out, leaving only numeric-parseable rows. Clear, complete, directly actionable. No notes.

## Q4 — first/Nth array element — DOCS-VERIFIED CORRECT, FULL MARKS

`element_at(feature_flags, 1)`. array.html confirms element_at(array(E), index) -> E is 1-based and returns NULL for index larger than array length, "whereas the subscript operator would fail in such a case." The responder's contrast (element_at NULL-safe vs array[1] errors out-of-range) is exactly right. No notes.

---

## Summary for teacher

- 3 of 4 answers are flawless and docs-verified (Q1 correct path, Q3, Q4).
- **One genuine gap (Q2):** the direct `map(keys, values)` 2-arg constructor is the missed canonical simplest form. This is the one item to act on for iter732.
- Q1 trim char-SET form remains un-re-probed (responder used a valid alternative); low priority because both forms are correct.
- No dialect errors, no parse-error forms, no fabricated functions. All standing pins held.
