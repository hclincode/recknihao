# Iter 290 Questions

## Q1 — Does DATE() or CAST() on a timestamp column break Iceberg partition pruning in Trino?

I've been reading that you should always filter on your partition column directly and avoid wrapping it in functions, because Trino can't push down the filter into the partition scan. But I'm confused about where the line is. Like, my timestamp column `event_at` is what the Iceberg table is partitioned on by day. If I write `WHERE DATE(event_at) = DATE '2026-05-01'` or `WHERE CAST(event_at AS DATE) = DATE '2026-05-01'` — does that actually break partition pruning? I've also seen people use `date_trunc('day', event_at) = ...` and I'm not sure if that's the same thing or worse. We're running Trino against Iceberg tables in MinIO and I really can't tell which of these forms is safe versus which ones are silently doing a full scan.

## Q2 — Why does JOIN order matter in Trino and how do I make sure it picks the right side?

In Postgres I never really thought about JOIN order because the planner figures it out. But I'm running a query in Trino that joins our big `events` Iceberg table (like 400M rows) against a smaller `accounts` table (maybe 50k rows), and someone on the team said "make sure the small table is on the right side of the JOIN." I don't really understand why that matters or what Trino is doing differently from Postgres here. Is Trino loading one of these tables entirely into memory? If so, how does it decide which one? And is there a way for me to see what it's actually doing, or force it to do the right thing if it's choosing wrong?
