# iter1074 Judge Feedback — 2026-06-18

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.

**Overall average: 4.83 / 5.00 — PASS** (threshold 3.5; margin +1.33)

Verified BOTH directions against RAW git-tag 467 source. Clean sweep, zero source-verified defects across all four answers. No `::`/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary patterns.

## Sources checked (RAW git-tag 467, dispositive over rendered HTML)
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/datetime.md — `date_add` signature/units
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md — `array_position`
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/aggregate.md — `corr`/`covar_samp`/`regr_slope`
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/select.md — HAVING + clause evaluation order

## Per-question breakdown

### Q1 — add 3 months to a timestamp (4.88)
`date_add('month', 3, started_at)`. VERIFIED: 467 signature is `date_add(unit, value, timestamp)` — exact argument order the responder used; `'month'` is an explicitly listed valid unit (millisecond/second/minute/hour/day/week/month/quarter/year). Correctly told the engineer there's no bare `+N` on dates; `INTERVAL '3' MONTH` is the documented alternative and date_add is the cleaner answer to "is there a function". Accuracy 5, Completeness 4.5, Clarity 5, Actionability 5.

### Q2 — index of a value in an array (4.94)
`array_position(tags, 'onboarding')` returning 1-based index, 0 if absent; `WHERE array_position(...) > 0` filter. VERIFIED: `array_position(x, element) -> bigint`, "position of the first occurrence ... or 0 if not found", 1-based. Exactly correct. "No UNNEST needed, works directly on the array" is accurate and useful. Accuracy 5, Completeness 5, Clarity 5, Actionability 4.75.

### Q3 — correlation between two columns (4.81)
`corr(total_spend, account_age_days)` plus `covar_samp` and `regr_slope`. VERIFIED: all three are native 467 aggregates, all `(y, x)` order; `corr` returns the correlation coefficient (Pearson by definition of the statistic). Result in [-1, 1] is correct; "do it in SQL, no special setup, don't pull data out" is the right SaaS guidance. corr/covar are order-symmetric; responder kept consistent (y, x) ordering — fine. Accuracy 5, Completeness 4.75, Clarity 4.75, Actionability 4.75.

### Q4 — count per customer, filter on COUNT > 5 (4.69)
`GROUP BY customer_id HAVING COUNT(*) > 5 ORDER BY upgrade_count DESC`. VERIFIED: HAVING is the correct clause for filtering on an aggregate; the FROM→WHERE→GROUP BY→HAVING→SELECT→ORDER BY logical order matches select.md ("ORDER BY ... evaluated after any GROUP BY or HAVING"). Critically the responder REPEATED `COUNT(*)` in HAVING rather than referencing the SELECT alias `upgrade_count` — correct per the #16533 family (Trino resolves output aliases only in ORDER BY, not in HAVING/WHERE/GROUP BY); and correctly noted ORDER BY MAY use the alias. The "WHERE runs before GROUP BY so it can't see aggregates" explanation is the right beginner mental model. No defects. Accuracy 5, Completeness 4.5, Clarity 5, Actionability 4.25.

## Imported-prior risk families
All answered correctly: date_add arg order (unit, value, timestamp); array_position 0-on-absent; corr/regr (y,x); HAVING-repeats-aggregate-not-alias (#16533).

## Recommendation
DEFAULT NO-OP. Margin +1.33. No resource edit, no commit warranted. MUST NOT bump state.json (already 1074).
