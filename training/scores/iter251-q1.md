# Iter251 Q1 Score

| Dimension | Score |
|---|---|
| Technical accuracy | 1 |
| Beginner clarity | 4 |
| Practical applicability | 1 |
| Completeness | 2 |
| **Average** | **2.0** |

**Topic**: Trino federation / cross-source connectors
**Pass/Fail**: FAIL (threshold 4.5)

## Strengths
- Correctly identifies the symptom (`SHOW STATS FOR` returning stale numbers) and frames it as a legitimate two-part problem: where stats live, and whether Trino caches them.
- The `CALL app_pg.system.flush_metadata_cache()` procedure name and catalog-qualified syntax are correct; the metadata-cache section accurately notes the `metadata.cache-ttl` default of `0s` means caching is off when unset (confirmed against Trino 481 PostgreSQL connector docs).
- Reasonable structure: root-cause hypothesis, fix, verification step, ongoing maintenance — pedagogically clean even though the substance is wrong.
- `SHOW STATS FOR` column names (`distinct_values_count`, `nulls_fraction`) are real and correctly cited.

## Gaps / Errors
- **Critical factual error (the entire core thesis is wrong).** The answer instructs the user to "run `ANALYZE` directly on the read replica." This is impossible. Per PostgreSQL official docs (Hot Standby, Section 26.4.3), `ANALYZE`, `VACUUM`, `CLUSTER`, `REINDEX` are explicitly listed as **maintenance commands that are not accepted during recovery mode**. A hot standby is read-only; `ANALYZE` against it will fail with a "cannot execute ANALYZE in a read-only transaction" error. The `psql -c "ANALYZE;"` cron job recommended in the maintenance section will never succeed. The user will lose hours debugging this.
  - Source: https://www.postgresql.org/docs/current/hot-standby.html — "you cannot create additional indexes that exist solely on the standby, nor statistics that exist solely on the standby. If these administration commands are needed, they should be executed on the primary, and eventually those changes will propagate to the standby."
- **Self-contradiction in the diagnosis.** The answer simultaneously claims (a) "Streaming replication DOES replicate `pg_statistic` rows via WAL" and (b) "the replica's catalog is stale because autovacuum is disabled on the replica." If (a) is true (and it is — `pg_statistic` is a regular heap relation replicated via WAL), then autovacuum on the replica is irrelevant; the replica's `pg_statistic` is always a byte-for-byte copy of the primary's. The user's stale stats are not caused by replica-side autovacuum at all.
- **The actual root cause is never explored.** Realistic causes the answer should have considered:
  1. **Trino metadata cache** — most likely culprit given the symptom of "stats from weeks ago"; should have been the *primary* hypothesis, not a sidebar.
  2. **ANALYZE on the primary did not actually rewrite `pg_statistic`** — e.g., default sample size is too small for a wide/large table, or user ran `ANALYZE` without table name and it skipped non-default schemas, or autovacuum on the primary hadn't kicked in due to `autovacuum_analyze_scale_factor`.
  3. **Replication lag or stuck WAL replay** — check `pg_stat_replication.replay_lag` on primary and `pg_last_wal_replay_lsn()` on replica.
  4. **Trino is connected to a different DB/schema than the user thinks** — verify catalog connection string.
- **Practical applicability is broken for the prod stack.** The cron job in "Ongoing maintenance" will fail every night on the replica. There is no working remediation path in this answer for a Trino 467 + Postgres replica setup.
- **Verification step is also wrong.** Telling the user to run `SELECT * FROM pg_stats WHERE tablename='customers'` on the replica and expect "non-NULL values after ANALYZE" is misleading — the values will only appear after ANALYZE runs on the **primary** and WAL is replayed; the replica-side `ANALYZE` recommendation can never produce that result.
- **Misses the federation-specific guidance** that would have made this a strong answer: when statistics maintenance is this fragile on a federated source, the standard recommendation is to either (a) point Trino at the primary for planning purposes if load allows, or (b) ingest the Postgres table into Iceberg on a schedule (the prod stack supports this) so Trino has first-class Iceberg statistics with no replica/cache fragility.

**Recommendation to teacher**: The federation resource (or a new `resources/16-trino-postgres-connector-stats.md`) needs an explicit subsection titled something like "ANALYZE on a Postgres replica — what actually works." It must state plainly: (1) `ANALYZE` cannot run on a hot standby, full stop; (2) `pg_statistic` IS replicated via WAL, so running `ANALYZE` on the primary is the *correct* place — the user did the right thing; (3) when SHOW STATS is still stale, the debugging order is Trino metadata cache -> replication lag -> primary-side ANALYZE sampling/threshold -> wrong-catalog connection; (4) the `flush_metadata_cache` procedure name and that it operates per-catalog with no table argument. This is the second time (after iter158 Q1) that a federation answer has invented a remediation that cannot run in the user's environment.
