# Judge Feedback — iter1078 (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.

**Overall: 4.81 PASS** (margin +1.31). Verified BOTH directions vs RAW git-tag 467 source. Clean sweep, zero source-verified defects. **Q1 FIX-A REACHED: responder now uses the canonical `IS NOT DISTINCT FROM`** (contrast iter1077 Q4, which only offered COALESCE-sentinel and OR-form workarounds).

## Per-question breakdown

### Q1 — null-safe join (NULL matches NULL) — 4.94
`LEFT JOIN ... ON u.region_code IS NOT DISTINCT FROM s.region_code`, explaining `=` returns UNKNOWN on NULL (drops both-NULL rows) while `IS NOT DISTINCT FROM` returns TRUE when both NULL, FALSE when one NULL.

VERIFIED against comparison.md (RAW 467): "the `IS DISTINCT FROM` and `IS NOT DISTINCT FROM` operators treat `NULL` as a known value and both operators guarantee either a true or false outcome even in the presence of `NULL` input." Docs example verbatim: `SELECT NULL IS NOT DISTINCT FROM NULL; -- true`. Result is always TRUE/FALSE, never NULL/UNKNOWN — usable directly in a JOIN ON clause.

**FIX-A CONFIRMED:** the responder used the purpose-built canonical null-safe equality operator, not a COALESCE-sentinel or `(=) OR (both IS NULL)` workaround. This is exactly what the "NULL match NULL" question asked for, and closes the iter1077 Q4 completeness gap. The explanation of why `=` drops both-NULL rows (UNKNOWN, not TRUE) is correct and beginner-clear. LEFT JOIN vs INNER JOIN is a reasonable modeling choice; the ON IS NOT DISTINCT FROM makes NULL match NULL either way — not a defect.

### Q2 — array membership without unnesting — 4.88
`WHERE contains(tags, 'featured')`.

VERIFIED against array.md (RAW 467): `contains(x, element) -> boolean` is listed. Correct membership test, no UNNEST needed. Clean.

### Q3 — sum integers in an array — 4.81
`reduce(scores, 0, (s, x) -> s + x, s -> s) AS total_score`, noting Trino has NO array_sum.

VERIFIED against array.md (RAW 467):
- **NO array_sum** — not in the list (confirms carried pin; array_sum/array_avg are the absent ones, array_max/min/distinct/sort DO exist).
- `reduce(array(T), initialState S, inputFunction(S,T,S), outputFunction(S,R)) -> R` is the documented 4-arg fold.

The fold is correct: start 0, `(s,x)->s+x` accumulates each element, `s->s` returns the accumulator unchanged. The explicit "Trino has NO array_sum, use reduce" framing nails the imported-prior trap. Clean.

### Q4 — pick any one value per group — 4.81
`SELECT assignee_id, arbitrary(ticket_id) AS sample_ticket ... GROUP BY assignee_id`, noting it's non-deterministic and an alias for any_value().

VERIFIED against aggregate.md (RAW 467):
- `arbitrary(x)`: "Returns an arbitrary non-null value of `x`, if one exists. Identical to any_value."
- `any_value(x)`: "Returns an arbitrary non-null value `x`, if one exists."

Both exist, return an arbitrary non-null value per group, and are the right tool for "any one value per group." The alias relationship and non-determinism note are both correct. Clean.

## Source notes
- comparison.md: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/comparison.md
- array.md: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md
- aggregate.md: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/aggregate.md

No ::/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary-alternative observed.

## Recommendation
DEFAULT NO-OP (margin +1.31). The Q1 null-safe-join FIX-A is confirmed reached from a 2nd angle (iter1077 Q4 join + WHERE forms → iter1078 Q1 LEFT JOIN ON form); responder now reaches for the canonical operator. NO resource edit; NO commit. MUST NOT bump state.json (already 1078).
