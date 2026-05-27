# Iteration 46, Q1 — Score

**Question**: I'm trying to write a Trino query that finds users who signed up in the last 30 days and also computes how many days it's been since their first event. I wrote this and it's breaking: `WHERE signup_date > NOW()::DATE - 30` and for the duration: `SELECT DATEDIFF(NOW(), first_event_at) AS days_active`. Can you fix these for Trino?

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling (Postgres -> Trino datetime translation sub-area)

---

## Technical verification (via WebSearch against trino.io)

1. **Is `NOW()::DATE` invalid in Trino?**
   YES — verified against trino.io date/time docs. The `::` cast syntax is PostgreSQL-specific; Trino uses `CAST(expr AS DATE)` or the shortcut `date(expr)`. `NOW()` itself is a valid Trino alias for `current_timestamp` (without parens preferred, but with parens accepted).

2. **Is subtracting an integer from a date (`date - 30`) invalid in Trino?**
   YES — verified against trino.io. Trino requires explicit `INTERVAL` for date arithmetic; `date - integer` is not a supported operator. Postgres allows it implicitly (treats integer as days), Trino does not.

3. **Is `current_date - INTERVAL '30' DAY` the correct fix?**
   YES — verified against the Trino 481/current docs and the Presto/Trino interval reference. INTERVAL value must be quoted, unit must be outside the quotes, singular, and uppercase. `'30' DAY` is correct; Postgres's `'30 days'` (plural, inside quotes) is invalid in Trino.

4. **Is `DATEDIFF()` invalid in Trino?**
   YES — `DATEDIFF()` is MySQL syntax; it does not exist in Trino. Trino has `date_diff()` (lowercase, underscore) with signature `date_diff(unit, timestamp1, timestamp2)`.

5. **Does `date_diff('day', first_event_at, current_timestamp)` compute `current_timestamp - first_event_at` in days?**
   YES — verified against trino.io: "Returns `timestamp2 - timestamp1` expressed in terms of `unit`." So the responder's argument order (earlier first, later second) correctly computes "days since first event," which is what the user asked for.

All five technical claims in the answer are accurate.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 5 | Every claim verified against trino.io. Correctly identifies both broken Postgres/MySQL idioms (`::` cast and `DATEDIFF`), correctly states the date-minus-integer rule, correctly fixes both with `current_date - INTERVAL '30' DAY` and `date_diff('day', first_event_at, current_timestamp)`. Argument order for `date_diff` is correct (earlier, later -> later - earlier). INTERVAL formatting rule (unit outside quotes, singular, uppercase) stated correctly. The aside about `date(current_timestamp)` for timestamp-typed signup columns is a useful defensive note and matches Trino's `date()` function. No factual errors. |
| **Beginner clarity** | 4 | Strong structure — names what's broken before showing the fix, uses bold subheaders for Issue 1 / Issue 2, gives a one-line explanation for each Postgres/Trino mismatch ("`::` cast is Postgres-specific", "DATEDIFF is MySQL syntax"). Closes with a "Why Trino is different" framing block that gives the engineer a generalizable mental model ("strict but consistent"). Minor clarity nit: "ANSI SQL" appears without a one-line gloss; an engineer who only knows the Postgres dialect may not know what ANSI SQL means in this context. Also the `date(current_timestamp)` aside in the "if signup_date is a timestamp" block could confuse beginners — they may not realize `current_date` already returns a DATE; the asymmetry isn't fully explained. Strong overall, but not perfect for zero-OLAP-background readers. |
| **Practical applicability** | 5 | Fixes the engineer's exact two broken queries — pastes back corrected SQL for both, not abstract rules. The final "Your full corrected query" block combines both fixes into a runnable statement with `iceberg.analytics.users`, `ORDER BY signup_date DESC` and the prod-stack-correct `Trino 467 + Iceberg` framing. This directly addresses the failure pattern flagged in Iter 45 Q2 ("responder names the abstract rule but doesn't paste back corrected SQL for user's actual broken queries"). The bonus examples for `hours since first event` and `days since signup` give the engineer a copy-paste template for adjacent variants they'll write next. Cleanest "what do I run right now" output of the recent Postgres-to-Trino datetime questions. |
| **Completeness** | 5 | Covers everything the expected-answer outline asked for: both broken queries diagnosed and fixed individually, the complete corrected query combining both, the `INTERVAL` formatting rule (unit outside quotes, singular, uppercase) called out explicitly, and the `date_diff` argument-order semantics (earlier first, later second -> later - earlier) explained. Bonus coverage on `CAST(... AS DATE)` / `date()` as the Trino replacement for `::DATE`, and the `Trino is stricter than Postgres` mental model close. Does not omit any sub-question. The only nit is that the answer does not explicitly state that `current_timestamp` in Trino takes no parens (writing `now()` with parens works but `current_timestamp` without parens is the canonical form) — but this is a refinement, not a gap. |

**Average**: (5 + 4 + 5 + 5) / 4 = **4.75**

---

## Rubric update

Topic: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling
- Prior: avg **4.231** across 47 questions
- New running avg: (4.231 × 47 + 4.75) / 48 = (198.857 + 4.75) / 48 = 203.607 / 48 = **4.242** across 48 questions
- Status: **PASSED** (unchanged)

---

## Notes for teacher

This answer is direct validation that the Iter 45 Q2 resource fix (before/after worked examples for Postgres -> Trino datetime translation in `resources/13-postgres-to-iceberg-ingestion.md`, with `date_diff` elevated as preferred idiom) is working. The Iter 45 Q2 score on a closely-analogous question (broken Postgres date arithmetic) was 3.00 with the failure pattern "named the abstract rule but did not paste back corrected SQL for user's actual broken queries." This iter46 Q1 answer scored 4.75 on essentially the same question shape, with the responder pasting back both corrected queries inline AND combining them into a runnable end-to-end query. Resource fix produced the intended behavior change.

No new critical resource gaps identified. Two minor improvements would push this from 4.75 toward 5.0:

1. **Inline ANSI SQL gloss**: in `resources/13-postgres-to-iceberg-ingestion.md`, when the "Why Trino is stricter" framing appears, add a one-line plain-English gloss for "ANSI SQL" (the standardized SQL specification that database engines may extend; Postgres extends it liberally, Trino sticks closer to it). This would close the only beginner-clarity gap.

2. **Canonical `current_timestamp` form**: the resource should explicitly state that the canonical Trino form is `current_timestamp` (no parens) and `current_date` (no parens), while `now()` is also accepted (with parens). The responder used `current_timestamp` and `current_date` consistently here — good — but a future weaker pull might mix `NOW()` with parens and `current_timestamp` without parens in the same answer and confuse a beginner.

Continue probing this topic from novel angles per state.json iter46 plan — the next test should hit an area the worked-examples fix has NOT directly addressed (e.g., timezone handling for `at_timezone('UTC')` vs Postgres's `AT TIME ZONE`, or `to_unixtime`/`from_unixtime` round-trip, or interval arithmetic on timestamps with subsecond precision).
