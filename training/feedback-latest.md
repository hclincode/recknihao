# Judge Feedback — iter1056

**Overall: 4.914 PASS** (Q1 4.875 / Q2 4.9375 / Q3 4.9375 / Q4 4.90625) — margin +1.414

Verified BOTH directions against RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/...) AND trino.io/docs/467 — NOT resources/. RAW git-tag dispositive.

Production-stack fit: all four are pure Trino-467 SQL questions (analytical query patterns), fully compatible with the on-prem Trino 467 + Iceberg + Hive Metastore stack in prod_info.md. No auth/authz/federation surface touched.

---

## Q1 — count starts per month by plan_type, sort month DESC + plan_type ASC — 4.875

`SELECT DATE_TRUNC('month', started_at) AS month, plan_type, COUNT(*) AS subscription_count FROM subscriptions GROUP BY DATE_TRUNC('month', started_at), plan_type ORDER BY DATE_TRUNC('month', started_at) DESC, plan_type ASC`

- **Verified (select.md):** ORDER BY supports multiple keys each with its own direction — synopsis `ORDER BY expression [ ASC | DESC ] [ NULLS {FIRST|LAST} ] [, ...]`. The mixed `DATE_TRUNC(...) DESC, plan_type ASC` is valid Trino. ✔
- **Verified (select.md):** GROUP BY "may contain any expression composed of input columns" — repeating `DATE_TRUNC('month', started_at)` in GROUP BY (not the `month` alias) is the CORRECT form. GROUP BY does NOT resolve SELECT aliases (#16533 family) — responder correctly repeated the expression rather than `GROUP BY month`. ✔
- **Verified (datetime.md):** `date_trunc('month', x)` returns first-day-of-month at midnight. Grouping months by truncation is sound. ✔
- Newest-first + alphabetical-within-month satisfied exactly. No defect.

## Q2 — users with AT LEAST ONE feature_flag starting with literal "beta_" — 4.9375

`WHERE any_match(feature_flags, flag -> starts_with(flag, 'beta_'))`
plus JSON-string-column note: `any_match(CAST(json_parse(feature_flags) AS ARRAY(VARCHAR)), flag -> starts_with(flag,'beta_'))`

- **Verified (array.md):** `any_match(array(T), function(T,boolean)) -> boolean` returns true if ≥1 element matches the predicate — exactly the "at least one flag" semantics. ✔
- **Verified (string.md):** `starts_with(string, substring) -> boolean` is a LITERAL prefix test, NO wildcards. So `starts_with(flag, 'beta_')` correctly matches the literal underscore — NOT a wildcard. This is the dialect-correct way to match a literal `beta_` prefix. ✔
- **Verified (json.md):** `json_parse(string)` returns a JSON value; CAST to `ARRAY(VARCHAR)` is supported for homogeneous string arrays. The bonus note for a JSON-string-typed column is sound and genuinely useful. ✔
- **Q2 BROKEN-SECONDARY LIKE DID NOT RECUR — 4th CONSECUTIVE CLEAN RE-PROBE (streak fully reversed).** The responder offered NO bare `LIKE 'beta_%'` "if you prefer" alternative. The escalation watch from iter1051 (2nd-occ `LIKE 'promo_%'` aside) and iter1037 is now reversed across iter1053 / iter1054 / iter1055 / iter1056 — four clean literal-prefix re-probes in a row. The FIX-A pair (r23 §653 LIKE literal-`_`/`%` + r07 ~L759 filter-lambda literal-prefix) is DURABLE; the bare-`LIKE 'X_%'`-as-equivalent secondary is NOT recurring. Watch stays CLOSED/passive. No 3rd-occurrence escalation trigger fired. Best answer of the set.

## Q3 — average session length in MINUTES, only valid ended_at — 4.9375

`SELECT AVG(CAST(DATE_DIFF('second', started_at, ended_at) AS DOUBLE) / 60) AS avg_session_minutes FROM sessions WHERE ended_at IS NOT NULL` + an `AVG(...) FILTER (WHERE ended_at IS NOT NULL)` variant.

- **Verified (datetime.md):** `date_diff('second', a, b)` returns `bigint`, complete-units (truncating, drops fractional). Casting to DOUBLE then `/60` yields FRACTIONAL minutes — strictly MORE precise than `date_diff('minute', ...)` which would drop the partial minute (complete-units). Good choice for an average. ✔
- **Verified (aggregate.md):** AVG "does not include null values in the count" — NULL `ended_at` rows are ignored by AVG; the explicit `WHERE ended_at IS NOT NULL` is defensively redundant and correct (also prunes the date_diff input). ✔
- **Verified (aggregate.md):** the `FILTER (WHERE ...)` clause "is supported for all aggregate functions" — the FILTER variant is a legitimate equivalent. ✔
- Fully addresses "only valid ended_at" two ways. No defect.

## Q4 — total revenue per customer formatted "$1,234.56" (amount = integer cents) — 4.90625

`SELECT customer_id, format('$%,.2f', SUM(amount) / 100.0) AS total_revenue FROM orders GROUP BY customer_id`

- **Verified (conversion.md):** `format()` follows java.util.Formatter; doc example `format('%,.2f', 1234567.89)` → `'1,234,567.89'`. `%,.2f` = comma grouping + 2 decimals. The `$` literal prefix in the format string is fine. → `"$1,234.56"` exactly. ✔
- **Verified (types.md):** undecorated `100.0` is a DECIMAL literal (only scientific notation like `1.03e1` is DOUBLE). `SUM(amount)` is bigint; `bigint / DECIMAL` → DECIMAL (mixed numeric arithmetic). `%,.2f` consumes the DECIMAL (the doc example's `1234567.89` is itself a DECIMAL literal), so NO cast-to-DOUBLE is needed and there is no float-rounding hazard. ✔
- GROUP BY customer_id → one row per customer. ✔
- Cents-to-dollars handled by `/100.0` (DECIMAL division, exact). Implicitly answers "SQL-side or app" by formatting SQL-side; a brief note that locale-aware currency formatting is often left to the app layer would have been the only marginal addition — not materially dinged.

---

## Cross-cutting clean checks

No `::`-cast, no QUALIFY, no false semi-join, no fabricated function, no regex-backslash trap, no INTERVAL quarter/week, no OFFSET-after-LIMIT, no over-warning folklore, no broken-secondary padding. All four leads are runnable Trino 467.

## Recommendation — DEFAULT NO-OP

Margin +1.414 over the 3.5 threshold. No source-verified resource defect. No 2+-consecutive same-shape slip — the only standing watch (Q2 broken-secondary LIKE) is now 4-in-a-row CLEAN and reversed, not advancing. Do NOT churn resources. No commit/push. Do NOT bump state.json (already 1056).
