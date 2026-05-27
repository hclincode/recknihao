# Iter 45, Q2 — Score

**Question**: I'm trying to figure out the age of events in our Iceberg table — specifically I want rows where `occurred_at` is more than 90 days old, and I also want to compute how many hours ago each event happened. I tried these queries in Trino and they're failing. Can you help me fix them? Here's what I wrote: `WHERE occurred_at < NOW() - INTERVAL '90 days'` and `SELECT EXTRACT(epoch FROM NOW()) - EXTRACT(epoch FROM occurred_at) AS seconds_since_event`.

**Target topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | Two correct facts (EXTRACT(EPOCH) unsupported → use to_unixtime; `INTERVAL '90 days'` plural is wrong → use `INTERVAL '90' DAY`). Verified against Trino docs: EXTRACT supports YEAR/QUARTER/MONTH/WEEK/DAY/DAY_OF_MONTH/DAY_OF_WEEK/DOW/DAY_OF_YEAR/DOY/YEAR_OF_WEEK/YOW/HOUR/MINUTE/SECOND/TIMEZONE_HOUR/TIMEZONE_MINUTE — no EPOCH. Errors / imprecisions: (a) the answer's first example uses `event_time >= current_date - INTERVAL '30' DAY` instead of fixing the user's actual `occurred_at < NOW() - INTERVAL '90 days'`; (b) the example mixes `current_date` (DATE) with an `INTERVAL DAY` on a TIMESTAMP column — that's an implicit-cast hazard worth calling out, not glossing over; (c) the answer states "Trino is case-insensitive" without qualification — Trino keywords are case-insensitive but quoted identifiers are case-sensitive; (d) `current_timestamp()` is written with parentheses several times — Trino accepts both `current_timestamp` and `now()` but the SQL-standard form is `current_timestamp` (no parens). |
| Beginner clarity | 4 | Section headings and the "Postgres-to-Trino differences" framing are easy to follow. Uses `DAY` not `days` explicitly. Weakness: the user asked "fix MY two specific queries" and got back a survey of differences — a beginner has to mentally map the survey back to their own SQL. |
| Practical applicability | 2 | The single biggest failure of this answer: it never shows the user the two corrected queries. Expected output is literally `WHERE occurred_at < current_timestamp - INTERVAL '90' DAY` and `SELECT to_unixtime(current_timestamp) - to_unixtime(occurred_at) AS seconds_since_event` (or `date_diff('hour', occurred_at, current_timestamp) AS hours_since_event`). The user is left to assemble these themselves from a list of building blocks. For the "hours ago" half of the question the answer never mentions `date_diff('hour', ...)` at all — that's the canonical Trino idiom for the user's exact ask. |
| Completeness | 3 | Covers EXTRACT(EPOCH) → to_unixtime, INTERVAL pluralization, and NOW() aliasing. Misses: (1) corrected SQL for both user queries; (2) `date_diff('hour', occurred_at, current_timestamp)` as the idiomatic answer for "how many hours ago"; (3) MICROSECOND also not supported by EXTRACT (related gotcha); (4) the user's `seconds_since_event` formula will work if you swap `EXTRACT(epoch FROM ...)` → `to_unixtime(...)`, but the answer never says so explicitly. |

**Average**: (3 + 4 + 2 + 3) / 4 = **3.00**

**Pass**: NO (below 3.5 threshold)

---

## Topic update

**Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling**
- Prior: avg 4.258 across 46 questions
- New running avg: (4.258 × 46 + 3.00) / 47 = (195.868 + 3.00) / 47 = 198.868 / 47 ≈ **4.231** across 47 questions
- Status: PASSED (avg 4.231 ≥ 3.5 threshold)

---

## Notes

The responder partially used the Postgres→Trino datetime translation table that was added to `resources/13-postgres-to-iceberg-ingestion.md` after the iter44 discovery. It correctly named the two highest-value facts (EXTRACT(EPOCH) is invalid in Trino; INTERVAL units go outside quotes, singular). But it failed the "fix my specific queries" framing of the question — the user explicitly pasted two broken queries and asked for help fixing them, and the responder returned a conceptual differences-list instead of two corrected queries.

Three concrete miss patterns:
1. **Did not show the corrected WHERE clause**: `WHERE occurred_at < current_timestamp - INTERVAL '90' DAY`. The example given uses `event_time`, `current_date`, and 30 days — not the user's column, type, or duration.
2. **Did not show the corrected seconds_since_event query**: `SELECT to_unixtime(current_timestamp) - to_unixtime(occurred_at) AS seconds_since_event`. The user wrote a precise transformation; the responder named the replacement function but didn't paste the corrected line.
3. **Did not mention `date_diff('hour', occurred_at, current_timestamp)`** for the explicit "how many hours ago" sub-question. This is the canonical Trino idiom and was named in the expected answer; the responder buried `date_diff` in a parenthetical about `date_add` and never connected it to the user's "hours" requirement.

Also note one minor accuracy issue: the answer says `current_date - INTERVAL '30' DAY` works, which is true, but mixing DATE with a TIMESTAMP column for `occurred_at` would force an implicit cast — the responder should have steered toward `current_timestamp` consistently for a TIMESTAMP comparison.

**Resource gap**: `resources/13-postgres-to-iceberg-ingestion.md` (or a new `resources/19-trino-sql-cheatsheet.md`) needs a worked-example pair showing the exact before/after for these two patterns:
- Before: `WHERE col < NOW() - INTERVAL '90 days'` → After: `WHERE col < current_timestamp - INTERVAL '90' DAY`
- Before: `EXTRACT(epoch FROM a) - EXTRACT(epoch FROM b)` → After: `to_unixtime(a) - to_unixtime(b)` or `date_diff('second', b, a)`
- Add `date_diff('hour'|'day'|'minute', ts1, ts2)` as the preferred idiom for "how long ago" / "duration between" questions, ahead of `to_unixtime` subtraction.

This is the second iteration in a row (iter44 → iter45) where the topic's resource fix landed conceptually but the responder still failed to translate the conceptual rule into the user's actual code. The pattern: when a user pastes broken SQL, the responder needs to paste back fixed SQL — not a list of rules.

---

## Sources

- [Trino Date and time functions and operators (current docs)](https://trino.io/docs/current/functions/datetime.html)
- [Trino Release 467 (6 Dec 2024)](https://trino.io/docs/current/release/release-467.html)
