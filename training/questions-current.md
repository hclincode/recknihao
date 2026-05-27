# Iter 306 Questions

Date: 2026-05-27
Topics: When Postgres is enough vs OLAP (Q1) + CDC ingestion Debezium→Kafka→Iceberg (Q2)

## Q1 — How do I know if this is a "fix Postgres" problem or "you've outgrown Postgres for analytics"?

Our dashboard runs about 15 analytics queries per page load. Last quarter they were averaging 800ms, now they're hitting 4-6 seconds and we're getting customer complaints. Someone on the team is saying we need to move everything to Snowflake. But I don't want to build a whole new data pipeline if we just need to tune some indexes. How do I actually figure out whether this is a "fix Postgres" problem or a "you've outgrown Postgres for analytics" problem? What should I be looking at?

## Q2 — How does change data capture actually work, and what happens to updates and deletes on the analytics side?

Right now we do a full dump of our Postgres tables every night at 2am and reload them into our analytics system. It's causing noticeable load on our production DB and we're also just getting stale data — customers are complaining their dashboards are 18 hours behind. Someone mentioned something called "change data capture" as a way to stream just the changes over instead of doing full copies. I have no idea how that works. Can you explain what's actually happening under the hood, and specifically, how do deletes and updates get handled on the analytics side — because I assume the analytics copy isn't just a live replica?
