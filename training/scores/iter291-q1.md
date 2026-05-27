# Iter291 Q1 Score

**Question**: Which date/time functions on a TIMESTAMP(6) partition column (partitioned by day(event_at)) are safe in Trino 467 vs which ones cause a full table scan?

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | Core unwrap-rule claims are correct (PR #13567 for CAST AS DATE, PR #14011 for date_trunc), and the safe/unsafe classification of year/month/day_of_week/hour matches official Trino blog and source. However, the `unwrap_casts` session property claim is FACTUALLY WRONG for Trino 467 — that session property and the `optimizer.unwrap-casts` config were REMOVED in Release 364 (Nov 2021, PR #9550). Since Trino 467 is several years later, an engineer trying `SET SESSION unwrap_casts = false` to test will get an error. Other claims (TWTZ caveat, EXPLAIN constraint output) are accurate. |
| Beginner clarity | 5 | Excellent table at the top, clear "Category 1 / Category 2" mental model, monotonic vs non-monotonic explanation is intuitive, fix examples are concrete. A Postgres engineer can follow this easily. |
| Practical applicability | 5 | Engineer can immediately rewrite queries. Concrete rewrite examples for each broken pattern, EXPLAIN verification snippet with what-to-look-for guidance, EXPLAIN ANALYZE bytes-measurement tip, and a clear "always prefer raw TIMESTAMP range" production recommendation. The day_of_week precompute pattern is a nice production touch. |
| Completeness | 5 | Covers all common patterns: CAST AS DATE, DATE(), date_trunc, year/month/day_of_week/hour, interval arithmetic. Mentions version-dependence, TWTZ caveat, EXPLAIN verification, and provides rewrites. The unwrap_casts caveat is wrong but represents an extra (not missing) data point — completeness is not docked, but accuracy is. |
| **Average** | **4.75** | **PASS** |

## Verification notes (WebSearch against trino.io and trinodb/trino)

1. CAST/DATE unwrap (PR #13567) — confirmed by trino.io date-predicates blog and issue context. Correct.
2. date_trunc unwrap (PR #14011) — confirmed; rule name UnwrapDateTruncInComparison authored by findepi. Correct.
3. year/month/day_of_week/hour — confirmed no unwrap rule exists for these in Trino source; full scan claim is correct (and matches the iter290 correction).
4. EXPLAIN TableScan `constraint on [event_at]` — pattern is plausible and consistent with Trino EXPLAIN output for Iceberg pushdown. Acceptable.
5. `unwrap_casts` session property — INCORRECT for Trino 467. Per PR #9550 (merged into Release 364, Nov 2021), both the session property and the `optimizer.unwrap-casts` config option were removed because the feature became always-on. An engineer following this advice on Trino 467 will get "Session property 'unwrap_casts' does not exist."
6. TIMESTAMP WITH TIME ZONE edge case — confirmed; UnwrapDateTruncInComparison does NOT handle TWTZ because date_trunc operates on local time while TWTZ stored in UTC. Accurate caveat.

## Pass/Fail

**PASS** (avg 4.75, well above 3.5 threshold).

## What to fix

The single factual error (`unwrap_casts` session property) is minor relative to the rest of the answer but should be corrected in resources to prevent it from recurring. Replace with: "These rules are always on in Trino 467 and cannot be disabled via session property — the `unwrap_casts` toggle was removed in Release 364 because the optimization became stable."

This is an excellent recovery from iter290 Q1 (3.00 FAIL) on the same topic. The teacher correctly addressed the core date_trunc unwrap rule gap. One residual stale claim about a removed session property remains — easy to fix.
