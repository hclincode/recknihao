# Iter102 Q1 — Answer

**Question**: Our Debezium connector that streams Postgres changes into Iceberg crashed and was down for about two hours before anyone noticed. We restarted it and it seems to be running again, but I'm not confident it picked up right where it left off. How do I verify whether any events were missed during that gap, and if some were, how do I go back and fill them in? I don't want to do a full re-sync of the entire table because it's huge.

---

## Answer

Your question touches on the core reliability mechanism of Debezium CDC — how it tracks its position in the Postgres write-ahead log (WAL) and how to recover after an outage without losing data or re-processing everything. Debezium has built-in safeguards for this scenario, but you need to understand how they work and verify they did their job.

### How Debezium's offset and replication slot mechanism works

When Debezium's PostgreSQL connector runs, two things track your position in the WAL:

1. **The Kafka Connect offset topic (`_debezium_connect_offsets`)**: Where Debezium records "which WAL position have I processed and written to Kafka?" On restart, Debezium reads this topic, finds the last committed LSN (log sequence number), and resumes from there.

2. **The Postgres replication slot (e.g., `debezium_slot`)**: A bookmark on the Postgres side saying "the WAL up to this LSN has been processed." Postgres retains every WAL segment from the slot's position forward. When Debezium crashes, the slot persists — Postgres doesn't discard WAL, it just stops seeing progress confirmations.

**What "picked up where it left off" actually means:** If the Kafka offset topic is intact, Debezium resumes from the last committed Kafka offset. If the offset topic is gone, it falls back to the replication slot's `confirmed_flush_lsn`. In both cases, events that Debezium had already pushed to Kafka but that your Spark consumer hadn't yet written to Iceberg are the most likely source of missed data.

### Step 1: Confirm the replication slot is healthy

Log into your Postgres primary:

```sql
SELECT slot_name, active, confirmed_flush_lsn, restart_lsn, wal_status
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

- `active = true` — Debezium is connected and consuming. `false` after restart means the connection didn't re-establish.
- `wal_status = 'reserved'` or `'extended'` — healthy. `wal_status = 'lost'` — the slot was invalidated and WAL was discarded. Data loss likely.
- `confirmed_flush_lsn` — should be recent. If it's from days ago, progress wasn't being flushed before the crash.

### Step 2: Check the Kafka offset topic

```bash
kubectl exec -it <kafka-pod> -- kafka-topics.sh --bootstrap-server localhost:9092 \
    --describe --topic _debezium_connect_offsets
```

If this topic doesn't exist or is empty, Debezium lost its offset reference and needs recovery mode (see below).

### Step 3: Compare Iceberg against Postgres to detect the gap

```python
# Get the latest event timestamp in Iceberg
iceberg_max_ts = spark.sql("""
    SELECT COALESCE(max(event_ts), CAST('1970-01-01' AS TIMESTAMP)) AS ts
    FROM iceberg.analytics.events
""").collect()[0].ts

# Compare against Postgres PRIMARY (not replica — need ground truth)
pg_max_ts = spark.read.jdbc(
    url="jdbc:postgresql://pg-primary:5432/app",
    table="(SELECT max(event_ts) AS ts FROM events) t",
    properties=PG_PROPS,
).collect()[0].ts

gap_minutes = (pg_max_ts - iceberg_max_ts).total_seconds() / 60
print(f"Iceberg is behind Postgres by {gap_minutes:.1f} minutes")

if gap_minutes > 5:  # more than expected lag
    print("GAP DETECTED — backfill needed")
else:
    print("Within normal lag — connector will catch up automatically")
```

**Interpreting results:**
- Gap within normal lag buffer (15-30 min): normal lag, the running connector will catch up. No action needed.
- Gap of ~2 hours: matches your outage window, backfill needed.
- `wal_status = 'lost'`: slot invalidated, follow the slot recovery path below.

### Backfill the missed window (targeted, not full resync)

Once you've confirmed the gap, re-read only the missed time range from Postgres and merge it idempotently into Iceberg:

```python
missed_start = iceberg_max_ts  # last timestamp Iceberg has
missed_end = "2026-05-25 16:30:00"  # when the connector came back online

missed_df = spark.read.jdbc(
    url="jdbc:postgresql://pg-primary:5432/app",
    table=(
        f"(SELECT * FROM events "
        f" WHERE event_ts > '{missed_start}' "
        f"   AND event_ts <= '{missed_end}') t"
    ),
    properties=PG_PROPS,
)

print(f"Found {missed_df.count()} rows in the missed window")

# Use MERGE INTO (not append) for idempotency
missed_df.createOrReplaceTempView("events_recovery")
spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_recovery s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
print("Backfill complete.")
```

**Why MERGE INTO instead of append:** MERGE with `event_id` as the join key handles any overlap between what Debezium already streamed and what the backfill pulls — duplicate rows become idempotent updates, not double-counted inserts.

Read from the **Postgres PRIMARY** (not a replica) to get ground truth — replicas may still be catching up.

### Special case: replication slot invalidated (`wal_status = 'lost'`)

A two-hour outage is usually short enough that the slot survives — Postgres retains WAL from the slot's position. But if the slot shows `wal_status = 'lost'`, WAL was discarded and Debezium cannot resume:

1. Drop the invalidated slot:
   ```sql
   SELECT pg_drop_replication_slot('debezium_slot');
   ```

2. Recreate it:
   ```sql
   SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
   ```

3. Set `snapshot.mode: recovery` on the connector (one-time) — this tells Debezium to re-read the slot position from the new slot's starting point and resume CDC without full snapshot. Change back to `no_data` after recovery completes.

4. Then run the targeted backfill above to fill the pre-invalidation window.

### Prevention: add `source_lsn` to Iceberg for precise gap detection

For future outages, add a column that tracks Debezium's WAL position:

```sql
ALTER TABLE iceberg.analytics.events ADD COLUMN source_lsn VARCHAR;
```

Then gap detection becomes a single definitive query:

```sql
SELECT max(source_lsn) FROM iceberg.analytics.events;
-- Compare directly to confirmed_flush_lsn in pg_replication_slots
```

No timestamp approximation needed — LSN-based comparison is exact.

### Post-backfill compaction

After the backfill, the affected partitions have many small files. Run compaction on the affected date range:

```sql
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.events',
  where => 'event_ts >= DATE ''2026-05-25'' AND event_ts < DATE ''2026-05-26''',
  options => map('target-file-size-bytes', '268435456', 'min-input-files', '5')
);
```

### Summary

1. **Check slot health** — `pg_replication_slots` for `active=true` and `wal_status != 'lost'`.
2. **Detect the gap** — compare `max(event_ts)` in Iceberg vs. Postgres PRIMARY.
3. **Backfill if needed** — time-scoped MERGE INTO from Postgres PRIMARY, idempotent on event_id.
4. **Compact** — `rewrite_data_files` on the affected date partition.
5. **Prevent next time** — add `source_lsn` column to Iceberg for definitive future gap detection.

No full table resync needed for a two-hour gap.
