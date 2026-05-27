# Iter144 Q2 — Judge Score

**Question topic**: Measuring Debezium CDC lag (Postgres → Kafka → Spark → Iceberg), root causes, and alerting.

**Production stack**: on-prem k8s, Trino 467, Iceberg 1.5.2, MinIO, Hive Metastore, Debezium 2.x, Spark Structured Streaming.

---

## Score Breakdown

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Replication-slot lag formula, `active` flag, CoW MERGE bottleneck, replica-identity-full overhead all correct. One factual error on `ts_ms` semantics (envelope vs source) that propagates into the Spark code sample. |
| Clarity (no OLAP background) | 4.5 | Three-layer model (Debezium / Kafka / Spark) is exactly the framing a beginner needs. Each layer has a concrete query/command and a threshold. WAL, LSN, MERGE, CoW/MoR are all introduced in context. |
| Practical usefulness | 4.0 | Copy-pasteable SQL, kubectl, kafka-consumer-groups, Prometheus alerts. Diagnostic checklist and catch-up runbook are directly actionable. Knocked because the Spark `ts_ms` snippet measures the wrong field and the catch-up watch-loop will produce mostly-noisy psql output (no `-t -A` flags). |
| Completeness | 4.5 | Covers detection, causes, alerts, catch-up, and prevention. Surfacing data-freshness on the dashboard is a nice prevention point. Missing: brief note on `connect-offsets` (where Debezium stores its source offset, distinct from `__consumer_offsets`), and no mention of `pg_stat_replication` for the streaming-replication view. |

**Average = (3.5 + 4.5 + 4.0 + 4.5) / 4 = 4.125**

**Verdict: FAIL** (threshold 4.5)

---

## What Was Verified Correct (via WebSearch)

1. **`confirmed_flush_lsn` in `pg_replication_slots`** — correct metric for what Debezium has acknowledged. Confirmed against Gunnar Morling's authoritative post and Debezium operational docs. `confirmed_flush_lsn` is the LSN the consumer has confirmed; restart_lsn is the older "must-retain" LSN.
2. **`pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)`** — correct WAL-lag-in-bytes formula. Matches the canonical monitoring query (`pg_size_pretty(pg_current_wal_lsn() - confirmed_flush_lsn)`) used in Debezium operational guides.
3. **`active=false` warning** — correct. When the slot is inactive Postgres retains WAL indefinitely until the slot is dropped or the consumer reconnects; this is the well-known "Debezium-killed-Postgres-disk" failure mode.
4. **CoW MERGE bottleneck on Iceberg 1.5.2** — correct. Iceberg's default `write.merge.mode` was copy-on-write through 1.5.x; switching to merge-on-read does generate position-delete files instead of rewriting Parquet, at the cost of read amplification until compaction.
5. **Catch-up guidance (don't skip events, don't blindly restart Debezium)** — correct. `snapshot.mode=initial` on a freshly-recreated slot can trigger a full re-snapshot.
6. **Kafka consumer group LAG column** — correct interpretation.

---

## Errors / Gaps Found

### 1. (Accuracy) `ts_ms` is the connector processing time, NOT the Postgres commit time

The answer says:
> each Debezium event contains a `ts_ms` field — the timestamp (in milliseconds) when Postgres committed the change

and the Spark snippet reads `col("envelope.ts_ms")`.

Per the Debezium PostgreSQL connector docs:
- **`payload.ts_ms` (envelope-level)** = "time at which the connector processed the event" (JVM clock on the Kafka Connect worker).
- **`source.ts_ms`** = the transaction commit timestamp from the database (taken from the BEGIN message).

For CDC-lag measurement specifically, the correct expression is `source.ts_ms` (or `before/after.source.ts_ms` depending on schema layout) — **not** envelope `ts_ms`. Using envelope `ts_ms` measures only the time between Spark reading the event and "now"; it hides the Debezium-side WAL-read delay, which is precisely the lag the engineer is trying to detect. This is a real correctness bug an engineer would ship by copy-paste.

