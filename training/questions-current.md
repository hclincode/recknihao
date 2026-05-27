# Iter 303 Questions

## Q1 — Rolling weekly/monthly active user counts without melting Postgres

We track user activity events in our data warehouse — something like one row per event, with a user_id and a timestamp. To show WAU (weekly active users) and MAU (monthly active users) on our internal ops dashboard, we currently re-scan the full events table for every time window on every page load. It's getting painfully slow as the table grows. I've heard that approximate distinct counts can help, but I'm not sure how to avoid re-scanning all the raw data every time just to count users for a sliding 30-day window. Is there a smarter way to pre-compute something incrementally so we aren't always going back to the full event history?

## Q2 — We had bad data in production last week — can we query what the table looked like before?

We had an incident last week where a bug in our ingestion pipeline wrote incorrect values into one of our Iceberg tables for about 6 hours before we caught it. We've since re-run the correct data, but now I'm trying to understand exactly which rows were affected and what the values looked like before the bad write. Is there a way to query the table as it existed at a specific point in time in the past — like "show me what this table looked like at 2pm on Tuesday"? And if we can do that, how long does that capability stick around before the old data is gone?
