# Judge Feedback — iter1059

**Phase:** extended (state.json already at 1059; do NOT bump). Verified BOTH directions vs RAW git-tag 467 source + trino.io/docs/467. NO federation probe (hard-locked). prod_info.md: on-prem Trino 467 + Iceberg/MinIO/HMS; none of the 4 Qs are auth/federation, so prod-fit is neutral here.

RAW 467 sources checked this sweep:
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/conversion.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/datetime.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/string.md

## Per-question scores

### Q1 — CSV text revenue → number for SUM/AVG
**Accuracy 5 / Clarity 4.875 / Applicability 5 / Completeness 4.75 → 4.90625**

- `CAST(revenue AS DECIMAL(10,2))` / `CAST(revenue AS DOUBLE)` is the CORRECT path. conversion.md: cast "can be used to cast a varchar to a numeric value type and vice versa." Verified.
- "Trino has no implicit text→number conversion" is CORRECT — conversion.md: "Trino will not convert between character and numeric types." Explicit CAST required.
- DECIMAL-for-money vs DOUBLE-for-float-tolerant framing is sound and correct for the SaaS revenue use case.
- `TRY_CAST(revenue AS DECIMAL)` returns NULL on bad rows (conversion.md: "Like cast, but returns null if the cast fails"), and SUM/AVG skip NULLs (aggregate semantics) — correct dirty-CSV guard.
- KEY POSITIVE: responder cast to DECIMAL/DOUBLE (the correct money path) and did NOT make the wrong "varchar-with-decimal-point CAST AS integer rounds half-up" claim that dinged iter1058 Q4. The iter1058 broken-secondary varchar→integer slip did NOT recur on this directly-adjacent topic. Clean.
- Minor completeness nit: `DECIMAL(10,2)` caps the integer part at 8 digits (max ~99,999,999.99); for very large revenue totals a wider scale could overflow, unmentioned. Illustrative-only, no ding to accuracy.

### Q2 — week number from timestamp
**Accuracy 5 / Clarity 4.875 / Applicability 4.875 / Completeness 4.875 → 4.90625**

- `week(started_at)` and `EXTRACT(WEEK FROM started_at)` both verified in datetime.md: returns the ISO week of the year, value ranges 1 to 53; EXTRACT WEEK field maps to the `week` function. Correct.
- ISO-week definition ("week 1 = first week with a Thursday, weeks start Monday") is the accurate ISO-8601 rule. Correct.
- `date_trunc('week', started_at)` → Monday of that week is a useful, correct add for labeling/sorting (date_trunc week = Monday-start in Trino).
- GROUP BY repeats the expression `week(started_at)` (not a SELECT alias) → #16533-compliant. Correct.
- Minor: did not flag the year-boundary caveat (ISO week 1 can belong to the prior calendar year, week 52/53 to the next) — for cross-year aggregation you'd group by ISO year+week. Nuance only, not asked.

### Q3 — orders where ≥1 tag starts with literal 'promo_'
**Accuracy 5 / Clarity 4.875 / Applicability 5 / Completeness 4.875 → 4.9375**

- `filter(tags, t -> starts_with(t,'promo_'))` + `cardinality(...) > 0` verified: filter(array(T), function(T,boolean))->array(T); cardinality(x)->bigint; starts_with(string,substring)->boolean LITERAL prefix (string.md "Tests whether substring is a prefix of string"). All correct.
- `any_match(tags, t -> starts_with(t,'promo_'))` verified: any_match(array(T), function(T,boolean))->boolean, true if ≥1 element matches (array.md). This is the cleanest form for the boolean test and correctly offered.
- KEY POSITIVE: `starts_with` correctly matches the LITERAL underscore. The responder did NOT offer the buggy bare `LIKE 'promo_%'` aside (where `_` is a single-char wildcard that over-matches `promoX...`). The broken-secondary LIKE pattern (iter1037/1051 family) did NOT recur — continues the long clean streak; r23 §653 + r07 ~L759 FIX-A durable, watch stays CLOSED.
- Subtle unmentioned edge: `any_match` returns NULL (not false) if no element matches AND some element is NULL; for a clean array of non-null tag strings this is a non-issue. Nuance only.

### Q4 — days since last_active_at, NULL for never-active, no crash
**Accuracy 5 / Clarity 4.75 / Applicability 4.875 / Completeness 4.75 → 4.84375**

- `date_diff('day', last_active_at, current_date)` — signature verified: date_diff(unit, timestamp1, timestamp2) -> bigint, returns timestamp2 - timestamp1 in the unit (datetime.md). Argument order (unit, earlier, later) is correct → produces a non-negative day count for past activity.
- NULL propagation: Trino built-in scalar functions return NULL on NULL input (standard engine-wide NULL propagation); date_diff with a NULL `last_active_at` yields NULL, no crash, no NULLIF/CASE needed. Correct — this is the safest, simplest form and exactly answers "show NULL, not crash."
- Mixed type note: `last_active_at` is a timestamp and `current_date` is a date; Trino 467 has implicit timestamp↔date coercion in date_diff, so this runs (consistent with the TIMESTAMP→TZ-coercion verification family). No type error. The day count is calendar-day-aware. Correct.
- Minor completeness: did not mention that if `last_active_at` could be in the future the result would be negative (not relevant for last-active), nor an explicit "either input NULL → NULL" being engine NULL-propagation rather than a documented date_diff clause. Nuance only.

## Overall

| Q | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 4.875 | 5 | 4.75 | 4.90625 |
| Q2 | 5 | 4.875 | 4.875 | 4.875 | 4.90625 |
| Q3 | 5 | 4.875 | 5 | 4.875 | 4.9375 |
| Q4 | 5 | 4.75 | 4.875 | 4.75 | 4.84375 |

**Overall average = 4.8984375 → PASS** (threshold 3.5; margin +1.40).

## Source-verified dialect notes / defects

- NO defects found. All four answers are technically accurate against RAW 467 source.
- Q1: iter1058's wrong "varchar→integer CAST rounds" slip did NOT recur — responder correctly used the DECIMAL/DOUBLE money path. Per-instance slip from iter1058 confirmed one-off, NOT a resource defect.
- Q3: broken-secondary `LIKE 'promo_%'` literal-underscore aside did NOT recur; starts_with literal-prefix used cleanly. FIX-A durable.
- No `::`/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary issues.

## Recommendation

DEFAULT NO-OP (margin +1.40). NO resource edit; NO commit. MUST NOT bump state.json (already 1059).
