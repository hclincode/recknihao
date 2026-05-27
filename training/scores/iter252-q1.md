# Iter252 Q1 Score

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topic**: Trino federation / cross-source connectors
**Pass/Fail**: PASS (threshold 4.5)

## Strengths

- **Does NOT repeat the iter251 critical error.** The answer explicitly directs the user to run `ANALYZE` on the **PRIMARY** (lines 9, 78) and explains that `pg_statistic` propagates via WAL to the standby. This is the correct mental model and aligns with PostgreSQL docs — hot standbys are strictly read-only and cannot accept `ANALYZE`. See [PostgreSQL Hot Standby docs](https://www.postgresql.org/docs/current/hot-standby.html).
- **Correct identification of `pg_statistic` as a regular heap table replicated via WAL.** Per [PostgreSQL planner statistics docs](https://www.postgresql.org/docs/current/planner-stats.html), `pg_statistic` is a system catalog updated by ANALYZE/VACUUM ANALYZE, and it propagates to standbys via WAL like any other table. (Distinct from the cumulative `pg_stat_*` system which is not replicated — the answer correctly stays on planner stats.)
- **Correct `flush_metadata_cache()` syntax.** `CALL app_pg.system.flush_metadata_cache()` matches the [Trino PostgreSQL connector docs](https://trino.io/docs/current/connector/postgresql.html).
- **Correct `ALTER TABLE ... ALTER COLUMN ... SET STATISTICS 300` syntax** — matches [PostgreSQL ALTER TABLE docs](https://www.postgresql.org/docs/current/sql-altertable.html). Default of 100 and the recommendation to raise to 300 for skewed/high-cardinality is sound.
- **Maps cleanly to the prod stack:** on-prem k8s Trino 467 + Postgres hot standby. Identifies the three break points the user actually faces (replication lag, Trino metadata cache, CBO plan cache) and gives a check-in-order diagnostic.
- **Verification steps are concrete and runnable:** `pg_last_xact_replay_timestamp()` for lag, `SHOW STATS FOR`, then `EXPLAIN` to confirm CBO sees the new estimates. The numbered 4-step diagnostic + TL;DR is exactly the format an on-call engineer needs.
- **`metadata.cache-ttl=60s` recommendation with rationale** (reduce replica query load, flush manually after urgent ANALYZE) is sensible operational guidance.
- **Cross-catalog `EXPLAIN` example joins `iceberg.analytics.events` with `app_pg.public.customers`** — anchors the federation context properly.

## Gaps / Errors

- **Beginner clarity (–1):** Terms like "CBO" (used in headers without expansion in body), "WAL", "histograms for skewed distributions", "NDV", and "hot standby" are dropped without inline plain-English glosses. A SaaS engineer who is "not sure if Trino is caching something" likely also doesn't know what CBO stands for on first read. A one-line "the cost-based optimizer (CBO) — Trino's query planner that picks join order" would help.
- **Minor nuance not addressed:** `hot_standby_feedback` and `max_standby_streaming_delay` are not mentioned as potential causes of the standby being behind or queries being cancelled. Not a blocker for this question, but worth a sentence in a future iteration. See [PostgreSQL Hot Standby docs](https://www.postgresql.org/docs/current/hot-standby.html).
- **`pg_stat_replication` is name-dropped** ("your DBA needs to investigate") but a one-line example query (`SELECT client_addr, state, replay_lag FROM pg_stat_replication`) on the primary would make the diagnostic self-contained for the engineer who doesn't have a DBA on call.
- **No explicit mention of the catalog property file location** beyond `etc/catalog/app_pg.properties` — for on-prem k8s this might live in a ConfigMap; a one-liner would help. Not a major gap.

Sources:
- [PostgreSQL Hot Standby](https://www.postgresql.org/docs/current/hot-standby.html)
- [PostgreSQL Statistics Used by the Planner](https://www.postgresql.org/docs/current/planner-stats.html)
- [PostgreSQL ALTER TABLE](https://www.postgresql.org/docs/current/sql-altertable.html)
- [Trino PostgreSQL connector](https://trino.io/docs/current/connector/postgresql.html)
- [Trino SHOW STATS](https://trino.io/docs/current/sql/show-stats.html)
- [Trino Table statistics](https://trino.io/docs/current/optimizer/statistics.html)
