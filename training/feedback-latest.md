# Judge Feedback — iter1052

**Overall: Q1 4.875 / Q2 4.875 / Q3 4.9375 / Q4 4.8125 → 4.875 PASS**

Verified BOTH directions against RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/...), NOT resources/. No federation probe (hard-locked).

Production fit: prod stack is Trino 467 + Iceberg connector on-prem; all four are plain analytic SQL with no stack-incompatible advice. Good fit.

---

## Q1 — integer cents → "$19.99" formatted string (SQL vs app-side) — 4.875

Answer: `format('$%.2f', CAST(price_cents AS DECIMAL(18,2)) / 100) AS price_formatted` (+ shows the DECIMAL division); explains format() = printf-style (Java Formatter).

Verification (RAW conversion.md):
- `format(format, args...) -> varchar` follows `java.util.Formatter` (printf-style). CONFIRMED.
- Doc examples: `format('%.5f', pi())` → `'3.14159'`; `format('%,.2f', 1234567.89)` → `'1,234,567.89'`. The `%,.2f` example feeds an undecorated decimal-point literal `1234567.89`, which per language/types.md is a DECIMAL (only sci-notation is DOUBLE) — so `%.2f`/`%f` ACCEPTS DECIMAL. The cast-to-DECIMAL numerator is correctly consumed; no cast-to-DOUBLE needed.
- `CAST(price_cents AS DECIMAL(18,2)) / 100`: numerator is DECIMAL, undecorated `100` is integer → DECIMAL/integer → DECIMAL, exact `19.99`. Output `"$19.99"` correct.

No thousands separator requested; `%.2f` (no comma) is the right minimal choice. SaaS framing (format in SQL vs app-side) addressed. Fully sound. (-0.125 polish only: could note app-side formatting is often preferable for locale/currency-symbol flexibility, but not required.)

## Q2 — monthly cohort fraction still active after 90 days — 4.875

Answer: `date_trunc('month', started_at)` cohort; `COUNT(*)` total; `COUNT(*) FILTER (WHERE cancelled_at IS NULL OR cancelled_at > started_at + INTERVAL '90' DAY)` numerator; `* 100.0 / COUNT(*)` percentage; GROUP BY repeats the date_trunc expression; ORDER BY cohort_month.

Verification (RAW datetime.md):
- `date_trunc('month', timestamp)` CONFIRMED.
- `started_at + INTERVAL '90' DAY` — `+` operator with day-interval on timestamp CONFIRMED; `INTERVAL '90' DAY` is a valid interval literal (DAY is a supported qualifier; not quarter/week).
- `COUNT(*) FILTER (WHERE ...)` — standard FILTER-on-aggregate, valid in 467.

**WATCH (s) — denominator-scope: CLEAN, iter1044 mistake did NOT recur.** The denominator is `COUNT(*)` over ALL cohort members (GROUP BY month with NO WHERE restricting the table); only the numerator is FILTER-restricted to the still-active-at-90-day population. This is the correct cohort-retention denominator. The iter1044 error of restricting the denominator with a table-level WHERE did NOT recur.
- Predicate `cancelled_at IS NULL OR cancelled_at > started_at + INTERVAL '90' DAY` correctly captures those active at the 90-day mark.
- `* 100.0` forces decimal division (avoids integer truncation). Sound.
- Minor cohort-maturity nuance (very recent cohorts <90 days old count not-yet-matured NULL-cancelled rows as "active") is acceptable and not required to flag. (-0.125 completeness only.)

## Q3 — events with ≥1 tag starting with literal "promo_" — 4.9375

Answer: PRIMARY `WHERE cardinality(filter(tags, t -> starts_with(t, 'promo_'))) > 0`; SIMPLER `WHERE any_match(tags, t -> starts_with(t, 'promo_'))`. States starts_with is literal prefix, NOT a wildcard. Offered NO bare `LIKE 'promo_%'` form.

Verification (RAW array.md + string.md):
- `any_match(array(T), function(T,boolean)) -> boolean` — true if ≥1 element matches; CONFIRMED ideal for "at least one matching tag".
- `filter(array(T), function(T,boolean)) -> array(T)` + `cardinality(x) -> bigint` — CONFIRMED; `cardinality(filter(...)) > 0` is a valid (if more verbose) equivalent.
- `starts_with(string, substring) -> boolean` — "Tests whether substring is a prefix of string." Literal prefix match, NOT a wildcard. CONFIRMED — `_` in `'promo_'` is a literal character here (no pattern engine), exactly the literal-underscore requirement.

**WATCH (c)/(o) — broken-secondary LIKE aside: CLEAN at 3rd-occurrence test.** The buggy `LIKE 'promo_%'` "if you prefer" alternative (iter1037 / iter1051) did NOT recur. Both offered forms use `starts_with` (literal-prefix-correct); had a bare `LIKE 'promo_%'` been offered as equivalent it would over-match `'promoX...'` (underscore = single-char wildcard) — but it was not offered. Clean re-probe; the two-occurrence broken-secondary streak does NOT advance to 3. (-0.0625 polish only.)

## Q4 — single most recent order per customer (cleaner than MAX+self-join) — 4.8125

Answer: `SELECT * FROM (SELECT ..., ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at DESC) AS rn FROM orders) WHERE rn=1 ORDER BY customer_id`.

Verification (RAW window.md):
- `row_number() -> bigint` — "unique, sequential number for each row ... according to ordering within the window partition." CONFIRMED.
- Window functions run after HAVING, before ORDER BY → cannot appear in WHERE; the subquery wrap (`WHERE rn=1` outside) is required and correctly applied. CONFIRMED.
- PARTITION BY customer_id + ORDER BY created_at DESC + rn=1 = canonical most-recent-per-group; cleaner than MAX(created_at)+self-join as asked; generalizes to top-N via `rn <= N`. Sound. (-0.1875: `SELECT *` carries the helper `rn` column into output — a final projection listing the wanted columns would be marginally cleaner, minor.)

---

## Recommendation: DEFAULT NO-OP

Margin +1.375 over threshold. All four source-verified clean. Both flagged watches came back CLEAN:
- (s) Q2 denominator-scope: denominator = full cohort, iter1044 mistake did NOT recur.
- (c)/(o) Q3 broken-secondary LIKE: did NOT recur at the 3rd-occurrence test (starts_with only).

No `::`-cast / QUALIFY / false-semi-join / fabricated-fn / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / over-warning / broken-secondary this iter. No source-verified resource defect and no 2-in-2 same-shape slip. NO resource edit; NO commit. MUST NOT bump state.json (already 1052).
