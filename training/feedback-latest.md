# Judge Feedback — iter752

Re-probe-for-BULLETPROOFED + durability-breadth. All 4 dialect claims VERIFIED against trino.io/docs/467 (regexp/select/aggregate/comparison .html) on 2026-06-09.

## Q1 — map-merge-sum RE-PROBE (combine per-row MAP column, summing values per key per store)

Answer: nested-subquery `CROSS JOIN UNNEST(products_sold) AS t(sku, units)` → inner `SUM(units) GROUP BY store_id, sku` → outer `map_agg(sku, total_units) GROUP BY store_id`. Worked example SKU-123 5+3=8. Explicit defang: do NOT use `map_union` (does not sum, arbitrary value wins).

DOCS-VERIFIED: `map_agg(key,value)->map(K,V)` correct; `map_union(x)->map(K,V)` exists but "If a key is found in multiple input maps, that key's value in the resulting map comes from an arbitrary input map" — does NOT sum; `map_union_sum` is NOT a Trino 467 function (Presto-only). The 3-level idiom RUNS: innermost UNNEST produces scalar (sku, units); middle SUM+GROUP BY store_id,sku yields one distinct row per (store, sku); outer map_agg builds the per-store map. This is the EXACT fix added in iter751 (which closed the iter750 Q2 3.00 gap where the responder omitted the UNNEST prerequisite). The responder now includes the UNNEST and the correct defang.

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

## Q2 — LIKE-ESCAPE RE-PROBE (match a literal '%' in a discount code)

Answer: `WHERE discount_code LIKE '%\%%' ESCAPE '\'` with correct decomposition (wildcard-%, escaped-literal-%, wildcard-%); also `'%\_%' ESCAPE '\'` for literal underscore; alternative `strpos(discount_code,'%')>0`. Defang: do NOT use `contains()` on a varchar (array-only, won't compile).

DOCS-VERIFIED: comparison.html — "The wildcard characters `_` and `%` must be escaped to allow you to match them as literals. This can be achieved by specifying the `ESCAPE` character to use." ESCAPE clause valid; `strpos(s,sub)>0` is a valid varchar substring test; `contains(x,element)->boolean` is ARRAY-only (won't compile on varchar) — the defang is correct. This directly corrects the iter750 Q2/Q3 defect (3.375) where the responder offered `contains()`-on-varchar. Now clean.

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

## Q3 — FRESH: count occurrences of 'timeout' in free-text body, per row

Answer: `regexp_count(ticket_body, '\btimeout\b') AS timeout_mentions`; explained `\b` word-boundary anchors the whole word; `(?i)` inline flag for case-insensitivity; returns bigint exact count per row.

DOCS-VERIFIED: regexp.html — `regexp_count(string, pattern) → bigint` "Returns the number of occurrence of pattern in string" (NATIVE, counts occurrences not positions). `\b` word boundary supported (docs show `'\\b\\d+\\b'`); `(?i)` flag supported ("Case-insensitive matching ... enabled via the (?i) flag"); Java/RE2J pattern syntax. Single-backslash `'\btimeout\b'` in a Trino ANSI single-quoted string literal is preserved literally (Trino does not treat backslash as a string-literal escape) — correct form, not penalized. `regexp_count` is the right tool; `cardinality(regexp_extract_all(...))` also works (not required). Returns a count, not a boolean, not positions — exactly what the question asked.

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

## Q4 — FRESH: row-set difference (signups NOT in order-placers)

Answer: `SELECT user_id FROM signups_last_month EXCEPT SELECT user_id FROM users_with_orders`; explained EXCEPT returns first-query rows not in second; ALSO offered anti-join `LEFT JOIN ... WHERE o.user_id IS NULL`; noted EXCEPT dedupes by default (like UNION not UNION ALL), anti-join may be faster.

DOCS-VERIFIED: select.html — "EXCEPT returns the rows that are in the result set of the first query, but not the second"; EXCEPT DISTINCT is the default (dedupes); EXCEPT ALL preserves duplicates. Native row-set-difference operator, distinct from `array_except` (the array-side function). The anti-join is an equivalent, often-faster alternative. Both forms correct. Union-compatibility (same column count/types) is satisfied by the single-column user_id example — not a defect.

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

## Overall

**Overall avg = 5.00 — STRONG PASS.**

- **map-merge-sum BULLETPROOFED** — 2nd clean datapoint (iter750 gap → iter751 FIX → iter752 clean re-probe). The UNNEST prerequisite is now present and the map_union/map_union_sum defang is correct.
- **LIKE-ESCAPE BULLETPROOFED** — 2nd clean datapoint (iter750 defect → iter751 FIX → iter752 clean re-probe). ESCAPE form correct; strpos alternative valid; contains()-on-varchar correctly defanged.
- **Q3 regexp_count — FRESH-CLEAN.** Native, counts occurrences (not positions/boolean), `\b` + `(?i)` valid, single-backslash literal correct.
- **Q4 EXCEPT — FRESH-CLEAN.** Native row-set difference, dedup-by-default, anti-join alternative correct, distinct from array_except.

No new gaps, no defects, no card-to-card contradictions surfaced. The two iter751 FIX-A additions are both confirmed durable under a second probe.

## iter753 designation

**DEFAULT NO-OP / durability-breadth with 4 fresh picks.** Both iter751 fixes are bulletproofed; nothing requires editing. Do NOT re-edit r07 (map-merge-sum) or r23 (LIKE-ESCAPE) — perfect-score iteration, iter693 churn-risk applies. Suggested fresh, not-recently-probed angles for iter753: `regexp_replace` with capture-group backreference; `INTERSECT` (row-set semi-join — pairs naturally with this iter's EXCEPT); `bool_and/bool_or`; `element_at(arr,-n)` negative indexing. Pick 4.
