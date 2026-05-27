# Iter39 Q4 Score

**Question**: MERGE INTO ran 3 times with wrong ON clause (`ON t.event_date = s.event_date`). Now 2-3x expected row counts. Fastest cleanup?
**Topic**: Postgres-to-Iceberg ingestion
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 5 |
| **Average** | **4.25** |

**Feedback**: Strategically correct — snapshot rollback first, comparison table shows tradeoffs clearly, root cause explanation of why date=date causes inserts (not updates) is precise. Engine-syntax-mixing issue: responder uses Trino-style `events$snapshots` path but Spark-style `CALL iceberg.system.*` with named args. In Trino 467 the correct syntax is `ALTER TABLE ... EXECUTE` for procedures. Engineer pasting into Trino during incident hits syntax errors. Also: the "if rollback unavailable, re-read from Postgres + overwritePartitions()" fallback is only implied via the comparison table, never spelled out as a runnable second-resort recipe.
