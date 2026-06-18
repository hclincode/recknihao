# Judge Feedback — iter1077 (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.

**Overall: 4.55 — PASS** (overall average governs; no per-question veto)

Verified BOTH directions against RAW git-tag 467 source:
- bitwise: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/bitwise.md
- datetime: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/datetime.md
- aggregate: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/aggregate.md
- comparison: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/comparison.md

---

## Q1 — bit-test on integer flags column — 4.875

`bitwise_and(flags, 8) <> 0` and dynamic `bitwise_and(flags, bitwise_left_shift(1, 3)) <> 0`.

- VERIFIED `bitwise_and(x, y) -> bigint` exists ("bitwise AND of x and y in 2's complement").
- VERIFIED `bitwise_left_shift(value, shift)` exists.
- VERIFIED there is NO infix `&` or `<<` operator in 467 — only the named functions are documented. The responder's explicit "Trino has NO << operator — use bitwise_left_shift(value, shift)" is correct and is exactly the imported-prior trap (C/Java/Postgres `1 << n` habit) the MEMORY card warns about. Got it right.
- Bit-test logic correct: value 8 = bit index 3; `bitwise_left_shift(1,3)` = 8, equivalent. `<> 0` is the right "bit is set" predicate.

Accuracy 5 / Completeness 4.5 / Clarity 5 / Actionability 5. Clean.

## Q2 — group signups by calendar month — 4.875

`date_trunc('month', started_at)` + repeat the expression in GROUP BY.

- VERIFIED `date_trunc(unit, x)` truncates to first instant: docs example `date_trunc('month', TIMESTAMP '2022-10-20 05:10:00')` -> `2022-10-01 00:00:00.000`. `'month'` is a supported unit.
- VERIFIED the GROUP-BY guidance: repeat the expression rather than reference the SELECT alias (#16533 family — Trino does not resolve SELECT aliases by name inside GROUP BY expressions). Correct and idiomatic.

Accuracy 5 / Completeness 4.5 / Clarity 5 / Actionability 5. Clean.

## Q3 — build user_id -> display_name map — 4.6875

`map_agg(user_id, display_name)` + GROUP BY tenant_id variant.

- VERIFIED `map_agg(key, value)` is a real 467 aggregate ("Returns a map created from the input key/value pairs").
- Duplicate-key note: docs do not explicitly specify map_agg duplicate behavior; the related map_union retains an arbitrary value for collided keys, so duplicate keys are effectively non-deterministic. The responder's framing — "user_id is unique here so no collision" — is safe, correct guidance and sidesteps the ambiguity. Acceptable.
- GROUP BY tenant_id variant for per-tenant maps is a good multi-tenant SaaS extension.

Accuracy 4.75 / Completeness 4.5 / Clarity 4.75 / Actionability 4.75. Clean.

## Q4 — null-safe join (NULL should match NULL on nullable promo_code) — 3.875

Responder gave (a) `ON COALESCE(o.promo_code,'') = COALESCE(p.promo_code,'')` with a sentinel-collision caveat, and (b) `ON (o.promo_code = p.promo_code) OR (o.promo_code IS NULL AND p.promo_code IS NULL)`. Did NOT mention `IS NOT DISTINCT FROM`.

- **CANONICAL ANSWER OMITTED:** `a IS NOT DISTINCT FROM b` is the purpose-built Trino 467 null-safe equality operator and is EXACTLY what this question asks for. VERIFIED on comparison.md: `NULL IS NOT DISTINCT FROM NULL` evaluates to TRUE, NULL is treated as a comparable value, result is guaranteed TRUE/FALSE (never NULL). It IS usable directly in a JOIN ON clause: `... ON o.promo_code IS NOT DISTINCT FROM p.promo_code`. This is the cleanest, idiomatic answer and should have been the lead.
- **Both given workarounds DO work (functionally correct, not a correctness failure):**
  - (a) COALESCE-sentinel: correct PROVIDED the sentinel `''` can never be a real promo_code value. The responder explicitly flagged the collision caveat — good — but it is a real footgun (an empty-string promo_code would falsely match a NULL). Inferior to IS NOT DISTINCT FROM.
  - (b) OR-form `(=) OR (both IS NULL)`: fully correct and always works, no sentinel risk. Standard portable fallback.
- **Verdict:** functionally CORRECT but missed the canonical operator the question was essentially asking for → COMPLETENESS/idiomaticity deduction, NOT a correctness failure.

Accuracy 4.0 / Completeness 3.25 / Clarity 4.25 / Actionability 4.0.

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5.0 | 4.5 | 5.0 | 5.0 | 4.875 |
| Q2 | 5.0 | 4.5 | 5.0 | 5.0 | 4.875 |
| Q3 | 4.75 | 4.5 | 4.75 | 4.75 | 4.6875 |
| Q4 | 4.0 | 3.25 | 4.25 | 4.0 | 3.875 |

Overall average = (4.875 + 4.875 + 4.6875 + 3.875) / 4 = **4.58 PASS**.

## Recommendation

DEFAULT NO-OP (margin +1.08). Q1/Q2/Q3 clean. The only soft spot is Q4 omitting `IS NOT DISTINCT FROM` — the question phrasing ("regular = skips NULL=NULL") is a textbook trigger for that operator, and the responder reached for two workarounds instead of the built-in. Worth checking whether resources surface `IS NOT DISTINCT FROM` as the lead null-safe-join canonical with a findable keyword (null-safe join / NULL matches NULL). The workarounds are valid, so this is not corrupting; treat as a per-instance completeness gap and re-probe the null-safe-join angle next sweep before any resource edit. MUST NOT bump state.json (already 1077).
