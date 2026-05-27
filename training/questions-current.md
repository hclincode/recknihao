# Iter 297 Questions

## Q1 — Storage keeps growing and old query results seem wrong

We've been writing event data into our data lake for about eight months now. I noticed our storage costs jumped 40% last quarter even though our data volume only grew 15%. Also, a junior engineer ran a report against "historical" data from two months ago and got a different number than the same report we ran at the time. I think something is accumulating in our storage that shouldn't be. Is there a cleanup process we're supposed to be running periodically? And is there a safe order to do it — like, do you delete the data first or do some kind of metadata step first — because I'm nervous about accidentally wiping data that's still in use?

## Q2 — Joining our live Postgres customer table against our analytics data

Right now our analytics data lives in a separate system (we moved our event data off Postgres a few months ago), but almost every dashboard query needs to join against our main Postgres `customers` table to filter by plan tier, signup date, or account region. The way we handle it today is we export a nightly CSV dump of `customers` into the analytics system. That means our joins are always 24 hours stale, and when a customer upgrades their plan mid-day the dashboard shows the wrong tier until tomorrow. Someone mentioned we might be able to query Postgres directly from our analytics engine in the same SQL statement. Is that actually possible, and is it fast enough to be practical, or does it just make everything slow?
