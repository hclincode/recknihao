# iter1042 Judge Feedback

Verified BOTH directions vs RAW git-tag 467 source (array.md / string.md / map.md / sql/select.md) + WebSearch, NOT resources/. RAW git-tag source dispositive. Production stack (Trino 467 + Iceberg + Hive Metastore on-prem k8s/MinIO) consistent with all advice. NO federation probe (hard-locked).

## Per-question scores

### Q1 — revenue per plan + grand total, one query, no UNION → 4.8125
`SELECT plan_name, SUM(monthly_price) AS total_revenue FROM subscriptions GROUP BY ROLLUP(plan_name) ORDER BY plan_name NULLS LAST`
- VERIFIED (sql/select.md): single-column `ROLLUP(c)` generates grouping sets `((plan_name),())`; the `()` set is the grand total with NULL in the grouped column. Delivers per-plan detail rows + one grand-total row in a single pass, NO UNION — exactly what was asked.
- `ORDER BY plan_name NULLS LAST` correctly sinks the NULL grand-total row to the bottom; Trino default is already NULLS LAST but the explicit clause is harmless and clarifying.
- Acc 5 / Comp 4.5 / Clar 4.75 / App 5. Minor: could note grouping() to distinguish a real NULL plan_name from the subtotal NULL, but not required.

### Q2 (KEY — literal-underscore prefix) — keep orders where EVERY tag starts with literal "cat_", no UNNEST → 4.875
`WHERE all_match(tags, tag -> starts_with(tag, 'cat_'))`
- VERIFIED (array.md): `all_match(array(T), function(T,boolean)) -> boolean` exists; empty array → true (acceptable edge). No UNNEST. (string.md): `starts_with(string, substring) -> boolean`.
- **LITERAL-UNDERSCORE CAVEAT IS CLEAN.** Responder used `starts_with(tag,'cat_')`, NOT `tag LIKE 'cat_%'`. Correct literal-prefix predicate — `_` in LIKE is a single-char wildcard, so LIKE would wrongly keep "catX...". This is the durability signal watch (o) was monitoring: the iter1036 filter-lambda LIKE-underscore relapse did NOT recur. CLEAN.
- Alt VERIFIED sound (array.md): `cardinality(array_except(tags, filter(tags, tag -> starts_with(tag,'cat_'))))=0`. filter keeps the passing elements; array_except(tags, passing) removes every passing element, so all-pass → empty → cardinality 0. array_except dedups, but for an all-pass boolean test that is harmless. Logically correct, not a broken secondary.
- Acc 5 / Comp 5 / Clar 4.75 / App 4.75.

### Q3 — how many distinct keys across all rows / what keys are sent → 4.625
`SELECT DISTINCT key FROM events CROSS JOIN UNNEST(map_keys(properties)) AS t(key) ORDER BY key`
- VERIFIED (map.md): `map_keys(x(K,V)) -> array(K)`. CROSS JOIN UNNEST … AS t(key) + DISTINCT is the canonical key-extraction pattern. Sound and runnable.
- Minor completeness nuance: the question literally asks "HOW MANY distinct keys" (a count), and the lead query LISTS the keys rather than `COUNT(DISTINCT key)`. The companion `GROUP BY key, COUNT(*)` usage-count variant + the "what keys are sent" framing cover intent, and COUNT is a trivial wrap. Not a defect — pure completeness shading.
- Acc 5 / Comp 4 / Clar 4.5 / App 5.

### Q4 (verify cents→dollars precision) — 1999 → 19.99 → 4.78125
- "Integer division truncates (1999/100 = 19)" — VERIFIED CORRECT. In Trino, `/` with two INTEGER operands is integer division (truncates toward zero), so `1999/100 = 19`. Accurate; this is the crux of the question.
- `amount * 1.0 / 100` — VERIFIED: an unsuffixed decimal literal like `1.0` is DOUBLE in Trino 467 (docs: "decimal literals without explicit type specifier … treated as DOUBLE by default"), so this yields DOUBLE 19.99 — correct value, but floating-point (not exact for money).
- `CAST(amount AS DECIMAL(18,2)) / 100` — VERIFIED: DECIMAL division yields an exact fixed-scale 19.99. Correct and the precision-preferable form for money.
- Responder led with the truncation warning and offered BOTH; DECIMAL (the better money form) was provided. Minor: could flag explicitly that `*1.0` is DOUBLE/inexact, but no penalty.
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.625.

## Overall
(4.8125 + 4.875 + 4.625 + 4.78125) / 4 = **4.7734375 → PASS** (margin +1.27 over 3.5).

## Findings
- **Q2 literal-underscore: CLEAN.** starts_with used, not LIKE. Durability signal positive — the literal-prefix caveat family is holding on the all_match surface. Continue passive monitor of watch (o); no churn.
- **Q4 integer-division: CORRECT.** Truncation warning accurate; both DOUBLE (`*1.0`) and exact-DECIMAL forms offered, DECIMAL correctly framed as the money-preferable option.
- TICS clean all 4: `::` absent; no QUALIFY / false-semi-join / fabricated function / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / over-warning folklore / broken-secondary. Q2 array_except alt is logically valid, not a broken secondary.

## Recommendation
**DEFAULT NO-OP.** No source-verified resource defect; no 2-in-2 same-shape slip; all four leads runnable and dialect-correct. No resource edit, no FIX-A, no commit. MUST NOT bump state.json (already 1042).
