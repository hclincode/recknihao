# Iter44 Q2 Score

**Question**: Postgres date arithmetic copied to Trino — are NOW() - INTERVAL '30 days' and EXTRACT(epoch FROM ...) just syntax differences or something fundamental?
**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.00** |

**Feedback**:

**What was correct (verified against trino.io/docs/current/functions/datetime.html):**
- `NOW()` is correctly identified as an alias for `current_timestamp` — verified.
- `EXTRACT(epoch FROM col)` is correctly identified as invalid in Trino — verified. The Trino EXTRACT field list does not include EPOCH.
- `to_unixtime(timestamp_col)` is correctly named as the substitute for `EXTRACT(epoch FROM ...)` — verified.
- INTERVAL syntax difference is correctly stated: Trino requires `INTERVAL '30' DAY` (unit outside quotes, singular), not Postgres's `INTERVAL '30 days'` — verified.
- `date_add('day', n, timestamp_col)` is named as the explicit date-math function — correct Trino 467 syntax.
- `current_date` returns DATE / `current_timestamp` returns TIMESTAMP distinction is correct.
- The framing "Postgres and Trino have fundamentally different date/time function implementations" matches the expected answer's core message.

**What was wrong or imprecise:**
1. **EXTRACT field list is understated.** The answer states Trino's EXTRACT "only supports fields down to SECOND (year, month, day, hour, minute, second)." Per the official Trino docs, EXTRACT actually supports: YEAR, QUARTER, MONTH, WEEK, DAY, DAY_OF_MONTH, DAY_OF_WEEK, DOW, DAY_OF_YEAR, DOY, YEAR_OF_WEEK, YOW, HOUR, MINUTE, SECOND, TIMEZONE_HOUR, TIMEZONE_MINUTE. The critical fact (EPOCH is not supported) is correct, but the implication that QUARTER/WEEK/DOW are also unsupported is wrong and will mislead an engineer who needs QUARTER or DOW.
2. **`current_timestamp()` with empty parens is shown as valid.** Per Trino docs, SQL-standard `current_timestamp` does NOT take empty parens — only optional precision parens (`current_timestamp(6)`). `now()` is the function-call form that takes empty parens. Minor imprecision.

**What is missing relative to the expected answer:**
1. `date_diff` is not mentioned alongside `date_add`. For the engineer's "rows within the last 7 days" use case, `date_diff` is the idiomatic Trino function for interval arithmetic and would round out the answer.
2. The sub-second precision check idiom (`date_diff('microsecond', date_trunc('millisecond', col), col) != 0`) is absent. This is flagged in the expected answer because engineers reaching for `EXTRACT(MICROSECOND FROM ...)` will hit a parse error in Trino — a real gap given that resource 13 was recently fixed for this exact pattern (per state.json notes).
3. The takeaway "treat Trino SQL as a distinct dialect and verify every date function against Trino 467 docs" is implied but not crisply stated as a closing rule.

**Resource gap**: `resources/13-postgres-to-iceberg-ingestion.md` (or a new `resources/22-trino-vs-postgres-datetime.md`) needs a side-by-side "Postgres -> Trino datetime translation" table covering: (1) EXTRACT supported field list (with EPOCH and MICROSECOND explicitly called out as invalid), (2) INTERVAL '30' DAY vs '30 days', (3) NOW() as alias vs to_unixtime() as substitute, (4) date_add/date_diff as the idiomatic interval math, (5) sub-second precision check pattern. The current answer leaned on examples in the resources but did not pull a comprehensive translation table — suggesting the resource itself does not yet have one.
