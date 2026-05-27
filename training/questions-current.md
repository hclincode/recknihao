# Iter 291 Questions

## Q1 — Which date/time functions on a timestamp partition column are safe in Trino, and which ones kill performance?

I've read a bunch of conflicting stuff about filtering on timestamp columns in Trino when the table is partitioned by day. Like, some places say `DATE(event_at) = DATE '2026-05-01'` is fine, others say it does a full table scan. Same with `date_trunc('day', event_at)`. And then there are functions like `year(event_at) = 2026` that I think are definitely a problem. Can you just give me a clear breakdown of which patterns are safe versus which ones will scan the whole table? Our table has an `event_at TIMESTAMP(6)` column partitioned by `day(event_at)` in Iceberg, and we're running Trino 467. I want to know what's actually happening under the hood, not just "avoid functions" — because clearly some functions are fine and some aren't.

## Q2 — Is there a way to see how much of my Iceberg table a query will actually read before I run it?

I have a few queries I want to run against a large Iceberg fact table in Trino (maybe 5 TB total, partitioned by day). Before I just fire them off and wait forever, is there a way to estimate how much data they'll actually scan? Like, I want to know if a query is going to read 50 GB or the whole 5 TB before I commit to running it. I know about EXPLAIN, but I'm not sure how to interpret the output for this specific question.
