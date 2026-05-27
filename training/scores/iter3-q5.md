# Iter 3 Q5 — Funnel / cohort / time-series query patterns

## Scores
- Technical accuracy: 5
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 5
- Average: 4.75

## Topic updated
- Topic name: "Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL"
- Questions asked so far for this topic: 0 → 1
- New running avg: 4.75

## Key finding
The answer over-delivered: the user asked specifically for the funnel SQL but got runnable Trino-on-Iceberg SQL for all three reports plus a "why each pattern matters in Trino/Iceberg vs Postgres" summary table. The funnel uses the correct idiom (MIN(event_time) per user, JOIN within 7-day window, COUNT + percentage); the cohort pivots into day_0_30/30_60/60_90 columns matching the product's exact 30/60/90 framing; the WAU query correctly addresses the gap-filling problem with calendar UNNEST(sequence()), CROSS JOIN to tenants, and COALESCE(0). Production-fit callouts (partition pruning on event_date, approx_distinct for large cohorts, MATCH_RECOGNIZE as a next step) all come from `07-analytical-query-patterns.md` and are accurate for Trino 467. No factual errors.

## Resource gap for next iteration
Beginner clarity is the only soft spot — "CTE", "MATCH_RECOGNIZE", "approx_distinct / HyperLogLog", "UNNEST(sequence())", and "partition pruning" appear without inline definitions; a true beginner would need to look each up. More importantly for the topic checklist, this is the FIRST question on this topic and the rubric requires at least 2 different question angles before passing. The next question should probe either (a) the *operational* side — "this funnel query takes 8 minutes, how do I make it faster on our Iceberg table?" (forces partition design, pre-aggregated funnel tables, sort/cluster keys) — or (b) the *correctness* side — "how do I make sure my cohort numbers match marketing's numbers when late-arriving events update last week's data?" (forces a discussion of Iceberg snapshots, time travel, and event-time vs ingestion-time).