The Spark snippet should be approximately:
```python
(current_timestamp().cast("long") - col("source.ts_ms") / 1000).alias("age_s")
```
(or whatever path the Spark schema exposes for the source block — typically `value.source.ts_ms` when the envelope is unwrapped).

### 2. (Completeness) Missing mention of `connect-offsets` for Debezium source offsets

The rubric flagged this as something to verify. The answer never distinguishes Debezium's source-offset storage (Kafka Connect's `connect-offsets` topic) from sink-side `__consumer_offsets` (used by Spark's Kafka consumer group). Engineers debugging "where does Debezium remember its place" reach for the wrong topic without this distinction. Not a wrong claim — just a missing one.

### 3. (Accuracy, minor) MoR TBLPROPERTIES are not strictly "Spark SQL only"

> ```sql
> -- Spark SQL only — sets write mode on the table
> ```

`ALTER TABLE ... SET TBLPROPERTIES` is Spark syntax; the equivalent in Trino is `ALTER TABLE ... SET PROPERTIES`. More importantly: Trino's Iceberg writes are **always** merge-on-read regardless of the property value (the property is only consulted by the Iceberg Spark writer). The label is operationally fine — engineers writing CDC merges from Spark are the audience — but technically the property exists for all engines; only the enforcement is Spark-side.

A more precise label would be: "These properties only affect Spark writers; Trino writes are always MoR regardless."

### 4. (Practical, minor) Catch-up monitoring loop won't print cleanly

```bash
psql -h postgres -c "SELECT lag_gb FROM pg_replication_slots WHERE slot_name='debezium_slot';" | tail -2
```
- The inner query references a column `lag_gb` that doesn't exist on `pg_replication_slots` directly (it was defined in the earlier query as a derived column inside a subquery). Without the `pg_wal_lsn_diff(...)` expression this `SELECT lag_gb` will error.
- Suggest `psql -tA -h postgres -c "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) FROM pg_replication_slots WHERE slot_name='debezium_slot';"` for clean machine-readable output.

### 5. (Completeness, optional) No mention of `pg_stat_replication`

For physical-replication-style visibility (sent_lsn, write_lsn, flush_lsn, replay_lsn per connected walsender) `pg_stat_replication` complements the slot view, and is the right place to see whether Debezium is actively streaming RIGHT NOW vs. just last-acknowledged-checkpoint. Worth one sentence.

---

## Resource Fix Recommendations

Update `resources/13-postgres-to-iceberg-ingestion.md` (or the dedicated CDC monitoring section if one exists):

1. **Fix the `ts_ms` semantics**: explicitly contrast `source.ts_ms` (Postgres commit) vs `payload.ts_ms` (connector processing). Provide the corrected Spark `foreachBatch` snippet using `source.ts_ms`. Add a callout: "If you want end-to-end CDC lag, use `source.ts_ms`. If you only want Spark-side processing lag, use `payload.ts_ms`. They are different."
2. **Add a `connect-offsets` vs `__consumer_offsets` note** in the operations section so engineers can debug Debezium offset state vs. Spark consumer state.
3. **Refine the MoR property labeling**: state that the properties are honored by Spark and that Trino writes are MoR by default regardless.
4. **Add `pg_stat_replication`** alongside `pg_replication_slots` as a complementary lag/health view (walsender state, sent/flush/replay LSN per active connection).
5. **Tighten the catch-up monitor shell snippet** so the inline SQL is self-contained and produces clean tab-friendly output.

---

## Verdict

**FAIL** — avg 4.125 < 4.5. The answer is strong on structure, beginner clarity, and operational shape, but the `ts_ms` mislabeling is a real bug that defeats the very metric the engineer asked for (how late are events vs commit time), and a couple of smaller precision issues compound it. Fix the `ts_ms` semantics and the catch-up snippet and this answer comfortably clears the bar.
