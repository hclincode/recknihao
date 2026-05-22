# Answer: Why does a GROUP BY / COUNT query slow down so much worse than a point-lookup as rows grow?

> Note: prod_info.md does not have the production stack filled in. This answer assumes a generic Postgres setup. If your cloud provider, data scale, or other constraints are specified later, revisit this answer to check whether specific tooling recommendations change.

---

## The short answer

The two queries you are comparing do fundamentally different amounts of work. "Fetch settings for user 123" is a **point lookup** — it asks Postgres to find one row. "Count every event grouped by user over 90 days" is a **full table scan with aggregation** — it asks Postgres to read and process every qualifying row. As your table grows, the first query's cost stays nearly flat; the second query's cost grows in direct proportion to the number of rows.

---

## Why point lookups barely slow down

When you run:

```sql
SELECT * FROM settings WHERE user_id = 123;
```

Postgres uses an index on `user_id` to jump straight to the right row (or small set of rows). The work is: traverse a B-tree index (a few page reads, logarithmic in table size), read the single matching row. Going from 1 million to 10 million rows adds maybe one extra level to the B-tree. The query still finishes in milliseconds. The index is doing its job.

---

## Why the aggregation query scales so badly

When you run:

```sql
SELECT user_id, COUNT(*)
FROM events
WHERE created_at >= NOW() - INTERVAL '90 days'
GROUP BY user_id;
```

Postgres has to:

1. **Scan every row** in the 90-day window to evaluate the `WHERE` clause. If 80% of your 10 million rows fall in that window, it reads 8 million rows. There is no shortcut — to count events per user, it must see every event.
2. **Read the entire row** from disk for each of those rows — even though you only care about `user_id` and `created_at`. Postgres stores data in row-oriented format: every column for a row is packed together. To read `user_id`, Postgres pulls the entire row off disk, including every other column you never asked for.
3. **Aggregate in memory** across all those rows to build the per-user counts.
4. **Compete for disk I/O** with every other query your application is running at the same time (signups, billing, user sessions). This is the same production database, so the dashboard query is fighting for the same disk and CPU resources as live user traffic.

At 1 million rows this might complete in 2 seconds. At 10 million rows — 10× the data — you pay 10× the scan cost, 10× the disk I/O, and 10× the memory pressure. 45 seconds is exactly the kind of linear degradation you expect.

---

## The structural mismatch: OLTP vs OLAP

Your Postgres database is an **OLTP** (Online Transaction Processing) system. It is optimized for:
- Writing one row at a time quickly (new signup, new billing event)
- Reading one row at a time quickly (fetch user settings, look up an order)

Your dashboard query is **OLAP** (Online Analytical Processing) work. It needs to:
- Scan millions of rows in a single query
- Touch only a few columns across all those rows
- Aggregate results across the full dataset

These two workloads have opposite requirements. OLTP systems like Postgres store data **row by row** — all columns for a given row are packed together on disk. That layout is perfect for fetching one user's full record. It is inefficient for scanning millions of rows to sum a single column, because the database reads all the columns it does not need just to get to the ones it does.

OLAP systems (like ClickHouse, BigQuery, Snowflake, Redshift) store data **column by column** — all values for `user_id` are stored together, all values for `created_at` are stored together. A query that only needs two columns reads only those two columns from disk, skipping everything else. This can cut disk reads by 60–90% for typical analytical queries. Those systems also compress column data aggressively (repeating event names, sequential timestamps) and process batches of values using CPU-level optimizations, getting dramatically faster at exactly the workload that hurts Postgres.

---

## Why indexes do not fully solve this

You might wonder: can't you just add an index on `(created_at, user_id)` and solve this? A partial index can help filter the 90-day window faster, but it does not remove the aggregation work. Postgres still has to scan every matching row to count them per user. As rows keep growing, the index helps less and less with this shape of query, and the index itself consumes memory that your application queries also need.

---

## What to do about it

Your situation — 10 million rows, a query that used to be fast and is now slow, running on the same Postgres instance as your application — is a textbook signal that you are hitting the OLTP/OLAP boundary.

Near-term options in rough order of effort:

1. **Read replica**: Route dashboard queries to a Postgres read replica so they stop competing with your application for disk I/O. This buys time but does not fix the fundamental scan problem — the query will still be slow, just less damaging to live users.

2. **Materialized view or pre-aggregation**: Run a nightly (or hourly) job that pre-computes the per-user counts and stores the results in a summary table. Your dashboard reads the summary instead of scanning raw events. This works well if near-real-time data is not required.

3. **Dedicated OLAP system**: Move event data to a columnar store (ClickHouse is popular for event analytics; BigQuery or Snowflake if you want managed infrastructure). Your application continues writing to Postgres; events are also streamed or batched into the OLAP system. Dashboard queries run there and finish in seconds even at 100 million rows.

The right choice depends on how real-time your dashboard needs to be, your budget, and your operational capacity — all of which depend on your specific stack (see prod_info.md once it is filled in).

---

## Summary

"Fetch settings for user 123" uses an index to jump to one row — its cost barely changes as the table grows. "Count events per user over 90 days" must scan and read millions of rows — its cost grows linearly with table size. Postgres's row-oriented storage makes this worse because it reads every column of every row even when you only need two. This is not a bug in Postgres; it is a design optimized for OLTP work. Analytical aggregation queries are OLAP work, and at the scale you are at now, they need either a different system or a pre-computation strategy to stay fast.
