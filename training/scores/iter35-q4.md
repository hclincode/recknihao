# Iter35 Q4 Score

**Question**: Incremental Spark job reads from Postgres replica with `WHERE updated_at > :last_watermark`. Observed 6-minute replica lag. 0 new rows shown — rows between old and new watermark were invisible on lagging replica. Permanently lost? What is the lag buffer?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 4.5 |
| **Average** | **4.75** |

**Feedback**: Strong answer on all mechanics. Correctly explains the permanent-miss scenario and why recovery must read from PRIMARY not replica. Lag buffer recipe present. `pg_last_xact_replay_timestamp()` correctly placed on replica connection with the NULL-on-primary gotcha implicit. `safe_upper = min(now_utc(), replay_ts)` cap is a nice improvement over static lag buffer. Silent data loss framing is correct and compelling. Two gaps: (1) detection method for already-missed rows absent — `SELECT max(updated_at)` diff between Iceberg and Postgres primary to identify affected window; (2) 4-hour lag buffer default is 16x more conservative than canonical 15-minute guidance — should tune to observed P99 lag, typically 15-30 minutes.
