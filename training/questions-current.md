# Iter 317 Questions

Date: 2026-05-27
Topics: Mixed column-masking-uri + batch-column-masking-uri footgun (Q1) + Debezium heartbeat.action.query for low-traffic databases (Q2)

## Q1 — Column masking stopped working after adding batch masking endpoint

We set up Trino with a security policy to mask certain columns in our analytics tables — things like email addresses and API keys — so that different customers only see their own data and sensitive fields are hidden. That's been working fine. But last week we added a new "batch" version of the same masking endpoint because our team heard it was more efficient. Now we're getting reports that some users who were previously seeing masked data are suddenly seeing plain text values instead. We didn't change any policy logic, just added the new endpoint. What could be causing column masking to stop working after adding a second masking endpoint?

## Q2 — Debezium heartbeat not reducing replication slot lag on low-traffic database

We're using Debezium to stream changes from our Postgres database into our data lake. On our high-traffic production database, everything works — we can see events flowing through. But on our analytics staging database, which barely gets any writes (maybe a handful per hour), Debezium seems to fall behind and the lag just keeps growing even though the connector is running and showing as healthy. We added a heartbeat interval config thinking that would help keep things moving, but the lag on the Postgres side doesn't seem to be going down. What's actually happening and what are we missing?
