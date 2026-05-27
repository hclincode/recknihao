# Iter 214 Q2 — Iceberg Time Travel in Cross-Catalog Context: What Postgres Sees

## Answer

## What happens to Postgres in a time-travel join with Iceberg

Your situation is expected behavior, not a bug. When you use Iceberg's `FOR TIMESTAMP AS OF` (or `FOR SYSTEM_TIME AS OF` in Trino syntax) in a cross-catalog join with Postgres, the two sides operate under **completely different consistency models with no coordination between them**.

### What `FOR TIMESTAMP AS OF` does on the Iceberg side

`FOR TIMESTAMP AS OF` pins your Iceberg side to a specific historical snapshot. Trino captures that snapshot ID at query planning time and reads from it for the entire query duration. Concurrent writes to Iceberg do not affect what you see — this is Iceberg's **snapshot isolation guarantee**.

### What Postgres sees: current live data only

The Postgres side, by contrast, always reads **current live data** at the moment of each fetch. Postgres uses its default `READ COMMITTED` isolation level (Trino has no knob to override this). This means:

- **Every JDBC fetch from Postgres returns whatever rows currently exist** in your database — not a historical snapshot.
- If customer records existed 90 days ago but have since been deleted from Postgres, those rows will not appear in your query results, even though they were present when you set the Iceberg timestamp.
- Similarly, rows updated in Postgres after your query started may appear with their new values, not their old values from 90 days ago.

### Why this is expected, not a bug

Trino has **no protocol to coordinate snapshots across catalogs**. The Iceberg snapshot and the Postgres MVCC state are not synchronized in any way. You cannot ask Trino to "freeze both sides at time T" — it simply doesn't exist as a feature in Trino 467.

The concrete risks in your scenario:

- **Vanished deletes**: Customer records that existed 90 days ago are now deleted from Postgres. Your Iceberg events table still refers to them (because you pinned Iceberg to the past), but Postgres cannot find them on the join. Depending on your join type, you may lose those event rows in your results.
- **Updated rows**: A customer metadata field (e.g., `plan_tier`) changed between now and 90 days ago. Your Iceberg side sees events from 90 days ago, but the `plan_tier` value comes from today's Postgres row, not the historical value.

### Mitigation options for historical reporting

Choose based on your consistency requirements:

| Situation | Mitigation |
|---|---|
| **Consistency is critical; you need reproducible historical reports** | **Materialize the Postgres dimension into Iceberg on a regular cadence** (5–15 minute micro-batch via Spark or dbt). Both sides of the join now live in Iceberg, both pin to snapshots at plan time — full snapshot isolation across the whole query. This is the only way to guarantee historical consistency. |
| **You need to reproduce a specific historical report exactly as it appeared on a given date** | Create a **nightly materialized join result table in Iceberg** on a fixed schedule (e.g., every night at 02:00 UTC). Store the complete joined result. When you need a historical report, query that pre-computed snapshot instead of computing it live. Single snapshot, no cross-catalog gap. |
| **You can accept narrow inconsistency windows** | Use `FOR SYSTEM_TIME AS OF (CURRENT_TIMESTAMP - INTERVAL '15' MINUTE)` on the Iceberg side. This gives Postgres time to settle before the Iceberg snapshot, reducing (but not eliminating) the timing skew. **Important**: This does NOT pin the Postgres side — it still reads current live data. This only works if your Postgres dimension changes infrequently and your tolerance for mismatches is high. |

### What the resources say

From the Trino federation guide:

> **Iceberg `FOR SYSTEM_TIME AS OF` only controls which Iceberg snapshot is used. It does NOT pin the Postgres side — every fetch from the Postgres table still reads at JDBC fetch time under `READ COMMITTED`. The Postgres reads are not deferred or rewound.** So this technique reduces the inconsistency surface area but does not provide cross-catalog snapshot isolation. For full isolation, the only answer is "both tables in Iceberg."

The mismatches you're seeing (customer records that existed 90 days ago now missing) are a direct consequence of querying a historical Iceberg snapshot against a live Postgres table. This is fundamentally unsolvable without materializing the Postgres data into Iceberg on a predictable schedule.
