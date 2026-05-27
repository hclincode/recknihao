# Iter257 Q2 — Postgres Query Isolation in Trino Long-Running Scans

## Answer

Yes, this is actually possible — and you've identified a real consistency problem. Trino does **not** take a point-in-time snapshot of your Postgres data at the moment the query starts. Instead, it reads from Postgres under `READ COMMITTED` isolation, and the way it fetches rows can pick up writes that happen while the query is running.

### How Trino Reads Postgres Data

Trino's PostgreSQL connector uses JDBC under the hood, and each JDBC fetch operates independently. By default, your catalog has `defaultRowFetchSize=1000` set in the JDBC URL. This means:

- For your big table scan over hundreds of millions of rows, Trino doesn't fetch all rows in one statement. Instead, it batches them: 1000 rows per JDBC fetch.
- Each batch of 1000 rows is a **separate statement** with its own `READ COMMITTED` snapshot.
- Under PostgreSQL's `READ COMMITTED` isolation level (the default), each statement sees all committed rows as of the moment *that statement executes*.

So the timeline looks like this:

1. Query starts at T0. Trino begins fetching batch 1 (rows 1–1000) — they're read at T0.
2. Your application writes new rows to Postgres at T5 (those rows commit to the database).
3. Trino fetches batch 2 (rows 1001–2000) at T10 — this statement executes at T10 and **can see the rows written at T5** because they're now committed and `READ COMMITTED` means "see any row committed before this statement starts."
4. Result: rows written between the start of the query and the completion of batch 2 become visible in your results.

### Why This Causes Inconsistent Counts

For aggregate queries like `SELECT COUNT(*) FROM events`, this is a real problem. If your application is continuously writing events to this table, a long-running 8–10 minute scan can easily pick up some of those new events partway through. Your event count will include some rows that were written *after* you kicked off the query, making it appear larger than what was in the database when the query started.

Conversely, rows *deleted* from Postgres after the scan started (but before a later batch reads them) will simply disappear from the results.

### Why Trino Doesn't Offer a Workaround Here

There's no Trino-side knob to change this. Under `READ COMMITTED`, each individual statement sees committed rows as of the moment the statement executes, but successive fetches within the same query can see different states.

Ideally you'd wrap the Postgres read in a `REPEATABLE READ` transaction to get a consistent snapshot, but the Trino JDBC connector does not support wrapping multiple fetches in a single transaction. Each fetch is a separate statement, so you can't use `BEGIN REPEATABLE READ; ... COMMIT;` through the connector.

### Practical Workarounds

**Option 1: Materialize to a staging Iceberg table (recommended for critical analytics)**

Before running your long-running query, create a snapshot of the Postgres table in Iceberg on a fixed schedule (e.g., hourly or every 15 minutes) using a Trino federated INSERT or a dbt micro-batch job. Then run your analytics queries against the Iceberg copy, which will be snapshot-isolated for the entire query duration:

```sql
-- Your long-running query now reads from a stable Iceberg table instead of live Postgres
SELECT COUNT(*) FROM iceberg.staging.events_snapshot WHERE ...;
```

Both sides of any join stay in Iceberg, pinned to the same snapshot at plan time. No mid-query consistency gaps.

**Option 2: Query a read replica with replication lag**

If your Postgres read replica has intentional replication lag (e.g., 5–15 minutes behind the primary), rows written during your query may not have reached the replica yet. This doesn't guarantee consistency, but it narrows the window of newly-written rows that could be picked up.

**Option 3: Schedule long scans during low-write windows**

If your application has predictable low-write periods (e.g., 2–6 AM), run the long-running query then. The probability of inconsistent results drops significantly if new writes are rare during the scan.

**Option 4: Accept the gap for your use case**

If the analytics aren't critical (e.g., you're okay with counts that may be slightly off), you can accept this as a known trade-off of querying a live OLTP table directly. For most analytics queries, the gap is usually small — it's only noticeable on high-write tables scanned over 8+ minutes.

### Summary

Trino reads Postgres with `READ COMMITTED` isolation, one JDBC batch per statement. With `defaultRowFetchSize=1000`, your 8-minute scan over hundreds of millions of rows consists of tens of thousands of independent JDBC statements, each seeing all commits up to that moment. Rows written partway through your scan will be picked up. There is no Trino-side setting to change this behavior. The recommended fix is to materialize the Postgres data to Iceberg first, then run analytics against the stable Iceberg snapshot.
