# Iter 208 Q2 — Cross-Catalog Consistency: Iceberg Snapshot vs Postgres MVCC

## Answer

The short answer: **No, Trino does not provide cross-catalog transaction isolation. Each catalog reads data independently using its own consistency model.** This is a real concern that deserves careful attention in your federated query design.

Here's what's actually happening in your Postgres + Iceberg federation:

---

### Iceberg's side: Fixed snapshot isolation

When your Trino query scans the Iceberg events table, it reads a **consistent snapshot** — all rows come from a single point-in-time in Iceberg's table history. The query captures a snapshot ID at start time, and every row it reads comes from that immutable snapshot. New events written to Iceberg after the query started are invisible to it.

This is reliable and atomic. The issue is that it gives you only *part* of the consistency picture.

---

### Postgres's side: Live, unrestricted reads

The PostgreSQL connector in Trino (which uses JDBC under the hood) does **not** enforce any snapshot isolation on Postgres itself. When Trino executes your cross-catalog join, it:

1. Scans the Iceberg table against a fixed snapshot (say, captured at 2:00 PM)
2. Sends a JDBC query to fetch matching tenant config rows from the Postgres read replica
3. The JDBC connection **reads whatever rows Postgres returns at the exact moment of the JDBC fetch** — potentially at 2:05 PM or whenever the Postgres side of the join executes

The Postgres read replica uses **READ COMMITTED isolation** by default (the standard Postgres default for new connections). This isolation level means:
- **Visible:** Any rows that were committed to Postgres before the JDBC read started
- **Not visible:** Rows not yet committed, or committed after the read started

---

### The concrete risks you've identified

Your concerns are all real:

**1. Mid-query Postgres updates are visible.** A tenant's plan tier updated at 2:03 PM appears in your results even though the Iceberg data snapshot was taken at 2:00 PM. Your analytics query now contains a mix of events from one point in time and configuration data from a different, later point in time.

**2. Phantom rows.** A new tenant row inserted to Postgres at 2:04 PM can appear in the query results if the Postgres scan hasn't finished yet. You might see Postgres dimension rows for events that don't exist in the Iceberg snapshot yet.

**3. Deleted rows may disappear.** If a tenant row is deleted from Postgres after the query started but before the JDBC fetch completes, you won't see it — even if the corresponding events are in the Iceberg snapshot you're reading.

---

### Why Trino can't fix this

Cross-catalog joins always execute on Trino workers — Postgres doesn't know about Iceberg and Iceberg doesn't know about Postgres. There is no mechanism for Trino to "ask Postgres to freeze to the same snapshot ID as Iceberg" because they use completely different storage engines with incompatible snapshot models.

---

### Practical mitigation strategies

**1. Accept the narrow inconsistency window and design queries carefully.**

If your Postgres read replica lag is low (typically < 5 minutes on a healthy replica), and your tenant config changes are rare, the window where stale/phantom rows cause problems is small. For most analytics dashboards and customer reports, this is acceptable. The key is acknowledging the trade-off exists — do not assume consistency guarantees that aren't there.

**2. Add a lag buffer to the watermark.**

If you're also doing incremental ingestion from Postgres into Iceberg (e.g., ingesting tenant config as a dimension table), your watermark calculation should include a lag buffer — typically 2–3x your observed replica P99 lag. This ensures late-arriving Postgres rows are re-read on the next job run rather than missed.

**3. Materialize critical dimension data into Iceberg.**

For tenant config, plan info, or any dimension that's critical to query correctness, **ingest it into Iceberg as a separate dimension table on a regular cadence (e.g., every 5–15 minutes).** Then join Iceberg-to-Iceberg instead of cross-catalog. This gives you true snapshot isolation on both sides.

```sql
-- Instead of:
SELECT e.*, p.plan_tier
FROM iceberg.analytics.events e
JOIN app_pg.public.plans p ON e.plan_id = p.id

-- Use:
SELECT e.*, p.plan_tier
FROM iceberg.analytics.events e
JOIN iceberg.analytics.plans p ON e.plan_id = p.id
```

The dimension table (`iceberg.analytics.plans`) is ingested from Postgres via Spark every 5 minutes using a simple full refresh (the entire table is small). A cross-catalog join against it now becomes an intra-Iceberg join, and both sides see the same snapshot.

**4. For customer-facing analytics, use a canned reporting pattern.**

Instead of ad-hoc federated queries, materialize the join result into a reporting table each night. Run a batch job that joins the full Iceberg events table against Postgres config at a specific time, writes the denormalized result to a new Iceberg table, and customers query from that table. This pushes the cross-catalog join out of the critical path and lets you validate the results before anyone sees them.

---

### What NOT to do

- Don't assume Postgres rows are "as of the moment your query started."
- Don't rely on row-level consistency for per-customer analytics unless you've explicitly materialized the dimensions into Iceberg.
- Don't lower your replica lag buffer below your observed P99 replica lag — this is where silent data loss happens.

---

### Summary

Trino's federation is practical for low-consistency-risk joins (e.g., a very selective predicate returning a small number of rows, or dimension data that changes infrequently). It's not safe for queries where every row's correctness depends on consistent dimension data that changes frequently.

| Side | Isolation model | What you get |
|---|---|---|
| Iceberg events | Snapshot isolation (query-start snapshot) | Consistent, immutable view of events |
| Postgres dimensions | READ COMMITTED (live JDBC reads) | Latest committed rows at fetch time |
| Cross-catalog | **None** — Trino cannot coordinate | Mixed-time view; mid-query changes visible |

**Recommendation**: Move tenant config and plan info into Iceberg as a materialized dimension table (15-minute refresh). Cross-catalog joins are fine for exploratory queries, but customer-facing analytics should join Iceberg-to-Iceberg for consistent results.
