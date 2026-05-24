# Score: iter51-q2

**Topic**: Analytical query patterns on Iceberg+Trino
**Score**: 4.25 / 5.0

## What the answer got right
- Three-CTE structure (first_events → cohort_sizes → returns) cleanly maps to the three conceptual steps the expected answer calls out (cohort assignment, denominator, retention measurement).
- `date_trunc('week', MIN(occurred_at))` for cohort assignment matches the question's "first event in a given week" framing exactly — a sharper choice than `MIN(date(occurred_at))` from the expected answer.
- `date_diff('day', first_event_at, occurred_at)` is correct Trino syntax (verified against trino.io: `date_diff(unit, ts1, ts2)` returns ts2 - ts1 in `unit`).
- Explicit DATEDIFF-is-MySQL callout matches the expected criterion.
- `BETWEEN 1 AND 7` correctly excludes the signup event itself (day-0) — a nuance the expected answer's `BETWEEN 0 AND 90` does not handle.
- The incomplete-data filter `date_diff('day', c.cohort_week, current_date) >= 90` is present and explained in its own "incomplete-data gotcha" section — directly hits the expected criterion.
- Percentage computation with `ROUND(100.0 * ... / total_users, 1)` answers the question's "what percentage" wording directly (the expected answer stops at retained_users counts).
- Customization section (event filter, cohort granularity, same-day handling) gives the engineer concrete next-step knobs.
- Performance section flags scan-twice cost, mentions partition pruning implicitly via the materialization recommendation, and recommends pre-aggregating to a materialized Iceberg table for daily dashboards — matches the expected "production dashboards, pre-aggregate" criterion.
- Example output block shows the expected shape (cohort_week × pct_retained_7d / 30d / 90d) so the engineer knows what success looks like.
- Anchored to the production stack (`iceberg.analytics.events` catalog naming, materialized Iceberg table recommendation).

## Gaps or errors
- **Distinct-user counting bug in `returns` CTE**: `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` counts event-rows, not distinct users. If a user fires 5 events in the 1–7 day window, they contribute 5 to `returned_7d` while contributing only 1 to `total_users` in the denominator. This makes `pct_retained_7d` exceed 100% for any active cohort and is the most consequential error in the answer. The correct idiom is either `COUNT(DISTINCT CASE WHEN date_diff(...) BETWEEN 1 AND 7 THEN e.user_id END)` or pre-aggregating distinct (user_id, cohort_week, days_since_first) tuples before the SUM(CASE). The expected answer uses `COUNT(DISTINCT e.user_id)` for exactly this reason.
- Partitioning advice is implicit only — the answer mentions "pre-compute into a materialized Iceberg table" but does not name `partition by day(occurred_at)` as the prerequisite for the self-join to prune to relevant date ranges, which the expected answer calls out explicitly.
- "Returned within 90 days" buckets are nested (1–7, 1–30, 1–90) so the 7-day bucket is a subset of the 30-day bucket and the 30-day is a subset of the 90-day. That matches industry convention, but the answer never makes the nesting choice explicit — an engineer comparing to a vendor analytics tool that uses non-overlapping buckets (1–7, 8–30, 31–90) will get confused without this note.
- Minor: `first_event_at` is a timestamp; computing `date_diff('day', first_event_at, occurred_at)` between two timestamps measures whole-day boundaries from the timestamp components, not calendar-day differences. For an event at 23:00 and a return at 01:00 next day, this returns 0, not 1. Casting to `date()` (as the expected answer does) sidesteps this subtle off-by-one.

## Verdict
Strong pedagogical structure and correctly uses `date_diff`, `BETWEEN`, and the incomplete-data filter, but the `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` pattern counts events not distinct users — a bug that will produce retention percentages above 100% on real data and that the engineer will hit immediately when validating against a known cohort.
