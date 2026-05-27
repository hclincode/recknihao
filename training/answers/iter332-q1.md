# Answer to Q1: offset.flush.interval.ms Delivery Gap and MERGE INTO Protection (Iter 332)

Your understanding of at-least-once delivery is correct in spirit, but the mechanics are more specific — and the duplicate window is time-based, not event-count-based.

## How offset.flush.interval.ms Actually Works

`offset.flush.interval.ms` (default 60,000 ms = 60 seconds) controls how often Kafka Connect commits its offset bookmark — the position in the Postgres WAL that Debezium has processed. Every event processed *between* offset commits will be **re-delivered on restart**, making the duplicate window **directly proportional to the flush interval**.

Concrete example:
- Default `offset.flush.interval.ms = 60000` (60 seconds)
- Connector crashes 30 seconds after its last offset commit → ~30 seconds of events get re-delivered on restart
- At 100 events/sec: ~3,000 duplicates on restart
- At 1 event/sec on a quiet table: just a few

**The worst case is when a crash happens just before the next flush** — you lose nearly the full 60-second window. A burst of 100,000 events in one second followed by 59 seconds of silence still creates only one offset commit window.

## Does MERGE INTO Handle This?

Yes, but only if you do two things correctly:

### 1. Use an LSN guard in the MERGE (required)

```sql
MERGE INTO iceberg.analytics.events t
USING events_delta s
ON t.event_id = s.event_id
WHEN MATCHED AND s.op = 'd' THEN DELETE
WHEN MATCHED AND s.source_lsn > t.source_lsn THEN UPDATE SET *
WHEN NOT MATCHED AND s.op IN ('c', 'r', 'u') THEN INSERT *
```

The `s.source_lsn > t.source_lsn` guard prevents old duplicates from overwriting newer state. Without it: if a row was updated three times (LSN1 → LSN2 → LSN3) and Debezium re-delivers LSN1 after a restart, your MERGE will blindly overwrite the correct LSN3 state with stale LSN1 data. The row converges to the wrong value.

### 2. Deduplicate each micro-batch before the MERGE (required)

Debezium can emit multiple change events for the same primary key within a single Spark micro-batch (e.g., three rapid UPDATEs to the same row). Spark's MERGE INTO does not handle this gracefully — without pre-MERGE dedup, results become nondeterministic on retry.

```python
from pyspark.sql.window import Window
from pyspark.sql.functions import col, row_number

w = Window.partitionBy("event_id").orderBy(col("source_lsn").desc())
events_dedup = (
    events_delta
    .withColumn("_rn", row_number().over(w))
    .filter(col("_rn") == 1)  # keep only the latest event per key
    .drop("_rn")
)
```

Replay the same micro-batch without this step and a different source row may "win," producing a different final Iceberg row. This breaks idempotency.

## Reducing the Duplicate Window

Lower `offset.flush.interval.ms` to reduce the duplicate window:
- 10,000 ms (10s) → max ~10 seconds of re-delivered events on restart
- Tradeoff: higher Kafka write load (offset topic written more frequently)

## Summary

1. **The duplicate window is `offset.flush.interval.ms`** — time-based, not event-count-based. Default = 60 seconds worst-case.
2. **MERGE INTO does protect you**, but only with the LSN guard (`s.source_lsn > t.source_lsn`) and pre-MERGE micro-batch dedup via `ROW_NUMBER()`.
3. **Without storing `source_lsn`**, stale duplicates from restart can silently overwrite correct newer values — a real production risk.
4. **Store `source_lsn` as a BIGINT column** in your Iceberg table (8 bytes per row) — cheap insurance that makes the entire pipeline idempotent.

**Resources cited:** `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
