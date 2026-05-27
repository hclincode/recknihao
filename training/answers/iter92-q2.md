# Iter92 Q2 — Answer

**Question**: Our CDC pipeline was down 6 hours and is now catching up. Will old events land in the right historical partition or dump into today's? Will dashboards show wrong numbers during catch-up?

---

## Answer

## Good news: late events land in the correct historical partition

**Iceberg partitions by the event's `occurred_at` timestamp, not the ingestion time.** When your CDC catches up and replays those 6 hours of missed events, each event still carries its original `occurred_at` timestamp — the time it actually happened in your application. Iceberg uses that original timestamp to determine which partition the row belongs to.

So if an event occurred on May 22 at 2 PM (even though you're ingesting it today on May 23), it lands in May 22's partition — exactly the right historical bucket. The events end up where they belong, not in today's partition.

## Dashboard impact during catch-up

Here's where it gets temporarily confusing for users:

**During the 6-hour outage**: Dashboards showing May 22–23 data are silently incomplete. Events from that window haven't been written to Iceberg yet.

**During catch-up**: The CDC replays missed WAL events in order and writes them to Iceberg. Each write creates a new Iceberg snapshot. A dashboard query running **during the catch-up** will see a partially-replayed state — some of the May 22 events are there, others aren't yet. Different queries at different moments see different levels of completeness.

**After catch-up completes**: All numbers are correct. This typically takes 30–60 minutes for a 6-hour backlog depending on event volume.

**Key behavior**: Each Iceberg query is internally consistent — it reads one atomic snapshot. Users won't see "torn" reads or partial rows within a single query. They will see numbers that grow and change as successive queries hit newer and newer snapshots. This is better than many systems where recovery shows corrupted data, but it's still confusing if users are actively watching dashboards during the window.

## How to handle it more gracefully

**Option 1: Communicate proactively**

Post a brief status note: "CDC outage 6AM–12PM Saturday. Dashboard data for that window will be incomplete and will auto-correct by [ETA]. Don't make business decisions based on May 22–23 numbers until we post an all-clear."

**Option 2: Schedule catch-up for off-hours**

If possible, delay the CDC restart until a low-traffic window (overnight). Users won't be actively watching dashboards, so the gradual number updates won't alarm anyone.

**Option 3: Pause dashboard auto-refresh during catch-up**

Temporarily disable automated dashboard refreshes for the affected date ranges while catch-up is in progress. Re-enable once the CDC has confirmed all events are replayed.

## Critical assumption: verify your watermark column

This whole answer assumes your pipeline uses the event's original `occurred_at` as the partition key — the timestamp of when it happened in your application.

**Verify this now in your Debezium/Spark config:** what timestamp is actually being written to the `occurred_at` column in Iceberg? It should be the original event timestamp from the Postgres row, not the time Debezium read the WAL or the time Spark wrote the file.

If your pipeline is accidentally using the ingestion timestamp (when Debezium processed the event) as the partition value, then yes — all 6 hours of replayed events would land in today's partition and corrupt your historical data. That would be a configuration error to fix.

To check:
```sql
-- Query a few rows and compare occurred_at to ingested_at (if you have both):
SELECT occurred_at, ingested_at
FROM iceberg.analytics.events
WHERE tenant_id = 'your-tenant'
ORDER BY occurred_at DESC LIMIT 10;

-- occurred_at should be the original event time, not near-now
```

## Summary

- Late events land in the **correct historical partition automatically** — no special handling needed on the Iceberg side.
- Dashboards will show **temporarily incomplete numbers** during catch-up, then auto-correct. This is expected behavior.
- Communicate proactively; schedule catch-up off-hours if possible.
- Verify that `occurred_at` in Iceberg is the original event timestamp, not an ingestion timestamp.
