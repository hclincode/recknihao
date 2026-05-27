# Iter 5 Q1 — When to move off Postgres (2nd angle)

## Scores
- Technical accuracy: 5
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 5
- Average: 4.75

## Topic updated
- Topic name: "When to add an OLAP layer vs staying on the transactional DB"
- Prior: avg 4.0, 1 question → now 2 questions
- New running avg: (4.0 + 4.75) / 2 = 4.375 → status: PASSED (>= 3.5 threshold, 2 questions answered)

## Key finding
This is the tuning-first 2nd-angle question the prior judge feedback explicitly requested, and the responder nailed it. The answer reverses the "buy a new system" framing the engineer brought in, gives a concrete NO-at-5M-rows verdict, lists four quantitative thresholds (>50M rows, >2s after tuning, >3 ad-hoc users, >1 data source), enumerates the exact Postgres tuning ladder that was missing from Iter 2 Q5 (read replica, materialized views, partial indexes, EXPLAIN ANALYZE, pg_partman), and correctly calls ClickHouse a red herring for an on-prem stack that already has Trino + Iceberg + MinIO. The "EXPLAIN ANALYZE first — likely a missing index" closer is exactly the next action the engineer should take. Completeness gap from Iter 2 Q5 (Postgres-tuning half barely addressed) is fully closed.

## Resource gap
Beginner clarity is the only soft spot: "materialized view", "partial index", "read replica", "pg_partman", and "EXPLAIN ANALYZE" are dropped without inline plain-English glosses. Add a one-line "what this is and when you'd reach for it" gloss next to each Postgres-tuning lever in `resources/01-olap-vs-oltp.md` (or wherever the tuning ladder lives), so a SaaS engineer who has never run EXPLAIN ANALYZE can still act on the recommendation. Also worth adding a brief "how to measure the four thresholds" sub-section (e.g., `pg_stat_statements` for slow-query counts, `pg_class.reltuples` for row counts) so the thresholds are operational rather than abstract.
