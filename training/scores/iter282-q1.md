Score: 4.85/5.0 PASS

## Dimension scores
- Technical accuracy (40%): 5/5
- Beginner clarity (25%): 5/5
- Completeness (20%): 5/5
- Actionability (15%): 4/5

## What the answer got right
- Correctly states that pointing Trino at a Postgres read replica requires only the `connection-url` change in the catalog properties file — nothing else (no special "replica mode" flag in Trino).
- Correctly and emphatically states that Trino has **zero awareness of replication lag** — it treats the replica as an ordinary Postgres instance and will silently return stale rows. This is the heart of the question.
- Provides accurate Postgres monitoring queries:
  - `pg_stat_replication` with `write_lag, flush_lag, replay_lag` columns — all are valid columns of type `interval` in the official Postgres docs.
  - `pg_last_wal_receive_lsn()` and `pg_last_wal_replay_lsn()` — both are real Postgres functions (renamed from pg_last_xlog_replay_location in PG 10), returning `pg_lsn` type.
- Correctly explains where to run each query (primary vs replica) — primary for `pg_stat_replication`, replica for the LSN functions.
- Sound, practical guidance on when replica federation is appropriate vs when to stick with the primary (freshness tolerance framing is correct and useful for a SaaS engineer).
- Correctly captures the default Trino PostgreSQL connector `metadata.cache-ttl=0s` (caching disabled), and correctly explains the implication of a higher TTL.
- Fits production environment: catalog properties path (`etc/catalog/app_pg.properties`), on-prem k8s DNS naming convention for the replica host, and emphasis that Trino load belongs on a replica are all aligned with the described stack.
- Format is clean: tabular summary at the end is excellent for a beginner to scan.

## Errors or gaps
- Minor: the answer does not mention that `pg_stat_replication` reports lag columns can revert to NULL on a fully replayed idle system — a real-world gotcha when interpreting "lag = NULL" (could be either "caught up" or "no data flowing"). Not critical for the question.
- Minor: did not mention `pg_is_in_recovery()` as a simple sanity check that you're actually pointed at a replica — would be a useful one-liner for verification.
- Minor: no mention of the PostgreSQL JDBC driver's `targetServerType=preferSecondary` / `loadBalanceHosts` URL options as an alternative pattern (using a list of hosts in the JDBC URL). Not required for the asked question (which presumes pointing at one replica host), but a complete actionability would note it exists.
- The schema caching edge case ("schema older than what fresh would see") is theoretically correct but the framing is slightly unusual — the more common concern with `metadata.cache-ttl > 0` is staleness of the schema on the *primary* propagating slowly to Trino, not of the replica itself. Minor clarity quibble, not an error.

## Verification notes
- **connection-url change only**: Confirmed via trino.io PostgreSQL connector docs — only `connector.name`, `connection-url`, `connection-user`, `connection-password` are the basic required catalog properties. No replica-aware setting exists.
- **No Trino replication lag awareness**: Confirmed — no such feature is documented in any Trino release. The connector is a generic JDBC connector and treats the endpoint opaquely.
- **pg_stat_replication.replay_lag**: Confirmed valid. Official Postgres docs list it as type `interval`, representing elapsed time during committed WALs from primary to standby.
- **pg_last_wal_replay_lsn()**: Confirmed valid. Added in PG 9.0 (originally pg_last_xlog_replay_location, renamed in PG 10). Returns `pg_lsn`.
- **metadata.cache-ttl default**: Confirmed default is 0ms (disabled) for the PostgreSQL connector.

All four required technical facts called out in the rubric verification requirement are accurate. This is a strong PASS well above the 4.5 threshold.
