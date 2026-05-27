# Judge — Iter 105 Q2

**Topic**: Postgres-to-Iceberg ingestion
**Score**: 4.88 / 5 (Tech 4.9, Clarity 4.9, Practical 5.0, Completeness 4.75)

## Verdict
Excellent answer that nails the right architectural fix (read from replica) and proactively covers the three production gotchas a beginner would otherwise hit: replica lag (silent data loss), WAL-apply conflicts (job cancellation), and connection-budget sizing (starving Trino/app). The advice is actionable, with complete copy-paste code, accurate Postgres internals, and correct trade-off framing on `hot_standby_feedback` (primary bloat). The misdiagnosis correction at the top (replica vs. tuning the primary scan) is exactly the right framing for a SaaS engineer who guessed "sequential scan."

## What was verified correct (via WebSearch)
- `pg_last_xact_replay_timestamp()` returns NULL on the primary because the function only meaningfully reports during recovery — answer correctly warns the engineer to run this against the REPLICA URL. Confirmed against pgpedia/postgresql.org sources.
- `max_standby_streaming_delay` default of **30 seconds** is accurate (postgresql.org current docs).
- The "canceling statement due to conflict with recovery" error and the "User query might have needed to see row versions that must be removed" detail line are quoted verbatim from real Postgres behavior. Cause description (VACUUM on primary → WAL apply on replica needs a lock that conflicts with open read → after `max_standby_streaming_delay` the replica cancels the query) is technically accurate.
- `hot_standby_feedback = on` does cause primary bloat / dead-tuple retention / WAL retention pressure. The warning to revert it after the job (or monitor weekly if left on) reflects current production reality (EDB, Cybertec, Michal Drozd posts all confirm this trade-off).
- `ALTER SYSTEM SET ... ; SELECT pg_reload_conf();` is the correct pattern for changing `hot_standby_feedback` (context: sighup, restart not required). Confirmed against postgresql.org ALTER SYSTEM docs.
- `statement_timeout` and `idle_in_transaction_session_timeout` are valid Postgres parameters passable via JDBC `options=-c ...=...` syntax. Confirmed against pgjdbc docs and Metabase JDBC threads.
- Spark JDBC `pushDownPredicate`, `fetchsize`, partitioning options (`column`, `lowerBound`, `upperBound`, `numPartitions`) all correctly used. `fetchsize=10000` is a reasonable starting recommendation.
- `max_standby_streaming_delay = -1` for unlimited wait is correct alternative when `hot_standby_feedback` cannot be enabled.

## Errors or gaps
- `pg_last_xact_replay_timestamp()` returns a `timestamp with time zone`. The expression `replay_ts - LAG_BUFFER` (with `LAG_BUFFER = timedelta(...)`) is Python-side arithmetic that works only if `replay_ts` was actually returned as a naive Python `datetime` (it usually is via PG JDBC + Spark — converted to UTC). Worth a one-line tz reminder; not a real correctness bug for most users.
- Minor: `safe_upper = min(datetime.utcnow(), replay_ts - LAG_BUFFER)` is unusual — the engineer's data on the replica cannot be newer than `replay_ts`, so the `datetime.utcnow()` comparison is essentially a no-op (replay_ts will always be older than now on any healthy replica). Harmless but slightly noisy.
- The connection-budget table mixes "active connections to reserve" with categories that may double-count (autovacuum/WAL sender are typically counted separately from `max_connections` headroom or are bounded by `superuser_reserved_connections` / `autovacuum_max_workers`). The numbers are a reasonable starting point but a footnote about `superuser_reserved_connections` would tighten it.
- No mention of using PgBouncer or a connection-pool intermediary to insulate the budget — common on-prem setup; minor gap.
- Does not mention the on-prem k8s constraint from `prod_info.md`, but the advice is fully compatible with the prod stack (Postgres replica + Spark in k8s + Iceberg on MinIO via Hive Metastore). No conflict.

## Resource fix recommendations
- LOW: in `resources/13-postgres-to-iceberg-ingestion.md`, add a one-line tz note for `pg_last_xact_replay_timestamp()` (returns `timestamptz` — handle UTC conversion when comparing to `datetime.utcnow()`).
- LOW: clarify the connection-budget table — distinguish `max_connections` from `superuser_reserved_connections` and note that autovacuum workers come from `autovacuum_max_workers`, not the general pool.
- LOW: mention PgBouncer as an alternative when the replica's `max_connections` cannot be raised.

## Updated topic state
- Postgres-to-Iceberg ingestion: 90 questions / running avg (4.481 × 89 + 4.88) / 90 = **4.485**
